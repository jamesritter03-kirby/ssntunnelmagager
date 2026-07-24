# Remote Stuff — Cross-Platform (.NET 8 + Avalonia)

A cross-platform rebuild of the macOS **Remote Stuff** SSH tunnel manager, written in
**C# / .NET 8** with an **[Avalonia](https://avaloniaui.net) 11** UI. It runs on
**macOS, Linux, and Windows** from a single codebase.

> This lives in its own `cross-platform/` folder and is completely separate from the
> original Swift/SwiftUI app, which is preserved untouched in the repository root.

---

## What works today

- 🗂️ **Saved tunnel profiles** — host, port, user, identity key, jump host (`-J`),
  and any number of port forwards. Persisted as JSON.
- ↔️ **All three forward types** — Local (`-L`), Remote (`-R`), Dynamic/SOCKS (`-D`),
  each with optional bind address and (for local forwards) a service category.
- 📂 **Local shell profiles** — open your login shell in a chosen folder.
- 👀 **Live `ssh` command preview** — see and copy the exact command a profile generates,
  updated live as you edit.
- 🖥️ **Real embedded terminal tabs** — each connection opens a **PTY-backed** terminal
  built on `forkpty`, so **interactive password / host-key / 2FA prompts work** exactly
  as in a normal terminal. Includes a from-scratch VT100/xterm emulator (cursor motion,
  256-colour + truecolor SGR, scroll regions, alternate screen, scrollback).
- 🧵 Tunnels keep running in the background while you switch tabs.
- 🌱 **Example profiles** seeded on first launch (`-L`, `-D`, `-J`, `-R`).
- ⚙️ Full profile editor: shell/compression/keep-alive/agent-forwarding options,
  connect timeout, host-key policy, remote command, run-on-connect, extra ssh options,
  favourites and groups.

The embedded terminal currently targets **macOS and Linux** (via `forkpty`). Windows
runs the UI and profile management today; a ConPTY terminal backend is the planned
follow-up.

## Requirements

- [.NET SDK 8.0](https://dotnet.microsoft.com/download) or newer
- The system `ssh` client (`/usr/bin/ssh` or on `PATH`)

## Build & run

```bash
cd cross-platform
dotnet run --project src/RemoteStuff/RemoteStuff.csproj
```

Or open `cross-platform/RemoteStuff.slnx` in your IDE.

Profiles are stored per-user under the platform app-data directory, e.g.
`~/.config/RemoteStuff/profiles.json` (macOS/Linux).

## Publish a self-contained app

```bash
# macOS (Apple Silicon)
dotnet publish src/RemoteStuff/RemoteStuff.csproj -c Release -r osx-arm64 --self-contained
# Linux
dotnet publish src/RemoteStuff/RemoteStuff.csproj -c Release -r linux-x64 --self-contained
# Windows
dotnet publish src/RemoteStuff/RemoteStuff.csproj -c Release -r win-x64 --self-contained
```

---

## Auto-updates (Windows / macOS / Linux)

The app checks for and installs updates in-app via [Velopack](https://velopack.io).
On launch (when **Preferences ▸ Automatically check for updates** is on) and from
**Tools ▸ Check for Updates…**, it queries GitHub Releases and — if a newer build
exists — offers to download, install, and relaunch.

Updates are read from the `desktop-updates` release on
`jamesritter03-kirby/ssntunnelmagager`, using **one Velopack channel per runtime**
(`osx-arm64`, `osx-x64`, `win-x64`, `linux-x64`) so a platform never installs
another's package. This is separate from the macOS Swift app's Sparkle `updates`
release and does not interfere with it.

> Update checks are silently skipped when running an uninstalled build (e.g.
> `dotnet run` or `bin/Debug`), so development is unaffected.

### Build & publish an update

Bump `<Version>` in `src/RemoteStuff/RemoteStuff.csproj`, then:

```bash
cd cross-platform

# One-time tooling (versions must match the Velopack NuGet package):
dotnet tool install -g vpk --version 1.2.0     # ensure ~/.dotnet/tools is on PATH
brew install squashfs                          # only needed for the Linux AppImage

# Build + package all platforms into releases/ (macOS packages require a Mac;
# Windows and Linux are cross-built from macOS automatically):
./velopack.sh

# …then upload the feeds + installers to the desktop-updates GitHub release:
./velopack.sh --upload
```

Optional macOS signing/notarization (recommended for distribution):

```bash
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="your-notarytool-keychain-profile"
./velopack.sh --upload
```

`velopack.sh` produces, per platform: a full `.nupkg` (the update payload), the
per-channel `releases.<rid>.json` feed the app reads, and a first-run installer
(`.pkg` / `Setup.exe` / `.AppImage`). Old `.nupkg`s are kept on the release so
Velopack can serve smaller delta updates.

### Publish via GitHub Actions (all platforms)

Instead of running `velopack.sh` locally, the
[`Desktop release (Velopack)`](../.github/workflows/desktop-release.yml) workflow
builds each platform on its **native runner** (macOS, Ubuntu, Windows) and uploads
to the same `desktop-updates` release. Trigger it by pushing a tag:

```bash
git tag desktop-v1.9.42 && git push origin desktop-v1.9.42
```

…or run it manually from the Actions tab (optionally overriding the version).
macOS builds are unsigned for now; signing/notarization can be added to the
workflow later via the `--signAppIdentity` / `--notaryProfile` vpk options.

---

## Architecture

```
src/RemoteStuff/
  Models/            Domain types (SshProfile, PortForward, enums) — ported from Swift
  Services/
    SshCommandBuilder.cs   Faithful port of the ssh argument/preview builder
    ProfileStore.cs        JSON persistence + first-run example seeding
    ExampleProfiles.cs
    Terminal/
      UnixPtyProcess.cs     forkpty-based PTY child process (macOS/Linux)
      TerminalEmulator.cs   Compact VT100/xterm screen-buffer emulator
  ViewModels/        MVVM (CommunityToolkit.Mvvm) — Main, ProfileEditor, TerminalTab
  Views/
    MainWindow / ProfileEditorWindow
    Controls/TerminalControl.cs   Avalonia control that renders the emulator + input
```

## Roadmap (feature parity with the macOS app)

These exist in the original and are the natural next additions here:

- SFTP file browser, VNC-over-SSH viewer
- Native MQTT explorer and Redis browser
- Built-in syntax-highlighting text editor
- Workspaces, tab tiling, detachable windows, command palette
- Keychain-equivalent secure password storage + biometric gating
- Menu-bar / tray quick-connect, auto-updates
- Windows ConPTY terminal backend
