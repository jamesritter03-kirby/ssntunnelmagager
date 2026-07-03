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
            shortVersion: "1.9.26", build: 36, date: "Jul 3, 2026",
            highlights: [
                "Save a whole workspace as a profile: right‑click a workspace tab and choose Save as Profile… to turn its set of tabs into a one‑click launcher. It appears in the sidebar and welcome screen, and connecting it reopens the workspace with every tab reconnecting through its own profile.",
                "When every tab in a workspace is docked to a side, the empty center now offers the full set of welcome‑screen starting points — New Local Terminal, Browser, Finder and Text Editor tabs, the Connect‑to‑a‑server shortcuts (Remote Terminal, SFTP, VNC, MQTT, Redis, ZeroTier), your profiles and recently‑closed items — instead of just New Local Terminal.",
            ],
            isDownloadable: false
        ),
        Release(
            shortVersion: "1.9.25", build: 35, date: "Jul 3, 2026",
            highlights: [
                "New in the SFTP window — Mount with FUSE: mount a server as a drive in Finder and open its files in any app, just like a local folder. Look for the drive button in the SFTP toolbar, or right‑click inside the file list (or the SFTP tab) and choose Mount with FUSE. Mounting reuses the profile’s host, port, key and jump‑host — and your saved password from the Keychain — and unmounts automatically when you disconnect or close the tab.",
                "Because macOS doesn’t include a filesystem‑mount layer (only ssh and sftp), the first time you mount, a short setup sheet points you to the free fuse‑t helper with copy‑paste install commands and a Re‑check button — no kernel extension and no reboot required.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.24", build: 34, date: "Jul 2, 2026",
            highlights: [
                "Fixed: the text editor’s right‑click menu now shows Undo and Redo again (at the top, above Cut / Copy / Paste), each enabled only when there’s something to undo or redo. The ⌘Z / ⇧⌘Z keyboard shortcuts were unaffected.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.23", build: 33, date: "Jul 2, 2026",
            highlights: [
                "A big upgrade to the text editor’s folding engine — new View Options: highlight the current line, show indentation guides, reveal spaces and tabs, add a column ruler at 80, and turn on a Git‑style change‑history bar in the margin that marks the lines you’ve modified (orange), saved (green) or reverted (teal) since the file was opened.",
                "Smarter editing as you type: the matching bracket is highlighted wherever your cursor lands (and a mismatched one is flagged), selecting a word underlines every other occurrence, and you can work with multiple cursors — press ⌘D to add the next match and edit them all at once. Option‑drag makes a rectangular (column) selection.",
                "Handy code commands with keyboard shortcuts, gathered into a new Actions menu on the editor toolbar: move lines up/down (⌥↑ / ⌥↓), duplicate a line (⇧⌘D), delete a line (⇧⌘K), toggle comments for the current language (⌘/), complete a word from the rest of the file (⌥⎋), and drop bookmarks to jump around.",
                "Right‑click inside the editor for a proper menu: Cut, Copy, Paste and Select All alongside Toggle Comment, Duplicate / Delete line, Move line up/down and Toggle Bookmark — each enabled only when it applies.",
                "Right‑click a text‑editor tab for file actions: Save, Save As…, Revert to Saved, Reveal in Finder, Open in Default App, Copy Full Path or File Name, and Compare With another open file.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.22", build: 32, date: "Jul 2, 2026",
            highlights: [
                "New in the text editor — code folding (beta): turn on the Folding Engine from the editor toolbar to collapse and expand structured sections (objects and arrays in JSON, tags in XML/HTML, and blocks in many other languages), with the classic +/- markers in the margin.",
                "Document map (minimap): the folding engine can show a zoomed‑out map of the whole file down the right edge with a draggable “you are here” slider — click or drag it to sail through a long file at a glance. Toggle it from the editor toolbar.",
                "Compare two open files side by side: click Compare in the folding engine and pick another open file. Differences are colour‑coded line by line — added, removed and changed — with the exact edited text highlighted inside each changed line, original line numbers on both sides, synchronized scrolling, and up/down buttons to jump between changes.",
                "The folding engine now follows your theme end to end: syntax colours and the fold markers in the margin match your chosen editor theme, and find & replace (with regex and whole‑word) plus the live line/column readout work here too.",
                "Fixed: dragging a file onto a terminal reliably shows the Paste Path / Paste Contents menu again — it could be missed when several terminal tabs were stacked in the same area.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.21", build: 31, date: "Jul 2, 2026",
            highlights: [
                "See what’s connected at a glance: the sidebar now shows a green dot on profiles with a live tunnel, and each row’s button switches between Connect and a red Disconnect. Right‑click a profile for a Disconnect command too.",
                "Name your port forwards: give each forward a friendly name in the profile editor and it appears wherever you open that service (web, MQTT, Redis) — so multiple web forwards are finally easy to tell apart. The profile dialog is also wider and easier to fill in.",
                "Launch whole workspaces from a profile: open a profile in its own dedicated workspace with an editable name, or pick a saved workspace as a launch template so connecting rebuilds a whole set of tabs at once.",
                "Duplicating a profile now guides you: the editor shows a short checklist to finish the copy correctly — rename it, point it at the right server, set up sign‑in (passwords aren’t copied) and review your forwards.",
                "Save a workspace in one step: right‑click a workspace and choose Save Workspace to store or update it under its own name, alongside the existing Save as Workspace… And MQTT / Redis tabs opened without a profile are now remembered in saved workspaces, resumed sessions and Recently Closed.",
                "A more consistent app throughout: unified dialog headers each with a “?” help button, matching empty‑state screens, icons on every right‑click menu, and clearer wording (for example “Set Up Passwordless Login” everywhere).",
                "Polish: Settings gains an Editor section for the default text‑editor theme plus its own help topic, the Keyboard Shortcuts guide is up to date, the Help window’s topic list is wider, and the ZeroTier browser is now resizable and remembers your “Connect as” username.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.20", build: 30, date: "Jul 1, 2026",
            highlights: [
                "Drag a file onto a terminal and choose what to paste: a small menu now offers Paste Path (shell‑quoted, as before) or Paste Contents (the file’s text). Binary files are detected and skipped, and a very large paste asks first.",
                "Edit remote files in place: right‑click a file in an SFTP tab and choose Edit with Text Editor — it downloads, opens in the built‑in editor, and every save automatically uploads it back to the server.",
                "Open local files fast: right‑click a file in a Finder tab and choose Open in Text Editor, or drag a file onto an untitled editor tab to load its contents.",
            ],
            isDownloadable: true
        ),
        Release(
            shortVersion: "1.9.19", build: 29, date: "Jul 1, 2026",
            highlights: [
                "New Text Editor tab — a built‑in, Notepad++‑style editor with syntax highlighting for 20+ languages, line numbers, word wrap, find & replace (with regex and whole‑word), adjustable font size, and 11 colour themes. Open it from the welcome screen or the New menu.",
                "The editor never loses your work: unsaved text — even in a never‑saved, untitled tab — is backed up automatically and restored the next time you launch, just like Notepad++.",
                "The editor watches your open files: if another program changes one on disk, it offers to reload it (or lets you keep your version), so you're never editing a stale copy.",
                "ZeroTier devices: connect straight to any device with one‑click buttons for a browser tab, SSH terminal, SFTP, VNC, MQTT and Redis — plus a “Connect as” username and password you can save to your Keychain for quick reconnects.",
                "Change a terminal tab’s colour theme on the fly: right‑click the tab and pick a theme. For a profile’s tab it’s remembered on the profile, exactly like the profile editor.",
            ],
            isDownloadable: true
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
