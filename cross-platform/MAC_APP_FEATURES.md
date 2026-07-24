# Remote Stuff (macOS app) — Complete Feature Inventory

This is the authoritative catalog of **every feature** in the macOS-only app
(`Sources/SSHTunnelManager/`), compiled from a full read of all 85 Swift source
files. It is the reference for cross-platform parity work. The macOS app is
READ-ONLY — this document describes what the cross-platform Avalonia port should
match.

**App identity:** "Remote Stuff" — a macOS SwiftUI SSH tunnel / remote-tools
manager that runs both as a windowed app and a persistent menu-bar app. Current
release documented in source: 1.9.42 (build 52).

---

## Table of Contents
1. App Shell & Lifecycle
2. Full Menu Bar
3. Menu Bar Extra & Dock Menu
4. Settings / Preferences
5. Sidebar & Profile List
6. Command Palette
7. Help System
8. Window Management — Detach, Tiling, Docking
9. Auto-Update & Install-Location Guard
10. Keyboard Shortcuts
11. Profiles (model, store, import/export, examples)
12. Keychain & Security
13. Known Hosts
14. Workspaces, Resume & Recently Closed
15. Terminal Sessions — kinds, lifecycle, tab bar
16. Terminal Features (run-on-connect, snippets, history, themes, broadcast, logging, copy/paste, links, host-key)
17. Port Forwarding (static & live)
18. SSH / mosh / SFTP / VNC command builders, ssh-copy-id, SSH-config import
19. SFTP File Browser & FUSE Mount
20. Finder (Local File) Browser
21. VNC Screen Sharing
22. MQTT Explorer
23. Redis Browser
24. In-App Web Browser Tab
25. Text / Code Editor
26. Spreadsheet
27. Network / LAN / "Mac as Router"
28. MikroTik Router Management
29. ZeroTier
30. Ad-hoc Connection Dialogs
31. Supporting Utilities

---

## 1. App Shell & Lifecycle

- **Dual-mode app**: normal windowed app **and** persistent menu-bar (status
  item) app.
- **Single-instance enforcement**: if another copy is already running, it
  activates that one and quits this one.
- **Native window tabbing disabled** — the app manages its own tab bar; removes
  AppKit's "Show/Hide Tab Bar" item.
- **Menu-bar-only launch** option: sets `.accessory` activation policy (no Dock
  icon or window flash at startup).
- **Custom app icon** installed at launch.
- **Session restore** at launch (optional) and continuous persistence of open
  sessions.
- **Router auto-start**: if "start router at launch" is on, brings the Mac
  router up (waits for LAN IP) before auto-connecting profiles.
- **Auto-connect** profiles flagged to connect at launch (staggered).
- **Quit confirmation** when a profile editor has unsaved edits (Save / Don't
  Save / Cancel; Save disabled if invalid).
- **Stays running after last window closed** (menu-bar app); **Dock reopen**
  re-shows the main window.
- **On terminate**: persists open tabs and reaps all tunnel processes so
  forwarded ports are freed for the next launch.
- **Web Inspector hotkey** (F12 / ⌥⌘I) installed app-wide for browser tabs.

---

## 2. Full Menu Bar

### File menu
- **New Local Terminal** — ⌘T
- **New Browser Tab** — ⇧⌘T
- **New Finder Tab**
- **New Text Editor** — ⌘N
- **New Spreadsheet**
- **New Remote Terminal…** (ad-hoc SSH sheet)
- **New SFTP Connection…**
- **New MQTT Connection…**
- **New Redis Connection…**
- **New VNC Connection…**
- **Browse ZeroTier Devices…**
- **Network & Routers…**
- **Close Tab** — ⌘W
- **Import Profiles…**
- **Import from ~/.ssh/config…**
- **Export All Profiles…**
- **Manage Known Hosts…**

### App menu
- **Check for Updates…** (Sparkle)

### View menu
- **Show/Hide Sidebar** — ⌃⌘S

### Profiles menu (custom)
- **New Profile…**
- **Connect ▸** (submenu, every profile)
- **Edit ▸** (submenu, every profile)
- **Open SFTP ▸** (non-local profiles)
- **Open VNC ▸** (non-local profiles)
- **Import Profiles…**
- **Export All Profiles…**

### Commands menu (custom)
- **Command Palette…** — ⌘K
- **Disconnect** (selected session)
- **Disconnect All Tunnels** — ⇧⌘D
- **Broadcast Input to All Terminals** — ⌃⌘B (toggle)
- **Set Up Passwordless Login…** (ssh-copy-id prompt)
- **Increase Terminal Text** — ⌘+
- **Decrease Terminal Text** — ⌘−
- **Actual Size** — ⌘0

