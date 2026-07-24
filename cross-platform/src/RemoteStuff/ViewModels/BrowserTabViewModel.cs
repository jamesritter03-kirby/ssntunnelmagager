using System;
using System.Collections.Generic;
using System.Reflection;
using Avalonia.Interactivity;
using Avalonia.Threading;
using AvaloniaWebView;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace RemoteStuff.ViewModels;

/// <summary>
/// An in-app browser tab. The tab view-model owns the live <see cref="WebView"/> so
/// its page and navigation state survive tab switches: the surrounding view is
/// rebuilt whenever the tab is shown, but it re-hosts this same web view instead of
/// creating a new one — exactly how a terminal tab keeps its PTY control (and how the
/// Mac app keeps the WKWebView alive on the model). The view model also carries the
/// address text and a back/forward history it manages itself (the embedded engine
/// exposes no reliable navigation API).
/// </summary>
public sealed partial class BrowserTabViewModel : TabViewModel
{
    public override string Glyph => "\U0001F310";

    /// <summary>The URL loaded when the tab is first shown.</summary>
    public string InitialUrl { get; }

    [ObservableProperty] private string _addressText;

    /// <summary>True while a page is loading (drives the progress indicator).</summary>
    [ObservableProperty] private bool _isLoading;

    public override bool IsBrowserTab => true;

    private WebView? _web;
    private bool _didInitialNavigate;

    private readonly Stack<string> _back = new();
    private readonly Stack<string> _forward = new();
    private string? _currentUrl;
    private bool _suppressHistoryOnce;

    public bool CanGoBack => _back.Count > 0;
    public bool CanGoForward => _forward.Count > 0;

    /// <summary>The live native web view, owned by this tab. Created lazily on first
    /// access (on the UI thread, during view layout) and reused for the tab's whole
    /// lifetime so its running page is not lost when the tab is unmounted.</summary>
    public WebView Web
    {
        get
        {
            if (_web is null)
            {
                _web = new WebView();
                EnableDeveloperTools(_web);
                _web.NavigationStarting += OnNavigationStarting;
                _web.NavigationCompleted += OnNavigationCompleted;
                _web.Loaded += OnWebLoaded;
            }
            return _web;
        }
    }

    public BrowserTabViewModel(string url, string? title = null)
    {
        InitialUrl = Normalize(url);
        _addressText = InitialUrl;
        _currentUrl = InitialUrl;
        Title = string.IsNullOrWhiteSpace(title) ? "Browser" : title!;
    }

    public override RemoteStuff.Services.TabSnapshot? CreateSnapshot() => new RemoteStuff.Services.TabSnapshot
    {
        Kind = "browser",
        Title = Title,
        Url = string.IsNullOrWhiteSpace(_currentUrl) ? AddressText : _currentUrl
    };

    private void OnWebLoaded(object? sender, RoutedEventArgs e)
    {
        if (_web is null) return;
        var have = _web.Url?.ToString();
        var blank = string.IsNullOrEmpty(have) || have == "about:blank";

        if (!_didInitialNavigate)
        {
            _didInitialNavigate = true;
            NavigateTo(_currentUrl ?? InitialUrl);
        }
        else if (blank && !string.IsNullOrWhiteSpace(_currentUrl) && _currentUrl != "about:blank")
        {
            // The tab was unmounted and the native view came back empty; restore the
            // page the user was on so switching tabs "remembers where it was".
            NavigateTo(_currentUrl);
        }

        // The native view has just attached. A freshly-realized WKWebView (notably a
        // second one created by "Duplicate Tab" while sibling web views are mounted) is
        // often born with an unattached surface that paints black. OnCellVisibilityChanged
        // can fire before this control exists (so its nudge no-ops on a null _web); nudging
        // here guarantees the repaint happens once the view is actually created and attached.
        if (IsCellVisible) NudgeRepaint();
    }

    /// <summary>When our center cell is shown again, the platform may have torn down the
    /// native web view while it was hidden (leaving it blank on return). Restore the page
    /// the user was on, but only when the native view has actually lost its content so we
    /// don't needlessly reload (and lose scroll position) on every tab switch.</summary>
    protected override void OnCellVisibilityChanged(bool visible)
    {
        if (!visible || _web is null) return;
        // Deferred so the native control has been re-created by layout before we inspect it.
        Dispatcher.UIThread.Post(() =>
        {
            if (_didInitialNavigate) RestorePageIfBlank();
            // A newly-realized WKWebView (e.g. a second browser tab from "Duplicate Tab")
            // is sometimes born with an unattached surface that paints black; a tiny layout
            // change forces the native host to re-attach and repaint it.
            NudgeRepaint();
        }, DispatcherPriority.Background);
    }

