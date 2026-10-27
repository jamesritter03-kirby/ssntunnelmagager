# S2 Labs auth integration — implementation plan (RemoteStuff / SSH Tunnel Manager)

> Left for the next session by the S2 Labs edge-device work (2026-10-27). This
> project needs to support logging into S2 Labs edge devices with the **new**
> credential mechanisms. Read this, confirm scope with the user, then implement.
> **No secrets are stored in this file.** Client secrets live only in Key Vault /
> the operator's Azure session.

## ✅ Implementation status (2026-10-27)

All phases are now implemented in **both** apps under a generic **"Key Vault"**
label (not S2 Labs–branded), with vault coordinates configurable per environment.

**Configure once:** open **Preferences → Key Vault** and set the Vault URI +
subscription (defaults point at the dev vault). Secret names / cert validity /
principals / secret prefixes are all editable there too.

**Per device:** in the profile editor a **Key Vault** section appears (only when a
vault URI is set). Optional **Device unit** overrides the hostname used for secret
lookups (blank = the host's first DNS label). Buttons:
- **Get / refresh certificate** (Phase A) — signs `<identityFile>.pub` with the CA
  fetched from the vault via `ssh-keygen -s`, writing `<identityFile>-cert.pub`
  beside the key so OpenSSH presents it automatically. *Dev shortcut; swap for a
  signing service before prod.*
- **Reveal break-glass password** (Phase B) — reads `os-snsadmin-<unit>` into the
  Password field (save to keep it).
- **Fill service passwords** (Phase B) — reads `app-stack-<unit>` into every
  MQTT/Redis forward's service-password field.
- **Provision device…** (Phase C) — pushes an operator-chosen `escrow.env` to
  `/etc/s2labs/escrow.env` and optionally triggers `sudo s2labs-upgrade`.

**Auth:** C# uses `Azure.Identity` (Azure CLI → interactive browser fallback);
Swift shells out to the `az` CLI (`az login` first). Access-policy vaults need the
operator's object-id to have a get/list secret policy.

**Minimal (0-code) path still works:** put a CA-signed cert next to your key
(`<key>-cert.pub`) and connect as usual — OpenSSH presents it automatically.

**Verify before prod:** SSH.NET may not support OpenSSH certs, so cert-only SFTP
could fail — terminals/tunnels via `ssh`/`ssh.exe` are fine. Keep a key/password
path for SFTP.

Code map: C# `Services/KeyVaultService.cs`, `AppSettings` `KeyVault*` props,
`SshProfile.KeyVaultUnit`, `ProfileEditorViewModel`/`Window`, `SettingsViewModel`/
`Window`. Swift `Models/KeyVaultService.swift`, `App/AppSettings.swift`,
`SSHProfile.keyVaultUnit`, `Views/ProfileEditorView.swift`, `Views/SettingsView.swift`.

## Background — what changed on the devices

S2 Labs edge devices (Seeed R2200 `.deb`, Advantech EPC-R3720 `.ipk`, RevPi, x86)
moved OFF a single shared OS password (`snsadmin` / `!qazwsxE`) to per-device,
escrowed credentials. Device-side code lives in
`d:\S2L-Dev\vscode\s2labs-edge-device-deploy` (platform packages 1.9.166+).

New mechanisms now live on devices:
- **SSH user-CA trust.** Devices trust short-lived certificates signed by a fleet
  CA (`TrustedUserCAKeys /etc/ssh/s2l-user-ca.pub`). Proven working on the EPC.
- **Per-device OS password**, randomized at provision/upgrade and escrowed to
  Azure Key Vault as secret `os-snsadmin-<hostname>` (break-glass only).
- **Per-device app-stack password** (MQTT/Redis/Node-RED) escrowed as
  `app-stack-<hostname>`; on-device file `/etc/s2labs/app-stack-password`.
- Optional **key-only lockdown** (`/etc/s2labs/ssh-key-only`) with a probation
  watchdog that auto-re-enables password auth if cert login isn't confirmed.

## Azure facts (non-secret)

- **Dev** Key Vault: `s2l-dev-escrow-kv`
  (`https://s2l-dev-escrow-kv.vault.azure.net/`), **access-policy** auth mode,
  dev subscription `kc-kds-s2labs-dev-001`. Prod will be a different subscription
  + vault later — keep vault URI / subscription **configurable per environment**.
- SSH user CA public fingerprint: `ED25519 SHA256:lR1rEeNOK/N0Vtejcr9iMIfRtGNCO2VPahYsWLOpRDA`.
  CA stored in KV as secrets `ssh-user-ca-private` / `ssh-user-ca-public`.
- Secret naming: `os-snsadmin-<unit>`, `app-stack-<unit>`, `<unit>` = device hostname.
- The device-side escrow service principal is **set-only** (cannot read secrets).
  Operators need their OWN Key Vault access (get/list secrets) added to the vault
  access policy — do NOT reuse the device SP.

## How this app authenticates today

Both the Swift app (`Sources/SSHTunnelManager`) and the cross-platform C# app
(`cross-platform/src/RemoteStuff`) shell out to the OpenSSH `ssh` binary via
`SshCommandBuilder` with `-i <identityFile> -o IdentitiesOnly=yes`. SFTP uses the
SSH.NET library; terminals/tunnels use `ssh.exe`.

### Key consequence
**Certificate login already works with no code change** — OpenSSH automatically
presents `<identityFile>-cert.pub` if it sits next to the key. So the minimal
path is: operator has a CA-signed cert beside their key, connect as normal.

### Gotcha to verify before any key-only lockdown
SSH.NET historically does **not** support OpenSSH certificates. Terminal/tunnels
(via `ssh.exe`) are fine; **SFTP via SSH.NET may fail cert-only**. Confirm the
SSH.NET version's cert support, or keep a plain key / password path for SFTP.

## Recommended scope (confirm with user which to build)

- **Minimal (0 code):** document "put your CA-signed cert next to your key" and
  connect as usual. Works today.
- **Phase A — "Get / refresh SSH certificate":** a button that refreshes the
  operator's short-lived cert. Prod design = call a **signing service** (repo VM
  w/ managed identity) that signs the operator's pubkey after Azure login; the CA
  key never leaves the server. Dev shortcut = fetch `ssh-user-ca-private` from Key
  Vault (operator Azure auth) and sign locally with `ssh-keygen -s`.
