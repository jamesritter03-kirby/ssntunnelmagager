import AppKit
import Darwin

/// Keeps automatic updates working by making sure the app runs from a writable,
/// permanent location (your Applications folder).
///
/// Because the app is signed locally (not notarized through Apple), macOS keeps
/// the *quarantine* flag on it after download and may launch it from a random,
/// **read-only** "App Translocation" path. Sparkle installs each update right
/// next to wherever the app is currently running — so from a translocated/read-
/// only spot an update can't replace the app in place, and you end up with extra
/// copies that never seem to update. (Sparkle's own docs call this out.)
///
/// On launch we detect that situation and offer to move the app into
/// /Applications (which also clears the quarantine flag), then relaunch from
/// there. After that, updates replace the app cleanly — a single copy.
enum InstallLocationGuard {

    /// A snapshot of where the app is running from and whether updates can work there.
    struct Status {
        var isTranslocated: Bool
        var parentIsWritable: Bool
        var inApplications: Bool

        /// True when the current location can't receive in-place updates, so we
        /// should offer to move the app to /Applications.
        var shouldOfferMove: Bool {
            // Already in a normal, writable Applications install — nothing to do.
            if inApplications && parentIsWritable && !isTranslocated { return false }
            // The two cases that break Sparkle's in-place update:
            //   • App Translocation (random read-only mount), or
            //   • running from any other read-only location (e.g. the .dmg).
            return isTranslocated || !parentIsWritable
        }
    }

    /// Check the running location and, if updates can't work there, offer to move
    /// the app to /Applications and relaunch. Safe to call once at launch.
    static func checkAndOfferMoveToApplications() {
        // Never get in the way of local development or our own tests.
        if ProcessInfo.processInfo.environment["SSHTM_NO_MOVE_PROMPT"] == "1" { return }
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.path.contains("/.build/") { return }   // running the raw SPM binary

        let status = status(of: bundleURL)
        guard status.shouldOfferMove else { return }

        let alert = NSAlert()
        alert.messageText = "Move SSH Tunnel Manager to Applications?"
        alert.informativeText = """
        The app is running from a temporary or read-only location, so automatic \
        updates can't replace it in place (that's what leaves extra copies behind).

        Move it to your Applications folder and it'll update itself cleanly from \
        now on.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Applications Folder")
        alert.addButton(withTitle: "Open Anyway")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        moveToApplications(from: bundleURL)
    }

    // MARK: - Status

    static func status(of bundleURL: URL) -> Status {
        let path = bundleURL.path
        let parent = bundleURL.deletingLastPathComponent().path
        return Status(
            isTranslocated: path.contains("/AppTranslocation/"),
            parentIsWritable: FileManager.default.isWritableFile(atPath: parent),
            inApplications: isInApplications(path)
        )
    }

    private static func isInApplications(_ path: String) -> Bool {
        if path.hasPrefix("/Applications/") { return true }
        let userApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications") + "/"
        return path.hasPrefix(userApps)
    }

    // MARK: - Move

    private static func moveToApplications(from sourceURL: URL) {
        let fm = FileManager.default
        let appName = sourceURL.lastPathComponent
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(appName)

        do {
            // Replace any existing copy at the destination (move it to the Trash).
            if fm.fileExists(atPath: destination.path) {
                if destination.standardizedFileURL == sourceURL.standardizedFileURL {
                    return   // already there; nothing to do
                }
                try? fm.trashItem(at: destination, resultingItemURL: nil)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
            }

            // Copy with ditto so the Sparkle framework's symlinks/permissions are
            // preserved exactly (the same tool the .dmg/.zip packaging uses).
            try runTool("/usr/bin/ditto", [sourceURL.path, destination.path])
            // Clear the quarantine flag so macOS won't translocate the copy.
            try? runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])

            // Launch the moved copy, then quit this (temporary) instance.
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            // Fall back to asking the user to drag it themselves.
            let alert = NSAlert()
            alert.messageText = "Couldn't move the app automatically"
            alert.informativeText = """
            Please drag “SSH Tunnel Manager” into your Applications folder yourself, \
            then open it from there. (\(error.localizedDescription))
            """
            alert.addButton(withTitle: "Reveal in Finder")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
            }
        }
    }

    /// Run a command-line tool and throw if it exits non-zero.
    private static func runTool(_ launchPath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "InstallLocationGuard", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "\(URL(fileURLWithPath: launchPath).lastPathComponent) exited with code \(process.terminationStatus)"])
        }
    }
}
