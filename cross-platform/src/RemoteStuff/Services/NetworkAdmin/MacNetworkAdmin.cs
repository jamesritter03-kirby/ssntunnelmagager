using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace RemoteStuff.Services.NetworkAdmin;

/// <summary>
/// macOS network administration via <c>networksetup</c>, <c>route</c>,
/// <c>sysctl</c> and <c>pfctl</c>. Privileged commands are run through
/// <c>osascript … with administrator privileges</c>, which shows the standard
/// macOS password dialog.
/// </summary>
internal sealed partial class MacNetworkAdmin : INetworkAdmin
{
    private const string NatConf = "/tmp/remotestuff-nat.conf";

    public bool IsSupported => true;
    public string PlatformName => "macOS";
    public string ElevationHint => "macOS will ask for your administrator password.";

    public async Task<IReadOnlyList<NetAdapter>> ListAdaptersAsync()
    {
        var (_, order) = await NetAdminUtil.RunAsync("/usr/sbin/networksetup", "-listnetworkserviceorder");
        var list = new List<NetAdapter>();
        // Blocks look like: "(1) Wi-Fi" then "(Hardware Port: Wi-Fi, Device: en0)".
        var lines = order.Replace("\r", "").Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            var svc = ServiceLine().Match(lines[i]);
            if (!svc.Success) continue;
            if (svc.Groups[1].Value == "*") continue; // disabled service
            var service = svc.Groups[2].Value.Trim();
            var device = "";
            if (i + 1 < lines.Length)
            {
                var dev = DeviceLine().Match(lines[i + 1]);
                if (dev.Success) device = dev.Groups[1].Value.Trim();
            }
            if (service.Contains('\'')) continue; // avoid shell-quoting hazards
            var (ipv4, mask) = AddressOf(device);
            list.Add(new NetAdapter
            {
                DisplayName = string.IsNullOrEmpty(device) ? service : $"{service} ({device})",
                ServiceName = service,
                Device = device,
                Ipv4 = ipv4,
                Mask = mask
            });
        }
        return list;
    }

    private static (string Ipv4, string Mask) AddressOf(string device)
    {
        if (string.IsNullOrEmpty(device)) return ("", "");
        try
        {
            var nic = NetworkInterface.GetAllNetworkInterfaces()
                .FirstOrDefault(n => n.Name == device);
            var ua = nic?.GetIPProperties().UnicastAddresses
                .FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork);
            if (ua is null) return ("", "");
            return (ua.Address.ToString(), ua.IPv4Mask?.ToString() ?? "");
        }
        catch { return ("", ""); }
    }

    public Task<AdminResult> SetDnsAsync(NetAdapter adapter, IReadOnlyList<string> dnsServers)
    {
        var servers = dnsServers.Count == 0 ? "Empty" : string.Join(" ", dnsServers);
        var cmd = $"networksetup -setdnsservers '{adapter.ServiceName}' {servers}";
        return RunElevatedAsync(cmd, "DNS servers updated.");
    }

    public Task<AdminResult> SetGatewayAsync(NetAdapter adapter, string gateway)
    {
        var cmd = $"route -n change default {gateway} || route -n add default {gateway}";
        return RunElevatedAsync(cmd, "Default gateway updated.");
    }

    public Task<AdminResult> StartSharingAsync(NetAdapter upstream, NetAdapter downstream,
        string routerIp = "10.1.1.1", int prefixLength = 24)
    {
        if (string.IsNullOrEmpty(upstream.Device) || string.IsNullOrEmpty(downstream.Device))
            return Task.FromResult(AdminResult.Fail("Could not determine interface names."));
        var mask = NetAdminUtil.PrefixToMask(prefixLength);
        var up = upstream.Device;
        var down = downstream.Device;
        var cmd =
            $"networksetup -setmanual '{upstream.ServiceName}' dummy dummy dummy 2>/dev/null; " +
            $"ifconfig {down} {routerIp} netmask {mask} && " +
            "sysctl -w net.inet.ip.forwarding=1 && " +
            $"printf 'nat on {up} from ({down}:network) to any -> ({up})\\npass all\\n' > {NatConf} && " +
            $"pfctl -f {NatConf} -e";
        return RunElevatedAsync(cmd, $"Router active: {routerIp}/{prefixLength} on {down}.");
    }

    public Task<AdminResult> StopSharingAsync(NetAdapter upstream, NetAdapter downstream)
    {
        var cmd =
            "pfctl -d; " +
            $"rm -f {NatConf}; " +
            "sysctl -w net.inet.ip.forwarding=0";
        return RunElevatedAsync(cmd, "Sharing stopped.", bestEffort: true);
    }

    private static async Task<AdminResult> RunElevatedAsync(string shellScript, string okMessage, bool bestEffort = false)
    {
        var apple = "do shell script \"" + EscapeAppleScript(shellScript) + "\" with administrator privileges";
        var (code, output) = await NetAdminUtil.RunAsync("/usr/bin/osascript", "-e", apple);
        if (code == 0 || bestEffort && !output.Contains("-128"))
            return AdminResult.Success(okMessage);
        if (output.Contains("-128")) return AdminResult.Fail("Cancelled.");
        return AdminResult.Fail(output.Length == 0 ? "Command failed." : output);
    }

    private static string EscapeAppleScript(string s) =>
        s.Replace("\\", "\\\\").Replace("\"", "\\\"");

    [GeneratedRegex(@"^\((\*|\d+)\)\s+(.*)$")]
    private static partial Regex ServiceLine();

    [GeneratedRegex(@"Device:\s*([^\),]+)")]
    private static partial Regex DeviceLine();
}
