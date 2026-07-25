using System.Collections.Generic;

namespace RemoteStuff.Models;

/// <summary>A single block of help content within an article.</summary>
public abstract class HelpBlock { }

public sealed class HelpParagraph : HelpBlock
{
    public required string Text { get; init; }
}

/// <summary>A bold sub-heading that breaks a long article into sections.</summary>
public sealed class HelpHeading : HelpBlock
{
    public required string Text { get; init; }
}

public sealed class HelpBullets : HelpBlock
{
    public required IReadOnlyList<string> Items { get; init; }
}

public sealed class HelpSteps : HelpBlock
{
    public required IReadOnlyList<string> Items { get; init; }
}

public sealed class HelpTip : HelpBlock
{
    public required string Text { get; init; }
}

public sealed class HelpShortcuts : HelpBlock
{
    public required IReadOnlyList<(string Keys, string Description)> Rows { get; init; }
}

/// <summary>One topic in the in-app help guide.</summary>
public sealed class HelpArticle
{
    public required string Id { get; init; }
    public required string Title { get; init; }
    public required string Icon { get; init; }
    public required IReadOnlyList<HelpBlock> Blocks { get; init; }
    public override string ToString() => Title;
}

/// <summary>The body of the in-app help guide, authored as data so topics are easy to edit.
/// Paragraphs, bullets, steps and tips support a little Markdown emphasis — **bold** and
/// `inline code` — which the Help window renders as styled text.</summary>
public static class HelpContent
{
    public static IReadOnlyList<HelpArticle> Articles { get; } = new List<HelpArticle>
    {
        // ─────────────────────────────────────────────────────────── Getting started
        new()
        {
            Id = "getting-started", Title = "Getting Started", Icon = "✨",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "**Remote Stuff** keeps your SSH servers, port-forwarding tunnels and remote tools one click away. Save each server as a **profile**, then connect, forward ports, browse files over SFTP, share screens over VNC, and open web / MQTT / Redis tools — all in tabs." },
                new HelpHeading { Text = "Create your first connection" },
                new HelpSteps { Items = new[]
                {
                    "Click the **+** at the top of the sidebar (or **Profile ▸ New…**) and give the profile a name and host.",
                    "Add a username, choose an SSH key or save a password, and add any **port forwards** you need.",
                    "Select the profile and press **Connect** (or double-click it) — a terminal tab opens with your tunnels running.",
                } },
                new HelpTip { Text = "No server yet? Open **New ▸ Local Shell** for a normal terminal on this machine, or a **Finder** tab to browse local files." },
                new HelpHeading { Text = "How the window is organised" },
                new HelpBullets { Items = new[]
                {
                    "The **sidebar** on the left lists your saved profiles — search, favourite and group them.",
                    "The **workspace bar** across the top holds your top-level workspaces; each one contains its own tabs.",
                    "The **+ menu** beside the tabs opens any new tab — terminal, SFTP, VNC, browser, editor and more.",
                    "Press **Ctrl+K** (**⌘K** on Mac) at any time to open the **Command Palette** and jump to anything.",
                } },
                new HelpParagraph { Text = "Drag tabs to reorder them, detach a tab into its own window, or tile several side by side." },
            }
        },

        // ─────────────────────────────────────────────────────────── Profiles
        new()
        {
            Id = "profiles", Title = "Profiles", Icon = "🗂",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "A **profile** stores everything about one connection: host, port, username, authentication, port forwards, environment, theme, saved commands and links. Manage them from the **Profile** menu or by right-clicking the sidebar." },
                new HelpHeading { Text = "The essentials" },
                new HelpBullets { Items = new[]
                {
                    "**Name & Host** are required; **Port** defaults to `22`.",
                    "**Username** and an optional **Jump host** — a jump host hops through a bastion (`ssh -J`).",
                    "**Authentication** — pick an SSH key file, or save a password to the OS credential store. Passwords are **never** included when you export.",
                    "**Local Shell** profiles open a shell on this machine in a chosen folder instead of connecting out.",
                    "**Icon**, **tab colour** and **terminal theme** make a profile's tabs instantly recognisable.",
                } },
                new HelpHeading { Text = "Working with profiles" },
                new HelpBullets { Items = new[]
                {
                    "**Right-click** a profile to Connect, open SFTP / VNC, Set Up Passwordless Login, Edit, Duplicate, Export or Delete.",
                    "**Profile ▸ Duplicate** copies a profile as a starting point; **Compare & Bulk Edit…** edits a setting across many profiles at once.",
                    "The **Command Preview** at the bottom of the editor shows the exact `ssh` command it will run — copy it any time.",
                } },
                new HelpTip { Text = "Store profiles in a Git repo with **Profile ▸ Sync Profiles with Git…** to share them across machines." },
            }
        },

        // ─────────────────────────────────────────────────────────── Organizing
        new()
        {
            Id = "organizing", Title = "Organising the Sidebar", Icon = "🗃",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "As your list grows, use search, favourites and groups to keep it tidy." },
                new HelpBullets { Items = new[]
                {
                    "**Search** — type in the box at the top of the sidebar to filter by name, host, username or group.",
                    "**Favourites** — click the **★** on a row (or set it in the editor) to pin a profile to a **Favourites** section at the top.",
                    "**Groups** — give profiles a **Group** name in the editor to gather them into collapsible sections. Right-click the sidebar to **Expand All** or **Collapse All**.",
                    "**Reorder** — drag a profile up or down within its group to arrange it.",
                    "**Status dot** — a coloured dot on a connected profile shows its live health (green = healthy, amber = degraded).",
                } },
                new HelpTip { Text = "Turn on **Right-click a profile connects immediately** in Settings if you prefer a single click to connect." },
            }
        },

        // ─────────────────────────────────────────────────────────── Tunnels
        new()
        {
            Id = "tunnels", Title = "Tunnels & Port Forwarding", Icon = "🔀",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Port forwards tunnel network traffic through your SSH connection. Add them in the profile editor under **Port Forwards**." },
                new HelpBullets { Items = new[]
                {
                    "**Local (`-L`)** — opens a port on *this* machine that forwards through the server to a target it can reach. Example: reach a remote database at `localhost:5432`.",
                    "**Remote (`-R`)** — opens a port on the *server* that forwards back to a target reachable from this machine.",
                    "**Dynamic / SOCKS (`-D`)** — runs a SOCKS proxy on this machine; apps pointed at it route through the server.",
                } },
                new HelpParagraph { Text = "Tunnels start as soon as you **Connect** the profile. The connection uses `ExitOnForwardFailure=yes`, so if a port is already taken the tab reports it instead of silently continuing." },
                new HelpTip { Text = "Tag a **Local** forward with a **category** (Web / MQTT / Redis) to get a one-click button that opens the right tool against that forwarded port — see **Web / MQTT / Redis Tabs**." },
            }
        },

        // ─────────────────────────────────────────────────────────── Advanced options
        new()
        {
            Id = "advanced-options", Title = "Advanced SSH Options", Icon = "🛠",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "The editor's advanced section maps friendly toggles onto real `ssh` options. Everything you set is reflected in the **Command Preview**." },
                new HelpBullets { Items = new[]
                {
                    "**Forward agent** (`-A`) and **Add keys to agent** — hand your local key to the server and load keys into the agent on connect.",
                    "**Request a TTY** (`-t`) — force a pseudo-terminal, useful when running a remote command interactively.",
                    "**Compression** (`-C`) and **Keep-alive** — squeeze slow links and stop idle sessions dropping.",
                    "**Connect timeout** — seconds to wait before giving up (`0` uses the ssh default).",
                    "**Host-key checking** — Ask, Accept-new, Yes or No (`StrictHostKeyChecking`).",
                    "**Remote command** — run a command on the server instead of an interactive shell.",
                    "**Environment variables** — send `NAME=VALUE` pairs with `SetEnv`.",
                    "**Extra options** — any raw `ssh -o` flags, appended verbatim for anything not covered above.",
                } },
                new HelpTip { Text = "Prefer a low-latency, roaming shell? Tick **Use mosh** to run the interactive session over mosh while your tunnels still run over ssh." },
            }
        },

        // ─────────────────────────────────────────────────────────── Automation
        new()
        {
            Id = "automation", Title = "Automation & Sessions", Icon = "🔁",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Make connections happen on their own and keep them alive." },
                new HelpBullets { Items = new[]
                {
                    "**Connect on launch** — mark a profile to connect automatically when the app starts.",
                    "**Auto-reconnect** — reopen the session automatically if it drops.",
                    "**Run on connect** — a command typed into the terminal for you once the shell is ready (e.g. `tmux attach`).",
                    "**Log session** — save the terminal output to a file in the app's Logs folder for a record of what happened.",
                    "**Resume last session** — a Settings option that reopens the tabs you had open when you last quit.",
                } },
                new HelpTip { Text = "Combine **Connect on launch** with **Launch in its own workspace** to have a project's whole tab set spring up when you open the app." },
            }
        },

        // ─────────────────────────────────────────────────────────── Passwordless
        new()
        {
            Id = "passwordless", Title = "Passwordless Login", Icon = "🔑",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Install your SSH public key on a server so you can connect without typing a password. Right-click a profile ▸ **Set Up Passwordless Login** (also in the Command Palette)." },
                new HelpSteps { Items = new[]
                {
                    "Pick the key to install — the app offers your existing public keys, or can generate a new key pair.",
                    "It runs `ssh-copy-id` for you, prompting once for the server password to authorise the copy.",
                    "From then on the profile connects using the key. Passwords are only used for that one setup step.",
                } },
                new HelpTip { Text = "No key yet? The setup flow can create one, then install it in the same step." },
            }
        },

        // ─────────────────────────────────────────────────────────── Terminal
        new()
        {
            Id = "terminal", Title = "The Terminal", Icon = "⌨",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Terminal tabs are full xterm-style terminals with colour, resizing and scrollback. Open a **Remote Terminal** on a server, or a **Local Shell** on this machine." },
                new HelpHeading { Text = "Everyday use" },
                new HelpBullets { Items = new[]
                {
                    "**Copy & paste** with your platform's usual shortcuts; selecting text copies it on most systems.",
                    "**Zoom** the text size in or out, and pick a colour **theme** per profile.",
                    "**Command history (🕘)** in the tab header lists the commands you've run **this session** (up to 200) so you can re-run one — history is in-session only.",
                    "**Clear scrollback** wipes the buffer; **Save log** writes the visible output to a file.",
                } },
                new HelpHeading { Text = "Broadcast typing" },
                new HelpParagraph { Text = "Turn on **Broadcast Typing to All Terminals** to type the same command into every open terminal at once — handy for running one thing across a fleet. Turn it off again from the same menu." },
                new HelpTip { Text = "If a server's host key changes, the terminal warns you and refuses to connect until you clear the old key — see **SSH Config & Known Hosts**." },
            }
        },

        // ─────────────────────────────────────────────────────────── Snippets & links
        new()
        {
            Id = "snippets", Title = "Saved Commands & Links", Icon = "⌥",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Give a profile a small library of reusable commands and web links in its editor." },
                new HelpBullets { Items = new[]
                {
                    "**Saved commands** — name a command (e.g. *Tail logs* → `tail -f /var/log/syslog`) and insert it into the session's terminal from the tab, or run it from the Command Palette.",
                    "**Links** — save labelled URLs (e.g. a router UI on a forwarded port). Opening a link starts the profile's tunnel first, and routes through its SOCKS proxy if it has a dynamic (`-D`) forward.",
                } },
                new HelpTip { Text = "Saved commands are the fastest way to standardise routine tasks across a team when you share profiles over Git." },
            }
        },

        // ─────────────────────────────────────────────────────────── Workspaces
        new()
        {
            Id = "workspaces", Title = "Workspaces", Icon = "🔳",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "**Workspaces** are the big top-level tabs — each holds its own set of terminal / browser / SFTP tabs. Use them to separate projects or environments. Manage them from the **Workspace** menu." },
                new HelpBullets { Items = new[]
                {
                    "**New Workspace** creates an empty one; switch with the workspace bar or **Next / Previous Workspace**.",
                    "**Rename Workspace…** and **Close Workspace** tidy them up.",
                    "**Save Current Workspace…** stores its whole tab set to reopen later via **Open Saved Workspace ▸**.",
                    "**Save Current Workspace as Profile…** turns a layout into a launcher: opening that profile recreates the whole workspace, re-pointed at its host.",
                    "In a profile's editor, set **Launch in ▸ its own workspace** to give the profile a dedicated workspace on connect.",
                } },
                new HelpTip { Text = "Closed one by accident? The welcome screen's **Recently Closed** list reopens a closed tab or a whole workspace." },
            }
        },

        // ─────────────────────────────────────────────────────────── Tiling
        new()
        {
            Id = "tiling", Title = "Tiling, Docking & Detaching", Icon = "🀫",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "See several tabs at once, pop one out of the window, or pin one to a side. Right-click a tab for these options." },
                new HelpBullets { Items = new[]
                {
                    "**Dock ▸ Left / Right / Top / Bottom** slides a tab into a drawer on that edge while your other tabs stay in the centre; **Move to Centre** brings it back.",
                    "**Detach into New Window** moves a tab into its own floating window without disturbing its connection. Closing the window re-attaches the tab. (Double-clicking a terminal tab also detaches it.)",
                    "**Tile mode** shows multiple tabs side by side in a grid.",
                    "**Rename Tab…**, **Tab Colour** and **Duplicate Tab** help you keep busy layouts readable.",
                } },
                new HelpTip { Text = "Drag tabs along the strip to reorder them at any time." },
            }
        },

        // ─────────────────────────────────────────────────────────── SFTP
        new()
        {
            Id = "sftp", Title = "SFTP File Transfer", Icon = "↕",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Open an **SFTP** tab to move files with a graphical browser. Right-click a profile ▸ **Open SFTP**, or choose **New SFTP Connection…** from the + menu to connect by host and port." },
                new HelpBullets { Items = new[]
                {
                    "**Navigate** — double-click a folder to open it; use **Up** and the path menu to move around.",
                    "**Transfer** — double-click a file (or **Download**) to save it, or **Download To…** to pick a destination. Drag files between an SFTP tab and a **Finder** tab.",
                    "**Manage** — **New Folder**, **Rename** and **Delete** are on the toolbar and the right-click menu.",
                    "**Edit in place** — right-click a file ▸ **Edit in Text Editor**. It downloads a temporary copy; each **Save** uploads it straight back to the server.",
                } },
                new HelpHeading { Text = "Mount as a folder" },
                new HelpParagraph { Text = "**Mount** attaches the remote filesystem as a local folder (via sshfs) under `~/mnt/<name>`, so any app on your machine can open its files. **Reveal mounted folder** opens it, and **Unmount** detaches it." },
                new HelpTip { Text = "A **Log** button shows the raw sftp transcript if you need to troubleshoot a transfer." },
            }
        },

        // ─────────────────────────────────────────────────────────── Finder
        new()
        {
            Id = "finder", Title = "Finder Tab (Local Files)", Icon = "📁",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "A **Finder** tab browses files on *this* machine — open one from the **New** or **+** menu, or the Command Palette." },
                new HelpBullets { Items = new[]
                {
                    "Type a path (or `~`) in the path bar and press **Enter** to jump straight there.",
                    "Sort by name, size, modified date or kind, and flip the sort direction.",
                    "Filter the listing as you type, and toggle hidden files.",
                    "Right-click a file ▸ **Open in Text Editor** to edit it in a built-in editor tab.",
                } },
            }
        },

        // ─────────────────────────────────────────────────────────── Text editor
        new()
        {
            Id = "text-editor", Title = "Text Editor", Icon = "📄",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "A built-in **Text Editor** tab works like a lightweight code editor: open, edit and save text or code with syntax highlighting, line numbers and find & replace." },
                new HelpBullets { Items = new[]
                {
                    "**Syntax highlighting** for many languages, auto-detected from the file extension.",
                    "**Line numbers**, soft-wrap toggle and live font **zoom**.",
                    "**Find & Replace** (🔍) with **match case**, **whole word** and **regular-expression** options.",
                    "**Go to line** with `Ctrl+G`, and **toggle a comment** with `Ctrl+/`.",
                    "**Compare / Diff** two files side by side, and switch the file **encoding** (UTF-8, UTF-8 with BOM, UTF-16).",
                    "Edit **remote** files over SFTP: in an SFTP tab, right-click a file ▸ **Edit in Text Editor**. Saving uploads it back to the server.",
                } },
                new HelpShortcuts { Rows = new[]
                {
                    ("Ctrl+G", "Go to line"),
                    ("Ctrl+F", "Find & Replace"),
                    ("Ctrl+/", "Toggle line comment"),
                    ("Alt+↑ / Alt+↓", "Move the current line up / down"),
                    ("Ctrl+Shift+D", "Duplicate the current line"),
                    ("Ctrl+Shift+K", "Delete the current line"),
                } },
            }
        },

        // ─────────────────────────────────────────────────────────── Spreadsheet
        new()
        {
            Id = "spreadsheet", Title = "Spreadsheets & CSV", Icon = "▦",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Open a **Spreadsheet** tab to view and edit **CSV**, **TSV** and **Excel (.xlsx)** files in a grid." },
                new HelpBullets { Items = new[]
                {
                    "Add or delete rows and columns, rename columns, and toggle a header row.",
                    "Sort by any column (right-click a column header), and switch the delimiter for text files.",
                    "Excel files keep their **worksheets** — add, rename, delete and switch between sheets.",
                    "**Save** writes back to the same format, or use **Save As** to change it.",
                } },
                new HelpTip { Text = "This is a data grid, not a calculator — it edits values and structure, but doesn't evaluate spreadsheet formulas." },
            }
        },

        // ─────────────────────────────────────────────────────────── VNC
        new()
        {
            Id = "vnc", Title = "VNC Screen Sharing", Icon = "🖥",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Open a **VNC** tab to reach a server's screen over the SSH connection. The app forwards a local port to the server's VNC service, then hands off to your **system VNC viewer** — tunnelled and encrypted." },
                new HelpParagraph { Text = "Right-click a remote profile ▸ **Open VNC**, or use the Command Palette. With no profile, choose **New VNC Connection…** to connect directly to any `host:port` (not tunnelled — best for a machine on your LAN)." },
                new HelpParagraph { Text = "The tab shows the tunnel status and a **Log** expander with the raw ssh output. Click **Open Viewer** once it's ready, or **Reconnect** / **Disconnect** from the toolbar." },
            }
        },

        // ─────────────────────────────────────────────────────────── Services
        new()
        {
            Id = "services", Title = "Web / MQTT / Redis Tabs", Icon = "📶",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Tag a **Local** port forward with a **category** in the profile editor to get a one-click tool against that forwarded port:" },
                new HelpBullets { Items = new[]
                {
                    "**Web Page** — opens the port in an in-app browser tab.",
                    "**MQTT** — a native MQTT explorer with subscribe / publish, a message list, and a live **Graph** of a topic's numeric values.",
                    "**Redis** — a native Redis browser: scan keys, view typed values with TTLs, and run raw commands.",
                } },
                new HelpParagraph { Text = "You can also open **ad-hoc** MQTT or Redis connections — not tied to a profile — from the **+** menu (**New MQTT / Redis Connection…**) or the welcome screen, pointing them at any host and port." },
            }
        },

        // ─────────────────────────────────────────────────────────── Browser
        new()
        {
            Id = "links", Title = "Browser Tabs", Icon = "🌍",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "**New ▸ Browser** opens an in-app web view you can point anywhere. It's handy for a tunnel's web UI (e.g. `localhost:8080`)." },
                new HelpBullets { Items = new[]
                {
                    "A URL without a scheme defaults to `http` for `localhost` / IPs and `https` otherwise.",
                    "Opening a **profile link** starts that profile's tunnel first, and routes through its SOCKS proxy if it has a dynamic (`-D`) forward.",
                } },
            }
        },

        // ─────────────────────────────────────────────────────────── Network
        new()
        {
            Id = "network", Title = "Network Browser", Icon = "🌐",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "A **Network** tab shows this machine's interfaces (addresses, MAC, gateway, DNS and public IP) and scans your local subnet for live hosts." },
                new HelpBullets { Items = new[]
                {
                    "**Refresh** re-reads the interface list and looks up the public IP.",
                    "Enter a `/24` subnet and press **Scan** to ping-sweep it; results resolve reverse-DNS names as they arrive.",
                    "**Stop** halts an in-progress scan.",
                } },
            }
        },

        // ─────────────────────────────────────────────────────────── MikroTik
        new()
        {
            Id = "mikrotik", Title = "MikroTik Router", Icon = "📡",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "A **MikroTik** tab talks to a RouterOS device over its REST API to view status and manage the router." },
                new HelpBullets { Items = new[]
                {
                    "Connect with host, port, username and password (tick **HTTPS** for a TLS API; self-signed certs are accepted).",
                    "Browse the **Overview**, **Interfaces**, **Addresses** and **DHCP Leases** tabs; enable or disable an interface inline.",
                    "Export the running config, apply a config snippet, reboot, or explore any menu path.",
                } },
            }
        },

        // ─────────────────────────────────────────────────────────── ZeroTier
        new()
        {
            Id = "zerotier", Title = "ZeroTier Devices", Icon = "🌎",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "The **ZeroTier** panel (toggle it from the button at the right of the toolbar) browses the devices on your ZeroTier networks so you can connect straight to any of their managed IP addresses." },
                new HelpSteps { Items = new[]
                {
                    "Create an API token at **my.zerotier.com/account** and paste it into **Add an account**. Tokens are stored in the OS credential store.",
                    "Pick a network to list its members — each device shows whether it's online, its node id and managed IPs.",
                    "Type a username, then click **SSH**, **SFTP** or **VNC** next to any IP to open a tab connected to that device.",
                } },
                new HelpTip { Text = "Self-hosted controllers (e.g. ZTNET) work too — put your server's URL in the **Server** field when adding an account." },
            }
        },

        // ─────────────────────────────────────────────────────────── Connection health
        new()
        {
            Id = "connection-health", Title = "Connection Health", Icon = "💓",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Keep an eye on how your live connections are doing." },
                new HelpBullets { Items = new[]
                {
                    "A **status dot** on each connected profile in the sidebar shows its current health at a glance.",
                    "Right-click a workspace and choose **Connection Health…** for a panel of latency sparklines across its sessions.",
                    "Turn on **Keep-alive** and **Auto-reconnect** in a profile to ride out brief network drops.",
                } },
            }
        },

        // ─────────────────────────────────────────────────────────── SSH config & known hosts
        new()
        {
            Id = "ssh-config", Title = "SSH Config & Known Hosts", Icon = "🔐",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Reuse what you already have in your `~/.ssh` folder, and manage host keys when servers change." },
                new HelpHeading { Text = "Import your ~/.ssh/config" },
                new HelpParagraph { Text = "**Tools ▸ Import from ~/.ssh/config** reads your existing SSH config and creates a profile for each `Host` entry — hostnames, users, ports, identity files and jump hosts included — so you don't have to re-enter them." },
                new HelpHeading { Text = "Manage known hosts" },
                new HelpParagraph { Text = "**Tools ▸ Manage Known Hosts…** lists the server fingerprints in your `known_hosts` file. If a server is rebuilt and its host key changes, ssh refuses to connect — remove the stale entry here to trust the new key." },
                new HelpTip { Text = "A changed host key can also mean a genuine security problem. Only clear an entry when you're sure the change is expected." },
            }
        },

        // ─────────────────────────────────────────────────────────── Git sync
        new()
        {
            Id = "git-sync", Title = "Sync Profiles with Git", Icon = "🔄",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "**Profile ▸ Sync Profiles with Git…** keeps your profiles in a Git repository so you can share them across machines or with a team." },
                new HelpBullets { Items = new[]
                {
                    "Point it at a repo to **push** your current profiles or **pull** the latest set.",
                    "Only profile *settings* travel with Git — **passwords and secrets stay in each machine's own credential store** and are never committed.",
                    "Combine with **saved commands** and **links** so a shared profile carries your team's standard workflows.",
                } },
            }
        },

        // ─────────────────────────────────────────────────────────── Command palette
        new()
        {
            Id = "palette", Title = "Command Palette", Icon = "⌘",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Press **Ctrl+K** (**⌘K** on Mac) to open the **Command Palette** — a fast, searchable list of everything: connect to a profile, open SFTP / VNC, set up passwordless login, run a saved command, toggle broadcast, manage known hosts and more." },
                new HelpShortcuts { Rows = new[]
                {
                    ("Ctrl+K / ⌘K", "Open the palette"),
                    ("Type", "Fuzzy-filter the list"),
                    ("↑ / ↓", "Move the selection"),
                    ("Enter", "Run the selected item"),
                    ("Esc", "Close the palette"),
                } },
            }
        },

        // ─────────────────────────────────────────────────────────── Menu bar / tray
        new()
        {
            Id = "tray", Title = "Menu Bar & Tray", Icon = "🍎",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Remote Stuff adds a **menu-bar / system-tray** icon so your servers are reachable without bringing the whole window forward." },
                new HelpBullets { Items = new[]
                {
                    "Connect to a profile or open a saved workspace straight from the tray menu.",
                    "**Disconnect All** closes every live session at once.",
                    "**Show** brings the window back; **Quit** exits the app.",
                    "Turn on **Menu-bar only** in Settings to run without a Dock / taskbar entry.",
                } },
            }
        },

        // ─────────────────────────────────────────────────────────── Updates
        new()
        {
            Id = "updates", Title = "Updates", Icon = "⬇",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Remote Stuff can update itself so you're always on the latest release." },
                new HelpBullets { Items = new[]
                {
                    "**Tools ▸ Check for Updates…** looks for a newer version right away and offers to install it.",
                    "Leave **Automatically check for updates** on in Settings to be told when one is ready.",
                    "Updates download in the background and apply on the next restart.",
                } },
            }
        },

        // ─────────────────────────────────────────────────────────── Settings
        new()
        {
            Id = "settings", Title = "Settings", Icon = "⚙",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Open **Tools ▸ Preferences…** (or the Command Palette). Most changes take effect right away; startup options apply the next time the app launches." },
                new HelpHeading { Text = "General" },
                new HelpBullets { Items = new[]
                {
                    "**Resume last session** — reopen the tabs that were open when you last quit.",
                    "**Start at login** — launch Remote Stuff automatically when you sign in.",
                    "**Menu-bar only** — run from the tray without a Dock / taskbar entry.",
                    "**Confirm before closing** — ask before quitting with live sessions open.",
                } },
                new HelpHeading { Text = "Appearance & behaviour" },
                new HelpBullets { Items = new[]
                {
                    "**Theme** — Light, Dark or Auto (follow the system).",
                    "**Right-click a profile connects immediately** — one-click connecting from the sidebar.",
                    "**Automatically check for updates** — see **Updates**.",
                } },
                new HelpHeading { Text = "Terminal" },
                new HelpBullets { Items = new[]
                {
                    "Default terminal **theme** and text **size** (8–36 pt) for new terminals.",
                } },
            }
        },

        // ─────────────────────────────────────────────────────────── Shortcuts
        new()
        {
            Id = "shortcuts", Title = "Keyboard Shortcuts", Icon = "⌨",
            Blocks = new HelpBlock[]
            {
                new HelpHeading { Text = "Anywhere" },
                new HelpShortcuts { Rows = new[]
                {
                    ("Ctrl+K / ⌘K", "Open the Command Palette"),
                } },
                new HelpHeading { Text = "In the Command Palette" },
                new HelpShortcuts { Rows = new[]
                {
                    ("↑ / ↓", "Move the selection"),
                    ("Enter", "Run the selected item"),
                    ("Esc", "Close the palette"),
                } },
                new HelpHeading { Text = "In the Text Editor" },
                new HelpShortcuts { Rows = new[]
                {
                    ("Ctrl+G", "Go to line"),
                    ("Ctrl+F", "Find & Replace"),
                    ("Ctrl+/", "Toggle line comment"),
                    ("Alt+↑ / Alt+↓", "Move line up / down"),
                    ("Ctrl+Shift+D", "Duplicate line"),
                    ("Ctrl+Shift+K", "Delete line"),
                } },
                new HelpHeading { Text = "Files & tabs" },
                new HelpShortcuts { Rows = new[]
                {
                    ("Enter", "Go to the typed path (Finder / SFTP)"),
                    ("Double-click a tab", "Detach a terminal into its own window"),
                    ("Drag a tab", "Reorder it along the strip"),
                } },
                new HelpTip { Text = "Almost every action also lives in the **Command Palette** (Ctrl+K), so you rarely need to remember a shortcut." },
            }
        },
    };
}
