# Publishing Remote Stuff (auto-update releases)

How the in-app updater works and how to ship a new version. Read this first — the
most common mistake is packing a build at a version that's **already published**, which
makes the app report "no update available."

## How updates work

- The app (`RemoteStuff`) auto-updates via **Velopack**, reading its feed from a GitHub
  release tagged **`desktop-updates`** on repo **`jamesritter03-kirby/ssntunnelmagager`**.
  See [Services/UpdateService.cs](src/RemoteStuff/Services/UpdateService.cs).
- There is **one Velopack channel per runtime**, named after the RID: `win-x64`,
  `linux-x64`, `osx-arm64`, `osx-x64`. A platform only ever installs its own channel.
- The update check just downloads a small JSON feed (e.g. `releases.win-x64.json`) and
  compares the highest version to what's installed. It is a version comparison, **not** a
  scan — so the number of old versions on the release does **not** slow detection.

## The #1 gotcha: bump the version

The app version lives in [src/RemoteStuff/RemoteStuff.csproj](src/RemoteStuff/RemoteStuff.csproj)
`<Version>`. **It must be strictly greater than the highest version already on the live
feed**, or the updater offers nothing.

Check the *live* max (the local `releases/` folder is often stale) via the public API:

```powershell
$rel = Invoke-RestMethod "https://api.github.com/repos/jamesritter03-kirby/ssntunnelmagager/releases/tags/desktop-updates" -Headers @{ 'User-Agent'='ps' }
$asset = $rel.assets | Where-Object { $_.name -eq 'releases.win-x64.json' }
$feed = Invoke-RestMethod $asset.browser_download_url -Headers @{ 'User-Agent'='ps' }
$feed.Assets | Where-Object Type -eq 'Full' | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 5 Version
```

Deleting old versions does **not** help updates show up faster. Don't do it — old nupkgs
are what Velopack uses to build small delta updates.

## Do NOT run `velopack.sh` on Windows

`velopack.sh` is a Bash script intended for macOS. On this Windows box:

- `bash` resolves to **WSL** (`C:\WINDOWS\system32\bash.exe`) — a Linux environment where
  the Windows `vpk.exe` .NET tool doesn't exist (`vpk not found`).
- The script has CRLF line endings, so WSL fails with `/usr/bin/env: 'bash\r'`.

Instead, drive `vpk` **natively in PowerShell** (installed at
`C:\Users\<you>\.dotnet\tools\vpk.exe`). Note: `vpk 1.2.0` takes a command
(`pack` / `download` / `upload` / `delta`); `vpk --version` is invalid.

## Publish a Windows update (PowerShell, native vpk)

Run from `cross-platform/`. Substitute `<V>` with the new version (e.g. `1.9.109`).

```powershell
# 0. Bump <Version> in src/RemoteStuff/RemoteStuff.csproj to <V> and save all files.

# 1. Sync the LIVE feed first so the regenerated JSON keeps every prior version and
#    can build a delta from the current release. (Public repo -> no token needed.)
vpk download github -o releases -c win-x64 --repoUrl https://github.com/jamesritter03-kirby/ssntunnelmagager

# 2. Publish the app to a plain (multi-file, NOT single-file) folder.
dotnet publish src/RemoteStuff/RemoteStuff.csproj -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=false -p:PublishTrimmed=false -p:DebugType=none -o pub/win-x64 -v quiet

# 3. Pack the Velopack release into releases/.
vpk pack --packId RemoteStuff --packVersion <V> --packDir pub/win-x64 `
  --packTitle "Remote Stuff CP" --packAuthors "Remote Stuff CP" `
  --mainExe RemoteStuff.exe --channel win-x64 --outputDir releases `
  --icon src/RemoteStuff/Assets/AppIcon.ico

