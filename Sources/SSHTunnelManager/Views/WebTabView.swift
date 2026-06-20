import SwiftUI
import AppKit
import WebKit
import Network

/// A SOCKS proxy endpoint a web tab should route through. Derived from a
/// profile's dynamic (`-D`) port forward so the in-app browser reaches hosts as
/// if it were the server.
struct WebProxy: Equatable {
    let host: String
    let port: Int
}

/// Drives a single in-app browser tab: holds the navigation state and a weak
/// reference to the live `WKWebView` so the toolbar can drive it.
final class WebTabModel: ObservableObject {
    /// The address-bar text (user-editable).
    @Published var addressText: String = ""
    /// The current committed URL string (used for the session snapshot / resume).
    @Published private(set) var currentURLString: String = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0

    /// The URL loaded when the web view is first created.
    let initialURL: URL?

    /// A SOCKS proxy to route through (from the profile's `-D` forward), if any.
    let proxy: WebProxy?

    /// Fires when the page title changes (wired to the owning tab's title).
    var onTitleChange: ((String) -> Void)?

    /// The web view, owned strongly and built once. Holding it on the model (not
    /// the SwiftUI view) means the page keeps running when the tab is unmounted —
    /// e.g. when you switch to another workspace — so it doesn't reload on return,
    /// exactly like a terminal tab keeps its process alive.
    private(set) lazy var webView: WKWebView = makeWebView()

    /// The delegate / KVO controller for `webView`. Owned here so it lives as long
    /// as the model (a `WKWebView` only holds its delegates weakly).
    private var navigator: WebNavigator?

