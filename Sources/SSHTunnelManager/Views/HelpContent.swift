import Foundation

/// The body of the in-app Help window — a comprehensive, friendly guide to every
/// feature. Authored as data so topics are easy to add, edit and search. Markdown
/// emphasis (**bold**, `code`) is supported in paragraphs and bullets.
enum HelpContent {
    static let articles: [HelpArticle] = [
        gettingStarted, profiles, tunnels, passwordless, terminal, snippets,
        workspaces, tilingDetaching, sftp, finder, vnc, services, links,
        paletteAndMenuBar, updates, shortcuts,
    ]

    // MARK: Getting started

    static let gettingStarted = HelpArticle(
        id: "getting-started", title: "Getting Started", icon: "sparkles",
        blocks: [
            .paragraph("**SSH Tunnel Manager** keeps your SSH connections, port‑forwarding tunnels and remote tools one click away. Save each server as a **profile**, then connect, forward ports, browse files over SFTP, share screens over VNC, and open web/MQTT/Redis tools — all in tabs."),
            .steps([
                "Click **+** in the sidebar (or **New Profile**) and enter a name and host.",
                "Add a username, an SSH key or password, and any port forwards you need.",
                "Select the profile and press **Connect** — a terminal tab opens with your tunnels running.",
            ]),
            .tip("No server yet? Use **File ▸ New Local Terminal** (⌘T) for a normal shell on this Mac, or **New Finder Tab** to browse local files."),
            .paragraph("Everything lives in **tabs** inside **workspaces**. Drag tabs to reorder, detach a tab into its own window, or tile several side by side."),
            .tip("The **welcome screen** (shown whenever a workspace is empty) gathers **Resume Last Session**, quick **Connect to a server** buttons, your **Profiles**, and a **Recently Closed** list — click any recently‑closed tab or workspace to reopen it."),
        ])

    // MARK: Profiles

    static let profiles = HelpArticle(
        id: "profiles", title: "Profiles", icon: "person.crop.rectangle.stack",
        blocks: [
            .paragraph("A **profile** stores everything about one connection: host, port, username, authentication, port forwards, theme, saved commands and links."),
            .bullets([
                "**Name & host** are required (they're marked in the editor).",
                "**Username / Jump host** — optional; a jump host hops through a bastion (`ssh -J`).",
                "**Authentication** — choose an SSH key, or save a password to your macOS Keychain (typed automatically at the prompt). Passwords are never included when you export.",
                "**Local Shell profiles** open a shell on this Mac in a chosen folder instead of connecting out.",
            ]),
            .paragraph("Right‑click a profile in the sidebar to **Connect**, open **SFTP/VNC**, **Set Up Key Login**, **Edit**, **Duplicate**, **Export** or **Delete**. The **Command Preview** at the bottom of the editor shows the exact `ssh` command, which you can copy."),
            .tip("Give each profile an **icon** and a **theme** so its tabs are instantly recognizable."),
            .tip("If you try to quit while a profile editor is still open with unsaved changes, the app **asks whether to save** first — so edits are never lost by accident."),
        ])

    // MARK: Tunnels

    static let tunnels = HelpArticle(
        id: "tunnels", title: "Tunnels & Port Forwarding", icon: "arrow.left.arrow.right",
        blocks: [
            .paragraph("Port forwards tunnel network traffic through your SSH connection. Add them in the profile editor under **Port Forwards**."),
            .bullets([
                "**Local (`-L`)** — opens a port on **this Mac** that forwards through the server to a target it can reach. Example: reach a remote database at `localhost:5432`.",
                "**Remote (`-R`)** — opens a port on the **server** that forwards back to a target reachable from this Mac.",
                "**Dynamic / SOCKS (`-D`)** — runs a SOCKS proxy on this Mac; apps pointed at it route through the server.",
            ]),
            .paragraph("Tunnels start as soon as you **Connect** the profile. The connection uses `ExitOnForwardFailure=yes`, so if a port is already taken the tab reports it instead of silently continuing."),
            .tip("Tag a **Local** forward with a **category** (Web / MQTT / Redis) to get a one‑click button that opens the right tool against that forwarded port — see **Service Tabs**."),
        ])

    // MARK: Passwordless login

