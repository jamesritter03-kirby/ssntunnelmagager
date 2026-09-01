using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Threading.Tasks;

namespace RemoteStuff.Services.NetworkAdmin;

/// <summary>
/// Windows network administration via PowerShell (<c>Set-DnsClientServerAddress</c>,
/// <c>New-NetRoute</c>, <c>New-NetNat</c>). Privileged scripts run elevated through
/// a UAC prompt; their output is captured via a temporary file.
/// </summary>
internal sealed class WindowsNetworkAdmin : INetworkAdmin
{
    private const string NatName = "RemoteStuffShare";

    public bool IsSupported => true;
    public string PlatformName => "Windows";
    public string ElevationHint => "Windows will show a User Account Control (UAC) prompt.";

    public Task<IReadOnlyList<NetAdapter>> ListAdaptersAsync()
    {
        var list = new List<NetAdapter>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces()
                         .Where(n => n.OperationalStatus == OperationalStatus.Up
                                     && n.NetworkInterfaceType != NetworkInterfaceType.Loopback))
            {
                var props = nic.GetIPProperties();
                var ua = props.UnicastAddresses
                    .FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork);
                list.Add(new NetAdapter
                {
                    DisplayName = nic.Name,
                    ServiceName = nic.Name,
                    Device = nic.Name,
                    Ipv4 = ua?.Address.ToString() ?? "",
                    Mask = ua?.IPv4Mask?.ToString() ?? ""
                });
            }
        }
        catch { /* return whatever we gathered */ }
        return Task.FromResult<IReadOnlyList<NetAdapter>>(list);
    }

    public Task<AdminResult> SetDnsAsync(NetAdapter adapter, IReadOnlyList<string> dnsServers)
    {
        var alias = Ps(adapter.Device);
        string script = dnsServers.Count == 0
            ? $"Set-DnsClientServerAddress -InterfaceAlias '{alias}' -ResetServerAddresses"
            : $"Set-DnsClientServerAddress -InterfaceAlias '{alias}' -ServerAddresses ({string.Join(",", dnsServers.Select(d => $"'{Ps(d)}'"))})";
        return RunElevatedAsync(script, "DNS servers updated.");
    }

    public Task<AdminResult> SetGatewayAsync(NetAdapter adapter, string gateway)
    {
        var alias = Ps(adapter.Device);
        var script =
            $"Remove-NetRoute -InterfaceAlias '{alias}' -DestinationPrefix '0.0.0.0/0' -Confirm:$false -ErrorAction SilentlyContinue; " +
            $"New-NetRoute -InterfaceAlias '{alias}' -DestinationPrefix '0.0.0.0/0' -NextHop '{Ps(gateway)}'";
        return RunElevatedAsync(script, "Default gateway updated.");
    }

    public Task<AdminResult> StartSharingAsync(NetAdapter upstream, NetAdapter downstream,
        string routerIp = "10.1.1.1", int prefixLength = 24)
    {
        var network = NetAdminUtil.NetworkAddress(routerIp, prefixLength);
        if (network is null)
            return Task.FromResult(AdminResult.Fail("Invalid router IP or prefix length."));
        return StartSharingCoreAsync(upstream, downstream, routerIp, prefixLength, network);
    }

    private async Task<AdminResult> StartSharingCoreAsync(NetAdapter upstream, NetAdapter downstream,
        string routerIp, int prefixLength, string network)
    {
        var up = Ps(upstream.Device);
        var down = Ps(downstream.Device);
        var internalPrefix = $"{network}/{prefixLength}";
        // Ported from PC_Shared_Network_Manager/NatSharingService — handles ICS conflicts,
        // APIPA cleanup and DAD disable that the simple version missed. Uses WinNAT when its
        // WMI class is registered, else falls back to Windows ICS (which forces 192.168.137.0/24).
        var script = $@"
$ErrorActionPreference = 'Stop'

# 1. Disable ICS only on the two adapters we're taking over (leaves WSL/Hyper-V ICS untouched).
try {{
    $m = New-Object -ComObject HNetCfg.HNetShare
    foreach ($c in $m.EnumEveryConnection) {{
        try {{
            $nm = $m.NetConnectionProps($c).Name
            if ($nm -eq '{up}' -or $nm -eq '{down}') {{
                $cf = $m.INetSharingConfigurationForINetConnection($c)
                if ($cf.SharingEnabled) {{ $cf.DisableSharing() }}
            }}
        }} catch {{}}
    }}
}} catch {{}}

# 2. Choose the sharing mechanism: WinNAT if its WMI class is registered, else ICS.
$hasNat = $true
try {{ Get-NetNat -ErrorAction Stop | Out-Null }} catch {{ if ($_.Exception.Message -match 'Invalid class') {{ $hasNat = $false }} }}

if ($hasNat) {{
    $priv = Get-NetAdapter -Name '{down}' -ErrorAction Stop
    $pub  = Get-NetAdapter -Name '{up}'  -ErrorAction Stop

    # Assign a clean static gateway IP on the private adapter.
    Get-NetIPAddress -InterfaceIndex $priv.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        ForEach-Object {{ Remove-NetIPAddress -IPAddress $_.IPAddress -InterfaceIndex $priv.ifIndex -Confirm:$false -ErrorAction SilentlyContinue }}
    Remove-NetRoute -InterfaceIndex $priv.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $priv.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue
    # Disable DAD so the gateway IP is never falsely marked Duplicate by L2-overlay reflections.
    Set-NetIPInterface -InterfaceIndex $priv.ifIndex -AddressFamily IPv4 -DadTransmits 0 -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $priv.ifIndex -AddressFamily IPv4 -IPAddress '{Ps(routerIp)}' -PrefixLength {prefixLength} -ErrorAction Stop | Out-Null
    Get-NetIPAddress -InterfaceIndex $priv.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {{ $_.IPAddress -like '169.254.*' }} |
        ForEach-Object {{ Remove-NetIPAddress -IPAddress $_.IPAddress -InterfaceIndex $priv.ifIndex -Confirm:$false -ErrorAction SilentlyContinue }}

    # Enable forwarding on both adapters.
    Set-NetIPInterface -InterfaceIndex $priv.ifIndex -Forwarding Enabled -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $pub.ifIndex  -Forwarding Enabled -ErrorAction SilentlyContinue

    # Ensure the WinNAT service is running so its MSFT_NetNat class is available.
    try {{
        Set-Service -Name WinNat -StartupType Manual -ErrorAction SilentlyContinue
        Start-Service -Name WinNat -ErrorAction SilentlyContinue
    }} catch {{}}

    Get-NetNat -Name '{NatName}' -ErrorAction SilentlyContinue | Remove-NetNat -Confirm:$false -ErrorAction SilentlyContinue
    try {{
        New-NetNat -Name '{NatName}' -InternalIPInterfaceAddressPrefix '{internalPrefix}' -ErrorAction Stop | Out-Null
        Write-Output 'NAT_OK'
    }} catch {{
        Write-Output ('NAT_ERR:' + $_.Exception.Message)
        exit 1
    }}
}} else {{
    # WinNAT's WMI class isn't registered on this Windows install: fall back to ICS.
    # ICS assigns 192.168.137.1/24 to the private adapter and runs its own DHCP + DNS.
    try {{
        Set-Service -Name SharedAccess -StartupType Manual -ErrorAction SilentlyContinue
        Start-Service -Name SharedAccess -ErrorAction SilentlyContinue
    }} catch {{}}
    $m2 = New-Object -ComObject HNetCfg.HNetShare
    $pubC = $null; $privC = $null
    foreach ($c in $m2.EnumEveryConnection) {{
        $p = $m2.NetConnectionProps($c)
        if ($p.Name -eq '{up}')   {{ $pubC = $c }}
        if ($p.Name -eq '{down}') {{ $privC = $c }}
    }}
    if (-not $pubC -or -not $privC) {{ Write-Output 'ICS_ERR:Could not find the selected adapters for ICS.'; exit 1 }}
    try {{
        # 0 = ICSSHARINGTYPE_PUBLIC (internet), 1 = ICSSHARINGTYPE_PRIVATE (LAN).
        $m2.INetSharingConfigurationForINetConnection($pubC).EnableSharing(0)
        $m2.INetSharingConfigurationForINetConnection($privC).EnableSharing(1)
        Write-Output 'ICS_OK'
    }} catch {{
        Write-Output ('ICS_ERR:' + $_.Exception.Message)
        exit 1
    }}
}}
";
        var (ok, output) = await RunElevatedRawAsync(script);

        if (output.Contains("NAT_OK", StringComparison.Ordinal))
            return new AdminResult
            {
                Ok = true,
                Mode = "winnat",
                Message = $"Router active: {routerIp}/{prefixLength} on {downstream.Device}."
            };
        if (output.Contains("ICS_OK", StringComparison.Ordinal))
            return new AdminResult
            {
                Ok = true,
                Mode = "ics",
                Message = $"Router active via Windows Internet Connection Sharing on {downstream.Device} "
                          + "(NetNat unavailable — clients get 192.168.137.x)."
            };

        // Failure: give an accurate message for the missing-WMI-class case.
        if (output.Contains("Invalid class", StringComparison.OrdinalIgnoreCase)
            || output.Contains("MSFT_NetNat", StringComparison.OrdinalIgnoreCase))
        {
            return AdminResult.Fail(
                "Windows NAT (WinNAT) isn't available on this PC — its 'MSFT_NetNat' WMI class isn't registered "
                + "in the system — and the ICS fallback also failed. Repairing the OS may restore it:  "
                + "DISM /Online /Cleanup-Image /RestoreHealth  then  sfc /scannow  (run elevated), then retry.");
        }
        return AdminResult.Fail(output.Length == 0 ? "Command failed." : output);
    }

    public Task<AdminResult> StopSharingAsync(NetAdapter upstream, NetAdapter downstream)
    {
        var up = Ps(upstream.Device);
        var down = Ps(downstream.Device);
        // Tear down whichever mechanism is active: remove the WinNAT instance (if any) and
        // disable ICS on both adapters, then drop forwarding on the downstream side.
        var script = $@"
Remove-NetNat -Name '{NatName}' -Confirm:$false -ErrorAction SilentlyContinue
try {{
    $m = New-Object -ComObject HNetCfg.HNetShare
    foreach ($c in $m.EnumEveryConnection) {{
        try {{
            $nm = $m.NetConnectionProps($c).Name
            if ($nm -eq '{up}' -or $nm -eq '{down}') {{
                $cf = $m.INetSharingConfigurationForINetConnection($c)
                if ($cf.SharingEnabled) {{ $cf.DisableSharing() }}
            }}
        }} catch {{}}
    }}
}} catch {{}}
Set-NetIPInterface -InterfaceAlias '{down}' -Forwarding Disabled -ErrorAction SilentlyContinue
Write-Output 'STOP_OK'
";
        return RunElevatedAsync(script, "Sharing stopped.", successToken: "STOP_OK");
    }

    private static async Task<AdminResult> RunElevatedAsync(string psScript, string okMessage, string? successToken = null)
    {
        var (ok, output) = await RunElevatedRawAsync(psScript);
        var success = successToken is null ? ok : output.Contains(successToken, StringComparison.Ordinal);
        return success
            ? AdminResult.Success(okMessage)
            : AdminResult.Fail(output.Length == 0 ? "Command failed." : output);
    }

    /// <summary>Run a PowerShell script elevated (UAC) and return its success flag plus the
    /// captured stdout+stderr, so callers can branch on tokens the script writes.</summary>
    private static async Task<(bool Ok, string Output)> RunElevatedRawAsync(string psScript)
    {
        string scriptPath = Path.Combine(Path.GetTempPath(), $"remotestuff-{Guid.NewGuid():N}.ps1");
        string outPath = Path.Combine(Path.GetTempPath(), $"remotestuff-{Guid.NewGuid():N}.out");
        try
        {
            await File.WriteAllTextAsync(scriptPath, "$ErrorActionPreference='Stop'\n" + psScript + "\nexit $LASTEXITCODE");
            var psi = new ProcessStartInfo("cmd.exe")
            {
                Arguments = $"/c powershell -NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\" > \"{outPath}\" 2>&1",
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
                CreateNoWindow = true
            };
            using var proc = Process.Start(psi);
            if (proc is null) return (false, "Could not start elevated process.");
            await proc.WaitForExitAsync();
            var output = File.Exists(outPath) ? (await File.ReadAllTextAsync(outPath)).Trim() : "";
            return (proc.ExitCode == 0, output);
        }
        catch (Win32Exception)
        {
            return (false, "Cancelled.");
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
        finally
        {
            try { File.Delete(scriptPath); } catch { }
            try { File.Delete(outPath); } catch { }
        }
    }

    private static string Ps(string s) => s.Replace("'", "''");
}