    /// <summary>Force the native web view to re-attach/repaint by momentarily changing its
    /// layout. Works around the macOS backend painting a freshly-created second WKWebView
    /// black until something invalidates its surface.</summary>
    private void NudgeRepaint()
    {
        if (_web is null) return;
        var original = _web.Margin;
        _web.Margin = new Avalonia.Thickness(original.Left, original.Top, original.Right, original.Bottom + 1);
        Dispatcher.UIThread.Post(() =>
        {
            if (_web is not null) _web.Margin = original;
        }, DispatcherPriority.Background);
    }

    private void RestorePageIfBlank()
    {
        if (_web is null || NativeViewHasPage()) return;
        var target = string.IsNullOrWhiteSpace(_currentUrl) ? InitialUrl : _currentUrl;
        if (!string.IsNullOrWhiteSpace(target) && target != "about:blank")
            NavigateTo(target);
    }

    /// <summary>True when the native WKWebView currently holds a real page. On backends
    /// where we can't inspect the native view we assume it kept its page (return true) so
    /// we never reload unnecessarily.</summary>
    private bool NativeViewHasPage()
    {
        if (_web is null) return true;
        try
        {
            var wk = FindNativeWebView(_web, 0, new HashSet<object>());
            if (wk is null) return false; // native view was torn down → blank
            var nsStringT = wk.GetType().Assembly.GetType("Foundation.NSString");
            if (nsStringT is null) return true;
            var valueForKey = wk.GetType().GetMethod("ValueForKey", new[] { nsStringT });
            var urlObj = valueForKey?.Invoke(wk, new[] { Activator.CreateInstance(nsStringT, "URL")! });
            var s = urlObj?.ToString();
            return !string.IsNullOrWhiteSpace(s) && s != "about:blank";
        }
        catch { return true; }
    }

    [RelayCommand]
    private void Navigate()
    {
        var target = Normalize(AddressText);
        OnNavigated(target, null);
        NavigateTo(target);
    }

    [RelayCommand(CanExecute = nameof(CanGoBack))]
    private void GoBack()
    {
        if (_back.Count == 0) return;
        if (_currentUrl is { } cur) _forward.Push(cur);
        var url = _back.Pop();
        _currentUrl = url;
        AddressText = url;
        _suppressHistoryOnce = true;
        NavigateTo(url);
        RaiseHistoryChanged();
    }

    [RelayCommand(CanExecute = nameof(CanGoForward))]
    private void GoForward()
    {
        if (_forward.Count == 0) return;
        if (_currentUrl is { } cur) _back.Push(cur);
        var url = _forward.Pop();
        _currentUrl = url;
        AddressText = url;
        _suppressHistoryOnce = true;
        NavigateTo(url);
        RaiseHistoryChanged();
    }

    [RelayCommand]
    private void Stop()
    {
        try { _web?.Stop(); } catch { /* not all backends support stop */ }
    }

    [RelayCommand]
    private void Reload()
    {
        // Re-assigning Url reloads the page (the control has no Reload on all backends).
        if (_web?.Url is { } current)
            _web.Url = current;
    }

    [RelayCommand]
    private void OpenDevTools()
    {
        // On Windows/WebView2 this pops the DevTools window directly. On macOS the
        // library's OpenDevToolsWindow is a no-op, so reach the native WKWebView and
        // open its Web Inspector ourselves (developer extras were enabled at creation).
        if (TryOpenNativeInspector()) return;
        try { _web?.OpenDevToolsWindow(); } catch { /* backend without dev tools */ }
    }

    /// <summary>
    /// Turn on the WebView's developer extras before it attaches to the visual tree.
    /// The control copies <c>AreDevToolEnabled</c> from its (DI-resolved) creation
    /// properties when it is attached and creates the native view; on macOS this maps
    /// to the WKWebView <c>developerExtrasEnabled</c> preference, which is what makes
    /// the Web Inspector (and the right-click ▸ Inspect Element item) available at all.
    /// Reflection is used because the property is not surfaced on the public control.
    /// </summary>
    private static void EnableDeveloperTools(WebView web)
    {
        try
        {
            var field = typeof(WebView).GetField("_creationProperties",
                BindingFlags.NonPublic | BindingFlags.Instance);
            if (field?.GetValue(web) is { } props)
            {
                var t = props.GetType();
                t.GetProperty("AreDevToolEnabled")?.SetValue(props, true);
                t.GetProperty("AreDefaultContextMenusEnabled")?.SetValue(props, true);
            }
        }
        catch { /* best effort — dev tools simply stay off if the internals change */ }
    }

