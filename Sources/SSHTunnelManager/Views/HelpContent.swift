import Foundation

/// The body of the in-app Help window — a comprehensive, friendly guide to every
/// feature. Authored as data so topics are easy to add, edit and search. Markdown
/// emphasis (**bold**, `code`) is supported in paragraphs and bullets.
enum HelpContent {
    static let articles: [HelpArticle] = [
        gettingStarted, profiles, organizing, tunnels, advancedOptions, automation,
        passwordless, terminal, snippets,
        workspaces, tilingDetaching, sftp, finder, textEditor, vnc, zerotier, services, links,
        sshConfig, paletteAndMenuBar, updates, settings, shortcuts,
    ]

    // MARK: Getting started

    static let gettingStarted = HelpArticle(
        id: "getting-started", title: "Getting Started", icon: "sparkles",
        blocks: [
            .paragraph("**Remote Stuff** keeps your SSH connections, port‑forwarding tunnels and remote tools one click away. Save each server as a **profile**, then connect, forward ports, browse files over SFTP, share screens over VNC, and open web/MQTT/Redis tools — all in tabs."),
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
            .paragraph("Right‑click a profile in the sidebar to **Connect**, open **SFTP/VNC**, **Set Up Passwordless Login**, **Edit**, **Duplicate**, **Export** or **Delete**. The **Command Preview** at the bottom of the editor shows the exact `ssh` command, which you can copy."),
            .tip("Give each profile an **icon** and a **theme** so its tabs are instantly recognizable."),
            .tip("If you try to quit while a profile editor is still open with unsaved changes, the app **asks whether to save** first — so edits are never lost by accident."),
        ])

    // MARK: Organizing profiles

    static let organizing = HelpArticle(
        id: "organizing", title: "Organizing Profiles", icon: "star",
        blocks: [
            .paragraph("As your list of profiles grows, the sidebar helps you keep it tidy and find things fast."),
            .bullets([
                "**Search** — the field at the top of the sidebar filters profiles as you type, matching the name and host.",
                "**Favourites** — star a profile (right‑click ▸ **Add to Favourites**, or the **Favourite** toggle in its editor's **Organization** section) to pin it to a **Favourites** section at the very top of the list.",
                "**Groups** — give profiles a **Group** name in that same **Organization** section and the sidebar collects them into **collapsible folders**. Click a group's header to fold it away; the collapsed state is remembered.",
            ]),
            .paragraph("Each connected profile shows a small **status dot**: **green** for a healthy tunnel, turning **orange** when one of its **local** port forwards stops answering. The app quietly probes the forwarded ports every few seconds, so a dead tunnel stands out without opening its tab."),
            .tip("Grouping is purely for your own organisation — a profile's **Group** doesn't change how it connects."),
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
            .paragraph("**Add or drop a forward without reconnecting**: right‑click a running tunnel's tab ▸ **Port Forwards** ▸ **Add Port Forward…**, or **Cancel** an existing one. This rides SSH's control connection, so the change applies to the live session — tick **Also save to the profile** to keep it for next time."),
            .bullets([
                "A **status dot** beside each connected profile in the sidebar turns **orange** if one of its **local** forwards stops answering, so a dead tunnel is easy to spot at a glance.",
            ]),
            .tip("Tag a **Local** forward with a **category** (Web / MQTT / Redis) to get a one‑click button that opens the right tool against that forwarded port — see **Service Tabs**."),
        ])

    // MARK: Advanced connection options

