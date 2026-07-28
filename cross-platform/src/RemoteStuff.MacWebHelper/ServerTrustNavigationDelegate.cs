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

    // Objective-C block lifetime + CoreFoundation refcounting, so a deferred (asynchronous)
    // trust prompt can keep the WebKit completion block and the SecTrust alive until the user
    // answers — without blocking the WebKit callback (which would spin a nested run loop and
    // wedge Avalonia's native compositor, blanking every web view).
    [DllImport("/usr/lib/libSystem.dylib", EntryPoint = "_Block_copy")]
    private static extern IntPtr BlockCopy(IntPtr block);
    [DllImport("/usr/lib/libSystem.dylib", EntryPoint = "_Block_release")]
    private static extern void BlockRelease(IntPtr block);
    [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
    private static extern IntPtr CFRetain(IntPtr cf);
    [DllImport("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")]
    private static extern void CFRelease(IntPtr cf);

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

            // Not a TLS server-trust challenge (e.g. HTTP auth) — let WebKit handle it.
            if (space is null || space.AuthenticationMethod != ServerTrustMethod)
            {
                Complete(completionHandler, PerformDefaultHandling, IntPtr.Zero);
                return;
            }

            var trust = space.ServerTrust;
            if (trust == IntPtr.Zero)
            {
                Complete(completionHandler, PerformDefaultHandling, IntPtr.Zero);
                return;
            }

            // The certificate already chains to a trusted CA — default handling accepts it.
            if (SecTrustEvaluateWithError(trust, out _))
            {
                Complete(completionHandler, PerformDefaultHandling, IntPtr.Zero);
                return;
            }

            var host = space.Host ?? string.Empty;

            // Previously confirmed for this session — accept immediately, no prompt.
            if (TrustedHosts.Contains(host))
            {
                AcceptWithCredential(completionHandler, trust);
                return;
            }

            // A prompt for this host is already on screen — cancel this extra challenge so we
            // don't stack duplicate dialogs.
            if (!PromptingHosts.Add(host))
            {
                Complete(completionHandler, CancelAuthenticationChallenge, IntPtr.Zero);
                return;
            }

            // Unknown untrusted host: ask the user, but do NOT block here. Blocking the WebKit
            // callback with a modal run loop freezes Avalonia's render loop and blanks every web
            // view. Instead retain the completion block + the trust, return now, and present the
            // alert on the next main-run-loop turn; answer the challenge from the alert handler.
            var savedBlock = BlockCopy(completionHandler);
            CFRetain(trust);
            BeginInvokeOnMainThread(() =>
            {
                long disposition = CancelAuthenticationChallenge;
                NSUrlCredential? credential = null;
                try
                {
                    if (PromptTrust(host))
                    {
                        TrustedHosts.Add(host);
                        credential = NSUrlCredential.FromTrust(trust);
                        if (credential is not null) disposition = UseCredential;
                    }
                }
                catch
                {
                    disposition = CancelAuthenticationChallenge;
                }
                finally
                {
                    PromptingHosts.Remove(host);
                    Complete(savedBlock, disposition, credential?.Handle ?? IntPtr.Zero);
                    credential?.Dispose();
                    CFRelease(trust);
                    BlockRelease(savedBlock);
                }
            });
        }
        catch
        {
            Complete(completionHandler, PerformDefaultHandling, IntPtr.Zero);
        }
    }

    /// <summary>Invoke the WebKit completion block with a disposition + optional credential.</summary>
    private static void Complete(IntPtr block, long disposition, IntPtr credential)
    {
        var invoke = Marshal.GetDelegateForFunctionPointer<AuthBlockInvoke>(BlockInvokePtr(block));
        invoke(block, (nint)disposition, credential);
    }

    /// <summary>Accept the connection by forming a credential from the server trust.</summary>
    private static void AcceptWithCredential(IntPtr block, IntPtr trust)
    {
        NSUrlCredential? credential = null;
        try { credential = NSUrlCredential.FromTrust(trust); } catch { /* fall through to cancel */ }
        if (credential is not null)
        {
            Complete(block, UseCredential, credential.Handle);
            credential.Dispose();
        }
        else
        {
            Complete(block, CancelAuthenticationChallenge, IntPtr.Zero);
        }
    }

    /// <summary>Prompt the user (Safari-style) whether to proceed with an untrusted certificate
    /// for <paramref name="host"/>. Must run on the main thread. Returns true to proceed.</summary>
    private static bool PromptTrust(string host)
    {
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
            return alert.RunModal() == 1000;
        }
        catch
        {
            return false;
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
