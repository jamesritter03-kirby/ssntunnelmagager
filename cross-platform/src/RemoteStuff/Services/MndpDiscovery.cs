using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;

namespace RemoteStuff.Services;

/// <summary>A MikroTik device found on the LAN via MNDP.</summary>
public sealed class DiscoveredRouter
{
    public string MacAddress { get; init; } = "";
    public string? Identity { get; init; }
    public string? Board { get; init; }
    public string? Version { get; init; }
    public string? Platform { get; init; }
    public string? Ipv4 { get; set; }
    public string? InterfaceName { get; init; }
    public long? UptimeSeconds { get; init; }

    public string DisplayName =>
        !string.IsNullOrEmpty(Identity) ? Identity! :
        !string.IsNullOrEmpty(Ipv4) ? Ipv4! :
        !string.IsNullOrEmpty(Board) ? Board! : MacAddress;
}

/// <summary>
/// Cross-platform MikroTik Neighbor Discovery Protocol (MNDP) client. Broadcasts
/// a discovery request on UDP 5678 and collects the TLV replies routers send
/// back. MNDP is link-local, so it finds routers on directly-attached subnets.
/// Uses a plain UDP socket — no special entitlement required.
/// </summary>
public static class MndpDiscovery
{
    private const int MndpPort = 5678;

    /// <summary>Broadcast a discovery request and collect replies for
    /// <paramref name="timeoutSeconds"/> seconds. Never throws — returns whatever
    /// it finds (possibly empty).</summary>
    public static Task<List<DiscoveredRouter>> DiscoverAsync(double timeoutSeconds = 3.0) =>
        Task.Run(() => BlockingDiscovery(timeoutSeconds));

    private static List<DiscoveredRouter> BlockingDiscovery(double timeoutSeconds)
    {
        var results = new Dictionary<string, DiscoveredRouter>();
        Socket? socket = null;
        try
        {
            socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            try { socket.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true); }
            catch { /* not all platforms */ }
            socket.EnableBroadcast = true;
            socket.ReceiveTimeout = 1000;
            try { socket.Bind(new IPEndPoint(IPAddress.Any, MndpPort)); }
            catch { socket.Bind(new IPEndPoint(IPAddress.Any, 0)); }

            var request = new byte[] { 0, 0, 0, 0 };

            // Global broadcast plus every interface's directed broadcast, so we
            // reach subnets beyond the default one.
            var targets = new HashSet<string> { "255.255.255.255" };
            foreach (var b in BroadcastAddresses()) targets.Add(b);
            foreach (var t in targets)
            {
                try { socket.SendTo(request, new IPEndPoint(IPAddress.Parse(t), MndpPort)); }
                catch { /* skip an unreachable broadcast address */ }
            }

            var deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
            var buf = new byte[2048];
            EndPoint remote = new IPEndPoint(IPAddress.Any, 0);
            while (DateTime.UtcNow < deadline)
            {
                int n;
                try { n = socket.ReceiveFrom(buf, ref remote); }
                catch (SocketException) { continue; } // timeout — re-check deadline
                if (n <= 4) continue;

                var device = ParseMndp(buf, n);
                if (device is null) continue;
                if (device.Ipv4 is null && remote is IPEndPoint ep)
                    device.Ipv4 = ep.Address.ToString();
                results[device.MacAddress] = device;
            }
        }
        catch { /* return whatever we have */ }
        finally { socket?.Dispose(); }

        var list = new List<DiscoveredRouter>(results.Values);
        list.Sort((a, b) => string.Compare(a.DisplayName, b.DisplayName, StringComparison.OrdinalIgnoreCase));
        return list;
    }

    /// <summary>Directed broadcast address of every active IPv4 interface
    /// (<c>addr | ~netmask</c>), skipping loopback.</summary>
    private static IEnumerable<string> BroadcastAddresses()
    {
        var seen = new HashSet<string>();
        NetworkInterface[] nics;
        try { nics = NetworkInterface.GetAllNetworkInterfaces(); }
        catch { yield break; }

        foreach (var nic in nics)
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            IPInterfaceProperties props;
            try { props = nic.GetIPProperties(); }
            catch { continue; }

            foreach (var ua in props.UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var mask = ua.IPv4Mask;
                if (mask is null) continue;
                var ip = ua.Address.GetAddressBytes();
                var nm = mask.GetAddressBytes();
                if (ip.Length != 4 || nm.Length != 4) continue;
                var bcast = new byte[4];
                for (int i = 0; i < 4; i++) bcast[i] = (byte)(ip[i] | (~nm[i] & 0xFF));
                var str = new IPAddress(bcast).ToString();
                if (str != "0.0.0.0" && seen.Add(str)) yield return str;
            }
        }
    }

    /// <summary>Parse an MNDP reply: a 4-byte header followed by big-endian
    /// type/length/value triplets (MikroTik / MAC-Telnet convention).</summary>
    private static DiscoveredRouter? ParseMndp(byte[] data, int length)
    {
        if (length <= 4) return null;
        int U16(int o) => (data[o] << 8) | data[o + 1];

        string? mac = null, identity = null, version = null, platform = null, board = null, iface = null, ipv4 = null;
        long? uptime = null;

        int i = 4;
        while (i + 4 <= length)
        {
            int type = U16(i);
            int len = U16(i + 2);
            i += 4;
            if (len < 0 || i + len > length) break;
            switch (type)
            {
                case 1 when len == 6:
                    mac = string.Join(":", Slice(data, i, 6).Select(b => b.ToString("X2")));
                    break;
                case 5: identity = Utf8(data, i, len); break;
                case 7: version = Utf8(data, i, len); break;
                case 8: platform = Utf8(data, i, len); break;
                case 10 when len == 4:
                    uptime = (long)data[i] | ((long)data[i + 1] << 8) | ((long)data[i + 2] << 16) | ((long)data[i + 3] << 24);
                    break;
                case 12: board = Utf8(data, i, len); break;
                case 16: iface = Utf8(data, i, len); break;
                case 17 when len == 4:
                    ipv4 = $"{data[i]}.{data[i + 1]}.{data[i + 2]}.{data[i + 3]}";
                    break;
            }
            i += len;
        }

        if (mac is null) return null;
        return new DiscoveredRouter
        {
            MacAddress = mac,
            Identity = identity,
            Board = board,
            Version = version,
            Platform = platform,
            Ipv4 = ipv4,
            InterfaceName = iface,
            UptimeSeconds = uptime,
        };
    }

    private static IEnumerable<byte> Slice(byte[] data, int start, int count)
    {
        for (int i = 0; i < count; i++) yield return data[start + i];
    }

    private static string Utf8(byte[] data, int start, int len) =>
        Encoding.UTF8.GetString(data, start, len);
}
