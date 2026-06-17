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
- 👀 **Live command preview** — see (and copy) the exact `ssh` command a profile generates.
- 📁 **Graphical SFTP file transfer** — open an **SFTP tab** for any profile (sidebar
  right‑click → *Open SFTP*, the ⬆⬇ button, a terminal **tab’s right‑click menu**, or the
  command palette) to get a real file
  **browser**: navigate remote folders, and **drag files from Finder to upload** or download
  with a click — using the same host, key and saved password as a normal connection.
- 🖥️ **VNC screen sharing over SSH** — open a **VNC tab** for any profile (sidebar
  right‑click → *Open VNC*, the 🖵 button, a terminal **tab’s right‑click menu**, or the
  command palette). It opens an encrypted SSH tunnel to the server’s screen and launches
  macOS **Screen Sharing** through it — so the remote desktop is private, using the same
  host, key and saved password as a normal connection.
- 📚 **Example profiles on first launch** — a fresh install starts with four ready‑to‑read
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

> **Sidebar:** show or hide the profile sidebar with **View → Show/Hide Sidebar** (**⌃⌘S**) —
> handy if the toolbar's sidebar button ever goes missing after the sidebar is collapsed.

> **Clipboard:** ⌘C / ⌘V work as usual, and **right‑clicking pastes** the clipboard (like
> PuTTY). When a full‑screen app has mouse reporting on (vim, htop, tmux…), the right‑click
> is passed through to that app instead.

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
tab (so ⌘+/⌘− and the snippet/history menus apply to it). Click the button again (it turns
into a single‑pane icon) or press **⌃⌘T** to go back to single‑tab view. The choice is
remembered. Every terminal stays live the whole time, tiled or not.

### Command history

Each terminal tab keeps a history of the commands you type in it. Click the **clock icon**
(🕒) at the right of the tab bar to see recent commands (newest first) and click any one to
**run it again** in that tab — handy for repetitive tunnel/diagnostic commands. It works for
both local shells and remote SSH sessions. **Save History…** exports the list to a text file
(oldest first, with a header), and **Clear History** empties the list.

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

This opens a **graphical file browser** (not a text prompt). It connects with `sftp` using the
same host, port, key, jump host and saved password as a normal connection — so host‑key and
password prompts work exactly like the SSH tabs — then shows the remote folder as a list with
icons, sizes and dates:

- **Drag files or folders from Finder** onto the browser to **upload** them to the current
  directory (the whole list highlights as a drop zone). There's also an **Upload…** toolbar
  button.
- **Double‑click a folder** to open it, or use the **↑ Up** button and the **path menu** to jump
  to any parent folder.
- **Double‑click a file** (or pick **Download**) to save it to your download folder; set that
  folder with **Save to:** in the status bar. Downloads are revealed in Finder when done.
- **New Folder**, **Rename…** and **Delete** are on the toolbar and the right‑click menu.
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
(`127.0.0.1:5900` on the server) and then launches macOS’s built‑in **Screen Sharing** pointed
at the local end. The screen session therefore travels **inside the encrypted SSH tunnel**, and
host‑key / password prompts work exactly like the SSH and SFTP tabs.

The VNC tab itself is a small **status console**: it shows when the tunnel is live, the
forwarded address, an **Open Screen Sharing** button (in case the viewer didn’t pop up or you
closed it), **Reconnect** if the tunnel drops, and a **Log** of the raw `ssh` output. Closing
the tab (or **Disconnect**) tears the tunnel down.

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
