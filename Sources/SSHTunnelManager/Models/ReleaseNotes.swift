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
            shortVersion: "1.9.19", build: 29, date: "Jul 1, 2026",
            highlights: [
                "New Text Editor tab — a built‑in, Notepad++‑style editor with syntax highlighting for 20+ languages, line numbers, word wrap, find & replace (with regex and whole‑word), adjustable font size, and 11 colour themes. Open it from the welcome screen or the New menu.",
                "The editor never loses your work: unsaved text — even in a never‑saved, untitled tab — is backed up automatically and restored the next time you launch, just like Notepad++.",
                "The editor watches your open files: if another program changes one on disk, it offers to reload it (or lets you keep your version), so you're never editing a stale copy.",
                "ZeroTier devices: connect straight to any device with one‑click buttons for a browser tab, SSH terminal, SFTP, VNC, MQTT and Redis — plus a “Connect as” username and password you can save to your Keychain for quick reconnects.",
                "Change a terminal tab’s colour theme on the fly: right‑click the tab and pick a theme. For a profile’s tab it’s remembered on the profile, exactly like the profile editor.",
            ],
            isDownloadable: false
        ),
        Release(
            shortVersion: "1.9.18", build: 28, date: "Jul 1, 2026",
            highlights: [
                "Edit a tab’s connection: right‑click an MQTT, Redis, VNC or SFTP tab and choose Edit Connection… to change its host, port or credentials and reconnect in place — no need to open a new tab to fix a mistyped password or re‑point at another server.",
                "VNC: fixed screen‑sharing tabs that sometimes didn’t connect — the viewer now retries briefly while the SSH tunnel’s port finishes coming up, instead of failing on the first try.",
                "Tidied the sidebar’s bottom bar: the local‑terminal button is now just its icon, matching the ZeroTier button next to it.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.17", build: 27, date: "Jul 1, 2026",
            highlights: [
                "MQTT: graph a topic’s numbers over time — the detail pane has a new Payload / Graph switch that plots a bare numeric payload, or lets you toggle individual numeric fields inside a JSON payload on and off as separate live series.",
                "Redis: fixed a connection bug where a password-protected server could look “Connected” while every command silently failed — the client now verifies the link and tells you plainly when a password is required (or harmlessly ignores a superfluous one).",
                "ZeroTier: the IP picker now shows each device’s network name beneath it, so it’s clear which network an address belongs to.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.16", build: 26, date: "Jun 29, 2026",
            highlights: [
                "New ZeroTier Devices browser: see every device across your ZeroTier networks and connect (SSH, SFTP or VNC) straight to any of its IP addresses — open it from the welcome screen, the sidebar, or File ▸ Browse ZeroTier Devices.",
                "Add multiple ZeroTier accounts (one API token each) and browse them together; filter devices by name, node id or IP, and hide ones that are offline.",
                "Self-hosted ZeroTier (e.g. ZTNET) is supported alongside ZeroTier Central — just add your server’s URL, including organization API tokens, which now work automatically.",
                "Pick a ZeroTier device IP right where you type a host: a globe button next to the host field in the Remote Terminal, SFTP, VNC, MQTT and Redis sheets and in the profile editor.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.15", build: 25, date: "Jun 29, 2026",
            highlights: [
                "Welcome screen now has a Recently Closed list: reopen a tab — or a whole workspace — you closed without saving, with one click.",
                "Get a Save / Don’t Save prompt if you quit with a profile editor still open and unsaved, so edits in progress are never lost by accident.",
                "Right-click a VNC tab for quick options: scaling, color depth, view-only, share clipboard, send Ctrl+Alt+Del, reconnect, or open in Screen Sharing.",
                "New VNC Connection… now lets you set scaling (fit or actual size), color depth, and view-only up front.",
                "Pan around a VNC desktop shown at actual size by dragging — handy when the remote screen is larger than the tab.",
                "Drag files straight out of an SFTP tab into any Finder window, and use Download To… to save them anywhere (not just Downloads).",
                "Open an ad-hoc Remote Terminal, SFTP, or VNC connection to any host without making a profile first — right from an empty workspace.",
                "Empty-workspace welcome screen: every connection type is now a labeled button, including MQTT and Redis.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.14", build: 24, date: "Jun 26, 2026",
            highlights: [
                "VNC tabs now show the remote desktop right inside the tab instead of handing off to macOS Screen Sharing — with a one-click “Open in Screen Sharing” fallback still available.",
                "New VNC Connection…: connect straight to a VNC server by host and port without setting up a profile first (from the + menu or File ▸ New).",
                "Transfer files from a VNC tab: the new File Transfer menu opens an SFTP browser or uploads files to the same server over your SSH connection.",
                "VNC connections stay live when you switch workspaces — no more re-entering the Screen Sharing password each time you come back.",
                "Remember a VNC password in the Keychain and unlock it with Touch ID, using each profile’s existing Touch ID setting.",
                "Docked drawers rearranged: the left and right drawers now sit between the top and bottom drawers, so the top and bottom span the full width.",
            ],
            isDownloadable: true
        ),
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
