using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using AppKit;
using Foundation;
using ObjCRuntime;
using WebKit;

namespace RemoteStuff.MacWebHelper;

/// <summary>
/// A native <c>WKNavigationDelegate</c> shim that adds TLS server-trust handling — the one
/// thing the <c>WebView.Avalonia</c> macOS backend's navigation delegate does not implement.
/// Without it, WKWebView rejects any site whose certificate does not chain to a trusted CA
/// (self-signed / private-PKI hosts, routers, local devices reached by IP on odd ports), so
/// the page never loads. Safari and the native Mac app both implement this, which is why such
/// pages work there but not here.
///
/// The backend owns the real navigation delegate (it drives the library's loading/progress
/// callbacks), so we do NOT replace it: this shim wraps it. WKWebView calls this object;
/// every selector except the authentication-challenge one is transparently forwarded to the
/// original delegate via <c>forwardingTargetForSelector:</c>, so all normal navigation keeps
/// working unchanged.
///
/// As with <see cref="JsDialogUIDelegate"/>, the challenge's completion handler is typed as a
/// raw <see cref="IntPtr"/> (the Objective-C block) and invoked by hand — the legacy
/// Xamarin.Mac binding on CoreCLR cannot marshal a completion-handler block into a managed
/// delegate for a method we newly implement.
/// </summary>
public sealed class ServerTrustNavigationDelegate : NSObject
{
    // NSURLSessionAuthChallengeDisposition values.
    private const long UseCredential = 0;
    private const long PerformDefaultHandling = 1;
    private const long CancelAuthenticationChallenge = 2;

    private const string ServerTrustMethod = "NSURLAuthenticationMethodServerTrust";

    // An Objective-C block's invoke function pointer lives at offset 16 on 64-bit.
    private const int BlockInvokeOffset = 16;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void AuthBlockInvoke(IntPtr block, nint disposition, IntPtr credential);

    private static IntPtr BlockInvokePtr(IntPtr block) => Marshal.ReadIntPtr(block, BlockInvokeOffset);

    [DllImport("/System/Library/Frameworks/Security.framework/Security")]
    private static extern bool SecTrustEvaluateWithError(IntPtr trust, out IntPtr error);

    // Hosts the user has chosen to trust for the lifetime of the process, and hosts with a
    // trust prompt currently on screen (so we don't stack duplicate dialogs).
    private static readonly HashSet<string> TrustedHosts = new();
    private static readonly HashSet<string> PromptingHosts = new();

    // The library's original navigation delegate. A strong managed reference keeps it (and its
    // native peer) alive after we take over the WKWebView's weak navigationDelegate outlet.
    private readonly NSObject? _inner;

    public ServerTrustNavigationDelegate(NSObject? inner) => _inner = inner;

    [Export("webView:didReceiveAuthenticationChallenge:completionHandler:")]
    public void DidReceiveAuthenticationChallenge(
        IntPtr webView, IntPtr challengePtr, IntPtr completionHandler)
    {
        long disposition = PerformDefaultHandling;
        NSUrlCredential? credential = null;
        try
        {
            // NOTE: The parameters are declared as raw IntPtr on purpose. The legacy Xamarin.Mac
            // binding running on CoreCLR cannot marshal a strongly-typed NSObject parameter
            // (NSUrlAuthenticationChallenge) for a method we newly [Export] — its custom
            // marshaler throws inside ConvertContentsToManaged and aborts the process. Also,
            // Runtime.GetNSObject can't wrap WebKit's private WKNSURLAuthenticationChallenge proxy
            // (it resolves to NSProxy, which has no NativeHandle constructor). So we force the
            // managed type by constructing NSUrlAuthenticationChallenge directly from the handle;
            // ObjC message forwarding on the proxy answers protectionSpace/serverTrust correctly.
            using var challenge = new NSUrlAuthenticationChallenge(challengePtr);
            var space = challenge.ProtectionSpace;
            if (space is not null && space.AuthenticationMethod == ServerTrustMethod)
            {
                var trust = space.ServerTrust;
                if (trust != IntPtr.Zero)
                {
                    if (SecTrustEvaluateWithError(trust, out _))
                    {
                        // Certificate is already valid — let WebKit's default handling accept it.
                        disposition = PerformDefaultHandling;
                    }
                    else if (ShouldTrust(space.Host ?? string.Empty))
                    {
                        credential = NSUrlCredential.FromTrust(trust);
                        disposition = credential is not null ? UseCredential : CancelAuthenticationChallenge;
                    }
                    else
                    {
                        disposition = CancelAuthenticationChallenge;
                    }
                }
            }
        }
        catch
        {
            disposition = PerformDefaultHandling;
        }
        finally
        {
            var invoke = Marshal.GetDelegateForFunctionPointer<AuthBlockInvoke>(BlockInvokePtr(completionHandler));
            invoke(completionHandler, (nint)disposition, credential?.Handle ?? IntPtr.Zero);
            credential?.Dispose();
        }
    }

    /// <summary>Decide whether to proceed with an untrusted certificate for <paramref name="host"/>,
    /// remembering the answer for the session. Prompts the user once per host (Safari-style).</summary>
    private static bool ShouldTrust(string host)
    {
        if (TrustedHosts.Contains(host)) return true;
        if (PromptingHosts.Contains(host)) return false; // a prompt is already up for this host
        PromptingHosts.Add(host);
        try
        {
            using var alert = new NSAlert
            {
                AlertStyle = NSAlertStyle.Warning,
                MessageText = "This Connection Is Not Private",
                InformativeText =
                    $"The identity of \u201c{host}\u201d cannot be verified. Its certificate is not " +
                    "trusted (it may be self-signed or issued by a private authority). Continue only " +
                    "if you trust this server."
            };
            alert.AddButton("Continue");
            alert.AddButton("Cancel");
            // NSAlertFirstButtonReturn (1000) == "Continue".
            var proceed = alert.RunModal() == 1000;
            if (proceed) TrustedHosts.Add(host);
            return proceed;
        }
        catch
        {
            return false;
        }
        finally
        {
            PromptingHosts.Remove(host);
        }
    }

    // --- Forward every non-authentication selector to the library's real navigation delegate ---

    public override bool RespondsToSelector(Selector? sel)
        => sel is not null && (base.RespondsToSelector(sel) || (_inner?.RespondsToSelector(sel) ?? false));

    [Export("forwardingTargetForSelector:")]
    public NSObject? ForwardingTargetForSelector(Selector sel) => _inner;
}

/// <summary>
/// Reflection entry point used by the main app (which cannot reference Xamarin.Mac types on
/// Windows/Linux). Given the live native WKWebView, wraps its existing navigation delegate with
/// <see cref="ServerTrustNavigationDelegate"/> so untrusted-certificate HTTPS pages can load.
/// </summary>
public static class ServerTrustInstaller
{
    // Strong references so the shims (and, through them, the wrapped delegates) stay alive.
    private static readonly List<ServerTrustNavigationDelegate> Live = new();

    /// <summary>Wrap the given WKWebView's navigation delegate to add server-trust handling.
    /// Returns true on success; safe to call more than once (idempotent per web view).</summary>
    public static bool Install(object webViewObject)
    {
        if (webViewObject is not WKWebView wk) return false;

        // Already wrapped? Then the current delegate is one of ours.
        var current = wk.WeakNavigationDelegate;
        if (current is ServerTrustNavigationDelegate) return true;

        var shim = new ServerTrustNavigationDelegate(current);
        wk.WeakNavigationDelegate = shim;
        Live.Add(shim);
        return true;
    }
}