    private bool _markedInspectable;

    /// <summary>
    /// Mark the native WKWebView <c>inspectable</c> (macOS 13.3+ / Safari 16.4+) so the
    /// right-click ▸ Inspect Element context item opens the Web Inspector. Runs once the
    /// native view exists (after the first navigation completes); idempotent and fully
    /// guarded so it is a no-op on Windows/Linux or if the internals change.
    /// </summary>
    private void MarkNativeInspectable()
    {
        if (_markedInspectable || _web is null) return;
        try
        {
            var wk = FindNativeWebView(_web, 0, new HashSet<object>());
            if (wk is null) return;

            var asm = wk.GetType().Assembly;
            var nsStringT = asm.GetType("Foundation.NSString");
            var nsObjectT = asm.GetType("Foundation.NSObject");
            var nsNumberT = asm.GetType("Foundation.NSNumber");
            if (nsStringT is null || nsObjectT is null || nsNumberT is null) return;

            var setValueForKey = wk.GetType().GetMethod("SetValueForKey", new[] { nsObjectT, nsStringT });
            var trueNum = nsNumberT.GetMethod("FromBoolean", new[] { typeof(bool) })?
                .Invoke(null, new object[] { true });
            if (setValueForKey is null || trueNum is null) return;

            setValueForKey.Invoke(wk, new[] { trueNum, Activator.CreateInstance(nsStringT, "inspectable")! });
            _markedInspectable = true;
        }
        catch { /* best effort */ }
    }

    /// <summary>
    /// Best-effort programmatic open of the macOS Web Inspector by walking to the
    /// native WKWebView and, via key-value coding, marking it inspectable and asking
    /// its private inspector to show. Fully guarded: any failure falls back to the
    /// library call (and the user can still use right-click ▸ Inspect Element).
    /// </summary>
    private bool TryOpenNativeInspector()    {
        if (_web is null) return false;
        try
        {
            var wk = FindNativeWebView(_web, 0, new HashSet<object>());
            if (wk is null) return false;

            var asm = wk.GetType().Assembly;
            var nsStringT = asm.GetType("Foundation.NSString");
            var nsObjectT = asm.GetType("Foundation.NSObject");
            var nsNumberT = asm.GetType("Foundation.NSNumber");
            var selectorT = asm.GetType("ObjCRuntime.Selector");
            if (nsStringT is null || nsObjectT is null || nsNumberT is null || selectorT is null)
                return false;

            object NsString(string s) => Activator.CreateInstance(nsStringT, s)!;

            // WKWebView.setValue(true, forKey: "inspectable") — required on macOS 13.3+.
            var setValueForKey = wk.GetType().GetMethod("SetValueForKey", new[] { nsObjectT, nsStringT });
            var trueNum = nsNumberT.GetMethod("FromBoolean", new[] { typeof(bool) })?.Invoke(null, new object[] { true });
            if (setValueForKey is not null && trueNum is not null)
            {
                try { setValueForKey.Invoke(wk, new[] { trueNum, NsString("inspectable") }); } catch { }
            }

            // Grab the private inspector and tell it to show.
            var valueForKey = wk.GetType().GetMethod("ValueForKey", new[] { nsStringT });
            var inspector = valueForKey?.Invoke(wk, new[] { NsString("_inspector") });
            if (inspector is null) return false;

            var selector = Activator.CreateInstance(selectorT, "show:");
            var perform = inspector.GetType().GetMethod("PerformSelector", new[] { selectorT });
            if (perform is null || selector is null) return false;
            perform.Invoke(inspector, new[] { selector });
            return true;
        }
        catch { return false; }
    }

    /// <summary>Recursively search the control's object graph for the native WKWebView.</summary>
    private static object? FindNativeWebView(object root, int depth, HashSet<object> seen)
    {
        if (root is null || depth > 5 || !seen.Add(root)) return null;
        var type = root.GetType();
        if (type.FullName is { } fn && fn.Contains("WKWebView", StringComparison.Ordinal))
            return root;

        const BindingFlags flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;
        foreach (var f in type.GetFields(flags))
        {
            if (!ShouldFollow(f.FieldType)) continue;
            object? child;
            try { child = f.GetValue(root); } catch { continue; }
            if (child is null) continue;
            var found = FindNativeWebView(child, depth + 1, seen);
            if (found is not null) return found;
        }
        foreach (var p in type.GetProperties(flags))
        {
            if (p.GetIndexParameters().Length != 0 || !p.CanRead || !ShouldFollow(p.PropertyType)) continue;
            object? child;
            try { child = p.GetValue(root); } catch { continue; }
            if (child is null) continue;
            var found = FindNativeWebView(child, depth + 1, seen);
            if (found is not null) return found;
        }
        return null;

