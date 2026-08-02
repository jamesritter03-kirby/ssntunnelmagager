using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Threading.Tasks;

namespace RemoteStuff.Services.NetworkAdmin;

/// <summary>
/// Linux network administration via <c>nmcli</c> / <c>ip</c> / <c>iptables</c> /
/// <c>sysctl</c>. Privileged scripts run through <c>pkexec</c>, which shows the
/// desktop's polkit authentication dialog.
/// </summary>
internal sealed class LinuxNetworkAdmin : INetworkAdmin
{
    public bool IsSupported => true;
    public string PlatformName => "Linux";
    public string ElevationHint => "Linux will show a polkit password dialog (via pkexec).";

    public async Task<IReadOnlyList<NetAdapter>> ListAdaptersAsync()
    {
        var list = new List<NetAdapter>();
        var (code, output) = await NetAdminUtil.RunAsync("/usr/bin/nmcli",
            "-t", "-f", "DEVICE,TYPE,STATE", "device");
        if (code == 0 && output.Length > 0)
        {
            foreach (var line in output.Replace("\r", "").Split('\n'))
            {
                var parts = line.Split(':');
                if (parts.Length < 2) continue;
                var device = parts[0];
                var type = parts[1];
                if (device is "lo" or "" || type is "loopback") continue;
                var (ipv4, mask) = AddressOf(device);
                list.Add(new NetAdapter
                {
                    DisplayName = $"{device} ({type})",
                    ServiceName = device,
                    Device = device,
                    Ipv4 = ipv4,
                    Mask = mask
                });
            }
        }
        if (list.Count == 0)
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces()
                         .Where(n => n.NetworkInterfaceType != NetworkInterfaceType.Loopback))
            {
                var (ipv4, mask) = AddressOf(nic.Name);
                list.Add(new NetAdapter
                {
                    DisplayName = nic.Name,
                    ServiceName = nic.Name,
                    Device = nic.Name,
                    Ipv4 = ipv4,
                    Mask = mask
                });
            }
        }
        return list;
    }

    private static (string Ipv4, string Mask) AddressOf(string device)
    {
        try
        {
            var nic = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(n => n.Name == device);
            var ua = nic?.GetIPProperties().UnicastAddresses
                .FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork);
            if (ua is null) return ("", "");
            return (ua.Address.ToString(), ua.IPv4Mask?.ToString() ?? "");
        }
        catch { return ("", ""); }
    }

    public async Task<AdminResult> SetDnsAsync(NetAdapter adapter, IReadOnlyList<string> dnsServers)
    {
        var dns = string.Join(" ", dnsServers);
        var con = await ActiveConnectionFor(adapter.Device);
        string script;
        if (con is not null)
        {
            script = dnsServers.Count == 0
                ? $"nmcli con mod '{con}' ipv4.ignore-auto-dns no; nmcli con mod '{con}' ipv4.dns ''; nmcli con up '{con}'"
                : $"nmcli con mod '{con}' ipv4.ignore-auto-dns yes; nmcli con mod '{con}' ipv4.dns '{dns}'; nmcli con up '{con}'";
        }
        else
        {
            script = dnsServers.Count == 0
                ? $"resolvectl revert {adapter.Device}"
                : $"resolvectl dns {adapter.Device} {dns}";
        }
        return await RunElevatedAsync(script, "DNS servers updated.");
    }

    public Task<AdminResult> SetGatewayAsync(NetAdapter adapter, string gateway)
    {
        var dev = string.IsNullOrEmpty(adapter.Device) ? "" : $" dev {adapter.Device}";
        var script = $"ip route replace default via {gateway}{dev}";
        return RunElevatedAsync(script, "Default gateway updated.");
    }

    public Task<AdminResult> StartSharingAsync(NetAdapter upstream, NetAdapter downstream)
    {
        var up = upstream.Device;
        var down = downstream.Device;
        if (string.IsNullOrEmpty(up) || string.IsNullOrEmpty(down))
            return Task.FromResult(AdminResult.Fail("Could not determine interface names."));
        var script =
            "sysctl -w net.ipv4.ip_forward=1; " +
            $"iptables -t nat -C POSTROUTING -o {up} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o {up} -j MASQUERADE; " +
            $"iptables -C FORWARD -i {down} -o {up} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i {down} -o {up} -j ACCEPT; " +
            $"iptables -C FORWARD -i {up} -o {down} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i {up} -o {down} -m state --state RELATED,ESTABLISHED -j ACCEPT";
        return RunElevatedAsync(script, $"Sharing {up} → {down} is active.");
    }

    public Task<AdminResult> StopSharingAsync(NetAdapter upstream, NetAdapter downstream)
    {
        var up = upstream.Device;
        var down = downstream.Device;
        var script =
            $"iptables -t nat -D POSTROUTING -o {up} -j MASQUERADE 2>/dev/null; " +
            $"iptables -D FORWARD -i {down} -o {up} -j ACCEPT 2>/dev/null; " +
            $"iptables -D FORWARD -i {up} -o {down} -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; " +
            "sysctl -w net.ipv4.ip_forward=0";
        return RunElevatedAsync(script, "Sharing stopped.");
    }

    private static async Task<string?> ActiveConnectionFor(string device)
    {
        if (string.IsNullOrEmpty(device)) return null;
        var (code, output) = await NetAdminUtil.RunAsync("/usr/bin/nmcli",
            "-t", "-f", "NAME,DEVICE", "connection", "show", "--active");
        if (code != 0) return null;
        foreach (var line in output.Replace("\r", "").Split('\n'))
        {
            var idx = line.LastIndexOf(':');
            if (idx <= 0) continue;
            var name = line[..idx];
            var dev = line[(idx + 1)..];
            if (dev == device && !name.Contains('\'')) return name;
        }
        return null;
    }

    private static async Task<AdminResult> RunElevatedAsync(string shellScript, string okMessage)
    {
        if (!await NetAdminUtil.ExistsAsync("pkexec"))
            return AdminResult.Fail("pkexec not found. Install polkit or run the app as root.");
        var (code, output) = await NetAdminUtil.RunAsync("/usr/bin/pkexec", "sh", "-c", shellScript);
        if (code == 0) return AdminResult.Success(okMessage);
        if (code is 126 or 127) return AdminResult.Fail("Cancelled.");
        return AdminResult.Fail(output.Length == 0 ? "Command failed." : output);
    }
}
