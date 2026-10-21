# Set the Windows ICS (Internet Connection Sharing) LAN scope address to a value you choose.
# Classic ICS uses a /24; the address you pick becomes the gateway handed to shared clients.
#
# RUN AS ADMINISTRATOR:
#   powershell -ExecutionPolicy Bypass -File "D:\S2L-Dev\vscode\ssntunnelmagager\set-ics-scope.ps1" -Scope 10.1.1.1
param(
    [string]$Scope = '10.1.1.1'
)

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Run this from an ELEVATED PowerShell (Run as administrator). Aborting."
    return
}
if (-not ([System.Net.IPAddress]::TryParse($Scope, [ref]([System.Net.IPAddress]::None)))) {
    Write-Warning "'$Scope' is not a valid IPv4 address. Aborting."
    return
}

$p = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters'

Write-Host "== Setting ICS ScopeAddress to $Scope (/24) ==" -ForegroundColor Cyan
New-Item -Path $p -Force | Out-Null
Set-ItemProperty -Path $p -Name 'ScopeAddress'       -Value $Scope -Type String
Set-ItemProperty -Path $p -Name 'ScopeAddressBackup' -Value $Scope -Type String

Write-Host "== Restarting the ICS service so it re-applies the scope ==" -ForegroundColor Cyan
Set-Service SharedAccess -StartupType Manual -ErrorAction SilentlyContinue
Restart-Service SharedAccess -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Write-Host "`n== Result ==" -ForegroundColor Green
"ScopeAddress       = " + (Get-ItemProperty $p).ScopeAddress
"ScopeAddressBackup = " + (Get-ItemProperty $p).ScopeAddressBackup
$hit = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $Scope }
if ($hit) {
    Write-Host "A shared adapter now holds $Scope :" -ForegroundColor Green
    $hit | Format-Table InterfaceAlias,IPAddress,PrefixLength,PrefixOrigin -AutoSize
} else {
    Write-Warning "No adapter shows $Scope yet. ICS only re-applies the scope while sharing is ON."
    Write-Warning "Toggle Internet Sharing OFF then ON (Sharing tab or your app), then re-run the check:"
    Write-Host   "  Get-NetIPAddress -AddressFamily IPv4 | ? IPAddress -eq '$Scope' | ft InterfaceAlias,IPAddress,PrefixOrigin" -ForegroundColor DarkGray
}
