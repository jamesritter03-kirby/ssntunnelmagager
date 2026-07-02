import Foundation

/// Watches a single file for external changes (writes, truncation, deletion,
/// atomic replacement) and reports them on the main queue. Used by the text
/// editor to offer a "the file changed on disk — reload?" prompt like Notepad++.
///
/// Because many programs (including this editor) save by writing a temporary
/// file and renaming it over the original, the watched file descriptor becomes
/// stale after such a save. The monitor re‑arms itself on every event so it keeps
/// following the current file at the path across those inode swaps.
final class FileChangeMonitor {
    /// Invoked on the main queue whenever the watched file may have changed.
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var watchedURL: URL?
    private var reopenAttempts = 0
    private let maxReopenAttempts = 20
    private let queue = DispatchQueue(label: "com.local.sshtunnelmanager.filewatch")

    /// Begin watching `url`, replacing any previous watch.
    func start(url: URL) {
        stop()
        watchedURL = url
        reopenAttempts = 0
        arm()
    }

    /// Stop watching and release the file descriptor.
    func stop() {
        source?.cancel()
        source = nil
        watchedURL = nil
    }

    // MARK: - Private

    private func arm() {
        guard let url = watchedURL else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // The file is momentarily gone — this happens in the tiny window of an
            // external atomic save (write temp, then rename over us) or right after
            // a delete. Retry briefly so we re‑attach to the replacement file.
            scheduleReopen()
            return
        }
        reopenAttempts = 0
        descriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .link, .revoke, .attrib],
            queue: queue)

        src.setEventHandler { [weak self] in
            guard let self else { return }
            // Re‑establish the watch on whatever now lives at the path (an atomic
            // save unlinks the inode we opened), then notify on the main queue.
            DispatchQueue.main.async {
                self.reArm()
                self.onChange?()
            }
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        source = src
        src.resume()
    }

    /// Tear down the current source (closing its fd via the cancel handler) and
    /// re‑open the path so we keep watching after atomic replacements.
    private func reArm() {
        source?.cancel()
        source = nil
        descriptor = -1
        arm()
    }

    /// Retry re‑opening the path after it briefly disappeared during an atomic
    /// replacement. Gives up (until the next `start`) once the file stays gone.
    private func scheduleReopen() {
        guard watchedURL != nil, reopenAttempts < maxReopenAttempts else { return }
        reopenAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.watchedURL != nil, self.source == nil else { return }
            self.arm()
            // Once we're re‑attached, surface any change that happened while the
            // file was being swapped out from under us.
            if self.source != nil { self.onChange?() }
        }
    }

    deinit { stop() }
}
