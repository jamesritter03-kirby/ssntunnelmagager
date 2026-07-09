import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Carries the full set of files an **in‑app** drag represents.
///
/// SwiftUI's `.onDrag` can vend only a **single** `NSItemProvider`, so dragging
/// several selected rows out of an in‑app browser (e.g. a Finder tab) puts just
/// the one grabbed file on the drag pasteboard — the others are lost before any
/// drop handler runs. To carry a multi‑selection between two in‑app views we
/// record the whole set here when the drag starts, then let the drop side expand
/// the single pasteboard file back to the full selection.
final class InAppFileDrag {
    static let shared = InAppFileDrag()
    private init() {}

    /// The files the current in‑app drag represents (empty when none / external).
    private(set) var urls: [URL] = []

    /// Record the files a starting in‑app drag represents. Overwrites any prior
    /// (possibly stale) set, so only the newest in‑app drag is ever considered.
    func begin(_ urls: [URL]) { self.urls = urls }

    /// Expand a set of dropped pasteboard URLs to the full in‑app selection when
    /// they belong to it.
    ///
    /// An in‑app drag places exactly the **grabbed** file on the pasteboard, so
    /// if the drop carries a single file that's a member of the recorded set, the
    /// user dragged the whole multi‑selection — return all of it. Anything else
    /// (an external drag, or a genuine single‑file drag) passes through unchanged,
    /// so this never inflates an unrelated drop.
    func expand(_ pasteboardURLs: [URL]) -> [URL] {
        guard urls.count > 1,
              pasteboardURLs.count == 1,
              let dropped = pasteboardURLs.first,
              urls.contains(where: { $0.path == dropped.path })
        else { return pasteboardURLs }
        return urls
    }
}

/// Wraps SwiftUI `Content` inside a real AppKit `NSView` that is registered as a
/// file‑drop destination — the reliable way to accept a **multi‑file** Finder
/// drag.
///
/// SwiftUI's own `.onDrop` (and the `DropDelegate` it feeds) collapses a
/// multi‑file drag down to a **single** item provider, so dragging several files
/// at once only ever surfaces the first. AppKit's dragging destination, by
/// contrast, exposes the full `draggingPasteboard`, which lists every dragged
/// file. Because AppKit resolves a drop by hit‑testing the view under the cursor
/// and then walking **up** to a registered *ancestor* (never to sibling views
/// behind), the drop view has to genuinely contain the content — hence this
/// wrapper hosts the SwiftUI view as a subview rather than sitting over or under
/// it. Mouse handling is unaffected: the hosted content is frontmost and gets
/// clicks as usual.
struct FileDropContainer<Content: View>: NSViewRepresentable {
    /// Called on drop with every dragged file URL, plus the drop location in the
    /// container's top‑left coordinate space (matches SwiftUI's coordinates).
    let onFiles: ([URL], CGPoint) -> Void
    /// Called while a file drag hovers (the point) and when it leaves (nil), so
    /// the caller can drive drop highlighting.
    let onHover: (CGPoint?) -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DragDestinationView {
        let view = DragDestinationView()
        view.onFiles = onFiles
        view.onHover = onHover

        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        context.coordinator.hosting = hosting
        return view
    }

    func updateNSView(_ nsView: DragDestinationView, context: Context) {
        // Keep the closures fresh (they capture `self`, which changes each body
        // pass) and push the latest SwiftUI content into the hosted view.
        nsView.onFiles = onFiles
        nsView.onHover = onHover
        context.coordinator.hosting?.rootView = content()
    }

    final class Coordinator {
        var hosting: NSHostingView<Content>?
    }
}

/// The AppKit `NSView` that actually receives the file drag. Flipped so its
/// coordinate origin is top‑left, matching SwiftUI, and so its hosted subview
/// lays out the same way.
final class DragDestinationView: NSView {
    var onFiles: ([URL], CGPoint) -> Void = { _, _ in }
    var onHover: (CGPoint?) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Every file URL on the drag pasteboard, in drop order. Tries the strict
    /// file‑URL‑only read first, then a lenient read that keeps the file URLs —
    /// some drag sources (e.g. the in‑app Finder tab) don't set the flag the
    /// strict read requires.
    private func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let files = urls.filter(\.isFileURL)
            if !files.isEmpty { return files }
        }
        return []
    }

    /// Drop location in this (flipped) view's coordinates — top‑left origin, so
    /// it lines up with SwiftUI frames measured in the same coordinate space.
    private func point(_ sender: NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { onHover(nil); return [] }
        onHover(point(sender))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { onHover(nil); return [] }
        onHover(point(sender))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHover(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onHover(nil)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onFiles(urls, point(sender))
        onHover(nil)
        return true
    }
}
