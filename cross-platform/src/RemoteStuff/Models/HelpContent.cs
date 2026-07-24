using System.Collections.Generic;

namespace RemoteStuff.Models;

/// <summary>A single block of help content within an article.</summary>
public abstract class HelpBlock { }

public sealed class HelpParagraph : HelpBlock
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

/// <summary>The body of the in-app help guide, authored as data so topics are easy to edit.</summary>
public static class HelpContent
{
    public static IReadOnlyList<HelpArticle> Articles { get; } = new List<HelpArticle>
    {
        new()
        {
            Id = "getting-started", Title = "Getting Started", Icon = "✨",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Remote Stuff keeps your SSH connections, port-forwarding tunnels and remote tools one click away. Save each server as a profile, then connect, forward ports, browse files over SFTP, share screens over VNC, and open web/MQTT/Redis tools — all in tabs." },
                new HelpSteps { Items = new[]
                {
                    "Click + in the sidebar (or New Profile) and enter a name and host.",
                    "Add a username, an SSH key or password, and any port forwards you need.",
                    "Select the profile and press Connect — a terminal tab opens with your tunnels running.",
                } },
                new HelpTip { Text = "No server yet? Open a New Local Terminal for a normal shell on this machine, or a Finder tab to browse local files." },
                new HelpParagraph { Text = "Everything lives in tabs inside workspaces. Drag tabs to reorder, detach a tab into its own window, or tile several side by side." },
            }
        },
        new()
        {
            Id = "profiles", Title = "Profiles", Icon = "🗂",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "A profile stores everything about one connection: host, port, username, authentication, port forwards, theme, saved commands and links." },
                new HelpBullets { Items = new[]
                {
                    "Name & host are required.",
                    "Username / Jump host — optional; a jump host hops through a bastion (ssh -J).",
                    "Authentication — choose an SSH key, or save a password to the OS credential store. Passwords are never included when you export.",
                    "Local Shell profiles open a shell on this machine in a chosen folder instead of connecting out.",
                } },
                new HelpParagraph { Text = "Right-click a profile in the sidebar to Connect, open SFTP/VNC, Set Up Passwordless Login, Edit, Duplicate, Export or Delete. The Command Preview at the bottom of the editor shows the exact ssh command, which you can copy." },
                new HelpTip { Text = "Give each profile an icon and a theme so its tabs are instantly recognizable." },
            }
        },
        new()
        {
            Id = "tunnels", Title = "Tunnels & Port Forwarding", Icon = "🔀",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Port forwards tunnel network traffic through your SSH connection. Add them in the profile editor under Port Forwards." },
                new HelpBullets { Items = new[]
                {
                    "Local (-L) — opens a port on this machine that forwards through the server to a target it can reach. Example: reach a remote database at localhost:5432.",
                    "Remote (-R) — opens a port on the server that forwards back to a target reachable from this machine.",
                    "Dynamic / SOCKS (-D) — runs a SOCKS proxy on this machine; apps pointed at it route through the server.",
                } },
                new HelpParagraph { Text = "Tunnels start as soon as you Connect the profile. The connection uses ExitOnForwardFailure=yes, so if a port is already taken the tab reports it instead of silently continuing." },
                new HelpTip { Text = "Tag a Local forward with a category (Web / MQTT / Redis) to get a one-click button that opens the right tool against that forwarded port." },
            }
        },
        new()
        {
            Id = "workspaces", Title = "Workspaces", Icon = "🔳",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Workspaces are the big top-level tabs — each holds its own set of terminal/browser/SFTP tabs. Use them to separate projects or environments." },
                new HelpBullets { Items = new[]
                {
                    "Create one with New Workspace and switch between them from the workspace bar.",
                    "Save a workspace's tab set to reopen the whole group later — and to use it as a profile's launch template.",
                    "Closed one by accident? The welcome screen's Recently Closed list reopens a closed tab or a whole workspace.",
                    "In a profile's editor, set Launch in to give the profile its own workspace.",
                } },
            }
        },
        new()
        {
            Id = "tiling", Title = "Tiling & Detaching", Icon = "🀫",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "See several tabs at once, pop one out of the window, or pin one to a side." },
                new HelpBullets { Items = new[]
                {
                    "Dock a tab to any edge with a right-click → Dock ▸ Left / Right / Top / Bottom. It slides out into a drawer on that edge while your other tabs stay in the center.",
                    "Detach into New Window moves a tab into its own floating window without disturbing its connection. Closing the window re-attaches the tab.",
                } },
            }
        },
        new()
        {
            Id = "sftp", Title = "SFTP File Transfer", Icon = "↕",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Open an SFTP tab for any remote profile to move files with a graphical browser (right-click a profile ▸ Open SFTP). With no profile, pick New SFTP Connection… to connect by host and port." },
                new HelpBullets { Items = new[]
                {
                    "Double-click a folder to open it; use Up and the path menu to navigate.",
                    "Double-click a file (or Download) to save it to your default folder, or pick Download To… to choose a destination.",
                    "New Folder, Rename and Delete are on the toolbar and the right-click menu.",
                    "Edit a file in place: right-click a file ▸ Edit in Text Editor. It downloads a temporary copy; each Save uploads it straight back to the server.",
                } },
                new HelpTip { Text = "A Log button shows the raw sftp transcript if you need to troubleshoot." },
            }
        },
        new()
        {
            Id = "finder", Title = "Finder Tab (Local Files)", Icon = "📁",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "A Finder tab browses files on this machine — open one from the + menu or the command palette." },
                new HelpBullets { Items = new[]
                {
                    "Type a path (or ~) in the path bar and press Enter to jump straight there.",
                    "Sort by name, size, modified date or kind, and flip the sort direction.",
                    "Filter the listing as you type, and toggle hidden files.",
                    "Right-click a file ▸ Open in Text Editor to edit it in a built-in editor tab.",
                } },
            }
        },
        new()
        {
            Id = "text-editor", Title = "Text Editor", Icon = "📄",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "A built-in text editor tab works like a lightweight code editor: open, edit and save text or code files with syntax highlighting, line numbers and find & replace." },
                new HelpBullets { Items = new[]
                {
                    "Syntax highlighting for many languages, auto-detected from the file extension.",
                    "Line numbers, soft-wrap toggle, and live font zoom.",
                    "Find & Replace with match case, whole word and regular-expression options.",
                    "Edit remote files over SFTP: in an SFTP tab, right-click a file ▸ Edit in Text Editor. Saving uploads it back to the server.",
                } },
            }
        },
        new()
        {
            Id = "spreadsheet", Title = "Spreadsheets & CSV", Icon = "▦",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Open a spreadsheet tab to view and edit CSV, TSV and Excel (.xlsx) files in a grid." },
                new HelpBullets { Items = new[]
                {
                    "Add or delete rows and columns, rename columns, and toggle a header row.",
                    "Sort by any column (right-click a column header), and switch the delimiter for text files.",
                    "Excel files keep their worksheets — add, delete, rename and switch between sheets.",
                    "Save writes back to the same format, or use Save As to change it.",
                } },
            }
        },
        new()
        {
            Id = "vnc", Title = "VNC Screen Sharing", Icon = "🖥",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Open a VNC tab to reach a server's screen over the SSH connection. The app forwards a local port to the server's VNC service, then hands off to your system VNC viewer — tunneled and encrypted." },
                new HelpParagraph { Text = "Right-click a remote profile ▸ Open VNC, or use the command palette. With no profile, choose New VNC Connection… to connect directly to any host:port (not tunneled — best for a machine on your LAN)." },
                new HelpParagraph { Text = "The tab shows the tunnel status and a Log expander with the raw ssh output. Click Open Viewer once it's ready, or Reconnect / Disconnect from the toolbar." },
            }
        },
        new()
        {
            Id = "network", Title = "Network Browser", Icon = "🌐",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "A Network tab shows this machine's interfaces (addresses, MAC, gateway, DNS and public IP) and scans your local subnet for live hosts." },
                new HelpBullets { Items = new[]
                {
                    "Refresh re-reads the interface list and looks up the public IP.",
                    "Enter a /24 subnet and press Scan to ping-sweep it; results resolve reverse-DNS names as they arrive.",
                    "Stop halts an in-progress scan.",
                } },
            }
        },
        new()
        {
            Id = "mikrotik", Title = "MikroTik Router", Icon = "📡",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "A MikroTik tab talks to a RouterOS device over its REST API to view status and manage the router." },
                new HelpBullets { Items = new[]
                {
                    "Connect with host, port, username and password (tick HTTPS for a TLS API, self-signed certs are accepted).",
                    "Browse the Overview, Interfaces, Addresses and DHCP Leases tabs; enable or disable an interface inline.",
                    "Export the running config, apply a config snippet, reboot, or explore any menu path.",
                } },
            }
        },
        new()
        {
            Id = "zerotier", Title = "ZeroTier Devices", Icon = "🌎",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Browse the devices on your ZeroTier networks and connect straight to any of their managed IP addresses." },
                new HelpSteps { Items = new[]
                {
                    "Create an API token at my.zerotier.com/account and paste it into Add an account. Tokens are stored in the OS credential store.",
                    "Pick a network to list its members — each device shows whether it's online, its node id and managed IPs.",
                    "Type a username, then click SSH, SFTP or VNC next to any IP to open a tab connected to that device.",
                } },
                new HelpTip { Text = "Self-hosted controllers (e.g. ZTNET) work too — put your server's URL in the Server field when adding an account." },
            }
        },
        new()
        {
            Id = "services", Title = "Web / MQTT / Redis Tabs", Icon = "📶",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Tag a Local port forward with a category in the profile editor to get a one-click tool against that forwarded port:" },
                new HelpBullets { Items = new[]
                {
                    "Web Page — opens the port in an in-app browser tab.",
                    "MQTT — a native MQTT explorer with subscribe/publish, a message list, and a live Graph of a topic's numeric values.",
                    "Redis — a native Redis browser: scan keys, view typed values with TTLs, and run raw commands.",
                } },
                new HelpParagraph { Text = "You can also open ad-hoc MQTT/Redis connections — not tied to a profile — from the + menu, pointing them at any host and port." },
            }
        },
        new()
        {
            Id = "links", Title = "Browser Tabs", Icon = "🌍",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "New Browser Tab opens an in-app web view you can point anywhere. It's handy for a tunnel's web UI (e.g. localhost:8080)." },
                new HelpBullets { Items = new[]
                {
                    "A URL without a scheme defaults to http for localhost/IPs and https otherwise.",
                    "Opening a profile link starts that profile's tunnel first, and routes through its SOCKS proxy if it has a dynamic (-D) forward.",
                } },
            }
        },
        new()
        {
            Id = "palette", Title = "Command Palette", Icon = "⌘",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Open the Command Palette for a fast, searchable list of everything: connect to a profile, open SFTP/VNC, set up passwordless login, run a saved command, and more." },
                new HelpParagraph { Text = "Start typing to filter; press Enter to run the top match, or Escape to dismiss it." },
            }
        },
        new()
        {
            Id = "settings", Title = "Settings", Icon = "⚙",
            Blocks = new HelpBlock[]
            {
                new HelpParagraph { Text = "Open Settings from the ⋯ menu or the command palette. Changes take effect right away; startup options apply the next time the app launches." },
                new HelpBullets { Items = new[]
                {
                    "Resume last session — reopen the tabs that were open when you last quit.",
                    "Default terminal theme and text size for plain local terminals.",
                    "Default theme for new text-editor tabs.",
                } },
            }
        },
        new()
        {
            Id = "shortcuts", Title = "Keyboard Shortcuts", Icon = "⌨",
            Blocks = new HelpBlock[]
            {
                new HelpShortcuts { Rows = new[]
                {
                    ("Ctrl+K", "Command palette"),
                    ("Ctrl+T", "New local terminal"),
                    ("Ctrl+N", "New text editor"),
                    ("Ctrl+W", "Close tab"),
                    ("Ctrl+Shift+N", "New workspace"),
                    ("F5", "Refresh an SFTP tab"),
                    ("Enter", "Go to path (Finder) / run top palette match"),
                } },
            }
        },
    };
}