    static let passwordless = HelpArticle(
        id: "passwordless", title: "Passwordless Login", icon: "key",
        blocks: [
            .paragraph("**Set Up Passwordless Login** copies your SSH **public key** to a server with `ssh-copy-id`, so future connections sign in with the key — no password needed."),
            .steps([
                "Right‑click a profile (or use the 🔑 button, the tab menu, the command palette, or the profile editor) and choose **Set Up Key Login**.",
                "If you don't have a key yet, the app offers to **generate** a new ed25519 key or **choose** an existing one.",
                "A terminal tab runs `ssh-copy-id`. Enter the account password once when asked (a saved Keychain password fills in automatically).",
                "Done — the profile adopts the key, so the next connection is passwordless.",
            ]),
            .tip("This is the most secure and convenient setup: prefer a key over a saved password whenever you can."),
        ])

    // MARK: Terminal

    static let terminal = HelpArticle(
        id: "terminal", title: "Terminal Tabs & History", icon: "terminal",
        blocks: [
            .paragraph("Each connection (and each local shell) is a full terminal tab powered by SwiftTerm, with true‑color, themes and adjustable text size."),
            .paragraph("Connect from a **profile**, or open a quick **remote terminal** without one: choose **New Remote Terminal…** from the **+** menu, **File ▸ New**, or the welcome screen, then enter a host, port and optional username/password. Your SSH keys are tried first; a typed password is sent at the prompt but isn’t saved. For tunnels, a custom key or a jump host, make a profile instead."),
            .bullets([
                "**Right‑click** behavior is configurable in Settings: copy‑then‑paste (Windows/Linux style), paste, or a context menu.",
                "**Command history** — the tab remembers commands you type. Open the history menu to re‑run one, or **import/export** history (including `.zsh_history`/`.bash_history`).",
                "**Disconnect / Stop** ends the connection without closing the tab; **Reconnect** brings it back.",
                "Drag a file from Finder (or a **Finder tab**) onto the terminal to paste its path.",
            ]),
            .shortcuts([
                ("⌘ +  /  ⌘ −", "Increase / decrease terminal text"),
                ("⌘ 0", "Actual size"),
                ("⌘ W", "Close the current tab"),
                ("⌃⌘ D", "Detach the tab into its own window"),
            ]),
        ])

    // MARK: Snippets

    static let snippets = HelpArticle(
        id: "snippets", title: "Saved Commands & Links", icon: "text.badge.plus",
        blocks: [
            .paragraph("Add **Saved Commands** to a profile for things you run often. Insert one at the prompt (or run it immediately) from the **Snippets** menu in the toolbar or a tab's right‑click menu."),
            .paragraph("**Links** are web pages tied to a profile — like a tunnel's web UI. Open one from the globe menu and it loads in an in‑app browser tab, starting the profile's tunnel first if needed (and routing through its SOCKS proxy when it has a dynamic forward)."),
            .tip("Saved commands and links can be **imported and exported** so you can share them between profiles or Macs."),
        ])

    // MARK: Workspaces

    static let workspaces = HelpArticle(
        id: "workspaces", title: "Workspaces", icon: "square.grid.2x2",
        blocks: [
            .paragraph("**Workspaces** are the big top‑level tabs — each holds its own set of terminal/browser/SFTP tabs. Use them to separate projects or environments."),
            .bullets([
                "Create one with **Workspace ▸ New Workspace** (⇧⌘N) and switch with **⇧⌘[** / **⇧⌘]**.",
                "**Save** a workspace's tab set to reopen the whole group later.",
                "**Closed one by accident?** The welcome screen's **Recently Closed** list reopens a closed tab or a whole workspace — even if it was never saved.",
                "Assign a profile to a workspace with **“Open in workspace”** in the editor — connecting that profile (and opening its SFTP/VNC tabs) switches to that workspace, creating it if needed.",
            ]),
            .tip("Leave **Open in workspace** blank to open the profile wherever you currently are."),
        ])

    // MARK: Tiling & detaching

    static let tilingDetaching = HelpArticle(
        id: "tiling", title: "Tiling & Detaching", icon: "rectangle.split.2x2",
        blocks: [
            .paragraph("See several tabs at once, pop one out of the window, or pin one to a side."),
            .bullets([
                "**Tile Tabs** (⌃⌘T) lays the current workspace's tabs out in a resizable grid. Drag the dividers to size each pane; the layout is remembered per workspace.",
                "**Dock a tab to any edge** with a right‑click → **Dock ▸ Dock Left / Right / Top / Bottom** (or ⌃⌘[ / ⌃⌘] for the sides, ⌃⌘↑ / ⌃⌘↓ for top/bottom). It slides out into a drawer on that edge while your other tabs stay in the center; top and bottom drawers span the width between your side drawers. **Stack several tabs** in one drawer and drag the dividers to size them; collapse a drawer to a thin rail (click it to slide back out), drag its edge divider to resize it, or use the return button to put a tab back. Edges, sizes and collapsed state are remembered per workspace.",
                "**Detach into New Window** (⌃⌘D) moves a tab into its own floating window without disturbing its connection. Closing the window re‑attaches the tab.",
                "A detached window can be **pinned always‑on‑top**.",
            ]),
        ])

