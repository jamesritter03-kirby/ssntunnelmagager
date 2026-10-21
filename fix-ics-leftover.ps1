# Fully turn OFF Internet Connection Sharing (ICS) left behind by the app / a phantom binding,
# and restore normal internet on the Ethernet adapter.
#
# RUN AS ADMINISTRATOR. From an elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File "D:\S2L-Dev\vscode\ssntunnelmagager\fix-ics-leftover.ps1"
#
# What it does (deterministic order):
#   1. Stops AND disables the SharedAccess (ICS) service so it can't re-home 192.168.137.1.
#   2. Best-effort: disables ICS on every enumerable connection via HNetShare.
#   3. Removes the leftover 192.168.137.1 and returns Ethernet to DHCP.
#   4. Clears the stale ScopeAddress the ICS config remembers.

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script must be run from an ELEVATED PowerShell (Run as administrator). Aborting."
    return
}

$EthernetAlias = 'Ethernet'   # the adapter stuck at 192.168.137.1 (Intel I219-LM)

Write-Host "== 1. Stopping and disabling the ICS (SharedAccess) service ==" -ForegroundColor Cyan
Stop-Service SharedAccess -Force -ErrorAction SilentlyContinue
Set-Service  SharedAccess -StartupType Disabled -ErrorAction SilentlyContinue
# Give the service a moment to release the private-side address it manages.
try { (Get-Service SharedAccess).WaitForStatus('Stopped','00:00:05') } catch {}

Write-Host "== 2. Disabling ICS on every connection (best-effort) ==" -ForegroundColor Cyan
try {
    $m = New-Object -ComObject HNetCfg.HNetShare
    foreach ($c in @($m.EnumEveryConnection)) {
        foreach ($call in 'direct','invoke') {
            try {
                $cfg = if ($call -eq 'direct') { $m.INetSharingConfigurationForINetConnection($c) }
                       else                    { $m.INetSharingConfigurationForINetConnection.Invoke($c) }
                if ($cfg.SharingEnabled) {
                    $cfg.DisableSharing()
                    Write-Host "  Disabled sharing on a connection."
                }
                break
            } catch { }
        }
    }
} catch { Write-Warning "HNetShare pass skipped: $($_.Exception.Message)" }

Write-Host "== 3. Removing leftover ICS/router IPs and returning $EthernetAlias to DHCP ==" -ForegroundColor Cyan
Remove-NetIPAddress   -InterfaceAlias $EthernetAlias -IPAddress 192.168.137.1 -Confirm:$false -ErrorAction SilentlyContinue
Remove-NetIPAddress   -InterfaceAlias $EthernetAlias -IPAddress 10.1.1.1 -Confirm:$false -ErrorAction SilentlyContinue
Set-NetIPInterface    -InterfaceAlias $EthernetAlias -Dhcp Enabled -ErrorAction SilentlyContinue
Set-DnsClientServerAddress -InterfaceAlias $EthernetAlias -ResetServerAddresses -ErrorAction SilentlyContinue
Set-NetIPInterface    -InterfaceAlias $EthernetAlias -Forwarding Disabled -ErrorAction SilentlyContinue
# Clear any WinNAT instance the app may have created too.
Get-NetNat -Name 'RemoteStuffShare' -ErrorAction SilentlyContinue | Remove-NetNat -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "== 4. Clearing the stale ICS ScopeAddress ==" -ForegroundColor Cyan
$p = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters'
Remove-ItemProperty -Path $p -Name 'ScopeAddress'       -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $p -Name 'ScopeAddressBackup' -ErrorAction SilentlyContinue

ipconfig /renew | Out-Null

Write-Host "`n== Result ==" -ForegroundColor Green
Get-Service SharedAccess | Format-Table Name,Status,StartType -AutoSize
$leftover = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like '192.168.137.*' }
if ($leftover) {
    Write-Warning "192.168.137.x is STILL present:"
    $leftover | Format-Table InterfaceAlias,IPAddress,PrefixOrigin -AutoSize
    Write-Warning "Reboot once to let the disabled service fully release it, then re-check."
} else {
    Write-Host "No 192.168.137.x address remains." -ForegroundColor Green
}
Get-NetIPAddress -InterfaceAlias $EthernetAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Format-Table InterfaceAlias,IPAddress,PrefixLength,PrefixOrigin -AutoSize

Write-Host "`nICS is now disabled. To re-enable Windows sharing / Mobile Hotspot later, run:" -ForegroundColor DarkGray
Write-Host "  Set-Service SharedAccess -StartupType Manual" -ForegroundColor DarkGray