    static let advancedOptions = HelpArticle(
        id: "advanced-options", title: "Advanced Connection Options", icon: "gearshape.2",
        blocks: [
            .paragraph("The profile editor's **Advanced** section exposes the `ssh` options power users reach for. Everything here is mirrored live in the **Command Preview** at the foot of the editor, so you can see exactly what each toggle adds."),
            .bullets([
                "**Forward SSH agent (`-A`)** — lets a jump chain reuse your local keys without copying them onto intermediate hosts.",
                "**Add keys to the agent on first use** — caches the key's passphrase in `ssh-agent` so you're only asked once (`AddKeysToAgent=yes`).",
                "**Host key checking** — choose how strictly the server's key is verified (`StrictHostKeyChecking`): **ask**, **accept new** keys automatically, or refuse outright.",
                "**Connect timeout** — give up after N seconds rather than hang on an unreachable host (`ConnectTimeout`). Leave it at 0 for the system default.",
                "**Force a TTY (`-tt`)** — allocate a terminal for an interactive remote command such as `sudo`, `tmux` or a text menu.",
                "**Remote command** — run a specific command on the server instead of a plain login shell.",
                "**Environment (`SetEnv`)** — a small key/value editor for variables sent to the server (it must allow them with `AcceptEnv`).",
            ]),
            .paragraph("**Mosh (mobile shell)** — turn on **Use mosh** for a resilient session that survives sleep, Wi‑Fi changes and roaming. Install it first (e.g. `brew install mosh`). Note that **port forwards don't apply** to a mosh session, so keep a regular SSH profile for tunnels."),
        ])

    // MARK: Automation

    static let automation = HelpArticle(
        id: "automation", title: "Automation", icon: "wand.and.stars",
        blocks: [
            .paragraph("The profile editor's **Automation** section lets a connection look after itself."),
            .bullets([
                "**Connect automatically at launch** — bring this connection up as soon as the app starts, right after your last session is restored.",
                "**Reconnect automatically if the connection drops** — after an *unexpected* drop the app retries with a short, increasing backoff (a couple of seconds, then longer). It won't fight you when you disconnect on purpose.",
                "**Run on connect** — a command typed into the terminal once the shell is ready, e.g. `tmux attach || tmux new`.",
                "**Log this session to a file** — save a full transcript of the tab. Open it afterwards from the tab's right‑click menu ▸ **Reveal Session Log**; files live under *Application Support/SSHTunnelManager/Logs*.",
            ]),
            .tip("Pair **Connect at launch** with a saved **workspace** to have a whole set of tabs and tunnels ready the moment you open the app."),
        ])

    // MARK: Passwordless login

