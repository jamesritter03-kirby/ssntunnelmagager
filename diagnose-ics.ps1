# READ-ONLY diagnostic for the stuck ICS "shared connection" (ethernet_32773) phantom.
# Makes NO changes. Run normally (no elevation needed for these reads):
#   powershell -ExecutionPolicy Bypass -File "D:\S2L-Dev\vscode\ssntunnelmagager\diagnose-ics.ps1"

$ErrorActionPreference = 'SilentlyContinue'

Write-Host "==== SharedAccess service ====" -ForegroundColor Cyan
Get-Service SharedAccess | Format-Table Name,Status,StartType -AutoSize | Out-String | Write-Host

Write-Host "==== SharedAccess\Parameters ====" -ForegroundColor Cyan
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters').PSObject.Properties |
    Where-Object { $_.Name -notlike 'PS*' } | Format-Table Name,Value -AutoSize | Out-String | Write-Host

Write-Host "==== Network connections (GUID -> Name -> backing device) ====" -ForegroundColor Cyan
$netClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Network\{4D36E972-E325-11CE-BFC1-08002BE10318}'
$rows = foreach ($k in Get-ChildItem $netClass) {
    $connKey = Join-Path $k.PSPath 'Connection'
    if (-not (Test-Path $connKey)) { continue }
    $c = Get-ItemProperty $connKey
    $present = if ($c.PnpInstanceID) {
        if (Get-PnpDevice -InstanceId $c.PnpInstanceID) { (Get-PnpDevice -InstanceId $c.PnpInstanceID).Status } else { 'ABSENT' }
    } else { '(no PnpInstanceID)' }
    # Dump ALL values on the connection subkey so any ICS/sharing flag is visible.
    $extra = ($c.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' -and $_.Name -notin 'Name','PnpInstanceID' } |
              ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
    [PSCustomObject]@{
        Guid    = $k.PSChildName
        Name    = $c.Name
        Device  = $present
        Values  = $extra
    }
}
$rows | Sort-Object Device,Name | Format-Table -AutoSize -Wrap | Out-String | Write-Host

Write-Host "==== Connections whose backing device is ABSENT/missing (likely the phantom) ====" -ForegroundColor Yellow
$rows | Where-Object { $_.Device -in 'ABSENT','(no PnpInstanceID)' -or $_.Device -like 'Unknown*' -or $_.Device -eq 'Error' } |
    Format-Table Guid,Name,Device -AutoSize -Wrap | Out-String | Write-Host

Write-Host "==== Targeted search for the placeholder name (fast; SharedAccess only) ====" -ForegroundColor Cyan
reg query "HKLM\SYSTEM\CurrentControlSet\Services\SharedAccess" /f "ethernet_32773" /s 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "  (not stored as text under SharedAccess -- it's a synthesized name for a stored GUID)" }
