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

    /// The live web view, set by the representable so the toolbar can drive it.
    weak var webView: WKWebView?

    /// Fires when the page title changes (wired to the owning tab's title).
    var onTitleChange: ((String) -> Void)?

    init(initialURL: URL?, proxy: WebProxy? = nil) {
        self.initialURL = initialURL
        self.proxy = proxy
        if let initialURL {
            currentURLString = initialURL.absoluteString
            addressText = initialURL.absoluteString
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stop() { webView?.stopLoading() }

    /// Navigate to whatever is currently typed in the address bar.
    func submitAddress() { load(addressText) }

    /// Load a string, adding a scheme if the user omitted one.
    func load(_ string: String) {
        guard let url = ProfileLink(label: "", url: string).normalizedURL else { return }
        addressText = url.absoluteString
        webView?.load(URLRequest(url: url))
    }

    /// Hand the current page off to the user's default browser.
    func openInDefaultBrowser() {
        if let url = webView?.url ?? initialURL {
            NSWorkspace.shared.open(url)
        }
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

/// SwiftUI wrapper around `WKWebView`. The web view is owned for the lifetime of
/// the representable (one per tab) so the page keeps running while in the
/// background, like a terminal tab.
struct WebView: NSViewRepresentable {
    @ObservedObject var model: WebTabModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.dataStore(for: model.proxy)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        model.webView = webView
        context.coordinator.observe(webView)
        if let url = model.initialURL {
            webView.load(URLRequest(url: url))
        }
        return webView
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

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: WebTabModel
        private var observations: [NSKeyValueObservation] = []
        /// Retry bookkeeping: while an SSH tunnel is still coming up the first
        /// loads fail with connection errors; we retry a few times before giving up.
        private var retryCount = 0
        private let maxRetries = 6
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
                ?? webView.url ?? model.initialURL
            guard let url = failingURL else { return }
            retryCount += 1
            isRetrying = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak webView] in
                webView?.load(URLRequest(url: url))
            }
        }

        func observe(_ webView: WKWebView) {
            let sync: (WKWebView) -> Void = { [weak self] wv in
                guard let self else { return }
                let url = wv.url, title = wv.title
                let back = wv.canGoBack, forward = wv.canGoForward
                let loading = wv.isLoading, progress = wv.estimatedProgress
                DispatchQueue.main.async {
                    self.model.sync(url: url, title: title, back: back,
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

        /// Open `target="_blank"` / `window.open` links in the same web view
        /// rather than spawning a separate window.
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

            Button { model.openInDefaultBrowser() } label: { Image(systemName: "safari") }
                .help("Open in your default browser")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
