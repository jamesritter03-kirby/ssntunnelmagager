import Foundation

/// One released (or in-development) version of the app, used to power the
/// in-app **Release Notes** and **Download Older Versions** screens.
///
/// The download archives live on the GitHub "updates" release (the same place
/// Sparkle pulls auto-updates from), named `SSH-Tunnel-Manager-<short>-<build>.zip`.
struct Release: Identifiable {
    let shortVersion: String        // e.g. "1.9.8"
    let build: Int                  // CFBundleVersion, e.g. 18
    let date: String                // human-readable, or "In development"
    let highlights: [String]        // bullet points of what changed
    /// Whether a downloadable archive exists on the releases page (false for an
    /// unreleased / in-development entry).
    let isDownloadable: Bool

    var id: Int { build }

    var displayVersion: String { "\(shortVersion) (build \(build))" }

    /// The direct download URL for this version's zip on the GitHub release.
    var downloadURL: URL? {
        guard isDownloadable else { return nil }
        return URL(string:
            "\(ReleaseCatalog.releaseBaseURL)/SSH-Tunnel-Manager-\(shortVersion)-\(build).zip")
    }
}

/// The catalog of known releases, newest first, plus shared URLs and helpers.
enum ReleaseCatalog {
    /// Where the per-version zips are uploaded (the Sparkle "updates" release).
    static let releaseBaseURL =
        "https://github.com/jamesritter03-kirby/ssntunnelmagager/releases/download/updates"

    /// The human-facing GitHub Releases page.
    static let releasesPageURL =
        URL(string: "https://github.com/jamesritter03-kirby/ssntunnelmagager/releases")!

    /// The project page / README.
    static let homePageURL =
        URL(string: "https://github.com/jamesritter03-kirby/ssntunnelmagager")!

    /// All releases, newest first. Add a new entry at the top when shipping, and
    /// flip the previous top entry's `isDownloadable` to true once its archive is
    /// uploaded.
    static let all: [Release] = [
        Release(
            shortVersion: "1.9.13", build: 23, date: "Jun 26, 2026",
            highlights: [
                "Dock tabs to the top or bottom too: a docked drawer can now sit along any of the four edges, with top/bottom drawers spanning the width between your side drawers.",
                "Dock to the top or bottom from a tab's right-click menu (Dock ▸ Dock Top / Dock Bottom) or with ⌃⌘↑ and ⌃⌘↓.",
                "Stack several tabs in a top/bottom drawer side by side, drag the dividers to size them, and collapse the drawer to a slim rail — just like the side drawers.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.12", build: 22, date: "Jun 26, 2026",
            highlights: [
                "Docked drawers: the collapse and return buttons now sit on the drawer's inner edge so they're always visible, even with long file names in a Finder or SFTP tab.",
                "Long names in docked Finder and SFTP tabs are trimmed to fit instead of pushing the toolbar controls out of view.",
                "SFTP: drop files anywhere in the list to upload — not just in the empty area below the items.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.11", build: 21, date: "Jun 26, 2026",
            highlights: [
                "Finder tab now sorts and filters: click a column header to sort by name, size or date, or use the new menu to sort by kind and show folders or files only.",
                "Type in the Finder filter box to instantly narrow a folder by name.",
                "Finder and SFTP: click anywhere on a row to select it — not just the empty space between columns.",
                "Snappier single-click selection in both file browsers.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.10", build: 20, date: "Jun 26, 2026",
            highlights: [
                "Dock tabs to the left or right edge as slide-out drawers, so terminals can sit beside your tiled or single-tab layout.",
                "Stack several tabs in one side drawer and drag the dividers to size them; collapse a drawer to a thin rail and click to slide it back out.",
                "Dock from a tab's right-click menu (Dock ▸ Dock Left / Dock Right) or with ⌃⌘[ and ⌃⌘]; sides, widths and heights are remembered per workspace.",
                "Smoother divider dragging for docked drawers (and the resize no longer feels jumpy).",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.9", build: 19, date: "Jun 26, 2026",
            highlights: [
                "New Finder tab: browse local files, and drag a file onto a terminal to paste its path or onto an SFTP tab to upload it.",
                "Set Up Passwordless Login: one click copies your SSH key to a server with ssh-copy-id (generating a key if needed).",
                "SFTP: drop files directly onto a folder to upload into it, plus Refresh on the right-click menu and the F5 key.",
                "Help menu with a full feature guide, release notes, and a way to download older versions.",
                "22 terminal themes including Nord, Gruvbox, Tokyo Night, Catppuccin and more, grouped by light/dark.",
                "Profile editor marks required fields and can set up passwordless login in place.",
                "Fixed “Open in workspace” so connecting (and its SFTP/VNC tabs) reliably follow the assigned workspace.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.8", build: 18, date: "Jun 19, 2026",
            highlights: [
                "Native MQTT explorer with a topic tree and right-click Expand/Collapse.",
                "Open MQTT and Redis connections on demand from the + menu.",
                "Assign a profile to a workspace so its tabs open there.",
                "Fixed a blank-on-launch connection race and port-collision errors.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.7", build: 17, date: "Jun 19, 2026",
            highlights: [
                "Import command history into a terminal tab.",
                "Right-click a tile to act on it directly.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.6", build: 16, date: "Jun 19, 2026",
            highlights: [
                "Stability and connection-handling improvements.",
            ],
            isDownloadable: true
        ),
    ]

    /// The build number of the running app, from its Info.plist.
    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// The running app's short version string, from its Info.plist.
    static var currentShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Whether a release matches the currently-running build.
    static func isInstalled(_ release: Release) -> Bool {
        release.build == currentBuild
    }

    /// Downloadable releases other than the one currently installed.
    static var olderVersions: [Release] {
        all.filter { $0.isDownloadable && $0.build != currentBuild }
    }
}