- **Phase B — Key Vault reads:** "Reveal break-glass password" (`os-snsadmin-<unit>`)
  and auto-fill MQTT/Redis forward passwords (`app-stack-<unit>`). Use MSAL for
  Azure auth; the app already has `mqtt`/`redis` ForwardCategory hooks. Vault is
  access-policy mode, so the operator's object-id needs a get/list secret policy.
- **Phase C — "Provision / Upgrade device":** one-click push of
  `/etc/s2labs/escrow.env` + trigger the package upgrade, automating device
  onboarding from the app.

## Suggested implementation notes

- Add an environment/profile setting for **Key Vault URI + subscription** so dev
  vs prod is a config switch, never hardcoded.
- Prefer the signing-service model for cert issuance before shipping to prod;
  the KV-fetch-CA-and-sign-locally path is dev-only.
- Derive `<unit>` from the profile host/known hostname; let the user override.
- Cross-platform: implement shared logic in a service (mirror the existing
  `Services/` pattern in the C# app and `Models/` in Swift), keep UI thin.

## Device-side cross-reference

For the device scripts, escrow library, CA handling, and build/publish workflow,
see `d:\S2L-Dev\vscode\s2labs-edge-device-deploy` (CHANGELOG 1.9.166–1.9.168 and
`shared/files/base/s2labs-escrow.sh`, `s2labs-harden-credentials.sh`,
`app-stack-credentials.sh`).