# 4. Upload to the desktop-updates release with gh + --clobber (needs GitHub write auth
#    — see below). Upload ONLY this channel's files so you don't clobber other channels.
$env:GH_TOKEN = (gh auth token)   # or the git-credential bridge below
gh release upload desktop-updates `
  releases/RELEASES-win-x64 releases/assets.win-x64.json releases/releases.win-x64.json `
  releases/RemoteStuff-<V>-win-x64-full.nupkg releases/RemoteStuff-<V>-win-x64-delta.nupkg `
  releases/RemoteStuff-win-x64-Setup.exe `
  --repo jamesritter03-kirby/ssntunnelmagager --clobber
Remove-Item Env:GH_TOKEN
```

> **Do NOT use `vpk upload github --merge true`.** On this multi-channel release it fails
> with *"There is already a remote asset named 'releases.win-x64.json', and merging release
> files on GitHub is not supported."* `--merge` cannot overwrite the per-channel feed JSON.
> Use `gh release upload ... --clobber` (above), which is exactly what `velopack.sh` does.

> **Skipping step 1 corrupts the feed.** Without the download, `vpk` regenerates a
> `releases.win-x64.json` that omits the versions it never saw locally, and the upload
> clobbers the live feed — losing recent releases and their delta chain.

> `vpk pack` natively on Windows already targets Windows. The `[win]` directive is only
> needed when **cross-building** a Windows package from macOS.

## GitHub auth for upload

Uploading needs the GitHub **CLI** authenticated — which is separate from being logged
into GitHub in a browser, and separate from git's credential store.

```powershell
gh auth status            # check
gh auth login             # if not logged in (interactive; do this yourself)
```

`(gh auth token)` pulls the token locally and passes it to `gh`. **Never paste a token
into chat.** If `gh` isn't authenticated but git can push, bridge git's credential to `gh`
without printing it (this is what worked when `gh auth status` said "not logged in"):

```powershell
$cred = "protocol=https`nhost=github.com`n`n" | git credential fill
$env:GH_TOKEN = (($cred | Select-String '^password=').ToString() -replace '^password=','')
# ... run the gh release upload command ...
Remove-Item Env:GH_TOKEN
```

## Other platforms

- **linux-x64**: same steps, but note two differences:
  - `vpk download github -o releases -c linux-x64 ...` — `download` has **no** `--tag`
    argument; it fetches the channel from the `desktop-updates` release automatically.
  - Pack with the platform directive and an extensionless main exe:
    `vpk "[linux]" pack ... --mainExe RemoteStuff --channel linux-x64 --outputDir releases`.
    A bare `vpk pack --mainExe RemoteStuff` is rejected on Windows with *"--mainExe does
    not have an .exe extension"*; the `[linux]` directive enables cross-compile and allows
    the extensionless exe. `vpk` cross-builds the AppImage on Windows — `mksquashfs` is
    **not** required despite the note in `velopack.sh`.
  - Upload the linux assets (no Setup.exe — use `RemoteStuff-linux-x64.AppImage` instead):
    `gh release upload desktop-updates releases/RELEASES-linux-x64 releases/assets.linux-x64.json releases/releases.linux-x64.json releases/RemoteStuff-<V>-linux-x64-full.nupkg releases/RemoteStuff-<V>-linux-x64-delta.nupkg releases/RemoteStuff-linux-x64.AppImage --repo jamesritter03-kirby/ssntunnelmagager --clobber`.
- **osx-arm64 / osx-x64**: **must** be built on a Mac (needs `codesign`/`xcrun`). Run
  `./velopack.sh --upload osx-arm64 osx-x64` there, with signing env vars set.

## Standalone (non-updating) binaries

`./publish.sh` (or the equivalent `dotnet publish ... -p:PublishSingleFile=true` into
`dist/`) produces self-contained single-file executables for hand-distribution. **These
do not touch the update feed** — publishing to `dist/` will never make the in-app updater
see a new version. Use the Velopack flow above for updates.

## Verify after publishing

- Re-read the live feed (snippet at the top) and confirm `<V>` is now the max.
- In the app: check for updates. `UpdateService` logs every check/download/apply to
  `%AppData%\RemoteStuff\update.log` — useful if an update is offered but never finalizes.
