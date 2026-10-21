# READ-ONLY: find ICS-related GUID keys that have NO Connection subkey (ghost adapters)
# and dump anything sharing/ICS related. Makes NO changes. Fast.
#   powershell -ExecutionPolicy Bypass -File "D:\S2L-Dev\vscode\ssntunnelmagager\diagnose-ics2.ps1"

$ErrorActionPreference = 'SilentlyContinue'
$netClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}'

Write-Host "==== GUID keys WITHOUT a Connection subkey (potential ghosts) ====" -ForegroundColor Yellow
foreach ($k in Get-ChildItem $netClass) {
    if (Test-Path (Join-Path $k.PSPath 'Connection')) { continue }
    Write-Host ("GUID {0}" -f $k.PSChildName) -ForegroundColor White
    # top-level values on the GUID key
    (Get-ItemProperty $k.PSPath).PSObject.Properties |
        Where-Object { $_.Name -notlike 'PS*' } |
        ForEach-Object { Write-Host ("   {0} = {1}" -f $_.Name, $_.Value) }
    # child subkeys + their values
    foreach ($sub in Get-ChildItem $k.PSPath) {
        Write-Host ("   [subkey] {0}" -f $sub.PSChildName)
        (Get-ItemProperty $sub.PSPath).PSObject.Properties |
            Where-Object { $_.Name -notlike 'PS*' } |
            ForEach-Object { Write-Host ("      {0} = {1}" -f $_.Name, $_.Value) }
    }
}

Write-Host "`n==== Search Control\Network subtree for sharing/ICS markers ====" -ForegroundColor Cyan
reg query ($netClass -replace 'HKLM:','HKLM') /s 2>$null |
    Select-String -Pattern 'ethernet_3|Shared|Ics|IsIcs|Grant|Public|Private|Home|Nat' -SimpleMatch

Write-Host "`n==== HNetCfg store under SOFTWARE (common ICS persistence spots) ====" -ForegroundColor Cyan
foreach ($p in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Network\SharedAccessConnection',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Network\HomeNet',
    'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\AutoDialParameters'
)) {
    if (Test-Path $p) { Write-Host "FOUND: $p"; Get-ItemProperty $p | Format-List } else { Write-Host "absent: $p" }
}