    // MARK: SFTP

    static let sftp = HelpArticle(
        id: "sftp", title: "SFTP File Transfer", icon: "arrow.up.arrow.down",
        blocks: [
            .paragraph("Open an **SFTP tab** for any remote profile to move files with a graphical browser (right‑click a profile ▸ **Open SFTP**, the ⬆⬇ button, or ⌘K). With no profile, pick **New SFTP Connection…** from the **+** menu, **File ▸ New**, or the welcome screen to connect by host and port."),
            .bullets([
                "**Drag files or folders from Finder** onto the browser to upload them to the current folder — or **drop them onto a folder row** to upload straight into that folder.",
                "**Drag a file or folder out to Finder** (or the Desktop) to download it right where you drop it — the bytes are fetched on demand.",
                "**Double‑click a folder** to open it; use **↑ Up** and the **path menu** to navigate.",
                "**Double‑click a file** (or **Download**) to save it to your default folder (set with **Save to:**), or pick **Download To…** to choose a destination that one time.",
                "**New Folder**, **Rename** and **Delete** are on the toolbar and the right‑click menu.",
                "**Refresh** from the toolbar, the right‑click menu, or the **F5** key.",
            ]),
            .tip("Select several rows with ⌘‑click or ⇧‑click to download or delete them together. A **Log** button shows the raw `sftp` transcript if you need to troubleshoot."),
        ])

    // MARK: Finder tab

    static let finder = HelpArticle(
        id: "finder", title: "Finder Tab (Local Files)", icon: "folder",
        blocks: [
            .paragraph("A **Finder tab** browses files on **this Mac** — open one from the **+** menu, **File ▸ New Finder Tab**, or the command palette."),
            .bullets([
                "**Drag a file onto a terminal** to paste its full (shell‑quoted) path.",
                "**Drag a file onto an SFTP tab** to upload it to the server.",
                "Double‑click to open files/folders, toggle hidden files, make a new folder, reveal in Finder, copy a path, or move items to the Trash.",
            ]),
        ])

    // MARK: VNC

    static let vnc = HelpArticle(
        id: "vnc", title: "VNC Screen Sharing", icon: "display",
        blocks: [
            .paragraph("Open a **VNC tab** to view a server's screen over the SSH connection. The app forwards a local port to the server's VNC service and connects its **built‑in viewer** to it, so the remote desktop appears **right inside the tab** — tunneled and encrypted, no external app required."),
            .paragraph("Right‑click a remote profile ▸ **Open VNC**, use the display button in the sidebar, or the command palette. Or, with no profile at all, choose **New VNC Connection…** from the **+** menu / **File ▸ New** to connect the viewer **directly** to any host:port (not tunneled — best for a machine on your LAN)."),
            .paragraph("The desktop toolbar lets you switch between **Scale to fit** and **Actual size**, hand off to macOS **Screen Sharing** if you prefer it, view the raw `ssh` **Log**, or **Disconnect**. If the screen needs a password you'll be prompted (a Screen Sharing password, or an account name + password for *Apple Remote Desktop* auth) and can **remember** it in the Keychain."),
            .paragraph("For a VNC tab opened from a **profile**, the toolbar's **File Transfer** menu (↕) lets you **Open SFTP Browser** or **Upload Files…** to the same server over the SSH connection — handy for moving files while you work on the remote desktop. (Ad-hoc, non-tunneled VNC tabs have no SSH connection, so they don't offer file transfer.)"),
            .paragraph("**Right‑click the VNC tab** for a **VNC** menu with more options: **Scaling** (Scale to Fit / Actual Size), **Color Depth** (True Color, High Color or 256 Colors — drop it for a snappier picture over a slow link), **View Only** (watch without sending input), **Share Clipboard** (sync copy/paste with the remote), **Send Ctrl+Alt+Del**, **Reconnect**, and **Open in Screen Sharing**. Changing a display or input option briefly reconnects — your remembered password is reused, so you won't be asked again."),
            .paragraph("At **Actual Size** (scaling off), if the remote screen is bigger than the tab, scroll bars appear on the edges — **drag them to pan** around the desktop. (Two‑finger scrolling is sent to the remote computer, so use the scroll bars to move the view.) Switch back to **Scale to Fit** to see the whole screen at once."),
        ])

