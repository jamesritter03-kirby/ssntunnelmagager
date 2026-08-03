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
        var up = Ps(upstream.Device);
        var down = Ps(downstream.Device);
        var internalPrefix = $"{network}/{prefixLength}";
        // Ported from PC_Shared_Network_Manager/NatSharingService — handles ICS conflicts,
        // APIPA cleanup and DAD disable that the simple version missed.
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

$priv = Get-NetAdapter -Name '{down}' -ErrorAction Stop
$pub  = Get-NetAdapter -Name '{up}'  -ErrorAction Stop

# 2. Assign a clean static gateway IP on the private adapter.
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

# 3. Enable forwarding on both adapters.
Set-NetIPInterface -InterfaceIndex $priv.ifIndex -Forwarding Enabled -ErrorAction SilentlyContinue
Set-NetIPInterface -InterfaceIndex $pub.ifIndex  -Forwarding Enabled -ErrorAction SilentlyContinue

# 4. (Re)create the WinNAT instance.
Get-NetNat -Name '{NatName}' -ErrorAction SilentlyContinue | Remove-NetNat -Confirm:$false -ErrorAction SilentlyContinue
New-NetNat -Name '{NatName}' -InternalIPInterfaceAddressPrefix '{internalPrefix}' -ErrorAction Stop | Out-Null

Write-Output 'NAT_OK'
";
        return RunElevatedAsync(script, $"Router active: {routerIp}/{prefixLength} on {downstream.Device}.",
            successToken: "NAT_OK");
    }

    public Task<AdminResult> StopSharingAsync(NetAdapter upstream, NetAdapter downstream)
    {
        var down = Ps(downstream.Device);
        var script =
            $"Remove-NetNat -Name '{NatName}' -Confirm:$false -ErrorAction SilentlyContinue; " +
            $"Set-NetIPInterface -InterfaceAlias '{down}' -Forwarding Disabled -ErrorAction SilentlyContinue";
        return RunElevatedAsync(script, "Sharing stopped.");
    }

    private static async Task<AdminResult> RunElevatedAsync(string psScript, string okMessage, string? successToken = null)
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
            if (proc is null) return AdminResult.Fail("Could not start elevated process.");
            await proc.WaitForExitAsync();
            var output = File.Exists(outPath) ? (await File.ReadAllTextAsync(outPath)).Trim() : "";
            // A success token (e.g. "NAT_OK") is more reliable than the exit code, which some
            // cmdlets leave non-zero even after the operation succeeded.
            var ok = successToken is null ? proc.ExitCode == 0 : output.Contains(successToken, StringComparison.Ordinal);
            return ok
                ? AdminResult.Success(okMessage)
                : AdminResult.Fail(output.Length == 0 ? "Command failed." : output);
        }
        catch (Win32Exception)
        {
            return AdminResult.Fail("Cancelled.");
        }
        catch (Exception ex)
        {
            return AdminResult.Fail(ex.Message);
        }
        finally
        {
            try { File.Delete(scriptPath); } catch { }
            try { File.Delete(outPath); } catch { }
        }
    }

    private static string Ps(string s) => s.Replace("'", "''");
}