        static bool ShouldFollow(Type t)
        {
            if (t.IsPrimitive || t.IsEnum || t == typeof(string) || t == typeof(object)) return false;
            var ns = t.Namespace ?? "";
            var name = t.FullName ?? "";
            return name.Contains("WKWebView", StringComparison.Ordinal)
                || ns.StartsWith("Avalonia", StringComparison.Ordinal)
                || ns.StartsWith("WebViewCore", StringComparison.Ordinal)
                || ns.StartsWith("WebView", StringComparison.Ordinal);
        }
    }

    private void NavigateTo(string url)
    {
        if (_web is null) return;
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
            _web.Url = uri;
    }

    private void OnNavigationStarting(object? sender, EventArgs e)
        => Dispatcher.UIThread.Post(() => IsLoading = true);

    private void OnNavigationCompleted(object? sender, EventArgs e)
        => Dispatcher.UIThread.Post(() =>
        {
            IsLoading = false;
            // By now the native WKWebView exists — make sure it is inspectable so the
            // right-click ▸ Inspect Element item actually opens the Web Inspector
            // (required on macOS 13.3+ in addition to developerExtrasEnabled).
            MarkNativeInspectable();
            if (_web?.Url is { } uri)
                OnNavigated(uri.ToString(), TitleFor(uri));
            // A second browser tab's freshly-created WKWebView can paint black until its
            // surface is invalidated; nudge the layout once the first page has loaded.
            NudgeRepaint();
        });

    /// <summary>Pick a tab title for the page: the document's own &lt;title&gt; when the
    /// native view exposes one, otherwise the URL's host (or the full URL as a last
    /// resort) so the tab shows the page it is viewing instead of just "Browser".</summary>
    private string TitleFor(Uri uri)
    {
        var docTitle = TryGetNativeTitle();
        if (!string.IsNullOrWhiteSpace(docTitle)) return docTitle!;
        return string.IsNullOrEmpty(uri.Host) ? uri.ToString() : uri.Host;
    }

    /// <summary>Read the live document title from the native WKWebView via key-value
    /// coding (macOS). Guarded; returns null on other platforms or on any failure.</summary>
    private string? TryGetNativeTitle()
    {
        if (_web is null) return null;
        try
        {
            var wk = FindNativeWebView(_web, 0, new HashSet<object>());
            if (wk is null) return null;
            var asm = wk.GetType().Assembly;
            var nsStringT = asm.GetType("Foundation.NSString");
            if (nsStringT is null) return null;
            var valueForKey = wk.GetType().GetMethod("ValueForKey", new[] { nsStringT });
            var titleObj = valueForKey?.Invoke(wk, new[] { Activator.CreateInstance(nsStringT, "title")! });
            var s = titleObj?.ToString();
            return string.IsNullOrWhiteSpace(s) ? null : s;
        }
        catch { return null; }
    }

    /// <summary>Update the address bar / tab title / history when the page navigates.</summary>
    public void OnNavigated(string url, string? pageTitle)
    {
        if (_suppressHistoryOnce)
        {
            _suppressHistoryOnce = false;
        }
        else if (_currentUrl is { } cur && cur != url)
        {
            _back.Push(cur);
            _forward.Clear();
        }

        _currentUrl = url;
        AddressText = url;
        if (!string.IsNullOrWhiteSpace(pageTitle))
            Title = pageTitle!;
        RaiseHistoryChanged();
    }

    private void RaiseHistoryChanged()
    {
        OnPropertyChanged(nameof(CanGoBack));
        OnPropertyChanged(nameof(CanGoForward));
        GoBackCommand.NotifyCanExecuteChanged();
        GoForwardCommand.NotifyCanExecuteChanged();
    }

    public override void Dispose()
    {
        if (_web is not null)
        {
            _web.NavigationStarting -= OnNavigationStarting;
            _web.NavigationCompleted -= OnNavigationCompleted;
            _web.Loaded -= OnWebLoaded;
            _web = null;
        }
    }

    private static string Normalize(string? text)
    {
        var t = (text ?? "").Trim();
        if (t.Length == 0) return "about:blank";
        if (t.Contains("://")) return t;
        // A bare token with a dot (or localhost) is treated as a host; else search.
        if (t.Contains(' ') || (!t.Contains('.') && !t.StartsWith("localhost")))
            return "https://duckduckgo.com/?q=" + Uri.EscapeDataString(t);
        return "https://" + t;
    }
}