    // MARK: Services

    static let services = HelpArticle(
        id: "services", title: "Web / MQTT / Redis Tabs", icon: "antenna.radiowaves.left.and.right",
        blocks: [
            .paragraph("Tag a **Local port forward** with a **category** in the profile editor to get a one‑click tool against that forwarded port:"),
            .bullets([
                "**Web Page** — opens the port in an in‑app browser tab.",
                "**MQTT** — a native MQTT explorer with a **topic tree** (right‑click to Expand/Collapse) and publishing.",
                "**Redis** — a native Redis browser: scan keys, view typed values with TTLs, and run commands.",
            ]),
            .paragraph("You can also open **ad‑hoc** MQTT/Redis connections — not tied to a profile — from the **+** menu or **File ▸ New MQTT/Redis Connection**, pointing them at any host and port (optionally through a tunnel you've already started)."),
            .tip("A service password for a forward is stored in your Keychain, keyed to that forward — never in the profile file or exports."),
        ])

    // MARK: Links

    static let links = HelpArticle(
        id: "links", title: "Browser Tabs", icon: "globe",
        blocks: [
            .paragraph("**New Browser Tab** opens an in‑app web view you can point anywhere. It's handy for a tunnel's web UI (e.g. `localhost:8080`)."),
            .bullets([
                "A URL without a scheme defaults to `http` for localhost/IPs and `https` otherwise.",
                "Opening a profile **link** starts that profile's tunnel first, and routes through its SOCKS proxy if it has a dynamic (`-D`) forward.",
                "**F12** / ⌥⌘I opens the Web Inspector in the focused browser tab.",
            ]),
        ])

    // MARK: Palette & menu bar

    static let paletteAndMenuBar = HelpArticle(
        id: "palette", title: "Command Palette & Menu Bar", icon: "command",
        blocks: [
            .paragraph("Press **⌘K** for the **Command Palette** — a fast, searchable list of everything: connect to a profile, open SFTP/VNC, set up key login, run a saved command, re‑run history, and more."),
            .paragraph("The app also lives in the **menu bar**. From there you can show the main window, open a local terminal, connect profiles, and disconnect tunnels — even when the window is closed. In Settings you can launch **into the menu bar only** (no Dock icon or window at startup)."),
        ])

    // MARK: Updates

    static let updates = HelpArticle(
        id: "updates", title: "Updates & Versions", icon: "arrow.down.circle",
        blocks: [
            .paragraph("The app updates itself automatically using Sparkle. Updates are downloaded from the project's release feed and **verified with a cryptographic signature** before installing."),
            .bullets([
                "Check manually any time with **SSH Tunnel Manager ▸ Check for Updates…**.",
                "Toggle automatic checks in **Settings ▸ Updates**.",
                "See what changed in **Help ▸ Release Notes**, and grab an earlier build from **Help ▸ Download Older Versions**.",
            ]),
        ])

    // MARK: Shortcuts

    static let shortcuts = HelpArticle(
        id: "shortcuts", title: "Keyboard Shortcuts", icon: "keyboard",
        blocks: [
            .shortcuts([
                ("⌘ T", "New local terminal"),
                ("⇧⌘ T", "New browser tab"),
                ("⌘ K", "Command palette"),
                ("⌘ W", "Close tab"),
                ("⇧⌘ N", "New workspace"),
                ("⇧⌘ [  /  ⇧⌘ ]", "Previous / next workspace"),
                ("⌃⌘ D", "Detach tab into a window"),
                ("⌃⌘ T", "Tile tabs"),
                ("⇧⌘ D", "Disconnect all tunnels"),
                ("⌘ +  /  ⌘ −  /  ⌘ 0", "Terminal text bigger / smaller / actual size"),
                ("⌃⌘ S", "Show/Hide sidebar"),
                ("F5", "Refresh an SFTP tab"),
                ("F12  /  ⌥⌘ I", "Web Inspector in a browser tab"),
            ]),
        ])
}
