using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using AppKit;
using CoreGraphics;
using Foundation;
using ObjCRuntime;
using WebKit;

namespace RemoteStuff.MacWebHelper;

/// <summary>
/// A native WebKit UI delegate that renders JavaScript <c>alert()</c>, <c>confirm()</c>
/// and <c>prompt()</c> dialogs with <see cref="NSAlert"/> — exactly like Safari.
///
/// The <c>WebView.Avalonia</c> macOS backend (<c>Avalonia.WebView.MacCatalyst</c>) ships a
/// UI delegate whose JavaScript-panel overrides are empty, so WKWebView silently drops these
/// dialogs (they work in Safari, which implements them).
///
/// IMPORTANT: we do NOT subclass <c>WKUIDelegate</c> and override its strongly-typed methods.
/// This legacy Xamarin.Mac binding, running on CoreCLR, cannot build the reverse-callback
/// thunk that marshals the WebKit completion-handler *block* into a managed
/// <c>Action&lt;bool&gt;</c>/<c>Action&lt;string&gt;</c> — doing so aborts the process the moment
/// WebKit invokes the method. Instead this is a plain <see cref="NSObject"/> that
/// <c>[Export]</c>s the delegate selectors with the completion handler typed as a raw
/// <see cref="IntPtr"/> (the Objective-C block), which we invoke by hand. That avoids the
/// delegate trampoline entirely. It is assigned as the web view's weak UI delegate.
/// </summary>
public sealed class JsDialogUIDelegate : NSObject
{
    // NSAlertFirstButtonReturn — the first button added to the alert ("OK").
    private const long FirstButton = 1000;

    // An Objective-C block's function pointer lives at offset 16 in its layout on 64-bit:
    //   { void* isa; int32 flags; int32 reserved; void(*invoke)(void*, ...); void* descriptor; }
    private const int BlockInvokeOffset = 16;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void VoidBlockInvoke(IntPtr block);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void BoolBlockInvoke(IntPtr block, byte value);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void PtrBlockInvoke(IntPtr block, IntPtr value);

    private static IntPtr BlockInvokePtr(IntPtr block) => Marshal.ReadIntPtr(block, BlockInvokeOffset);

    [Export("webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:")]
    public void RunJavaScriptAlert(WKWebView webView, NSString message, WKFrameInfo frame, IntPtr completionHandler)
    {
        try
        {
            var alert = MakeAlert(frame, message);
            alert.AddButton("OK");
            RunModal(alert, webView);
        }
        catch { /* never leave the page hanging */ }
        finally
        {
            var invoke = Marshal.GetDelegateForFunctionPointer<VoidBlockInvoke>(BlockInvokePtr(completionHandler));
            invoke(completionHandler);
        }
    }

    [Export("webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:")]
    public void RunJavaScriptConfirm(WKWebView webView, NSString message, WKFrameInfo frame, IntPtr completionHandler)
    {
        bool ok = false;
        try
        {
            var alert = MakeAlert(frame, message);
            alert.AddButton("OK");
            alert.AddButton("Cancel");
            ok = RunModal(alert, webView) == FirstButton;
        }
        catch { ok = false; }
        finally
        {
            var invoke = Marshal.GetDelegateForFunctionPointer<BoolBlockInvoke>(BlockInvokePtr(completionHandler));
            invoke(completionHandler, (byte)(ok ? 1 : 0));
        }
    }

    [Export("webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:")]
    public void RunJavaScriptTextInput(
        WKWebView webView, NSString prompt, NSString defaultText, WKFrameInfo frame, IntPtr completionHandler)
    {
        // prompt() yields null to JavaScript when the user cancels.
        NSString? result = null;
        try
        {
            var alert = MakeAlert(frame, prompt);
            alert.AddButton("OK");
            alert.AddButton("Cancel");

            var input = new NSTextField(new CGRect(0, 0, 260, 24))
            {
                StringValue = defaultText?.ToString() ?? string.Empty
            };
            alert.AccessoryView = input;

            if (RunModal(alert, webView) == FirstButton)
                result = new NSString(input.StringValue ?? string.Empty);
        }
        catch { result = null; }
        finally
        {
            var invoke = Marshal.GetDelegateForFunctionPointer<PtrBlockInvoke>(BlockInvokePtr(completionHandler));
            invoke(completionHandler, result?.Handle ?? IntPtr.Zero);
            result?.Dispose();
        }
    }

    private static NSAlert MakeAlert(WKFrameInfo frame, NSString? body) => new NSAlert
    {
        MessageText = TitleFor(frame),
        InformativeText = body?.ToString() ?? string.Empty
    };

    private static long RunModal(NSAlert alert, WKWebView webView)
    {
        // Prefer a document-modal sheet attached to the page's own window (matches Safari and
        // the Mac app); fall back to an app-modal dialog if the window is unavailable.
        var window = webView?.Window;
        return window is not null ? alert.RunSheetModal(window) : alert.RunModal();
    }

    private static string TitleFor(WKFrameInfo frame)
    {
        try
        {
            var host = frame?.Request?.Url?.Host;
            if (!string.IsNullOrEmpty(host))
                return $"\u201c{host}\u201d says:";
        }
        catch { /* fall through */ }
        return "This page says:";
    }
}

/// <summary>
/// Reflection entry point used by the main app (which cannot reference Xamarin.Mac types
/// directly because they are absent on Windows/Linux). Given the live native WKWebView,
/// installs <see cref="JsDialogUIDelegate"/> as its weak UI delegate.
/// </summary>
public static class JsDialogInstaller
{
    // A strong reference so the delegate is not collected while the WKWebView uses it
    // (the web view holds only a weak reference to its UI delegate).
    private static readonly List<JsDialogUIDelegate> Live = new();

    /// <summary>Attach the native JS-dialog delegate to the given WKWebView. Returns true
    /// on success; safe to call more than once (re-attaches idempotently).</summary>
    public static bool Install(object webViewObject)
    {
        if (webViewObject is not WKWebView wk) return false;

        var del = new JsDialogUIDelegate();
        wk.WeakUIDelegate = del;
        Live.Add(del);
        return true;
    }
}
