# Purge ALL Internet Connection Sharing (ICS) pairings via the supported HNetShare COM API,
# then leave the service ready so you can re-enable sharing cleanly.
#
# RUN AS ADMINISTRATOR:
#   powershell -ExecutionPolicy Bypass -File "D:\S2L-Dev\vscode\ssntunnelmagager\reset-ics.ps1"

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Run this from an ELEVATED PowerShell (Run as administrator). Aborting."
    return
}

# ICS needs its service running to enumerate/modify sharing config.
Set-Service SharedAccess -StartupType Manual -ErrorAction SilentlyContinue
Start-Service SharedAccess -ErrorAction SilentlyContinue

$share = New-Object -ComObject HNetCfg.HNetShare
Write-Host ("SharingInstalled: {0}" -f $share.SharingInstalled) -ForegroundColor Cyan

function Get-Conns($s) {
    $list = @()
    try { foreach ($c in $s.EnumEveryConnection) { $list += $c } } catch {}
    return $list
}

$conns = Get-Conns $share
Write-Host ("Enumerated connections: {0}" -f $conns.Count) -ForegroundColor Cyan

Write-Host "`n==== BEFORE: sharing state per connection ====" -ForegroundColor Yellow
$enabled = @()
foreach ($c in $conns) {
    $name = try { $share.NetConnectionProps($c).Name } catch { '(name?)' }
    $guid = try { $share.NetConnectionProps($c).Guid } catch { '' }
    $cfg  = try { $share.INetSharingConfigurationForINetConnection($c) } catch { $null }
    if ($cfg) {
        $on = $cfg.SharingEnabled
        $ty = if ($on) { $cfg.SharingConnectionType } else { '-' }
        "{0,-42} enabled={1,-5} type={2}  {3}" -f $name, $on, $ty, $guid
        if ($on) { $enabled += [pscustomobject]@{ Name=$name; Cfg=$cfg } }
    } else {
        "{0,-42} (no sharing config)" -f $name
    }
}

Write-Host "`n==== Disabling sharing on every enabled connection ====" -ForegroundColor Yellow
if ($enabled.Count -eq 0) {
    Write-Host "  Nothing reported enabled via COM."
} else {
    foreach ($e in $enabled) {
        try { $e.Cfg.DisableSharing(); Write-Host ("  Disabled: {0}" -f $e.Name) -ForegroundColor Green }
        catch { Write-Warning ("  Failed to disable {0}: {1}" -f $e.Name, $_.Exception.Message) }
    }
}

# Clear the leftover scope address the config remembers.
$p = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters'
Remove-ItemProperty -Path $p -Name 'ScopeAddress'       -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $p -Name 'ScopeAddressBackup' -ErrorAction SilentlyContinue

Start-Sleep -Seconds 1
Write-Host "`n==== AFTER: sharing state per connection ====" -ForegroundColor Yellow
$share2 = New-Object -ComObject HNetCfg.HNetShare
foreach ($c in (Get-Conns $share2)) {
    $name = try { $share2.NetConnectionProps($c).Name } catch { '(name?)' }
    $cfg  = try { $share2.INetSharingConfigurationForINetConnection($c) } catch { $null }
    if ($cfg) { "{0,-42} enabled={1}" -f $name, $cfg.SharingEnabled }
}

Write-Host "`nDone. If every line above shows enabled=False, the phantom is gone." -ForegroundColor Green
Write-Host "You can now enable sharing fresh (app: Start sharing, or the Windows Sharing tab)." -ForegroundColor Green