### Workspace menu (custom)
- **New Workspace** — ⇧⌘N
- **Close Workspace** (disabled with <2 workspaces)
- **Next Workspace** — ⇧⌘]
- **Previous Workspace** — ⇧⌘[
- **Save Current Workspace…** (names & saves current tab set)
- **Save Current Workspace as Profile…**
- **Open Saved Workspace ▸** (with tab counts)
- **Delete Saved Workspace ▸**

### Window menu
- **Detach Tab into New Window** — ⌃⌘D
- **Tile Tabs** — ⌃⌘T (toggle)
- **Dock Tab to Left** — ⌃⌘[
- **Dock Tab to Right** — ⌃⌘]
- **Dock Tab to Top** — ⌃⌘↑
- **Dock Tab to Bottom** — ⌃⌘↓

### Help menu
- **Remote Stuff Help** — ⌘?
- **Keyboard Shortcuts**
- **Release Notes**
- **Download Older Versions…**
- **Check for Updates…**
- **Project Page on GitHub**

---

## 3. Menu Bar Extra & Dock Menu

### Menu bar status item
- Icon `point.3.connected.trianglepath.dotted` (template-tinted) with a **green
  active-tunnel count badge** + tooltip ("X active tunnels"); live-updates.
- Menu (rebuilt on open): **Remote Stuff** header · **Show Main Window** · **New
  Local Terminal** · **Connect** section (one item per profile, checkmark when
  live; each with a submenu: **Connect / Edit… / Open SFTP / Open VNC**) · **New
  Profile…** · **Open Workspace** section (each saved workspace "Name (count)") ·
  **Sessions** section (each session with ●/○ dot → focus; submenu **Focus /
  Disconnect|Close Tab**; **Disconnect All Tunnels** when tunnels live) ·
  **Options** (▸ **Start at Login** toggle, ▸ **Launch to Menu Bar** toggle) ·
  **Check for Updates…** · **Quit Remote Stuff** ⌘Q.

### Dock icon menu (right/Control-click)
- **Connect Profile** section (each profile, checkmark if active).
- **Open Workspace** section (each saved workspace "Name (count)").

---

## 4. Settings / Preferences (⌘,)

### Startup
- **Start at login** (via `SMAppService`).
- **Launch into the menu bar** (no window at startup; applies next launch).
- **Resume last session at startup** (default on).

### Terminal
- **Default theme for local terminals** (picker over all themes, with live
  preview).
- **Default text size for local terminals** (stepper, "N pt").
- **Right-click behavior**: **Paste clipboard** / **Copy selection, otherwise
  paste** (default) / **Show menu**.
- **Clear the selection after a right-click copy** (shown only for smart
  copy/paste; default on).

### Editor
- **Default theme for new text editors** (each tab can override).

### Updates
- **Automatically check for updates** (mirrors Sparkle).
- **Version X (build Y)** display + **Check Now…**.

---

## 5. Sidebar & Profile List

### Search bar
- **Search profiles…** field (filters by name / host / username / group), with
  clear (✕) button.
- **Online-only toggle** (wifi icon; green when on) — shows only profiles whose
  host is an online ZeroTier device or has a live connection.

### Profile list
- **Collapsible Favourites section** at top (star icon), then profiles grouped
  into **collapsible folders** by Group name (ungrouped bucket "Profiles" last);
  each header has chevron + count; collapse state remembered.
- **Empty states**: "No profiles yet", "No online devices", "No matches for '…'".
- **Drag-to-reorder** rows within a section (persists).
- **Esc** clears selection.
- **+ New Profile** button.

### Profile row
- Icon with **status dot**: green healthy / **orange degraded** (a local forward
  not responding), with tooltip.
- **Star** if favourite; **lightning bolt** if auto-connect-on-launch;
  **ZeroTier status glyph** (online/offline).
- Name, subtitle (host/user), forward summary line.
- Inline **Play/Stop** (connect / disconnect) button.

### Favourites header right-click
- **Connect All Favourites** / **Disconnect All Favourites**.

### Single-profile context menu
- **Connect** · **Disconnect** · (non-local) **Open SFTP / Open VNC / Set Up
  Passwordless Login…** · **Open Link ▸** (profile links) · **Open Service ▸**
  (categorized forwards → Web/MQTT/Redis) · **Add/Remove Favourites** · **Move ▸**
  (Top/Up/Down/Bottom) · **Edit…** · **Duplicate…** · **Export…** · **Delete**.

### Multi-select context menu (⌘/⇧-click)
- **Connect N** · **Disconnect N** · **Add/Remove Favourites** · **Export N…** ·
  **Delete N**.

### Bottom toolbar
- **Open local shell** · **Browse ZeroTier** · **Network & Routers** ·
  **Import/Export menu** (Import Profiles… / Export All… / Import from
  ~/.ssh/config… / Manage Known Hosts… / Export "Name"…) · context buttons for a
  selected profile (**Open SFTP / Open VNC / Passwordless Login / Edit**) · **+
  New Profile**.

---

## 6. Command Palette (⌘K)

Spotlight-style, 620pt, material background. Type to filter title/subtitle; ↑/↓
navigate, Enter runs, Esc dismisses, hover selects.

Actions: **New Local Terminal**, **New Finder Tab**, **New Text Editor**, **New
Spreadsheet**, **Set Up Passwordless Login…**, **Connect: [profile]** (each),
**SFTP: [profile]** / **VNC: [profile]** / **Passwordless Login: [profile]**
(non-local), **Run snippet: [label]** (active profile's snippets), **Run:
[command]** (command history across **every** terminal — last 30 each, focuses
that tab and runs), **Disconnect All Tunnels** (when tunnels live).

---

## 7. Help System

- Single reusable window (900×600), split view with **searchable** sidebar.
- **25 guide articles**: Getting Started, Profiles, Organizing Profiles, Tunnels
  & Port Forwarding, Advanced Connection Options, Automation, Passwordless Login,
  Terminal Tabs & History, Saved Commands & Links, Workspaces, Tiling &
  Detaching, SFTP File Transfer, Finder Tab, Text Editor, VNC Screen Sharing,
  ZeroTier Devices, Web/MQTT/Redis Tabs, Browser Tabs, SSH Config & Known Hosts,
  Command Palette & Menu Bar, Updates & Versions, Settings, Keyboard Shortcuts.
- Content rendered from typed blocks (paragraph, bullets, steps, tip callout,
  shortcuts table). Reusable **?** HelpButton throughout jumps to an article.
- **Release Notes** screen (version list with Installed / In-development badges).
- **Download Older Versions** screen (Check for Latest, All Releases on GitHub,
  per-version download buttons, signature-verification note).

---

## 8. Window Management — Detach, Tiling, Docking

### Detached terminal windows
- **Detach Tab into New Window** (⌃⌘D) — re-parents a live terminal into a
  floating 800×500 window without disturbing the process/tunnels; cascades.
- Floating window: **Always-on-top pin** toggle, **Re-attach** button (closing
  returns the tab to the main tab bar). Title stays synced; auto-closes if the
  session is killed elsewhere. **All-detached** view when every tab is detached.
- ⌘+/⌘−/⌘0 zoom works in the focused detached window.

### Tiling
- **Tile toggle** (per-workspace, remembered) — all center tabs shown in a
  resizable near-square grid vs one at a time.
- Each tile: header (status, icon, title, inline History menu, disconnect,
  detach, close) + live terminal; selected tile has an accent border.
- **Resizable dividers** with a live guide line; sizes stored as fractions per
  workspace and persisted; min tile 160×110.

### Docking to edges (side drawers)
- **Dock a tab to any of 4 edges** (left/right/top/bottom); multiple tabs stack
  in one drawer.
- Expanded drawer stacks panes with draggable dividers; collapsed drawer becomes
  a thin **rail** with status dots + icons and a slide-out chevron.
- Per-pane header: collapse-to-rail, return-to-tabs, status, icon, title, full
  context menu. Drawer cross-axis size + per-pane weights stored per workspace.
- **DockedOnlyCenter**: when all tabs are docked, the center shows the Welcome
  launch options.

---

## 9. Auto-Update & Install-Location Guard

- **Sparkle** auto-update: scheduled checks at launch; EdDSA-signed feed;
  surfaced from App menu, Help menu, menu bar, Settings, Older-Versions screen.
  "Check for Updates…" disabled while a check is in flight; automatic-check
  toggle bound to Settings.
- **Install-location guard**: if running from a read-only / translocated /
  non-Applications location, prompts **"Move to Applications?"** — copies via
  `ditto`, clears quarantine, relaunches from /Applications. Skipped for dev
  builds / `SSHTM_NO_MOVE_PROMPT=1`.

---

## 10. Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| ⌘T | New local terminal |
| ⇧⌘T | New browser tab |
| ⌘N | New text editor |
| ⌘K | Command palette |
| ⌘W | Close tab |
| ⇧⌘N | New workspace |
| ⇧⌘[ / ⇧⌘] | Previous / next workspace |
| ⌃⌘D | Detach tab into a window |
| ⌃⌘T | Tile tabs |
| ⌃⌘[ / ⌃⌘] | Dock tab left / right |
| ⌃⌘↑ / ⌃⌘↓ | Dock tab top / bottom |
| ⇧⌘D | Disconnect all tunnels |
| ⌃⌘B | Broadcast input to all terminals |
| ⌘+ / ⌘− / ⌘0 | Terminal text bigger / smaller / actual size |
| ⌃⌘S | Show/Hide sidebar |
| ⌘, | Settings |
| ⌘Q | Quit (from menu bar) |
| F5 | Refresh an SFTP tab |
| F12 / ⌥⌘I | Web Inspector in a browser tab |
| ⌘? | Open Help |
| ⌘O / ⌘S / ⇧⌘S | Editor: Open / Save / Save As |
| ⌘F / ⌥⌘F | Editor: Find / Find & Replace |
| ⌥↑ / ⌥↓ | Editor: Move line up / down |
| ⇧⌘D / ⇧⌘K | Editor: Duplicate line / Delete line |
| ⌘/ | Editor: Toggle comment |
| ⌘D | Editor: Select next occurrence |
| ⌥Esc | Editor: Complete word |

---

## 11. Profiles

### Profile model — every field
- **Identity**: id, name, **icon** (curated SF-Symbol picker in groups),
  `isLocal` (local shell profile), `startPath` (local shell start folder, ~).
- **Connection**: host, port (default 22), username, identityFile (`-i`),
  jumpHost (`-J`), extraOptions (verbatim), connectTimeout, strictHostKeyChecking
  (Ask / Accept-new / Refuse / Disable).
- **Session behavior**: openShell (else `-N`), compression (`-C`), keepAlive,
  verbose (`-v`), forwardAgent (`-A`), addKeysToAgent, requestTTY (`-tt`),
  remoteCommand, environment (SetEnv NAME/VALUE list), useMosh, runOnConnect,
  logSession, autoReconnect, autoConnectOnLaunch.
- **Port forwards** (list): name, type (local `-L` / remote `-R` / dynamic `-D`
  SOCKS), category (none / webpage / mqtt / redis), serviceUsername, bindAddress,
  listenPort, targetHost (default localhost), targetPort. Computed summaries,
  default ports (web 8080, mqtt 1883, redis 6379).
- **Organization/appearance**: isFavorite, group, terminal theme, fontSize
  (8–36), snippets (label+command), links (label+url).
- **Security**: requireAuthForSavedPassword (Touch ID gate; default true).
- **Workspace integration**: opensInOwnWorkspace, workspaceTemplateID,
  isWorkspaceLauncher, workspace (custom name), workspaceTabColor.
- Backward-compatible JSON decoders so upgrades never drop profiles.

### Profile store
- Pretty-printed JSON at `Application Support/SSHTunnelManager/profiles.json`;
  auto-saves on change.
- **First-launch seeding** of example profiles (only once).
- Mutations: add, update (upsert), delete (also removes Keychain passwords),
  duplicate (copies password, fresh forward ids, "… copy" name, inserts after),
  move/reorder (drag + per-section).
- **Import** de-duplicates display names.

### Import / Export (`ProfileTransfer`)
- Export/import as portable JSON (self-describing wrapper or bare array).
  **Passwords never exported**; imports get fresh ids.
- Export/import flows via NSSavePanel/NSOpenPanel, single or multiple, with
  confirmation alerts.
- **Command snippets** transfer separately (import/export per profile).

### Example profiles (seeded)
1. Database tunnel (`-L` 5433→5432, `-N`), 2. SOCKS proxy (`-D :1080`), 3.
Bastion + shell (`-J`, identity, 3 forwards, snippets), 4. Share local port
(`-R :9000→3000`).

### Profile edit coordinator
- Tracks the open editor's isOpen/isDirty/canSave; drives the quit-with-unsaved
  Save/Don't Save/Cancel flow; `profileToEdit` opens the editor (e.g. after "Save
  Workspace as Profile").

---

## 12. Keychain & Security

Login Keychain, "this device only" (never iCloud-synced). Four secret
categories:
- **SSH/profile passwords** (keyed by profile id): metadata-only `hasPassword`,
  set/delete/read, copy; **Touch ID / login-password gate** with a 60s secret
  cache + waiter coalescing so many tabs of one connection share **one**
  biometric prompt.
- **ZeroTier "Connect as" passwords** (keyed by username; never prompts).
- **MikroTik API passwords** (keyed by router UUID; never prompts).
- **Ad-hoc / workspace-template tab credentials** (via credentialID on
  snapshots).

---

## 13. Known Hosts

Manage `~/.ssh/known_hosts` in-app: parse entries (host label, key type, hashed
flag; handles `@cert-authority`/`@revoked`, `[host]:port`), **remove** by
rewriting the file (works for hashed entries `ssh-keygen -R` can't target).
- **UI** (sheet): list with per-entry icon/label/key-type + trash; **filter**
  field; **Remove Selected** (multi-select); reload; empty states.

---

## 14. Workspaces, Resume & Recently Closed

### Workspaces
- Named top-level tab collections (always ≥1). Add (⇧⌘N), switch, next/previous,
  rename, close (last can't close; goes to Recently Closed).
- **Drag-reorder pills**; **tab-count badge**; **workspace color** (8 colors +
  Default) tints the pill.
- **Save Workspace / Update Saved Workspace** (in place); **Save as Workspace…**
  (named, overwrite-confirm); **Open Saved Workspace**; **Delete Saved
  Workspace** (cleans up ad-hoc credentials, re-homes dependent profiles).
- **Save as Profile…** — snapshots tabs+layout into a template + creates a
  launcher/cloned profile; ad-hoc tab passwords persisted per-tab.
- **Dedicated / template workspaces**: a profile can launch into a named
  dedicated workspace, recreating a saved template's tabs/docks the first time,
  re-pointing ad-hoc tabs at the launching host.
- **Tiling & tile layout are per-workspace** and persisted.

### Persistence & Resume
- **Resume Last Session**: full workspace/tab/dock/selection/color/run-on-connect
  state serialized (debounced; force-saved on quit); legacy migration.
- Welcome screen **Resume Last Session (N tabs)** button.
- **Auto-connect on launch** (staggered); **auto-reconnect** on dropped ssh
  (exponential backoff 2→30s); **stray-tunnel reaping** frees ports.

### Recently Closed (max 25)
- Closed tabs and whole workspaces, each reopenable; **Reopen / Remove / Clear**;
  per-kind labels; relative timestamps.

---

## 15. Terminal Sessions — kinds, lifecycle, tab bar

### Session kinds (10)
`localShell`, `ssh`, `sftp`, `vnc`, `web`, `mqtt`, `redis`, `finder`, `editor`,
`spreadsheet` — each maps to a content view; each has an SF-Symbol icon (profile
icon overrides shell/ssh). Remote kinds say "Disconnect"; local says "Stop".
**Status dot**: green running / orange paused / red non-zero exit / gray ended.

### Opening tabs
From the tab-bar **+** menu, the Welcome screen, and the docked-only center:
New Local Terminal, Browser, Finder, Text Editor, Spreadsheet; New Remote
Terminal / SFTP / MQTT / Redis / VNC (ad-hoc sheets); Connect to Profile
submenu; ZeroTier browser.

### Lifecycle
- **Start deferral**: PTY terminals wait until attached + sized (avoids blank
  first screen on restore/tile).
- **Reconnect/Restart**, **Disconnect** (SIGHUP, keeps tab + Reconnect banner),
  **Shut down** (force-kill on close/quit to avoid zombie tunnels).
- **Exit banner** overlay ("Session ended" / "exit code N" + command preview +
  Reconnect / Close).
- **Duplicate Tab** (all kinds except profile-backed ssh); placed to the right;
  content tabs mirror live state, connection tabs reconnect fresh.

### Tab bar & chips
- Horizontally scrollable chips + **+** menu. Chip = status dot, kind icon,
  title, paused badge, inline close; tinted by selection or user tab color.
- **Drag-reorder** tabs.
- Adjacent controls for the selected session: **Snippets** menu, **History**
  menu, **Links** menu, **Disconnect/Stop**, **Tile toggle**, **Broadcast** pill.

### Per-tab context menu (chips, tiles, dock panes)
Adapts to kind. Includes: editor/spreadsheet file actions; **Snippets** (Run /
Insert at Prompt); **Links**; **Services**; **Copy IP Address**; **Pause/Resume
Connection** (web = Pause/Resume Page); **Enter Saved Password**; **Copy/Save
Terminal Output**, **Clear Terminal**; **Run Command on Launch… / Edit Launch
Command…**; **Reveal Session Log**; **Broadcast Input…**; **Edit Connection…**
(full editor for ssh, lightweight sheet for services); **Port Forwards ▸** (Add /
Cancel each); **Mount with FUSE… / Unmount**; **VNC options**; **Open SFTP / Open
VNC**; **Set Up Passwordless Login…**; **Theme ▸**; **Tab Color ▸**; **Dock ▸**;
**Duplicate Tab / Detach into New Window / Close Tab**.

---

## 16. Terminal Features

- **Run-on-connect**: per-profile + per-tab override; auto-fires once the shell
  looks ready (re-arms on password prompt); configurable via menu (Save / Save &
  Run Now); auto-renames the tab to the command's base name.
- **Snippets**: per-profile saved commands; Run (inject + Enter) or Insert at
  Prompt; **Edit Snippets…** opens the editor; launcher tabs surface the owning
  profile's snippets.
- **Command history**: reconstructed from typed bytes (swallows escapes, handles
  CR/LF/Backspace/Ctrl-C/Ctrl-U); **never records passwords**; dedup; cap 300.
  History menu (last 40, rerun). **Import History…** (incl. `.bash_history` /
  zsh EXTENDED_HISTORY), **Save History…**, **Clear History**.
- **Terminal themes**: **28 built-in** (Pro, Homebrew, Ocean, Solarized D/L,
  Dracula, Nord, Gruvbox D/L, One Dark/Light, Monokai, Tokyo Night, Catppuccin
  Mocha/Latte, GitHub D/L, Night Owl, Snazzy, Material, Ayu Dark, …); grouped
  Dark/Light; per-tab menu; profile tabs recolor all their tabs.
- **Font zoom** ⌘+/⌘−/⌘0 (per-terminal focus-aware); persisted; SF Mono → Menlo →
  system monospaced.
- **Broadcast Input to All Terminals** (⌃⌘B) with an orange "Broadcasting" pill.
- **Session logging** (per-profile) to a timestamped transcript; **Reveal
  Session Log**.
- **Copy/paste**: ANSI-sanitized copy; right-click behavior (paste / smart
  copy-paste / context menu; deferred for vim/htop/tmux mouse apps); **file drop**
  onto the visible terminal → Paste Path(s) or Paste Contents.
- **In-app link handling**: ⌘-click http(s)/`www.` opens an in-app browser tab;
  other schemes go to the system; hover highlight.
- **Host-key-changed handling**: detects the change, shows an alert with **Remove
  Key & Reconnect** (`ssh-keygen -R`) or Cancel.
- **Password autofill**: Keychain (Touch ID gated), max 2 attempts/connection;
  preset password for ad-hoc; source-profile autofill for launcher workspaces;
  ~45s unlock cache; never recorded to history.

---

## 17. Port Forwarding

### Static (built at launch)
- **local `-L`**, **remote `-R`**, **dynamic `-D`/SOCKS**; spec
  `[bind:]listenPort:targetHost:targetPort`. `ExitOnForwardFailure=yes` when any
  forward exists.

### Live via ControlMaster
- Profile-backed ssh opens a ControlMaster socket → **add/remove forwards without
  reconnect**. **Add Port Forward…** dialog (type, listen port, target host/port,
  bind address, "Also save to the profile" toggle) and **Cancel <forward>** in
  the Port Forwards submenu (`ssh -O forward|cancel`).
- **Tunnel health**: 5s TCP probe of local forward endpoints →
  healthy/degraded/unknown, drives the sidebar dot.

---

## 18. Command Builders, ssh-copy-id, SSH-config Import

- **SSH builder**: `-N`/remote-command/`-tt`, `-C`, `-v`, `-A`, keep-alive,
  ControlMaster, AddKeysToAgent, ConnectTimeout, StrictHostKeyChecking, SetEnv,
  `-p`, `-i`, `-J`, extra options, destination, remote command.
- **mosh builder** (alternative; `--ssh=` subcommand; no forwards).
- **SFTP builder**: `-C`, `-v`, `-P`, `-i`, `-J`, keep-alive, extra options.
- **VNC-over-SSH builder**: `ssh -N` local forward `localPort:127.0.0.1:5900`
  (free local port), embedded viewer.
- **ssh-copy-id** ("Set Up Passwordless Login…"): one-click in a local terminal;
  key resolution (identity `.pub` → default keys → **Generate New Key** (ed25519)
  / **Choose Existing…**); autofills password, handles host-key/password prompts;
  ad-hoc prompt variant.
- **SSH-config import**: parses `~/.ssh/config`, imports concrete hosts (skips
  wildcards), maps HostName/User/Port/IdentityFile/ProxyJump/ForwardAgent/
  Compression/ConnectTimeout + Local/Remote/Dynamic forwards; result alerts.

---

## 19. SFTP File Browser & FUSE Mount

- **Engine**: headless interactive `sftp` process; parses `ls -la` into entries
  (name, kind, size, date, perms, symlink target); friendly error mapping;
  password autofill priority (preset → own Keychain → workspace source → manual
  dialog); host-key verification alert.
- **File ops**: refresh, cd/up, open, upload (files/dirs, into a folder),
  download (default folder or chosen, reveal in Finder), single-file upload to
  absolute path (editor save-back), mkdir, remove, rename.
- **Toolbar**: go up, path/ancestor menu, refresh, **new folder**, **new file**
  (opens editor wired to save back), **upload**, **download**, **download to…**,
  **delete**, **Mount**, busy spinner.
- **Mount as drive (FUSE/sshfs)**: mounts remote home at `~/mnt/<name>` in
  Finder; states unmounted/mounting/mounted/failed; **eject** when mounted;
  helper discovery; sshfs args (Port/IdentityFile/ProxyJump/Compression/
  password_stdin/accept-new/keepalive/reconnect/volname); **remembered mounts**
  auto-remount once per session; **guided-install sheet** (fuse-t + sshfs, copy
  commands, Re-check).
- **List & drag-drop**: rows with icon/name/size/date; custom plain/⌘/⇧-click +
  double-click-open; delete key; **drop from Finder to upload** (multi-file, onto
  folder rows); **drag remote file out to Finder** (on-demand download).
- **Row context menu**: Open, Edit in Text Editor, Open as Spreadsheet, Download,
  Download To…, Rename…, Delete, New File/Folder, Refresh. Background menu:
  Refresh/New File/New Folder/Upload/Mount.
- **State/status**: connecting/failed/ended screens (Reconnect + Show Log);
  status bar (dot, "Save to:" folder, raw sftp log); **F5** refresh.

---

## 20. Finder (Local File) Browser

- Local Mac file browser tab mirroring SFTP. **Live 2s auto-refresh** (only
  republishes on content-signature change).
- **Navigation**: go up, **Home**, path/ancestor menu, open folder, open file
  (default app), follow symlinks.
- **Toolbar**: go up, home, path menu, **filter field**, **view-options menu**
  (Sort By Name/Size/Date/Kind, Order, **Keep Folders on Top**, Show
  All/Folders/Files), refresh, **new folder**, **show/hide hidden files**,
  **Reveal in Finder**.
- **Sortable columns** (Name/Size/Date; click to sort/flip); **responsive
  columns** (hide Size <240pt, Date <340pt).
- **Selection** (plain/⌘/⇧-click + double-click-open); **drag out** as file URL
  (paste path to terminal / upload to SFTP / drop to Finder); **delete → Move to
  Trash** (confirm, restorable).
- **Row context menu**: Open / Open with Default App, **Open in Text Editor**,
  **Open as Spreadsheet**, Reveal in Finder, Copy Path, Move to Trash.
- **Status bar**: drive icon + counts; error in red.

---

## 21. VNC Screen Sharing

Two shapes: **Tunneled** (profile: `ssh -N -L` + embedded viewer) and
**Direct/ad-hoc** (typed host:port). Both render **inside the tab** via
RoyalVNCKit, with macOS Screen Sharing.app fallback.
- **Options**: scaling (fit vs 1:1), view-only, clipboard sharing, **color
  depth** (True / High / 256), Ctrl+Alt+Del, native framebuffer size.
- **Reliable connect**: retries the first dial up to 12× (port ready before it
  accepts); distinguishes port-not-ready from auth failure / in-session drop.
- **Credentials**: cached → remembered Keychain (`VNCCredentialStore`, Touch ID
  gated, device-only) → preset ad-hoc → prompt (password + optional username +
  **Remember password**); bad-saved-password self-heal.
- **Framebuffer host**: scroll-to-pan at 1:1, keyboard focus forwarded.
- **UI**: connecting/connected/failed/ended screens (Reconnect + Show Log);
  toolbar (target label, **File Transfer (SFTP) menu** for tunneled — Open SFTP /
  Upload Files…, scale toggle, Open in Screen Sharing, show log, disconnect).
  Viewer owned by the session so it survives workspace switches / remounts.
- **New-VNC sheet**: host (+ZeroTier picker), port (5900), username, password
  (not saved), Display (fit/1:1), Colors, View-only; connects direct.

---

## 22. MQTT Explorer

- **Engine**: minimal MQTT 3.1.1 over Network framework; on connect subscribes to
  `#` and `$SYS/#`; per-topic state (payload, retained, count, last-update);
  **numeric history** for graphing (600 samples; extracts numbers from
  bare/JSON/number-with-unit payloads); QoS-1 PUBACK; patient 300s connect
  retry; publish (QoS 0, retain).
- **UI**: HSplitView (tree + detail/publish). **Topic tree** with filter,
  `/`-delimited nodes (chevron, icon, preview, retained pin, count badge),
  auto-expand new branches, Expand/Collapse (All). **Detail**: topic string +
  "use in publish", stats, **Payload / Graph** toggle (pretty JSON / text / hex;
  live Swift Charts line chart with toggleable field chips). **Publish** panel
  (topic, payload, retain, Send). **Status bar** (dot, topic/msg counts, Clear,
  Reconnect).

---

## 23. Redis Browser

- **Engine**: RESP2 over Network framework; optional AUTH (default/user),
  PING-verify (clear NOAUTH message), INFO version; SCAN paging (MATCH/COUNT),
  TYPE+TTL+typed value load (string/list/set/zset/hash), DEL, arbitrary command;
  25× connect retry.
- **UI**: HSplitView (keys + detail/console). **Key pane**: match field + Scan,
  key list, **Load more** pagination. **Detail**: key name + Delete, **type
  badge** (color-coded), **TTL**, **Live** 1s auto-refresh toggle; typed value
  views (pretty JSON string / indexed list/set tables / zset member-score / hash
  field-value). **Console**: `redis>` command + Run, collapsible output (last 200
  lines) + Clear. **Status bar** (dot, "Connected · Redis <version>", key count,
  Reconnect).

---

## 24. In-App Web Browser Tab

- **Toolbar**: Back / Forward (disabled states), **Reload/Stop** (combined),
  editable **address bar** (Enter loads), **SOCKS proxy indicator** (green lock
  when routing through a `-D` forward), **Web Inspector** (ladybug), **Open in
  default browser** (safari); top **loading progress bar**.
- **URL handling**: normalizes typed input (auto scheme); **honors typed http://**
  (clears HSTS, disables auto-upgrade); address bar reflects committed URL (KVO).
- **Pause / Resume** (unload to about:blank to stop background CPU/network;
  resume reloads exact page). WKWebView owned by the model → survives workspace
  switches without reloading (like a terminal).
- **Page title** observed → renames the tab.
- **Web Inspector**: F12 / ⌥⌘I / ⌥⌘C (app-wide monitor); forced detached window.
- **Developer right-click menu**: Reload, Hard Refresh (ignore cache), Empty
  Caches, Empty Caches + Hard Refresh, Clear Cookies, Clear Data for This Site…,
  Clear All Website Data…, Force HTTP (Clear HSTS) & Reload, Clear HSTS for All
  Sites, Copy Page Address, Open in Default Browser, Open Web Inspector.
- **TLS trust**: Safari-style per-host invalid-cert warning (Continue/Cancel;
  remembered for session).
- **Downloads** (WKDownloadDelegate): non-displayable content / `download` links
  → `~/Downloads` (unique-name), reveal in Finder.
- **File uploads**: `<input type=file>` opens NSOpenPanel.
- **`target=_blank`/window.open** open in the same view.
- **Tunnel-aware auto-retry**: retries transient errors up to 40×; probes the
  tunnel port (SOCKS or `-L`) and reloads when it opens (90s).
- **Gestures**: back/forward swipe, pinch-to-zoom.
- **SOCKS proxying** (macOS 14+): a profile `-D` tab routes through SOCKS v5.

---

## 25. Text / Code Editor

- **Two engines per tab**: **Classic** (NSTextView, regex highlighting, custom
  gutter) and **Scintilla (beta)** (folding, minimap, smart-editing, compare,
  extra view options) — toggled via the **Folding Engine** button.
- **File ops**: New, Open (⌘O), Save (⌘S), Save As (⇧⌘S), Revert to Saved; atomic
  writes; unsaved-changes confirmation; language preferred extension.
- **Encoding**: BOM sniff + UTF-8/Latin-1/Win-1252/Mac Roman detection; status-bar
  readout & menu. **Line endings**: LF/CRLF/CR (auto-detect + menu).
- **Syntax highlighting — 24 languages**: Plain Text, Swift, Python, JavaScript,
  TypeScript, JSON, HTML, XML, CSS, Markdown, Shell, C, C++, Java, C#, Go, Rust,
  Ruby, PHP, SQL, YAML, TOML, INI — with special basenames (Makefile, Dockerfile,
  .zshrc, .gitconfig, …). Auto-detect + manual language menu.
- **11 color themes**: System (Auto), Xcode Light/Dark, GitHub Light, One Dark,
  Dracula, Monokai, Solarized Light/Dark, Nord, Midnight (selecting sets app
  default).
- **View options**: Word Wrap, Line Numbers, font zoom (8–40pt), and (Scintilla)
  Current-Line Highlight, Indentation Guides, Show Whitespace, Column Ruler (80),
  Change History Bar, **Document Map / minimap**.
- **Find & Replace** (⌘F / ⌥⌘F): case, regex (capture groups), whole-word,
  prev/next, wrap, live count, Replace / Replace All; byte-accurate in Scintilla.
- **Go to line**; status bar Ln/Col, Sel N, N lines, N chars.
- **Smart editing** (Scintilla): Move Line Up/Down (⌥↑/⌥↓), Duplicate Line
  (⇧⌘D), Delete Line (⇧⌘K), **Toggle Comment** (⌘/, language-aware), Select Next
  Occurrence (⌘D, multi-cursor), Complete Word (⌥Esc), Bookmarks.
- **Compare / diff** (Scintilla): side-by-side vs another open tab; prev/next
  change; dependency-free LCS differ with intra-line spans; colored rows.
- **Auto-backup**: debounced crash-safe backups (incl. untitled) restored on
  relaunch.
- **External file-change detection**: file watcher → in-tab banner + modal
  (Reload / Keep Mine; deleted → Keep in Editor).
- **Remote (SFTP) editing**: edits a temp file and **uploads back on every save**;
  status-bar cloud indicator (Synced / Uploading / failed).
- **Dirty tracking**: "• " title prefix; live text mirrored so re-mounted editors
  restore typed text; plain-text code editor (substitutions/spelling off).

---

## 26. Spreadsheet

- Edits **CSV/TSV** and **Excel `.xlsx`** as a grid of **plain string cells**.
  **No formula-evaluation engine** (XLSX formula cells read their cached value
  only). Stable UUID row/column identities.
- **File ops**: New (3×3), Open (⌘O; xlsx/csv/tsv/text), Save (⌘S), Save As (⇧⌘S;
  format popup Excel/CSV/TSV), Revert, **Open in Excel** (falls back to Numbers).
- **Delimiters** (CSV/TSV): Comma/Tab/Semicolon/Pipe; auto-detect;
  RFC-4180-compliant parse/quote.
- **Header Row** toggle (promote/demote first row).
- **Rows**: Add Row (below selection), Delete Row.
- **Columns**: Add Column; header menu Rename / Sort Asc/Desc / Insert Left/Right
  / Delete; resizable.
- **Grid** (native NSTableView): row-number gutter, alternating rows, grid lines,
  multi-row selection, double-click to edit.
- **Sorting**: header-click + menu; numeric when both parse, else localized.
- **Excel workbooks**: multi-sheet (worksheet bar: switch, add, rename, delete),
  date/time detection, dependency-free reader/writer (`XLSXDocument` + `MiniZip`
  ZIP layer), numeric-vs-text preservation, sheet-name sanitization.
- **Remote (SFTP) editing** with the same cloud status indicator.

---

## 27. Network / LAN / "Mac as Router"

Network browser (resizable split): "This Mac" + saved/discovered routers.
- **This Mac** (live): host name, public IP (copyable, refreshable), **Wi-Fi**
  (SSID, signal %, RSSI, channel, Tx rate), overview (public IP, gateway, DNS),
  **interfaces** (name, IPv4, MAC, up/down, media type).
- **Actions**: **Flush DNS Cache**, **Renew DHCP** (per interface), **Refresh
  Public IP**, **Edit DNS servers** (per service, quick-fill Router/Cloudflare/
  Google/Reset), **Edit default gateway** (temporary or make-permanent).
- **Internet Sharing (ICS)**: read config, Turn On/Update/Off (pick source + to
  interfaces; writes NAT plist; one admin prompt).
- **Mac as Router (advanced)**: uplink + LAN device, router IP (10.1.1.1),
  subnet, **built-in DHCP** (bootpd, address pool/lease), **dnsmasq DNS
  forwarder**, autoStart, **web portal** (port 80). Start (assigns LAN IP, IP
  forwarding, pf NAT anchor, DHCP, portal — one admin prompt), **IP-conflict
  pre-flight** (ARP probe), Stop. **Connected devices** (DHCP leases + ARP:
  name/IP/MAC/active; 15s poll), **Clear ARP Cache**. Portal = live status page +
  config form; auto-start on launch.

---

## 28. MikroTik Router Management

RouterOS REST API (v7+, `/rest`); metadata in UserDefaults, passwords in
Keychain.
- **CRUD** routers (name, host, port 443/80, username, password, HTTPS/
  self-signed).
- **Auto-discovery**: **MNDP** (UDP 5678 broadcast) + **ZeroTier overlay probing**
  (TCP-probe WinBox 8291 / API 8728 / API-SSL 8729); quick "+ Add Router"
  pre-fill.
- **Status pane**: system (identity, model, version, arch, uptime, CPU, memory),
  interfaces (enable/disable toggle), IP addresses, DHCP leases; Refresh / Edit /
  **Reboot** / Remove.
- **WinBox-style config explorer**: grouped menus (Interfaces/Wireless/IP/
  Firewall/Queues/System) with **full CRUD** (reload, filter, Add curated fields,
  Edit all returned fields, enable/disable, Delete). Covers Interface List/Bridge/
  VLAN/WiFi, IP Addresses/ARP/DHCP/DNS/Routes/Pool/Cloud/Services/Neighbors,
  Firewall Filter/NAT/Mangle/Address Lists, Simple Queues, System Identity/Clock/
  NTP/Users/Packages/Scheduler/Scripts/Logs.
- **Config backup/export/import**: Export `.rsc`, Create on-router `.backup`,
  **Load & Apply Config File…** (confirm + apply via temp script).

---

## 29. ZeroTier

Browse/manage devices across one or more accounts (ZeroTier Central **and**
self-hosted ZTNET, incl. org-scoped tokens).
- **Accounts manager**: multiple accounts (label + baseURL; tokens in Keychain);
  add/edit/rename/remove.
- **Networks & members**: names, online/authorized/total counts, routes, member
  details (ip assignments, physical address, client version, last-online,
  is-online); org-token auto-detect; **30s auto-refresh**.
- **Member management**: **Authorize** / **Deauthorize** (confirm; optimistic +
  re-fetch).
- **Browser UI**: network list (All Networks + per account; copyable 16-hex id;
  local badge), **This Mac strip** (local client via loopback; joined networks
  details), filter + **Online-only**, **"Connect as"** username (+ optional saved
  password), **member cards** with per-IP **connect buttons**: Open in browser,
  SSH, SFTP, VNC, MQTT, Redis (ad-hoc tabs to that IP).
- **ZeroTier picker**: a globe button next to any host/IP field → popover of
  ZeroTier devices + Mac-router LAN clients (filter + Online toggle; inline
  add-account). **Status glyph** next to host fields (online/offline / router
  client).

---

## 30. Ad-hoc Connection Dialogs

All 440pt, shared DialogHeader + ZeroTier picker on Host, Connect gated on valid
host+port.
- **New Remote Terminal / New SFTP** (`RemoteConnectionView`): host, port (22),
  username, password (not saved); SSH keys tried first.
- **New VNC** (`VNCConnectionView`): host, port (5900), username, password;
  Display (fit/1:1), Colors, View-only; connects direct.
- **New MQTT / Redis** (`ServiceConnectionView`): service segmented picker (swaps
  default port 1883/6379), host (127.0.0.1), port, username, password (not
  saved); opens native client tab.
- **Edit Connection** sheet: re-point a live MQTT/Redis/direct-VNC/SFTP tab and
  reconnect in place.
- **Shared components**: DialogHeader (icon+title+subtitle+? HelpButton),
  EmptyStateView, **CopyableText** (click-to-copy with green-check flash).

---

## 31. Supporting Utilities

- **WindowAccessor**: captures the NSWindow so the menu bar can re-show it.
- **TCPProbe**: `isReachable` / `allReachable` — backs the tunnel-health dot.
- **Collection+Safe**: bounds-checked `subscript(safe:)`.
- **PortProbe** (web tab): polls a TCP endpoint until it accepts, then fires
  once — waits for a tunnel's forwarded/SOCKS port before (re)loading a web tab.
- **FileDropContainer / InAppFileDrag**: AppKit bridge for reliable **multi-file**
  Finder drag-and-drop (SwiftUI collapses these to one).

---

*Compiled from a complete read of all 85 Swift files under
`Sources/SSHTunnelManager/`. Use this as the parity checklist for the
cross-platform Avalonia port.*