    init(initialURL: URL?, proxy: WebProxy? = nil) {
        self.initialURL = initialURL
        self.proxy = proxy
        if let initialURL {
            currentURLString = initialURL.absoluteString
            addressText = initialURL.absoluteString
        }
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore(for: proxy)
        // Enable WebKit's developer tools (the same Web Inspector Safari uses) so
        // the tab can open it with F12 / ⌥⌘I. `developerExtrasEnabled` also adds
        // "Inspect Element" to the right-click menu and covers macOS 13.0–13.2.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Some pages cancel the `contextmenu` event to hide the browser menu.
        // Re-enable it so the developer right-click menu is always available: a
        // capture-phase listener added at document start runs before the page's
        // own handlers and stops their propagation, so WebKit shows its native
        // menu (which `InspectableWebView.willOpenMenu` then augments).
        let restoreContextMenu = WKUserScript(
            source: """
            (function() {
              window.addEventListener('contextmenu', function(e) {
                e.stopImmediatePropagation();
              }, true);
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false)
        config.userContentController.addUserScript(restoreContextMenu)
        let wv = InspectableWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        let nav = WebNavigator(model: self)
        wv.navigationDelegate = nav
        wv.uiDelegate = nav
        nav.observe(wv)
        navigator = nav
        if let initialURL { wv.load(URLRequest(url: initialURL)) }
        return wv
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    /// Navigate to whatever is currently typed in the address bar.
    func submitAddress() { load(addressText) }

    /// Load a string, adding a scheme if the user omitted one.
    func load(_ string: String) {
        guard let url = ProfileLink(label: "", url: string).normalizedURL else { return }
        addressText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    /// Hand the current page off to the user's default browser.
    func openInDefaultBrowser() {
        if let url = webView.url ?? initialURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// Open (or close) WebKit's Web Inspector for this tab — the developer tools
    /// shown by F12 / ⌥⌘I, the same inspector Safari uses.
    func toggleWebInspector() {
        (webView as? InspectableWebView)?.toggleInspector()
    }

    /// A data store configured to route through `proxy` when set (a profile's
    /// SOCKS forward). Proxying needs macOS 14+; on older systems we fall back to
    /// the default store (so `-L` localhost forwards still work).
    private static func dataStore(for proxy: WebProxy?) -> WKWebsiteDataStore {
        guard let proxy else { return .default() }
        if #available(macOS 14.0, *),
           let portValue = UInt16(exactly: proxy.port),
           let port = NWEndpoint.Port(rawValue: portValue) {
            let store = WKWebsiteDataStore.nonPersistent()
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.host), port: port)
            store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
            return store
        }
        return .default()
    }

    /// The local TCP endpoint that must accept connections before this tab's page
    /// can load: a profile's SOCKS proxy port, or — for a plain `-L` forward — the
    /// localhost port the target URL uses. `nil` for ordinary internet tabs that
    /// don't depend on a tunnel (those retry on a short timer instead).
    func tunnelGate() -> NWEndpoint? {
        if let proxy, let raw = UInt16(exactly: proxy.port),
           let port = NWEndpoint.Port(rawValue: raw) {
            return .hostPort(host: NWEndpoint.Host(proxy.host), port: port)
        }
        guard let url = webView.url ?? initialURL, let host = url.host,
              ["localhost", "127.0.0.1", "::1"].contains(host) else { return nil }
        let portNumber = url.port ?? (url.scheme == "https" ? 443 : 80)
        guard let raw = UInt16(exactly: portNumber),
              let port = NWEndpoint.Port(rawValue: raw) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: port)
    }

    /// Called by the coordinator whenever the web view's observed state changes.
    func sync(url: URL?, title: String?, back: Bool, forward: Bool, loading: Bool, progress: Double) {
        if let url {
            currentURLString = url.absoluteString
            addressText = url.absoluteString
        }
        canGoBack = back
        canGoForward = forward
        isLoading = loading
        self.progress = progress
        if let title { onTitleChange?(title) }
    }
}

/// SwiftUI wrapper that hosts the model's long-lived `WKWebView`. Returning the
/// same web view across mount / unmount (instead of building a new one) is what
/// keeps the page from reloading when the tab leaves and re-enters the view tree
/// — e.g. when switching workspaces.
struct WebView: NSViewRepresentable {
    @ObservedObject var model: WebTabModel

    func makeNSView(context: Context) -> WKWebView { model.webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// A `WKWebView` that opens WebKit's Web Inspector (developer tools) on F12 or
/// ⌥⌘I / ⌥⌘C, like a desktop browser. The inspector is the same one Safari
/// uses; it's enabled via the view's `isInspectable` flag and the configuration's
/// `developerExtrasEnabled` preference (set in `WebTabModel.makeWebView`).
final class InspectableWebView: WKWebView {
    /// Repeating check that keeps the Web Inspector in its own window (see
    /// `toggleInspector`). Runs only while the inspector is open.
    private var inspectorWatchdog: Timer?

    deinit { inspectorWatchdog?.invalidate() }

    override func keyDown(with event: NSEvent) {
        if Self.isInspectorShortcut(event) { toggleInspector(); return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Catch ⌥⌘I / ⌥⌘C here too: as a key *equivalent* it's offered down the
        // responder chain before the web content can consume it.
        if Self.isInspectorShortcut(event) { toggleInspector(); return true }
        return super.performKeyEquivalent(with: event)
    }

    /// True for F12 (keyCode 111) or ⌥⌘I / ⌥⌘C — the usual "open dev tools" keys.
    private static func isInspectorShortcut(_ event: NSEvent) -> Bool {
        if event.keyCode == 111 { return true }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == [.command, .option],
           let c = event.charactersIgnoringModifiers?.lowercased() {
            return c == "i" || c == "c"
        }
        return false
    }

    /// Toggle the Web Inspector for this view via WebKit's private `_inspector`
    /// hook (the same inspector "Inspect Element" opens). The app ships outside the
    /// App Store, so the private call is fine; it degrades to a beep if the hook
    /// isn't available on the running system.
    ///
    /// The inspector is forced into its own **detached** window. A *docked*
    /// inspector hosted inside our SwiftUI `NSViewRepresentable` comes up as an
    /// empty dark panel — WebKit can't lay out its docked frontend in that view
    /// hierarchy — so we detach it, giving it a normal `NSWindow` with the full
    /// developer interface (Elements, Console, Sources, Network, …). WebKit
    /// remembers the detached choice, so later opens stay detached.
    func toggleInspector() {
        guard let inspector = inspectorObject() else { NSSound.beep(); return }
        let visible = (inspector.value(forKey: "isVisible") as? Bool) ?? false
        if visible {
            invoke("close", on: inspector)
            stopInspectorWatchdog()
            return
        }
        invoke("show", on: inspector)
        // The inspector opens docked inside our embedded web view, where WebKit
        // can't lay out its frontend (an empty dark panel) and it fights SwiftUI's
        // layout. Keep it in its own window instead: the watchdog detaches it as
        // soon as it appears, and bounces it back out if the user later clicks
        // "dock" in the inspector toolbar.
        startInspectorWatchdog()
    }

    /// WebKit's private per-view inspector (`_WKInspector`), or `nil` if the hook
    /// isn't available on this system.
    private func inspectorObject() -> NSObject? {
        let key = "_inspector"
        guard responds(to: Selector((key))),
              let inspector = value(forKey: key) as? NSObject else { return nil }
        return inspector
    }

    /// True when the inspector is visible but docked into our content window — its
    /// frontend lives in our `NSWindow` rather than a standalone
    /// `_WKInspectorWindow`. (`_WKInspector` exposes no `isAttached` flag, so we
    /// infer dock state from where the frontend is hosted.)
    private func inspectorIsDocked(_ inspector: NSObject) -> Bool {
        guard (inspector.value(forKey: "isVisible") as? Bool) ?? false else { return false }
        guard let host = inspector.value(forKey: "extensionHostWebView") as? NSView,
              let window = host.window else { return false }
        return NSStringFromClass(type(of: window)) != "_WKInspectorWindow"
    }

    private func startInspectorWatchdog() {
        stopInspectorWatchdog()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
            guard let self, let inspector = self.inspectorObject() else {
                timer.invalidate(); return
            }
            let visible = (inspector.value(forKey: "isVisible") as? Bool) ?? false
            if !visible { self.stopInspectorWatchdog(); return }
            if self.inspectorIsDocked(inspector) { self.invoke("detach", on: inspector) }
        }
        RunLoop.main.add(timer, forMode: .common)
        inspectorWatchdog = timer
    }

    private func stopInspectorWatchdog() {
        inspectorWatchdog?.invalidate()
        inspectorWatchdog = nil
    }

    /// Call a no-argument Objective-C selector by name if the object responds.
    @discardableResult
    private func invoke(_ name: String, on object: NSObject) -> Bool {
        let sel = Selector((name))
        guard object.responds(to: sel) else { return false }
        object.perform(sel)
        return true
    }

    // MARK: - Developer context menu

    /// Cache-only website-data types, cleared by "Empty Caches" (leaves cookies and
    /// local storage intact so the user stays signed in).
    private static let cacheDataTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeFetchCache,
    ]

    /// Augment WebKit's native right-click menu with developer actions: hard
    /// refresh, cache clearing, copy address, open externally, and the Web
    /// Inspector. WebKit builds a fresh menu each time and calls this just before
    /// it opens, so we append our own group to whatever it produced.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        add("Hard Refresh (Ignore Cache)", #selector(devHardReload))
        add("Empty Caches", #selector(devEmptyCaches))
        add("Empty Caches and Hard Refresh", #selector(devEmptyCachesAndReload))
        add("Clear All Website Data…", #selector(devClearWebsiteData))
        menu.addItem(.separator())
        add("Copy Page Address", #selector(devCopyAddress))
        add("Open in Default Browser", #selector(devOpenInDefaultBrowser))
        add("Open Web Inspector", #selector(devOpenInspector))
    }

    /// Remove the given website-data types from this view's data store, then run
    /// `done` on the main thread.
    private func removeData(ofTypes types: Set<String>, then done: @escaping () -> Void = {}) {
        configuration.websiteDataStore.removeData(ofTypes: types,
                                                  modifiedSince: .distantPast) {
            DispatchQueue.main.async(execute: done)
        }
    }

    /// Reload bypassing the cache (end-to-end revalidation) — a "hard refresh".
    @objc private func devHardReload() { reloadFromOrigin() }

    /// Remove only the cache data types (keeps cookies and local storage).
    @objc private func devEmptyCaches() { removeData(ofTypes: Self.cacheDataTypes) }

    @objc private func devEmptyCachesAndReload() {
        removeData(ofTypes: Self.cacheDataTypes) { [weak self] in self?.reloadFromOrigin() }
    }

    /// Clear everything (cookies, storage, caches) after confirming — this can sign
    /// the user out of sites, and the default data store is shared across tabs.
    @objc private func devClearWebsiteData() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all website data?"
        alert.informativeText = "Removes cookies, local storage, and caches for the browser tabs that share this session. You may be signed out of sites."
        alert.addButton(withTitle: "Clear Data")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
    }

    @objc private func devCopyAddress() {
        guard let string = url?.absoluteString, !string.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @objc private func devOpenInDefaultBrowser() {
        guard let url else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }

    @objc private func devOpenInspector() { toggleInspector() }
}

/// Installs a single app-wide key monitor that opens the Web Inspector on F12 /
/// ⌥⌘I / ⌥⌘C for whichever browser tab has focus. A local monitor is needed
/// because a focused `WKWebView` hands key events straight to its web content
/// process, so the view's own `keyDown` never sees F12 — but the monitor runs in
/// `sendEvent(_:)`, before that dispatch, so it reliably catches the shortcut and
/// swallows it (the page never sees it).
enum WebInspectorHotkey {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isShortcut(event), let web = focusedInspectableWebView() else { return event }
            web.toggleInspector()
            return nil   // consume — don't pass F12 on to the page
        }
    }

    /// F12, or ⌥⌘I / ⌥⌘C — the usual "open developer tools" keys.
    private static func isShortcut(_ event: NSEvent) -> Bool {
        if event.keyCode == 111 { return true }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == [.command, .option],
           let c = event.charactersIgnoringModifiers?.lowercased() {
            return c == "i" || c == "c"
        }
        return false
    }

    /// The `InspectableWebView` that should receive the shortcut: the one in the
    /// key window's responder chain, else the first visible one (covers pressing
    /// the key right after the page loads, before clicking into it).
    private static func focusedInspectableWebView() -> InspectableWebView? {
        guard let window = NSApp.keyWindow else { return nil }
        var responder: NSResponder? = window.firstResponder
        while let r = responder {
            if let web = r as? InspectableWebView { return web }
            responder = r.nextResponder
        }
        return window.contentView.flatMap(firstWebView(in:))
    }

    private static func firstWebView(in view: NSView) -> InspectableWebView? {
        if let web = view as? InspectableWebView, web.window != nil { return web }
        for sub in view.subviews {
            if let found = firstWebView(in: sub) { return found }
        }
        return nil
    }
}

/// Drives a `WKWebView`'s navigation: mirrors its state back to the model via
/// KVO, keeps `target="_blank"` links in the same view, and retries transient
/// connection failures while an SSH tunnel is still coming up. Owned by the
/// model so it outlives any individual mount of the SwiftUI view.
final class WebNavigator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var model: WebTabModel?
    private var observations: [NSKeyValueObservation] = []
    /// Retry bookkeeping: a profile's link opens its web tab immediately, but the
    /// SSH tunnel it depends on is still coming up — and the forwarded port refuses
    /// connections until login finishes (which, with an interactive password, can
    /// take a while). On a connection failure we wait for that port to actually
    /// open (see `tunnelGate` / `PortProbe`) and reload then, so the page loads on
    /// its own with no manual reload. `maxRetries` just caps the number of failed
    /// loads so an ordinary unreachable site eventually stops.
    private var retryCount = 0
    private let maxRetries = 40
    private var isRetrying = false

    init(model: WebTabModel) { self.model = model }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // A fresh, user-driven navigation resets the retry budget; our own
        // retries don't.
        if !isRetrying { retryCount = 0 }
        isRetrying = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        retryCount = 0
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        retryIfTransient(webView, error: error as NSError)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        retryIfTransient(webView, error: error as NSError)
    }

    /// Re-attempt the load after a short delay for connection errors that
    /// typically clear once the tunnel finishes connecting.
    private func retryIfTransient(_ webView: WKWebView, error: NSError) {
        let transient: Set<Int> = [
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut,
            NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable,
            NSURLErrorNotConnectedToInternet,
        ]
        guard error.domain == NSURLErrorDomain, transient.contains(error.code),
              retryCount < maxRetries else { return }
        let failingURL = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? webView.url ?? model?.initialURL
        guard let url = failingURL else { return }
        retryCount += 1
        isRetrying = true
        // If this tab depends on an SSH tunnel, wait for its forwarded port / SOCKS
        // proxy to actually accept a connection before reloading — rather than
        // hammering WKWebView, which trips CFNetwork's connection-failure backoff
        // and delays the load. Probing with a raw socket lets the page load promptly
        // on its own the moment the tunnel finishes logging in. Ordinary internet
        // tabs (no tunnel) just retry on a short ramped timer instead.
        if let gate = model?.tunnelGate() {
            PortProbe.waitUntilOpen(gate, timeout: 90) { [weak webView] in
                webView?.load(URLRequest(url: url))
            }
        } else {
            let delay = min(2.5, 0.5 + 0.15 * Double(retryCount))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                webView?.load(URLRequest(url: url))
            }
        }
    }

    func observe(_ webView: WKWebView) {
        let sync: (WKWebView) -> Void = { [weak self] wv in
            guard let self, let model = self.model else { return }
            let url = wv.url, title = wv.title
            let back = wv.canGoBack, forward = wv.canGoForward
            let loading = wv.isLoading, progress = wv.estimatedProgress
            DispatchQueue.main.async {
                model.sync(url: url, title: title, back: back,
                           forward: forward, loading: loading, progress: progress)
            }
        }
        observations = [
            webView.observe(\.title, options: [.new]) { wv, _ in sync(wv) },
            webView.observe(\.url, options: [.new]) { wv, _ in sync(wv) },
            webView.observe(\.canGoBack, options: [.new]) { wv, _ in sync(wv) },
            webView.observe(\.canGoForward, options: [.new]) { wv, _ in sync(wv) },
            webView.observe(\.isLoading, options: [.new]) { wv, _ in sync(wv) },
            webView.observe(\.estimatedProgress, options: [.new]) { wv, _ in sync(wv) },
        ]
    }

    /// Open `target="_blank"` / `window.open` links in the same web view rather
    /// than spawning a separate window.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

/// An in-app browser tab: a slim navigation toolbar above a `WKWebView`.
struct WebTabView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: WebTabModel

    init(session: TerminalSession) {
        _session = ObservedObject(initialValue: session)
        _model = ObservedObject(initialValue: session.webModel ?? WebTabModel(initialURL: nil))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack(alignment: .top) {
                WebView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.isLoading {
                    ProgressView(value: max(0.02, model.progress))
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Back")
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("Forward")
            Button {
                if model.isLoading { model.stop() } else { model.reload() }
            } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            }
            .help(model.isLoading ? "Stop" : "Reload")

            TextField("Address", text: $model.addressText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onSubmit { model.submitAddress() }

            if let proxy = model.proxy {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                    .help("Routing through SOCKS proxy \(proxy.host):\(proxy.port)")
            }

            Button { model.toggleWebInspector() } label: { Image(systemName: "ladybug") }
                .help("Open Web Inspector — developer tools (F12 or ⌥⌘I)")

            Button { model.openInDefaultBrowser() } label: { Image(systemName: "safari") }
                .help("Open in your default browser")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// Polls a TCP endpoint until it accepts a connection, then invokes `onOpen` once.
/// Used to wait for an SSH tunnel's forwarded port (or SOCKS proxy) to come up
/// before (re)loading a web tab — so a page opened from a profile loads on its own
/// as soon as login finishes, with no manual reload.
enum PortProbe {
    static func waitUntilOpen(_ endpoint: NWEndpoint,
                              timeout: TimeInterval,
                              onOpen: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func attempt() {
            guard Date() < deadline else { return }
            let conn = NWConnection(to: endpoint, using: .tcp)
            var settled = false
            func settle(open: Bool) {
                guard !settled else { return }
                settled = true
                conn.cancel()
                if open {
                    DispatchQueue.main.async(execute: onOpen)
                } else {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.0, execute: attempt)
                }
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: settle(open: true)
                case .failed, .cancelled: settle(open: false)
                default: break
                }
            }
            conn.start(queue: .global())
            // Don't let a single hung connect stall the poll.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { settle(open: false) }
        }
        attempt()
    }
}
