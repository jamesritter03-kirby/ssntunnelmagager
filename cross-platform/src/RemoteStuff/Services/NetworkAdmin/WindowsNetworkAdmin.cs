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
        var cidr = $"{routerIp}/{prefixLength}";
        var network = NetAdminUtil.NetworkAddress(routerIp, prefixLength);
        if (network is null)
            return Task.FromResult(AdminResult.Fail("Invalid router IP or prefix length."));
        var up = Ps(upstream.Device);
        var down = Ps(downstream.Device);
        var script =
            // Remove any existing IPv4 address on the downstream adapter, then assign the router IP.
            $"Get-NetIPAddress -InterfaceAlias '{down}' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue; " +
            $"New-NetIPAddress -InterfaceAlias '{down}' -IPAddress '{Ps(routerIp)}' -PrefixLength {prefixLength} -ErrorAction SilentlyContinue; " +
            $"Set-NetIPInterface -InterfaceAlias '{up}' -Forwarding Enabled; " +
            $"Set-NetIPInterface -InterfaceAlias '{down}' -Forwarding Enabled; " +
            $"if (Get-NetNat -Name '{NatName}' -ErrorAction SilentlyContinue) {{ Remove-NetNat -Name '{NatName}' -Confirm:$false }}; " +
            $"New-NetNat -Name '{NatName}' -InternalIPInterfaceAddressPrefix '{network}/{prefixLength}'";
        return RunElevatedAsync(script, $"Router active: {routerIp}/{prefixLength} on {downstream.Device}.");
    }

    public Task<AdminResult> StopSharingAsync(NetAdapter upstream, NetAdapter downstream)
    {
        var down = Ps(downstream.Device);
        var script =
            $"Remove-NetNat -Name '{NatName}' -Confirm:$false -ErrorAction SilentlyContinue; " +
            $"Set-NetIPInterface -InterfaceAlias '{down}' -Forwarding Disabled -ErrorAction SilentlyContinue";
        return RunElevatedAsync(script, "Sharing stopped.");
    }

    private static async Task<AdminResult> RunElevatedAsync(string psScript, string okMessage)
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
            return proc.ExitCode == 0
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
