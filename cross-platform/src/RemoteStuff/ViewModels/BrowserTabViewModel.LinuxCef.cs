#if LINUX_CEF
using System;
using System.IO;
using Avalonia.Threading;
using Xilium.CefGlue;
using Xilium.CefGlue.Common;
using Xilium.CefGlue.Common.Events;
using Xilium.CefGlue.Common.Shared;
using Xilium.CefGlue.Avalonia;

namespace RemoteStuff.ViewModels;

/// <summary>
/// Linux-only Chromium runtime, embedded via CefGlue. WebView.Avalonia has no Linux
/// backend (its engines are Windows/macOS only), so the in-app browser uses CEF here.
/// Initialized once from <c>Program.BuildAvaloniaApp().AfterSetup(...)</c>, before any
/// browser tab is created; <see cref="Available"/> stays false if init throws so the
/// browser tab falls back to the "open in system browser" panel instead of crashing.
/// </summary>
internal static class LinuxCef
{
    private static readonly object Gate = new();
    private static bool _tried;

    /// <summary>True once CEF has initialized successfully; browser tabs only embed a
    /// live view when this is set.</summary>
    public static bool Available { get; private set; }

    public static void Initialize()
    {
        lock (Gate)
        {
            if (_tried) return;
            _tried = true;
            try
            {
                // A per-launch cache dir avoids "profile in use" errors and lets us clean up on exit.
                var cachePath = Path.Combine(Path.GetTempPath(),
                    "RemoteStuffCef_" + Guid.NewGuid().ToString("N"));
                CefRuntimeLoader.Initialize(new CefSettings
                {
                    RootCachePath = cachePath,
                    WindowlessRenderingEnabled = false,
                });
                AppDomain.CurrentDomain.ProcessExit += (_, _) =>
                {
                    try { CefRuntime.Shutdown(); } catch { /* best effort */ }
                    try { if (Directory.Exists(cachePath)) Directory.Delete(cachePath, true); }
                    catch { /* best effort */ }
                };
                Available = true;
            }
            catch
            {
                // CEF failed to load (missing libcef, arm64 TLS issue, etc.); the browser
                // tab shows its system-browser fallback instead.
                Available = false;
            }
        }
    }
}

public sealed partial class BrowserTabViewModel
{
    private AvaloniaCefBrowser? _cef;

    /// <summary>Create (once) and return the embedded CEF browser this tab hosts. Reused
    /// for the tab's lifetime so its page survives tab switches, mirroring the WebView path.</summary>
    private object CreateLinuxBrowser()
    {
        if (_cef is null)
        {
            _cef = new AvaloniaCefBrowser();
            _cef.LoadStart += OnCefLoadStart;
            _cef.LoadEnd += OnCefLoadEnd;
            _cef.TitleChanged += OnCefTitleChanged;
            _cef.Address = _currentUrl ?? InitialUrl;
        }
        return _cef;
    }

    private void LinuxNavigateTo(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out _)) return;
        Dispatcher.UIThread.Post(() => { if (_cef is not null) _cef.Address = url; });
    }

    private void LinuxReload() => _cef?.Reload();
    // CefGlue exposes no public stop-load; loads are fast, so Stop is a no-op on Linux.
    private void LinuxStop() { }
    private void LinuxOpenDevTools() => _cef?.ShowDeveloperTools();

    // CEF raises these off a browser thread; marshal every VM/UI mutation to the UI thread.
    private void OnCefLoadStart(object? sender, LoadStartEventArgs e)
    {
        if (!e.Frame.IsMain || e.Frame.Browser.IsPopup) return;
        var url = e.Frame.Url;
        Dispatcher.UIThread.Post(() =>
        {
            IsLoading = true;
            if (!string.IsNullOrWhiteSpace(url)) OnNavigated(url, null);
        });
    }

    private void OnCefLoadEnd(object? sender, LoadEndEventArgs e)
    {
        if (!e.Frame.IsMain || e.Frame.Browser.IsPopup) return;
        Dispatcher.UIThread.Post(() => IsLoading = false);
    }

    private void OnCefTitleChanged(object? sender, string title)
    {
        if (string.IsNullOrWhiteSpace(title)) return;
        Dispatcher.UIThread.Post(() => Title = title);
    }

    private void DisposePlatformBrowserImpl()
    {
        if (_cef is null) return;
        _cef.LoadStart -= OnCefLoadStart;
        _cef.LoadEnd -= OnCefLoadEnd;
        _cef.TitleChanged -= OnCefTitleChanged;
        try { _cef.Dispose(); } catch { /* best effort */ }
        _cef = null;
    }
}
#endif
