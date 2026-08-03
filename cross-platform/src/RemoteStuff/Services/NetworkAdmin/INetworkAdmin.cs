using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

namespace RemoteStuff.Services.NetworkAdmin;

/// <summary>A network interface that can be configured for DNS / gateway / sharing.
/// Carries every per-OS identifier the platform commands need.</summary>
public sealed class NetAdapter
{
    /// <summary>Human-readable label shown in the UI.</summary>
    public string DisplayName { get; init; } = "";
    /// <summary>macOS "network service" name (used by <c>networksetup</c>); on other
    /// platforms this equals <see cref="Device"/>.</summary>
    public string ServiceName { get; init; } = "";
    /// <summary>Interface/device name or Windows alias (en0 / eth0 / "Wi-Fi").</summary>
    public string Device { get; init; } = "";
    /// <summary>Current IPv4 address, if any (for subnet math).</summary>
    public string Ipv4 { get; init; } = "";
    /// <summary>IPv4 subnet mask, if known.</summary>
    public string Mask { get; init; } = "";

    public override string ToString() => DisplayName;
}

/// <summary>Result of a privileged network operation.</summary>
public sealed class AdminResult
{
    public bool Ok { get; init; }
    public string Message { get; init; } = "";

    public static AdminResult Success(string message = "Done") => new() { Ok = true, Message = message };
    public static AdminResult Fail(string message) => new() { Ok = false, Message = message };
}

/// <summary>
/// Cross-platform contract for privileged network configuration: editing DNS and
/// the default gateway, and turning this computer into a router that shares one
/// network's internet connection with another interface (NAT). Each platform
/// implements the details with its own tools; unsupported operations return a
/// failed <see cref="AdminResult"/>.
/// </summary>
public interface INetworkAdmin
{
    bool IsSupported { get; }
    string PlatformName { get; }
    /// <summary>How the OS will prompt for administrator rights (shown in the UI).</summary>
    string ElevationHint { get; }

    Task<IReadOnlyList<NetAdapter>> ListAdaptersAsync();
    Task<AdminResult> SetDnsAsync(NetAdapter adapter, IReadOnlyList<string> dnsServers);
    Task<AdminResult> SetGatewayAsync(NetAdapter adapter, string gateway);

    /// <summary>Share <paramref name="upstream"/>'s internet with devices on
    /// <paramref name="downstream"/> (enable forwarding + NAT). The downstream
    /// adapter is assigned <paramref name="routerIp"/>/<paramref name="prefixLength"/>.</summary>
    Task<AdminResult> StartSharingAsync(NetAdapter upstream, NetAdapter downstream,
        string routerIp = "10.1.1.1", int prefixLength = 24);
    Task<AdminResult> StopSharingAsync(NetAdapter upstream, NetAdapter downstream);
}

/// <summary>Selects the right <see cref="INetworkAdmin"/> for the current OS.</summary>
public static class NetworkAdmin
{
    public static INetworkAdmin Create()
    {
        if (OperatingSystem.IsMacOS()) return new MacNetworkAdmin();
        if (OperatingSystem.IsWindows()) return new WindowsNetworkAdmin();
        if (OperatingSystem.IsLinux()) return new LinuxNetworkAdmin();
        return new UnsupportedNetworkAdmin();
    }
}

/// <summary>Fallback for platforms we don't support.</summary>
internal sealed class UnsupportedNetworkAdmin : INetworkAdmin
{
    public bool IsSupported => false;
    public string PlatformName => "This platform";
    public string ElevationHint => "";
    public Task<IReadOnlyList<NetAdapter>> ListAdaptersAsync() =>
        Task.FromResult<IReadOnlyList<NetAdapter>>(Array.Empty<NetAdapter>());
    public Task<AdminResult> SetDnsAsync(NetAdapter a, IReadOnlyList<string> d) =>
        Task.FromResult(AdminResult.Fail("Not supported on this platform."));
    public Task<AdminResult> SetGatewayAsync(NetAdapter a, string g) =>
        Task.FromResult(AdminResult.Fail("Not supported on this platform."));
    public Task<AdminResult> StartSharingAsync(NetAdapter u, NetAdapter d, string routerIp = "10.1.1.1", int prefixLength = 24) =>
        Task.FromResult(AdminResult.Fail("Not supported on this platform."));
    public Task<AdminResult> StopSharingAsync(NetAdapter u, NetAdapter d) =>
        Task.FromResult(AdminResult.Fail("Not supported on this platform."));
}

/// <summary>Shared process / elevation / subnet helpers for the platform admins.</summary>
internal static class NetAdminUtil
{
    /// <summary>Run a program and capture stdout+stderr (non-elevated).</summary>
    public static async Task<(int Code, string Output)> RunAsync(string file, params string[] args)
    {
        var psi = new ProcessStartInfo(file)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        try
        {
            using var proc = Process.Start(psi);
            if (proc is null) return (-1, "");
            var stdout = await proc.StandardOutput.ReadToEndAsync();
            var stderr = await proc.StandardError.ReadToEndAsync();
            await proc.WaitForExitAsync();
            return (proc.ExitCode, (stdout + stderr).Trim());
        }
        catch (Exception ex)
        {
            return (-1, ex.Message);
        }
    }

    public static async Task<bool> ExistsAsync(string command)
    {
        var (code, _) = await RunAsync("/usr/bin/which", command);
        return code == 0;
    }

    /// <summary>The /24 (or mask-derived) CIDR of an adapter, e.g. 192.168.137.0/24.</summary>
    public static string? SubnetCidr(NetAdapter adapter)
    {
        if (string.IsNullOrEmpty(adapter.Ipv4) || string.IsNullOrEmpty(adapter.Mask)) return null;
        if (!IPAddress.TryParse(adapter.Ipv4, out var ip) || !IPAddress.TryParse(adapter.Mask, out var mask))
            return null;
        var ipb = ip.GetAddressBytes();
        var mb = mask.GetAddressBytes();
        if (ipb.Length != 4 || mb.Length != 4) return null;
        var net = new byte[4];
        int bits = 0;
        for (int i = 0; i < 4; i++)
        {
            net[i] = (byte)(ipb[i] & mb[i]);
            for (int b = 0; b < 8; b++) if ((mb[i] & (1 << b)) != 0) bits++;
        }
        return $"{new IPAddress(net)}/{bits}";
    }

    /// <summary>Returns the network address (host bits zeroed) for a given IP + prefix, e.g. "10.1.1.0".</summary>
    public static string? NetworkAddress(string ip, int prefixLength)
    {
        if (!IPAddress.TryParse(ip, out var addr)) return null;
        var bytes = addr.GetAddressBytes();
        if (bytes.Length != 4) return null;
        uint mask = prefixLength == 0 ? 0u : (~0u << (32 - prefixLength));
        uint ipInt = ((uint)bytes[0] << 24) | ((uint)bytes[1] << 16) | ((uint)bytes[2] << 8) | bytes[3];
        uint net = ipInt & mask;
        return $"{(net >> 24) & 0xFF}.{(net >> 16) & 0xFF}.{(net >> 8) & 0xFF}.{net & 0xFF}";
    }

    /// <summary>Converts a CIDR prefix length (e.g. 24) to a dotted subnet mask (e.g. "255.255.255.0").</summary>
    public static string PrefixToMask(int prefixLength)
    {
        uint mask = prefixLength == 0 ? 0u : (~0u << (32 - prefixLength));
        return $"{(mask >> 24) & 0xFF}.{(mask >> 16) & 0xFF}.{(mask >> 8) & 0xFF}.{mask & 0xFF}";
    }
}