    static let passwordless = HelpArticle(
        id: "passwordless", title: "Passwordless Login", icon: "key",
        blocks: [
            .paragraph("**Set Up Passwordless Login** copies your SSH **public key** to a server with `ssh-copy-id`, so future connections sign in with the key — no password needed."),
            .steps([
                "Right‑click a profile (or use the 🔑 button, the tab menu, the command palette, or the profile editor) and choose **Set Up Passwordless Login**.",
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
                "**Broadcast input** (⌃⌘B, or the tab menu ▸ **Broadcast Input to All Terminals**) sends every keystroke to **all** open terminals at once — handy for running the same thing across a fleet. Toggle it off to type in one tab again.",
                "**Session logging** — enable **Log this session to a file** in a profile's **Automation** options to capture a transcript, then open it from the tab menu ▸ **Reveal Session Log**.",
                "**Clickable links** — when a web address appears in the terminal, **⌘‑click** it to open it in an in‑app browser tab (hold ⌘ and the link underlines). Non‑web links (mail, files…) open in their usual app.",
                "Drag a file from Finder (or a **Finder tab**) onto the terminal and choose **Paste Path** or **Paste Contents**.",
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
                "**Save** a workspace's tab set (with its tiling and drawers) to reopen the whole group later — and to use it as a profile's launch template.",
                "**Closed one by accident?** The welcome screen's **Recently Closed** list reopens a closed tab or a whole workspace — even if it was never saved.",
                "In a profile's editor, set **Launch in** to give the profile its own workspace: **New workspace** opens a fresh one (named after the profile, or a name you choose), or pick a **saved workspace** to recreate its tabs and layout each time you connect.",
            ]),
            .tip("Assigning a saved workspace to a profile makes connecting spin up a fresh, profile‑named workspace with all those tabs — reconnecting reuses it rather than duplicating. Leave **Launch in** on **Current workspace** to just open where you are."),
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
                "**Edit a file in place**: right‑click a file ▸ **Edit in Text Editor**. It downloads a temporary copy and opens it in a text‑editor tab; each **Save** (⌘S) uploads it straight back to the server. The editor's status bar shows a cloud badge — *Synced*, *Uploading…* or the failure reason.",
                "**Make a new file or folder**: use the toolbar's **New File** / **New Folder** buttons (or right‑click). New File creates it on the server and opens it in the editor so you can start typing.",
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
                "**Drag a file onto a terminal** and choose **Paste Path** (shell‑quoted) or **Paste Contents** (the file’s text).",
                "**Right‑click a file ▸ Open in Text Editor** to edit it in a built‑in editor tab.",
                "**Drag a file onto an SFTP tab** to upload it to the server.",
                "Double‑click to open files/folders, toggle hidden files, make a new folder, reveal in Finder, copy a path, or move items to the Trash.",
            ]),
        ])

    // MARK: Text editor

    static let textEditor = HelpArticle(
        id: "text-editor", title: "Text Editor", icon: "doc.text",
        blocks: [
            .paragraph("A built‑in **text editor tab** works like a lightweight Notepad++: open, edit and save text or code files with syntax highlighting, line numbers and find & replace. Open one from the **+** menu, **File ▸ New Text Editor** (⌘N), the welcome screen, or the command palette."),
            .bullets([
                "**Syntax highlighting** for 20+ languages (Swift, Python, JavaScript/TypeScript, JSON, HTML/XML, CSS, Markdown, shell, C/C++, Java, Go, Rust, Ruby, PHP, SQL, YAML, TOML/INI and more) — auto‑detected from the file extension, or pick it from the status‑bar menu.",
                "**Line numbers** in a gutter, **soft‑wrap** toggle, and **live font zoom** (⌘ + / ⌘ − / ⌘ 0).",
                "**Find & Replace** (⌘F, or ⌥⌘F to reveal replace) with **match case**, **whole word** and **regular‑expression** options, plus **Replace All**.",
                "The status bar shows the **line & column**, selection length, line/character counts, **encoding** and **line endings** (LF / CRLF / CR — switchable).",
                "An **Open** dialog reads any text file; **Save** / **Save As** write it back. Unsaved tabs show a **•** and prompt to save before closing.",
                "**Drag a file onto the editor** to open it — you'll get a quick confirmation, then its contents load into the tab.",
                "**Edit remote files over SFTP**: in an SFTP tab, right‑click a file ▸ **Edit in Text Editor**. Saving uploads it back to the server automatically (watch the status‑bar cloud badge).",
            ]),
            .tip("Reopened automatically on the next launch if the document was saved to a file — like every other tab."),
            .shortcuts([
                ("⌘ N", "New text editor"),
                ("⌘ O  /  ⌘ S", "Open / Save"),
                ("⇧⌘ S", "Save As"),
                ("⌘ F  /  ⌥⌘ F", "Find / Find & Replace"),
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

    // MARK: ZeroTier

    static let zerotier = HelpArticle(
        id: "zerotier", title: "ZeroTier Devices", icon: "globe.americas.fill",
        blocks: [
            .paragraph("Browse the devices on your **ZeroTier** networks and connect straight to any of their managed IP addresses — no need to look up addresses by hand. Open it from the **ZeroTier** button on the welcome screen, the globe button in the sidebar, or **File ▸ Browse ZeroTier Devices…**."),
            .steps([
                "Create an **API token** at *my.zerotier.com/account* and paste it into **Add an account**. Give it a name (e.g. *Work*) and click **Add**. Tokens are stored in your macOS **Keychain** (never synced, never in exports).",
                "Pick a network on the left — or **All Networks** — to list its **members**. Each device shows whether it's **online**, its node id, last‑seen time and every managed **IP address**.",
                "Type a **username** (used for SSH/SFTP), then click the **SSH**, **SFTP** or **VNC** button next to any IP to open a tab connected to that device.",
            ]),
            .bullets([
                "**Multiple accounts** — add as many ZeroTier API tokens as you like (one per ZeroTier login). Networks are grouped by account in the list, and the **All Networks** view shows every device together. Use the **key** button to add, rename, re‑token or remove accounts.",
                "**Self‑hosted controllers** (e.g. **ZTNET**) work too — when adding an account, put your server’s URL (e.g. `https://zt.example.com`) in the **Server** field and use that server’s API token. Leave **Server** blank for ZeroTier Central.",
                "**Filter** the list by name, node id or IP, and flip **Online only** to hide devices that are currently offline.",
                "Connections are **ad‑hoc** (profile‑free): your SSH keys are tried first and a typed password isn't stored. Create a profile for anything you use often.",
                "Tabs open **behind** the browser window — close it to see them, or connect to several devices in a row first.",
            ]),
            .tip("Anywhere you enter a host or IP — the **New Remote Terminal / SFTP / VNC / MQTT / Redis** sheets and the **profile editor** — a small **globe** button sits next to the field. Click it to pick a device IP from ZeroTier without leaving the form."),
            .tip("ZeroTier IPs are reachable only while this Mac is joined to the same network in the ZeroTier app. The browser just lists devices and dials them — it doesn't join networks for you."),
        ])

    // MARK: Services

    static let services = HelpArticle(
        id: "services", title: "Web / MQTT / Redis Tabs", icon: "antenna.radiowaves.left.and.right",
        blocks: [
            .paragraph("Tag a **Local port forward** with a **category** in the profile editor to get a one‑click tool against that forwarded port:"),
            .bullets([
                "**Web Page** — opens the port in an in‑app browser tab.",
                "**MQTT** — a native MQTT explorer with a **topic tree** (right‑click to Expand/Collapse), publishing, and a **Graph** view that plots a topic's numeric values (or individual JSON fields) live over time.",
                "**Redis** — a native Redis browser: scan keys, view typed values with TTLs, and run commands.",
            ]),
            .paragraph("Give a forward a **Name** in the profile editor and it shows up in the **Open …** menus and on the tab it launches — so several web forwards (or MQTT/Redis services) are easy to tell apart."),
            .paragraph("You can also open **ad‑hoc** MQTT/Redis connections — not tied to a profile — from the **+** menu or **File ▸ New MQTT/Redis Connection**, pointing them at any host and port (optionally through a tunnel you've already started)."),
            .paragraph("**Right‑click** an MQTT, Redis, VNC or SFTP tab and choose **Edit Connection…** to change its host, port or credentials and reconnect in place — handy for fixing a mistyped password or re‑pointing at another server without opening a new tab."),
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

    // MARK: SSH config & known hosts

    static let sshConfig = HelpArticle(
        id: "ssh-config", title: "SSH Config & Known Hosts", icon: "doc.plaintext",
        blocks: [
            .paragraph("The app plays nicely with your existing OpenSSH setup — import the hosts you already have, and tidy up `known_hosts` without touching the command line."),
            .paragraph("**Import from `~/.ssh/config`** — choose **File ▸ Import from ~/.ssh/config…** (also in the import/export menu at the foot of the sidebar) to turn each `Host` block into a profile. It reads the host name, user, port, identity file, jump host (`ProxyJump`), agent forwarding, compression, connect timeout and any `LocalForward` / `RemoteForward` / `DynamicForward` lines. Wildcard `Host *` blocks are skipped, and you review the list before anything is added."),
            .paragraph("**Manage Known Hosts** — choose **File ▸ Manage Known Hosts…** to browse every entry in `~/.ssh/known_hosts`. Filter the list, then remove a stale or changed key so the next connection can re‑learn it. It even removes **hashed** entries that `ssh-keygen -R` can't match by name."),
            .tip("Removing a known‑hosts entry is the fix for the *“REMOTE HOST IDENTIFICATION HAS CHANGED”* warning after a server is rebuilt — delete its line here and reconnect."),
        ])

    // MARK: Palette & menu bar

    static let paletteAndMenuBar = HelpArticle(
        id: "palette", title: "Command Palette & Menu Bar", icon: "command",
        blocks: [
            .paragraph("Press **⌘K** for the **Command Palette** — a fast, searchable list of everything: connect to a profile, open SFTP/VNC, set up passwordless login, run a saved command, re‑run history, and more."),
            .paragraph("The palette also searches your **command history across every open terminal**, not just the active one — start typing a command you ran earlier, anywhere, and pick it to focus that tab and run it again."),
            .paragraph("The app also lives in the **menu bar**. From there you can show the main window, open a local terminal, connect profiles, and disconnect tunnels — even when the window is closed. In Settings you can launch **into the menu bar only** (no Dock icon or window at startup)."),
        ])

    // MARK: Updates

    static let updates = HelpArticle(
        id: "updates", title: "Updates & Versions", icon: "arrow.down.circle",
        blocks: [
            .paragraph("The app updates itself automatically using Sparkle. Updates are downloaded from the project's release feed and **verified with a cryptographic signature** before installing."),
            .bullets([
                "Check manually any time with **Remote Stuff ▸ Check for Updates…**.",
                "Toggle automatic checks in **Settings ▸ Updates**.",
                "See what changed in **Help ▸ Release Notes**, and grab an earlier build from **Help ▸ Download Older Versions**.",
            ]),
        ])

    // MARK: Settings

    static let settings = HelpArticle(
        id: "settings", title: "Settings", icon: "gearshape",
        blocks: [
            .paragraph("Open **Settings** with **⌘,** or the app menu. Changes take effect right away; the **Startup** options apply the next time the app launches."),
            .paragraph("**Startup**"),
            .bullets([
                "**Start at login** — launch the app automatically when you sign in.",
                "**Launch into the menu bar** — start as a menu‑bar item with no window or Dock icon; use the menu bar ▸ **Show Main Window** to open it.",
                "**Resume last session** — reopen the tabs that were open when you last quit.",
            ]),
            .paragraph("**Terminal**"),
            .bullets([
                "**Default theme** and **text size** for plain local terminals — each profile carries its own.",
                "**Right‑click** behaviour: paste, smart copy/paste, or always show a menu. Smart copy/paste copies a selection and otherwise pastes, and can clear the selection after copying so the next right‑click pastes.",
            ]),
            .paragraph("**Editor**"),
            .bullets([
                "**Default theme** for new text‑editor tabs — each tab can still switch its own theme from the editor toolbar.",
            ]),
            .paragraph("**Updates**"),
            .bullets([
                "Toggle **automatic update checks**, or **Check Now** to look immediately. Updates are downloaded from the release feed and verified with a cryptographic signature before installing.",
            ]),
        ])

    // MARK: Shortcuts

    static let shortcuts = HelpArticle(
        id: "shortcuts", title: "Keyboard Shortcuts", icon: "keyboard",
        blocks: [
            .shortcuts([
                ("⌘ T", "New local terminal"),
                ("⇧⌘ T", "New browser tab"),
                ("⌘ N", "New text editor"),
                ("⌘ K", "Command palette"),
                ("⌘ W", "Close tab"),
                ("⇧⌘ N", "New workspace"),
                ("⇧⌘ [  /  ⇧⌘ ]", "Previous / next workspace"),
                ("⌃⌘ D", "Detach tab into a window"),
                ("⌃⌘ T", "Tile tabs"),
                ("⌃⌘ [  /  ⌃⌘ ]", "Dock tab left / right"),
                ("⌃⌘ ↑  /  ⌃⌘ ↓", "Dock tab top / bottom"),
                ("⇧⌘ D", "Disconnect all tunnels"),
                ("⌃⌘ B", "Broadcast input to all terminals"),
                ("⌘ +  /  ⌘ −  /  ⌘ 0", "Terminal text bigger / smaller / actual size"),
                ("⌃⌘ S", "Show/Hide sidebar"),
                ("F5", "Refresh an SFTP tab"),
                ("F12  /  ⌥⌘ I", "Web Inspector in a browser tab"),
                ("⌘ ?", "Open Help"),
            ]),
        ])
}
