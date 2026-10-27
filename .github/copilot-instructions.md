# Copilot instructions — RemoteStuff / SSH Tunnel Manager

## Project
Cross-platform SSH tunnel/terminal manager. Two front-ends share one design:
- Swift/macOS: `Sources/SSHTunnelManager` (Models / Views / Util / Terminal).
- C# Avalonia (Windows "RemoteStuff"): `cross-platform/src/RemoteStuff`
  (Models / Services / ViewModels / Views). `Services/SshCommandBuilder.cs` is a
  faithful port of `Models/SSHCommandBuilder.swift`.
Both shell out to the OpenSSH `ssh` binary (`-i <key> -o IdentitiesOnly=yes`);
SFTP uses SSH.NET. Keep shared logic in services/models, UI thin, and mirror any
change across BOTH front-ends.

## Active task — S2 Labs new-auth integration
**Read `S2LABS-AUTH-INTEGRATION.md` at the repo root first** — it is the current
plan for making this app log into S2 Labs edge devices with the new mechanisms
(SSH user-CA certificates + Azure Key Vault escrow). Then confirm scope with the
user before implementing.

Key points:
- **Cert login already works with zero code change** — OpenSSH auto-presents
  `<identityFile>-cert.pub` next to the key. Minimal path = cert beside key.
- Optional Key Vault integration (dev vault `s2l-dev-escrow-kv`, access-policy
  mode, subscription `kc-kds-s2labs-dev-001`) for: (A) refreshing short-lived
  certs, (B) revealing break-glass passwords (`os-snsadmin-<unit>`) + auto-filling
  MQTT/Redis passwords (`app-stack-<unit>`), (C) one-click device provision/upgrade.
- Make Key Vault URI + subscription **configurable per environment** (prod is a
  different subscription/vault — never hardcode dev values).
- **Verify before shipping:** SSH.NET may not support OpenSSH certificates, so
  cert-only SFTP could fail — terminals/tunnels via `ssh.exe` are fine.
- **Never commit secrets.** Client secrets live in Key Vault / the operator's
  Azure session only. The device-side escrow principal is set-only (can't read).

## Related repo
Device-side scripts, CA handling, and build/publish live in
`d:\S2L-Dev\vscode\s2labs-edge-device-deploy` (CHANGELOG 1.9.166–1.9.168).
