import AppKit
import Foundation
import SwiftTerm

/// Sits in front of a `LocalProcessTerminalView`'s own delegate so that a web
/// link the user activates in the terminal (⌘‑click on a URL) opens in an in‑app
/// browser tab instead of the external browser.
///
/// SwiftTerm already detects both explicit OSC 8 hyperlinks and plain URLs in the
/// output (`linkReporting = .implicit`) and, on activation, calls
/// `TerminalViewDelegate.requestOpenLink`. `LocalProcessTerminalView` is normally
/// its *own* terminal delegate and relies on the default `requestOpenLink`, which
/// hands the URL to `NSWorkspace` (the system browser). Because that default lives
/// in a protocol extension it can't be overridden from a subclass, so we insert
/// this thin proxy as the terminal delegate: it intercepts `requestOpenLink` and
/// transparently forwards every other message to the terminal's built‑in handling
/// (keyboard input, resizing, the title, scrolling, the bell…). Forwarding keeps
/// the PTY working exactly as before — only link handling changes.
final class TerminalLinkDelegate: TerminalViewDelegate {
    /// The terminal's original delegate (the view itself). Weak: the session owns
    /// the view and this proxy, so there's no ownership cycle and no need to keep
    /// the view alive from here.
    weak var inner: TerminalViewDelegate?

    /// Invoked with a resolved http(s) URL that should open in an in‑app browser
    /// tab. Non‑web links (mailto:, file:, ssh:, …) bypass this and go to the
    /// system instead.
    var onOpenWebLink: ((URL) -> Void)?

    init(inner: TerminalViewDelegate?) {
        self.inner = inner
    }

    // MARK: - Link handling (the whole point of the proxy)

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = TerminalLinkDelegate.webURL(from: link) {
            onOpenWebLink?(url)
        } else if let url = URL(string: link) {
            // Preserve the system's default behaviour for anything that isn't a
            // plain web page (email, files, custom schemes…).
            NSWorkspace.shared.open(url)
        }
    }

    /// Turn a terminal link into a browsable http(s) URL, or return nil if it
    /// isn't a web page (so the caller can fall back to the system handler).
    /// A bare `www.…` is upgraded to `https://` the way a browser would.
    static func webURL(from link: String) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let scheme = URL(string: trimmed)?.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" else { return nil }
            return URL(string: trimmed)
        }
        // Scheme‑less but clearly a web host: treat like a browser would.
        if trimmed.lowercased().hasPrefix("www.") {
            return URL(string: "https://\(trimmed)")
        }
        return nil
    }

    // MARK: - Transparent forwarding of every other delegate message

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        inner?.send(source: source, data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        inner?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        inner?.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        inner?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func scrolled(source: TerminalView, position: Double) {
        inner?.scrolled(source: source, position: position)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        inner?.rangeChanged(source: source, startY: startY, endY: endY)
    }

    func bell(source: TerminalView) {
        inner?.bell(source: source)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        inner?.clipboardCopy(source: source, content: content)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        inner?.iTermContent(source: source, content: content)
    }
}
