# SSH Tunnel Manager

[![Verify appcast](https://github.com/jamesritter03-kirby/ssntunnelmagager/actions/workflows/verify-appcast.yml/badge.svg)](https://github.com/jamesritter03-kirby/ssntunnelmagager/actions/workflows/verify-appcast.yml)

A native macOS terminal app that makes it easy to **save profiles for SSH tunnels** and
launch them with one click. Each profile becomes a real, interactive terminal tab — so
password prompts, host‑key confirmations and shell access all just work.

Built with **SwiftUI** + [**SwiftTerm**](https://github.com/migueldeicaza/SwiftTerm)
(a full xterm‑compatible terminal emulator), driving the system `/usr/bin/ssh`.

---

## Features

- 🖥️ **Real terminal tabs** — PTY‑backed, so interactive password / 2FA / host‑key prompts work.
- 🔌 **Saved tunnel profiles** — host, port, user, identity key, jump host, and any number of forwards.
- 📂 **Local shell profiles** — a profile can instead be a **Local Shell** that opens your login
  shell in a new tab, starting in a **folder you choose** — a one‑click jump to a project directory.
- ↔️ **All three forward types**
  - **Local (`-L`)** — open a port on your Mac that tunnels to a target reachable from the server.
  - **Remote (`-R`)** — open a port on the server that tunnels back to your Mac.
  - **Dynamic (`-D`)** — a SOCKS proxy on your Mac that routes traffic through the server.
- 🏷️ **Forward categories → one‑click service tabs** — tag a **local** forward as a **Web Page**,
  **MQTT**, or **Redis** service and the app adds an **Open** action that launches the right tab
  for that port: an in‑app **browser**, a built‑in **MQTT Explorer** (live **topic tree** + payload
  viewer + publish), or a built‑in **Redis browser** (key list, typed value viewer, command
  console). The MQTT and Redis clients are **native** — they speak the protocol directly, so
  **nothing extra needs to be installed**. Each service can carry its own **username + password**
  (stored in the **Keychain**, sent over the tunnel). Reachable from the sidebar right‑click
  (*Open Service*) and a terminal **tab’s right‑click menu** (*Services*); the tunnel is brought
  up first automatically. You can also open an **ad‑hoc** MQTT or Redis tab to any host from the
  tab bar **+** menu (*New MQTT / Redis Connection…*) — no profile required.
- 👀 **Live command preview** — see (and copy) the exact `ssh` command a profile generates.
- 📁 **Graphical SFTP file transfer** — open an **SFTP tab** for any profile (sidebar
  right‑click → *Open SFTP*, the ⬆⬇ button, a terminal **tab’s right‑click menu**, or the
  command palette) to get a real file
  **browser**: navigate remote folders, and **drag files from Finder to upload** or download
  with a click — using the same host, key and saved password as a normal connection.
- 🖥️ **VNC screen sharing over SSH** — open a **VNC tab** for any profile (sidebar
  right‑click → *Open VNC*, the 🖵 button, a terminal **tab’s right‑click menu**, or the
  command palette). It opens an encrypted SSH tunnel to the server’s screen and renders the
  remote **desktop right inside the tab** — no external app — using the same host, key and
  saved password as a normal connection. macOS **Screen Sharing** stays one click away as a
  fallback. You can also open an **ad‑hoc** VNC tab to any host from the **+** menu
  (*New VNC Connection…*) — no profile required.
- � **Built‑in text editor** — a Notepad++‑style **text editor tab** (**+** menu, **File ▸ New
  Text Editor** ⌘N, or the command palette) with **syntax highlighting** for 20+ languages,
  **line numbers**, **soft‑wrap**, live **font zoom**, and **Find & Replace** (⌘F) with match‑case,
  whole‑word and **regex** options. Open/Save any text file; encoding and **line endings**
  (LF/CRLF/CR) are shown in the status bar. Saved documents reopen on the next launch.
- �📚 **Example profiles on first launch** — a fresh install starts with four ready‑to‑read
  examples (local `-L`, dynamic `-D`, remote `-R`, and a jump‑host `-J` with a shell) so the
  options are easy to learn. Edit or delete them freely — they're only ever added once.
- 🧵 **Tunnels stay alive in the background** while you switch between tabs.
- 🪟 **Detachable terminal windows** — pull any tab out into its own floating window
  (right‑click the tab → **Detach into New Window**, or **⌃⌘D**) and toggle **Always on
  Top** so it stays above other apps. The session keeps running while it moves; close the
  window to snap the tab back into the main window.
- ▦ **Tile tabs** — view every open tab at once in a side‑by‑side grid (**⌃⌘T**, or the tile
  button in the tab bar) to watch several tunnels/terminals together; switch back to single‑
  tab view any time.
- 🗂️ **Workspaces** — group tabs into named, switchable **workspaces** (the bar above the tabs),
  save a workspace’s tab set to reopen later, and **assign a profile to a workspace** so
  connecting it always opens in (and creates) that workspace.
- 🕒 **Per‑tab command history** — each terminal records the commands you type; reopen them
  from a menu to re‑run with one click. Passwords/passphrases are never recorded.
- 🎨 **Terminal themes** — per‑profile color themes modelled on macOS Terminal (Pro, Basic,
  Homebrew, Ocean, Novel, Solarized Dark/Light, Dracula) with a live preview.
- 🔎 **Adjustable text size** — grow/shrink the terminal text live with **⌘+ / ⌘−** (**⌘0**
  resets). The size is **saved to the profile** (or to the local‑terminal default), so new
  tabs open at your preferred size.
- 📌 **Saved commands** — store commonly used commands per profile and insert them into the
  terminal from a menu. **Import or export** a profile's commands as a JSON file to reuse them
  across profiles or machines.
- � **Keychain passwords + Touch ID** — optionally save a profile's password in the macOS
  login Keychain and have it typed automatically at the SSH password prompt, gated behind
  **Touch ID / your login password**. (SSH keys are still recommended where possible.)
- ⌨️ **Searchable command palette** — press **⌘K** for a Spotlight‑style palette to connect
  to a profile, open a terminal, re‑run history, run a saved snippet, or disconnect — all
  from the keyboard.
- 🔝 **Menu bar quick‑connect** — a status‑bar icon at the top of the screen to start any
  profile, jump to a running session, or open a terminal without touching the main window.
  It shows a **green count badge** when tunnels are active.
- ⚙️ **Startup options** — optionally **start at login** and/or **launch straight into the
  menu bar** (no window / Dock icon).
- � **Disconnect without losing the tab** — stop a tunnel/session from the **tab bar button**,
  the tab's **right‑click menu**, or **Commands → Disconnect**. The tab stays so you can
  **Reconnect** it with one click; **Close** (✕) still removes the tab entirely.
- 🔁 **Reconnect** a dropped or disconnected session with one click.
- 💾 **Profiles persist** to `~/Library/Application Support/SSHTunnelManager/profiles.json`.
- 📤 **Import & export profiles** — share a single profile or your whole list as a portable
  JSON file and import it on another Mac. Passwords are never included, and imports are added
  as new profiles (fresh IDs) so they never overwrite the ones you already have.
- 🔒 **Secure by default** — passwords (when saved) live in the macOS Keychain, never in the
  profile file, and are never written to command history.
- 🚀 **Automatic updates** — built‑in [Sparkle](https://sparkle-project.org) updater checks a
  release feed and installs new versions, each verified with an EdDSA signature. Check
  manually any time via the app menu → **Check for Updates…**.

---

## Requirements

- **Apple Silicon Mac** (M1 or newer)
- macOS 13 or later
- To **build**: the Swift toolchain (full Xcode **or** the Command Line Tools — `xcode-select --install`). To just **run** a prebuilt app, nothing extra is needed.

## Build & run

```bash
# Build a double‑clickable app bundle:
./build-app.sh
open "SSH Tunnel Manager.app"
```

Or, for quick development iteration:

```bash
swift run
```

To install it like a normal app:

```bash
mv "SSH Tunnel Manager.app" /Applications/
```

> The build script ad‑hoc code‑signs the app so macOS will launch it locally. The first
> time you open it you may still need to right‑click → **Open** to bypass Gatekeeper.

---

## Share with another Mac (Apple Silicon)

The app is built for **Apple Silicon (arm64)** — it runs on any M‑series Mac.

### Recommended: a drag‑to‑Applications disk image

```bash
./make-dmg.sh
```

This produces **`dist/SSH Tunnel Manager.dmg`**. The recipient:

1. Double‑clicks the `.dmg` and **drags the app onto the Applications folder**.
2. **First launch only:** right‑click (Control‑click) the app in Applications → **Open** →
   **Open**. If macOS still refuses, go to  **System Settings → Privacy & Security**, scroll
   down and click **Open Anyway**, then confirm.
3. After that first approval, it opens with a normal double‑click. **No Terminal required.**

> **Run it from Applications so updates work.** Because the app isn't notarized, macOS keeps
> a *quarantine* flag on it and may run it from a temporary, read‑only location (“App
> Translocation”). From there Sparkle can't replace the app in place, which can leave
> **duplicate copies that never seem to update**. To prevent this, the app **detects that
> situation on launch and offers to move itself into your Applications folder** (clearing the
> quarantine flag) and relaunch — after which updates replace it cleanly. Always launch it
> from **Applications**, not from the `.dmg` window or Downloads.

> The first‑launch step exists because the app is **ad‑hoc signed, not notarized**. A pure,
> zero‑click double‑click on another Mac requires notarization, which needs a paid Apple
> Developer ID ($99/yr). With one, run `codesign` with your *Developer ID Application*
> certificate, then `xcrun notarytool submit` + `xcrun stapler staple` on the `.dmg`.

#### Updates leave duplicate copies / don't apply

If an earlier version was run from the `.dmg` window or Downloads (not Applications), macOS
may have **translocated** it (run it from a random read‑only path). Sparkle installs each
update next to wherever the app is currently running, so from a translocated/read‑only spot
it can't replace the app and you can end up with several copies (e.g. “SSH Tunnel
Manager 2.app”). Newer versions self‑correct by offering to move into Applications on launch,
but to clean up an already‑affected Mac:

1. **Quit** SSH Tunnel Manager.
2. In **Applications** (and anywhere else copies landed, like **Downloads**), drag **every**
   copy of *SSH Tunnel Manager* to the Trash.
3. Open the latest **`.dmg`** and **drag the app into Applications** (replace if asked).
4. Open it from **Applications** (right‑click → **Open** the first time). If it offers to move
   itself to Applications, click **Move to Applications Folder**.

From then on, **Check for Updates…** (and the automatic daily check) will replace the single
Applications copy in place. Your saved profiles are stored separately in
`~/Library/Application Support/SSHTunnelManager/` and are **not** affected by deleting app
copies.

> **Tip:** Running `make-dmg.sh` from your own Terminal will prompt *"Terminal wants to
> control Finder."* Allow it once to get the polished window background + icon layout. If you
> decline, the DMG still works — it just uses a plain window.

### Alternative: a plain zip

```bash
./package-dist.sh
```

Produces **`dist/SSH Tunnel Manager (Apple Silicon).zip`** with the app and a
`READ ME FIRST.txt`. Same first‑launch step as above.

> **Requirements on the other Mac:** Apple Silicon, macOS 13+. No Swift/Xcode needed — the
> app is self‑contained (SwiftTerm is statically linked).

---

## Using it

1. Click **+** in the sidebar to create a profile.
2. Fill in the **host**, **username**, and (optionally) a **port** and **identity file**.
3. Under **Port Forwards / Tunnels**, add one or more forwards. The inline help explains
   each type, and the **command preview** at the bottom updates live.
4. Toggle **Open interactive shell** off if you only want the tunnels (adds `-N`).
5. Click **Save**, then press the ▶︎ button on the profile (or double‑click it) to connect.

Open a plain shell anytime with **⌘T** (or the **Local Terminal** button).

### Forward categories (Web / MQTT / Redis tabs)

When you add a **local (`-L`)** forward you can give it a **category** — a small dropdown next
to the forward (**None**, **Web Page**, **MQTT**, **Redis**). The category is purely a
convenience: it doesn’t change the `ssh` command, it just teaches the app what’s listening on
that local port so it can offer a matching **Open** action:

- **Web Page** — opens the forwarded port (`http://127.0.0.1:<port>`) in an in‑app browser tab.
- **MQTT** — opens a built‑in **MQTT Explorer**: a native MQTT 3.1.1 client subscribes to every
  topic and shows a live, filterable **topic tree** (grouped by the `/`‑delimited path, with
  per‑topic message counts and retained flags), a **detail pane** that pretty‑prints the latest
  payload (JSON when possible), and a **publish** panel (topic + payload + retain). The detail
  pane also has a **Graph** tab for any topic with numeric data: it plots the value over time
  (Swift Charts), and for JSON payloads you can toggle **individual fields** on and off to chart
  them as separate series. New branches expand automatically; **right‑click** the tree to
  **Expand All / Collapse All** (or a branch).
- **Redis** — opens a built‑in **Redis browser**: a native RESP client lets you **scan** keys
  (with a `MATCH` pattern), inspect a key’s **typed value** (string / list / set / sorted‑set /
  hash) with its **TTL**, **delete** keys, and run **arbitrary commands** in a small console.

Launch them from the profile’s **sidebar right‑click → Open Service**, or from a connected
tab’s **right‑click → Services**. The app brings the profile’s SSH tunnel up first (pausing a
moment for it to bind), so the client connects to a port that’s already listening. The MQTT and
Redis clients are **native** (built on Apple’s Network framework) — **no command‑line tools or
Homebrew packages are required** — and the tabs reopen with **Resume last session**.

**Edit a tab’s connection.** Right‑click an **MQTT**, **Redis**, **VNC** or **SFTP** tab and
choose **Edit Connection…** to change its host, port or credentials and reconnect in place — no
need to open a new tab to fix a mistyped password or re‑point at another server.

**Service credentials.** Brokers and Redis servers often require a login. For an **MQTT** or
**Redis** forward the editor shows a **Username** field and a **Password** field. The username
is saved in the profile; the **password is stored in your macOS Keychain** (keyed to that
forward, gated by the same **Touch ID** setting as the SSH password) and is **never** written
to `profiles.json` or included in exports. When the tab connects, the credentials are sent in
the protocol handshake over the encrypted tunnel — MQTT in its `CONNECT` packet, Redis via
`AUTH` — so they never appear in `ps` or any command preview.

**On‑demand connections.** You don’t need a profile or a forward to use the MQTT/Redis clients.
From the tab bar **+** menu (or **File → New**, or the welcome screen) choose **New MQTT
Connection…** or **New Redis Connection…**, enter a host, port and optional credentials, and the
app opens the same native Explorer/browser tab pointed straight at that server. Handy for a
broker on your LAN, or one you’ve already tunnelled by other means.

> **Sidebar:** show or hide the profile sidebar with **View → Show/Hide Sidebar** (**⌃⌘S**) —
> handy if the toolbar's sidebar button ever goes missing after the sidebar is collapsed.

> **Clipboard:** ⌘C / ⌘V work as usual. By default **right‑click is smart**: if text is
> selected it **copies** it (and clears the selection, so the next right‑click pastes);
> if nothing is selected it **pastes** the clipboard; and if there's nothing to paste either,
> it shows a small **Copy / Paste / Select All** menu — so a right‑click is never wasted. You
> can change this under **Settings → Terminal → Right‑click** (e.g. back to PuTTY‑style
> "always paste", or "always show menu"). When a full‑screen app has mouse reporting on
> (vim, htop, tmux…), the right‑click is passed through to that app instead.

### Welcome screen

Whenever a workspace has no open tabs, the center area shows a **welcome screen** that puts your
starting points in one place:

- **Resume Last Session** reopens every tab that was open when you last quit.
- **New Local Terminal**, **New Browser Tab**, **New Finder Tab** and a **New Connection** menu.
- **Connect to a server** — quick **Remote Terminal**, **SFTP**, **VNC**, **MQTT**, **Redis** and
  **ZeroTier** buttons that don’t need a saved profile.
- **Profiles** — a grid of one‑click launch cards (right‑click for SFTP/VNC/key setup).
- **Recently Closed** — a running list of tabs **and whole workspaces** you closed without
  saving. Click an entry to **reopen** it (a tab returns to the current workspace; a workspace
  opens as a new one), **right‑click** to remove a single entry, or use **Clear** to empty the
  list. Profile‑free ad‑hoc connections are remembered too — reopening one reconnects and
  re‑prompts for the password (which is never stored). The list survives quitting and relaunching.

### ZeroTier devices

Browse the devices on your **ZeroTier** networks and connect straight to any of their managed IP
addresses. Open it from the **ZeroTier** button on the welcome screen, the globe button in the
sidebar, or **File ▸ Browse ZeroTier Devices…**.

- Paste a ZeroTier Central **API token** (from *my.zerotier.com/account*) under **Add an account** —
  add **as many accounts as you like**, one per ZeroTier login. Tokens are stored in your macOS
  **Keychain**, never synced and never included in exports.
- Pick a network (or **All Networks**, which spans every account) to list its **members**: online
  status, node id, last‑seen time and every managed **IP address**. Networks are grouped by account.
- **Filter** by name, node id or IP, toggle **Online only**, set a **username** for SSH/SFTP, then
  click **SSH**, **SFTP** or **VNC** next to any IP to open a tab connected to that device.
- Connections are profile‑free (ad‑hoc); your SSH keys are tried first and a typed password isn’t
  stored. The **key** button manages accounts (add / rename / change token / remove).
- **Self‑hosted** controllers (e.g. [ZTNET](https://ztnet.network)) are supported: when adding an
  account, enter your server’s URL (e.g. `https://zt.example.com`) in the **Server** field and use
  that server’s API token. Leave **Server** blank to use ZeroTier Central.
- Anywhere you enter a host or IP — the **Remote Terminal / SFTP / VNC / MQTT / Redis** sheets and
  the **profile editor** — a small **globe** button lets you pick a device IP from ZeroTier inline.

> ZeroTier IPs are reachable only while this Mac is joined to the same network in the ZeroTier app.
> The browser lists devices and dials them; it doesn’t join networks for you.

### Workspaces

The bar above the tabs holds your **workspaces** — named groups of tabs you can switch between
(**⌘⇧N** for a new one, **⌘⇧[** / **⌘⇧]** to move between them). Each workspace remembers its
own tabs, selection and tiled layout. Use the **⊕** to add one, double‑click a workspace pill to
rename it, and the **save** menu to store a workspace’s tab set and reopen it later.

**Assign a profile to a workspace.** In the profile editor’s **Workspace** section, set
**Open in workspace** to a name (type one, or pick an existing one). Connecting that profile then
switches to that workspace — **creating it if it doesn’t exist** — so all of the profile’s tabs
(SSH, SFTP, VNC, links and service tabs) open there together. Leave it blank to use whatever
workspace is current. Restored and saved‑workspace tabs always reopen where they were saved.

### Detachable windows

Pull any tab out into its **own floating window** — right‑click the tab and choose
**Detach into New Window**, or press **⌃⌘D** for the active tab. Detaching only changes
*where* the terminal is shown: the session and its tunnels **keep running** the whole time.
Each detached window has a **📌 pin** button that toggles **Always on Top** (so the window
floats above other apps) and a **re‑attach** button. **Closing** a detached window snaps the
tab back into the main window's tab bar; closing the tab (⌘W) still ends the session as usual.

### Tiling tabs

When you have two or more tabs open, click the **tile button** at the right of the tab bar
(or press **⌃⌘T**) to show them **all at once in a grid** instead of one at a time — handy
for watching several tunnels or terminals side by side. Each tile has a slim header with its
status, title, and **detach**/**close** buttons; click a tile's header to make it the active
tab (so ⌘+/⌘− and the snippet/history menus apply to it). **Drag the dividers** between tiles
to resize them; the sizes are **remembered per workspace** (and restored when you switch
workspaces or relaunch). Click the button again (it turns into a single‑pane icon) or press
**⌃⌘T** to go back to single‑tab view. The choice is remembered. Every terminal stays live
the whole time, tiled or not.

### Docking a tab to an edge

Sometimes you want one tab pinned beside everything else rather than in the tile grid — say a
log you're tailing, or a reference shell. **Right‑click any tab** (or tile) → **Dock ▸ Dock
Left** / **Dock Right** / **Dock Top** / **Dock Bottom** (or press **⌃⌘[** / **⌃⌘]** for the
sides, **⌃⌘↑** / **⌃⌘↓** for top/bottom) to pull it out into a **slide‑out drawer** on that
edge. The rest of your tabs keep their normal tab bar / tiled grid in the center; top and
bottom drawers span the width between your left/right drawers.

You can **stack several tabs in one drawer** — dock more than one to the same edge and they
stack (vertically for left/right, side by side for top/bottom), each with its own header;
**drag the divider between them** to size them. Each drawer has a slim header with two buttons:
**collapse** shrinks the whole drawer to a thin **rail** along the edge — click the rail to
**slide it back out** — and **return** (⤢) puts a tab back in the tab bar. **Drag the divider**
between a drawer and the center to **resize** it. You can dock on multiple edges at the same
time. Edges, sizes and collapsed state are **remembered per workspace** and restored on
relaunch. Docked terminals stay fully live, and typing in them works as usual.

### Command history

Each terminal tab keeps a history of the commands you type in it. Click the **clock icon**
(🕒) at the right of the tab bar to see recent commands (newest first) and click any one to
**run it again** in that tab — handy for repetitive tunnel/diagnostic commands. It works for
both local shells and remote SSH sessions. **Save History…** exports the list to a text file
(oldest first, with a header), and **Clear History** empties the list.

**Import History…** loads commands from a text file and appends them to the tab's list — point
it at a previously exported history file, or at a shell's own `.bash_history` / `.zsh_history`
(hidden dotfiles are selectable in the open panel). Blank lines and `#` comments are skipped,
zsh `EXTENDED_HISTORY` timestamps are unwrapped automatically, and consecutive duplicates are
collapsed. Import is always available from the clock menu, even on a brand‑new tab.

> History is reconstructed from your keystrokes, so anything typed at a **password or
> passphrase prompt is deliberately skipped**. (Because it's keystroke‑based, tab‑completed
> or up‑arrow‑recalled lines may not be captured verbatim.) History lives in memory for the
> life of the tab.

### Editing a profile

A compact **type switch** at the top of the editor chooses between an **SSH Tunnel** profile
and a **Local Shell** profile:

- **SSH Tunnel** groups everything into clearly labelled sections — **Connection**,
  **Authentication**, **Port Forwards**, **SSH Options**, **Terminal**, and **Saved Commands** —
  each with an icon and a one‑line explanation. Host and port share a row, the option toggles
  carry their matching `ssh` flag as a tooltip, and the SSH‑key row shows the chosen file with
  **Change…/Clear** buttons.
- **Local Shell** profiles skip all the SSH fields and just ask for a **name** and an optional
  **start folder** (type a path or pick one with **Choose…**). Launching the profile opens your
  login shell in a new tab already `cd`‑ed into that folder — handy for jumping straight to a
  project directory. Leave the folder empty to start in your home directory.

Both kinds start with an **Icon** row: click it to pick an SF Symbol from a grouped gallery
(servers, devices, storage, security, tags…), or choose **Default**. Your icon then shows in the
sidebar, the command palette, the editor header, and on the session's tab.

A live **command preview** at the bottom shows exactly what will run (the `ssh` command, or the
shell + `cd` for a local profile), and the header tells you whether you're adding or editing.

> **Unsaved changes are protected.** Profiles save automatically once you press **Save/Add
> Profile**, but if you try to **quit** while a profile editor is still open with edits you
> haven’t committed, the app asks whether to **Save**, **Don’t Save**, or **Cancel** first — so a
> stray ⌘Q never throws away work in progress.

### Import & export profiles

Share connection setups between Macs. Use **File → Export All Profiles…** (or the
import/export button at the bottom of the sidebar) to save your whole list as a portable
`.json` file, or right‑click a single profile → **Export…** to share just that one. On the
other Mac, choose **File → Import Profiles…** and pick the file.

> **Passwords are never exported.** They stay in the macOS Keychain on the original Mac, so
> after importing, open the profile and re‑enter any saved password. Imported profiles are
> always added as **new** profiles (with fresh IDs and a unique name) — importing never
> overwrites or deletes anything you already have.

### Themes

Each profile has a **Theme** (in the profile editor's *Terminal* section) that sets the
terminal's background, text, cursor and full 16‑color ANSI palette. Choose from presets
modelled on macOS Terminal — **Pro, Basic, Homebrew, Ocean, Novel, Solarized Dark, Solarized
Light, Dracula** — with a live preview as you pick. Saving a profile **re‑colors its open
tabs immediately**. Set a **default theme for plain local terminals** in **Settings…** (⌘,).

### Text size

Press **⌘+** (bigger) and **⌘−** (smaller) to zoom the text in the active terminal, and
**⌘0** to return to the default. The new size is **remembered on the profile** (for SSH
tabs) or as the **local‑terminal default** (for plain shells), so the next tab you open uses
it. You can also set an exact size in the profile editor's *Terminal* section, or the
local‑terminal default in **Settings…** (⌘,). The commands also live in the **Commands** menu.

### Disconnecting & reconnecting

There's a difference between **disconnecting** a session and **closing** its tab:

- **Disconnect** stops the running `ssh` (closing its tunnels) or ends a local shell, but
  **keeps the tab**. A “Session ended” banner appears with a **Reconnect** button so you can
  bring it straight back. Trigger it from the **disconnect button in the tab bar** (the
  ⚡ icon, acts on the current tab), the tab's **right‑click → Disconnect**, the per‑tile
  button in tiled view, or **Commands → Disconnect**. In tiled view the button only shows
  while a tab is still running.
- **Close** (the **✕** on the tab, **⌘W**, or right‑click → Close Tab) tears the tab down
  completely — which also stops its tunnels.

To drop every tunnel at once (closing those tabs), use **Commands → Disconnect All Tunnels**
(**⇧⌘D**).

### Saved commands

In the profile editor's **Saved Commands** section, add commands you run often (each with a
friendly label). When a session from that profile is active, click the **“+” text icon** in
the tab bar and pick a command to either **Run** it immediately or **Insert at Prompt**
(so you can tweak it before pressing Enter). Great for long tunnel‑test or diagnostic
commands you don't want to retype.

Use the **import/export menu** in that section's header to **export** a profile's commands to
a `.json` file or **import** a set from another profile or machine. Imported commands are
appended (with fresh IDs), so they never replace what's already there.

### SFTP file transfer

Need to move files instead of run commands? Open an **SFTP tab** for a profile:

- **Sidebar** → right‑click a profile → **Open SFTP**, or select it and click the **⬆⬇ button**
  at the bottom of the sidebar.
- A terminal **tab’s right‑click menu** → **Open SFTP** (opens an SFTP tab for that tab’s profile).
- **Command palette** (**⌘K**) → *SFTP: ‹profile›*.
- **Without a profile**, choose **New SFTP Connection…** from the **+** menu, **File → New**, or the
  welcome screen and enter a host, port and optional credentials.

This opens a **graphical file browser** (not a text prompt). It connects with `sftp` using the
same host, port, key, jump host and saved password as a normal connection — so host‑key and
password prompts work exactly like the SSH tabs — then shows the remote folder as a list with
icons, sizes and dates:

- **Drag files or folders from Finder** onto the browser to **upload** them to the current
  directory (the whole list highlights as a drop zone) — or **drop them onto a folder row** to
  upload straight **into that folder** (the folder highlights as you hover). There's also an
  **Upload…** toolbar button.
- **Drag a file or folder out to a Finder window or the Desktop** to **download** it right where
  you drop it — the file is fetched from the server on demand into the spot you choose.
- **Double‑click a folder** to open it, or use the **↑ Up** button and the **path menu** to jump
  to any parent folder.
- **Double‑click a file** (or pick **Download**) to save it to your default folder; set that
  folder with **Save to:** in the status bar. To save somewhere else just this once, use the
  **Download To…** toolbar button (tray icon) or right‑click menu and pick a destination.
  Downloads are revealed in Finder when done.
- **New Folder**, **Rename…** and **Delete** are on the toolbar and the right‑click menu.
- **Refresh** from the toolbar, the right‑click menu, or the **F5** key.
- A **Log** button shows the raw `sftp` transcript if you need to troubleshoot, and a failed
  connection offers **Reconnect**.

SFTP tabs can be **tiled** and **detached** like any other tab.

### VNC screen sharing (over SSH)

Want the remote **desktop** instead of a shell or files? Open a **VNC tab** for a profile:

- **Sidebar** → right‑click a profile → **Open VNC**, or select it and click the **🖵 button**
  at the bottom of the sidebar.
- A terminal **tab’s right‑click menu** → **Open VNC** (opens a VNC tab for that tab’s profile).
- **Command palette** (**⌘K**) → *VNC: ‹profile›*.

VNC is normally **unencrypted**, so rather than connecting to it directly this opens a
tunnels‑only `ssh -N` connection that **forwards a local port to the server’s screen**
(`127.0.0.1:5900` on the server). The app then connects its **built‑in VNC client** to the
local end of that tunnel and shows the live desktop **inside the tab**. The screen session
therefore travels **inside the encrypted SSH tunnel**, and host‑key / password prompts work
exactly like the SSH and SFTP tabs.

The embedded desktop has a slim toolbar: toggle **Scale to fit / Actual size**, a **File
Transfer** menu (for a profile VNC tab — **Open SFTP Browser** or **Upload Files…** to the same
server over SSH), **Open in Screen Sharing** (hand off to macOS’s built‑in viewer if you prefer
it), a **Log** of the raw `ssh` output, and **Disconnect**. The first time a screen asks for
credentials you’ll get a prompt — a single **Screen Sharing password**, or an **account name +
password** for Macs set to *Apple Remote Desktop* authentication — with an option to **remember**
it (stored in the Keychain, separate from your SSH password). Closing the tab (or **Disconnect**)
tears the tunnel down.

**Right‑click the VNC tab** for a **VNC** submenu of common screen‑sharing options: **Scaling**
(Scale to Fit / Actual Size), **Color Depth** (True Color · High Color · 256 Colors — drop it for
a snappier picture over a slow link), **View Only** (watch without sending any input), **Share
Clipboard** (sync copy/paste with the remote), **Send Ctrl+Alt+Del**, **Reconnect**, and **Open in
Screen Sharing**. Changing a display or input option reconnects for a moment, reusing your
remembered password so there's no re‑prompt.

**Panning at actual size.** With scaling off (**Actual Size**), if the remote screen is larger
than the tab, scroll bars appear along the edges — **drag them to pan** around the desktop.
(Two‑finger scrolling is forwarded to the remote computer, so the scroll bars are what move the
view.) Switch back to **Scale to Fit** to see the whole screen at once.

**On‑demand VNC.** You don’t need a profile. From the tab bar **+** menu (or **File → New**, or
the welcome screen) choose **New VNC Connection…**, enter a host, port (default `5900`) and an
optional password, and the app opens an embedded VNC tab pointed **directly** at that server.
This connection isn’t tunnelled — it’s meant for a machine on your LAN or one you’ve already
made reachable; for an encrypted session over an untrusted network, open VNC from a profile so
it rides the SSH tunnel.

> The server must have a VNC / screen‑sharing server listening on its `localhost:5900` (e.g.
> macOS **System Settings → General → Sharing → Screen Sharing**, or a Linux VNC server). To
> reach a different remote port, add a matching **Local (`-L`)** forward and use Screen Sharing
> directly.

VNC tabs can be **tiled** and **detached** like any other tab.

### Keychain passwords & Touch ID

For servers that authenticate with a **password** (not a key), open the profile editor's
**Authentication** section and type the password into **Save password in Keychain**. It's
stored in your macOS **login Keychain** (item: *com.local.sshtunnelmanager.passwords*),
**never** in `profiles.json`. On the next connect, the app detects the SSH password prompt
and types it for you.

- **Require Touch ID / login password before use** (on by default) gates each use of the
  saved password behind biometric or password authentication.
- Auto‑fill happens **once per connection** — if the password is wrong you'll just get the
  normal prompt, with no retyped‑password loop.
- **Remove** clears it from the Keychain; deleting a profile also deletes its saved password.

> 🔐 **SSH keys are still the better option.** Keychain auto‑fill is a convenience for hosts
> you can't use keys with. The password is stored *ThisDeviceOnly* (never synced to iCloud).

### Command palette (⌘K)

Press **⌘K** anywhere to open a **Spotlight‑style command palette**. Start typing to fuzzy‑
search across:

- **Connect: …** every saved profile,
- **New Local Terminal**,
- **Run snippet: …** the active profile's saved commands,
- **Run: …** the active tab's command history (most‑recent first),
- **Disconnect All Tunnels** (when tunnels are live).

Use **↑/↓** to move, **Return** to run the selection, and **Esc** to dismiss — entirely from
the keyboard.

### Menu bar

A status‑bar icon (the tunnel glyph, near the clock) gives you one‑click access from
anywhere:

- **Connect** — pick any profile to start its tunnels; a ✓ marks profiles that already
  have a live session.
- **Sessions** — jump to (Focus) or Disconnect a running session, or **Disconnect All
  Tunnels** at once.
- **Show Main Window / New Local Terminal**.
- **Options** — toggle **Start at Login** and **Launch to Menu Bar** right from the menu
  (also available in **Settings…**, ⌘,).
- **Check for Updates…** — manually check for a new version (also in the app menu); handy
  when running in menu‑bar‑only mode with no window open.

When one or more SSH tunnels are running, the menu bar icon shows a **green number badge**
with the active tunnel count.

> Because of the menu bar item, closing the main window **does not quit the app** — it keeps
> running so your tunnels stay up. Quit from the menu bar's **Quit** item (or **⌘Q** while the
> window is focused). Clicking the Dock icon reopens the window.
>
> With **Launch to Menu Bar** enabled, the app starts with no window or Dock icon at all
> (no window flash) — use the menu bar → **Show Main Window** to bring it up. This makes it a
> tidy login item: enable **Start at Login** + **Launch to Menu Bar** and it comes up silently
> in the menu bar at every login.

### Example: reach a remote PostgreSQL locally

| Field        | Value            |
|--------------|------------------|
| Type         | Local (`-L`)     |
| Local port   | `5433`           |
| Target host  | `localhost`      |
| Target port  | `5432`           |

Now `psql -h localhost -p 5433` on your Mac talks to the server's database.

### Example: SOCKS proxy for browsing through the server

| Field      | Value          |
|------------|----------------|
| Type       | Dynamic (`-D`) |
| SOCKS port | `1080`         |

Point your browser at SOCKS proxy `127.0.0.1:1080`.

---

## Software updates

The app ships with the [Sparkle](https://sparkle-project.org) auto‑updater. Users can pick
**Check for Updates…** from the app menu, toggle **Automatically check for updates** in
**Settings… (⌘,) → Updates**, and background checks run on a schedule
(`SUScheduledCheckInterval`, daily by default). Every downloaded update is verified against a
bundled **EdDSA public key** before it installs — so updates are secure even though the app
is only ad‑hoc signed (not notarized).

### Hosting (GitHub Releases + GitHub Pages)

Updates are distributed entirely from this GitHub repo:

| Piece | Where it lives | URL |
|-------|----------------|-----|
| **Update feed** (`appcast.xml`) | GitHub **Pages** from the `docs/` folder | `https://jamesritter03-kirby.github.io/ssntunnelmagager/appcast.xml` |
| **Update binaries** (`.zip` / `.delta`) | A single rolling GitHub **Release** tagged `updates` | `…/releases/download/updates/<file>` |
| **Installer** (`.dmg`) | The same `updates` release (for first‑time installs) | `…/releases/download/updates/SSH-Tunnel-Manager.dmg` |

These URLs are already wired into [Info.plist](Info.plist) (`SUFeedURL`) and
[make-appcast.sh](make-appcast.sh) (`DOWNLOAD_URL_PREFIX`).

### One‑time setup

The signing keys already exist — a key pair was generated with Sparkle's `generate_keys`; the
**private key lives in your login Keychain** and the **public key** is in
[Info.plist](Info.plist) as `SUPublicEDKey`. Keep that Keychain item safe — if you lose it,
existing installs can't verify future updates.

Two repo settings need enabling once (in the GitHub web UI):

1. **Enable Pages:** repo **Settings → Pages → Build from a branch → `main` / `/docs`**.
   That publishes `docs/appcast.xml` at the feed URL above.
2. **The `updates` release** is created automatically the first time you run
   `./publish-release.sh` (or make it by hand on the Releases page).

To publish from the command line you'll want the GitHub CLI:

```bash
brew install gh && gh auth login   # one time
```

### Releasing a new version

```bash
# 1. Bump the version in Info.plist FIRST (Sparkle compares CFBundleVersion):
#      CFBundleShortVersionString  e.g. 1.1     (shown to users)
#      CFBundleVersion             e.g. 2       (must increase every release)

# 2. Build the app, zip it, and (re)generate the SIGNED appcast → docs/appcast.xml:
./make-appcast.sh

# 3. Publish: upload the archives + DMG to the 'updates' release and push the feed:
./publish-release.sh
```

`publish-release.sh` uploads `sparkle-updates/*.zip` (+ any `.delta`) and the installer DMG to
the rolling **`updates`** release, then commits & pushes `docs/appcast.xml`. (No `gh`? It
prints the manual upload + `git push` steps instead.) Existing installs pick up the new
version at their next scheduled check, or immediately via **Check for Updates…**.

> Keep the local `sparkle-updates/*.zip` files around — Sparkle uses them to build smaller
> **delta** updates for the next release. They're git‑ignored (too large for the repo); only
> `docs/appcast.xml` is committed.

### Continuous verification (safety net)

A GitHub Actions workflow ([.github/workflows/verify-appcast.yml](.github/workflows/verify-appcast.yml))
runs whenever `docs/appcast.xml` or `Info.plist` changes. It executes
[scripts/verify_appcast.py](scripts/verify_appcast.py), which re‑checks the whole trust chain —
**the public key in Info.plist ↔ the appcast signature ↔ the actual hosted binary** — and fails
the build if any update is mis‑signed, the wrong length, or unreadable. That catches a botched
release *before* it can break auto‑update for users.

You can run the same check locally before pushing:

```bash
pip install cryptography                 # one time
python3 scripts/verify_appcast.py        # verifies against the local sparkle-updates/ zips
```

---

## Project layout

```
Sources/SSHTunnelManager/
├── App/                      # @main entry, AppDelegate, menu bar item, window manager
├── Models/                   # SSHProfile, ProfileStore (persistence), SSHCommandBuilder
├── Terminal/                 # TerminalSession, TerminalSessionManager, SwiftUI bridge
├── Views/                    # Sidebar, terminal tabs, profile editor
└── Util/
build-app.sh                  # assembles + embeds Sparkle + ad-hoc signs the .app bundle
sign-app.sh                   # (re)signs a .app inside-out (Sparkle helpers, then the bundle)
make-dmg.sh                   # builds a drag-to-Applications .dmg installer
make-appcast.sh               # builds a release zip + signed Sparkle appcast → docs/
publish-release.sh            # uploads archives to the 'updates' release + pushes the feed
docs/                         # GitHub Pages site: landing page + published appcast.xml
scripts/verify_appcast.py     # checks every appcast signature (run by CI and locally)
.github/workflows/            # GitHub Actions — verify-appcast.yml (signature safety net)
make-icon.sh / make-icon.swift  # generates AppIcon.icns (terminal + tunnel art)
dmg-background.swift          # renders the DMG window background
package-dist.sh               # zips the app for another Apple Silicon Mac
Info.plist                    # bundle metadata + Sparkle keys (SUFeedURL, SUPublicEDKey)
```

---

## App icon

The icon (a terminal window with a glowing green “tunnel”) is drawn programmatically in
[make-icon.swift](make-icon.swift) — no image assets to manage. Regenerate it after tweaking
the artwork:

```bash
./make-icon.sh        # writes AppIcon.icns
./build-app.sh        # re-embeds it in the app bundle
```

---

## Notes & ideas for later

- Auto‑connect favourite tunnels on launch.
- Import existing hosts from `~/.ssh/config`.
- Let the command palette search history across **all** open tabs.
