using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Services.NetworkAdmin;

namespace RemoteStuff.ViewModels;

/// <summary>
/// A cross-platform network browser: lists this machine's interfaces, gateway,
/// DNS servers, hostname and public IP, and offers a LAN ping-sweep scanner. On
/// macOS it additionally shows live Wi-Fi details (SSID, signal/RSSI, channel,
/// transmit rate), read from <c>system_profiler</c> — no privileges required.
/// A "Router &amp; DNS" panel adds privileged operations: editing an adapter's DNS
/// servers and default gateway, and turning this computer into a router that
/// shares one network's internet connection with another interface (NAT). Those
/// operations are implemented per-OS via <see cref="INetworkAdmin"/> and only run
/// on an explicit button click, prompting for administrator rights each time.
/// </summary>
public sealed partial class NetworkTabViewModel : TabViewModel
{
    public override string Glyph => "network";

    public override RemoteStuff.Services.TabSnapshot? CreateSnapshot() =>
        new RemoteStuff.Services.TabSnapshot { Kind = "network", Title = Title };

    public sealed class InterfaceRow
    {
        public string Name { get; init; } = "";
        public string TypeLabel { get; init; } = "";
        public bool IsUp { get; init; }
        public string Ipv4 { get; init; } = "";
        public string Ipv6 { get; init; } = "";
        public string Mac { get; init; } = "";
        public string StatusGlyph => IsUp ? "🟢" : "⚪";
        public string Subtitle =>
            (string.IsNullOrEmpty(Ipv4) ? Ipv6 : Ipv4) is { Length: > 0 } addr
                ? $"{TypeLabel} · {addr}"
                : TypeLabel;
    }

    public sealed partial class ScanHit : ObservableObject
    {
        public string Ip { get; init; } = "";
        public long LatencyMs { get; init; }

        [NotifyPropertyChangedFor(nameof(Display))]
        [ObservableProperty] private string _hostName = "";

        public string Display => string.IsNullOrEmpty(HostName) ? Ip : $"{Ip}  ({HostName})";
    }

    public ObservableCollection<InterfaceRow> Interfaces { get; } = new();
    public ObservableCollection<ScanHit> ScanResults { get; } = new();

    [ObservableProperty] private string _hostName = Dns.GetHostName();
    [ObservableProperty] private string _defaultGateway = "—";
    [ObservableProperty] private string _dnsServers = "—";
    [ObservableProperty] private string _publicIp = "—";
    [ObservableProperty] private bool _isRefreshing;

    // ---- Wi-Fi (macOS only) ----
    [ObservableProperty] private bool _hasWifi;
    [ObservableProperty] private string _wifiSsid = "";
    [ObservableProperty] private string _wifiSignal = "";
    [ObservableProperty] private string _wifiChannel = "";
    [ObservableProperty] private string _wifiTxRate = "";

    [ObservableProperty] private string _scanSubnet = "";
    [ObservableProperty] private bool _isScanning;
    [ObservableProperty] private string _scanStatus = "";
    [ObservableProperty] private double _scanProgress;

    public string ScanButtonText => IsScanning ? "Stop" : "Scan";

    partial void OnIsScanningChanged(bool value) => OnPropertyChanged(nameof(ScanButtonText));

    private CancellationTokenSource? _scanCts;

    public NetworkTabViewModel()
    {
        Title = "Network";
        _admin = NetworkAdmin.Create();
        AdminSupported = _admin.IsSupported;
        AdminPlatform = _admin.PlatformName;
        AdminHint = _admin.ElevationHint;
        _ = RefreshAsync();
    }

    // ===== Router & DNS (privileged, per-OS via INetworkAdmin) =====

    private readonly INetworkAdmin _admin;
    private Services.DhcpServer? _dhcp;

    /// <summary>Adapters available for DNS/gateway/sharing configuration.</summary>
    public ObservableCollection<NetAdapter> Adapters { get; } = new();

    [ObservableProperty] private bool _adminSupported;
    [ObservableProperty] private string _adminPlatform = "";
    [ObservableProperty] private string _adminHint = "";
    [ObservableProperty] private bool _isAdminBusy;
    [ObservableProperty] private string _adminStatus = "";

    // DNS / gateway editor
    [NotifyPropertyChangedFor(nameof(DnsEditText))]
    [NotifyPropertyChangedFor(nameof(GatewayEditText))]
    [ObservableProperty] private NetAdapter? _dnsAdapter;
    [ObservableProperty] private string _dnsEditText = "";
    [ObservableProperty] private string _gatewayEditText = "";

    // Sharing (this computer as a router)
    [ObservableProperty] private NetAdapter? _upstreamAdapter;
    [ObservableProperty] private NetAdapter? _downstreamAdapter;
    [ObservableProperty] private bool _isSharing;
    [ObservableProperty] private string _routerIp = "10.1.1.1";
    [ObservableProperty] private string _routerSubnet = "255.255.255.0";
    [ObservableProperty] private string _dhcpStart = "10.1.1.100";
    [ObservableProperty] private string _dhcpEnd = "10.1.1.254";

    public string ShareButtonText => IsSharing ? "Stop sharing" : "Start sharing";
    partial void OnIsSharingChanged(bool value) => OnPropertyChanged(nameof(ShareButtonText));

    // When the upstream (internet) adapter is chosen, surface its DNS servers so the
    // user sees exactly what clients will receive (they can still override the field).
    partial void OnUpstreamAdapterChanged(NetAdapter? value)
    {
        if (value is null) return;
        var dns = UpstreamDnsServers(value);
        if (dns.Count > 0 && string.IsNullOrWhiteSpace(DnsEditText))
            DnsEditText = string.Join(", ", dns);
    }

    private static int MaskToPrefix(string mask)
    {
        if (!System.Net.IPAddress.TryParse(mask, out var m)) return 24;
        int bits = 0;
        foreach (var b in m.GetAddressBytes())
            for (int i = 7; i >= 0; i--)
                if ((b & (1 << i)) != 0) bits++;
        return bits;
    }

    private async Task LoadAdaptersAsync()
    {
        if (!_admin.IsSupported) return;
        try
        {
            var adapters = await _admin.ListAdaptersAsync();
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                var prevDns = DnsAdapter?.Device;
                var prevUp = UpstreamAdapter?.Device;
                var prevDown = DownstreamAdapter?.Device;
                Adapters.Clear();
                foreach (var a in adapters) Adapters.Add(a);
                DnsAdapter = Adapters.FirstOrDefault(a => a.Device == prevDns) ?? Adapters.FirstOrDefault();
                UpstreamAdapter = Adapters.FirstOrDefault(a => a.Device == prevUp) ?? Adapters.FirstOrDefault();
                DownstreamAdapter = Adapters.FirstOrDefault(a => a.Device == prevDown)
                                    ?? Adapters.FirstOrDefault(a => a.Device != UpstreamAdapter?.Device);
            });
        }
        catch (Exception ex)
        {
            await Dispatcher.UIThread.InvokeAsync(() => AdminStatus = ex.Message);
        }
    }

    [RelayCommand]
    private async Task RefreshAdapters() => await LoadAdaptersAsync();

    /// <summary>Copy an IP or MAC address to the clipboard (click-to-copy on the network tab).</summary>
    [RelayCommand]
    private async Task CopyText(string? value)
    {
        var text = value?.Trim();
        if (string.IsNullOrEmpty(text) || text is "—") return;
        if (Services.DialogService.Top?.Clipboard is { } cb)
        {
            await cb.SetTextAsync(text);
            ScanStatus = $"Copied {text}";
        }
    }

    private static IReadOnlyList<string> ParseServers(string text) =>
        text.Split(new[] { ',', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    [RelayCommand]
    private async Task ApplyDns()
    {
        if (DnsAdapter is null) { AdminStatus = "Pick an adapter first."; return; }
        var servers = ParseServers(DnsEditText);
        await RunAdminAsync(() => _admin.SetDnsAsync(DnsAdapter, servers));
    }

    [RelayCommand]
    private async Task ApplyGateway()
    {
        if (DnsAdapter is null) { AdminStatus = "Pick an adapter first."; return; }
        var gw = GatewayEditText.Trim();
        if (!IPAddress.TryParse(gw, out _)) { AdminStatus = "Enter a valid gateway IP."; return; }
        await RunAdminAsync(() => _admin.SetGatewayAsync(DnsAdapter, gw));
    }

    [RelayCommand]
    private async Task ToggleSharing()
    {
        if (UpstreamAdapter is null || DownstreamAdapter is null)
        {
            AdminStatus = "Pick both an upstream (internet) and downstream adapter.";
            return;
        }
        if (UpstreamAdapter.Device == DownstreamAdapter.Device)
        {
            AdminStatus = "Upstream and downstream must be different adapters.";
            return;
        }
        var up = UpstreamAdapter;
        var down = DownstreamAdapter;
        var wasSharing = IsSharing;
        var prefix = MaskToPrefix(RouterSubnet.Trim());
        var ok = await RunAdminAsync(() => wasSharing
            ? _admin.StopSharingAsync(up, down)
            : _admin.StartSharingAsync(up, down, RouterIp.Trim(), prefix));
        if (ok)
        {
            IsSharing = !wasSharing;
            // Publish active router state so the ZeroTier IP picker can show NAT clients.
            ActiveRouter = IsSharing
                ? new RouterState(RouterIp.Trim(), prefix)
                : null;

            if (IsSharing)
                StartDhcp(up, down);
            else
                StopDhcp();
        }
    }

    // WinNAT sets the downstream interface to DHCP-Disabled and the gateway is not a
    // DNS resolver, so we run our own DHCP server to hand out addresses + real DNS.
    private void StartDhcp(NetAdapter upstream, NetAdapter downstream)
    {
        if (!OperatingSystem.IsWindows()) return;
        try
        {
            _dhcp?.Dispose();
            _dhcp = new Services.DhcpServer();
            // Prefer DNS the user typed; otherwise hand clients the upstream adapter's
            // own DNS servers so they resolve names through the same path this PC does.
            var dns = ParseServers(DnsEditText).ToList();
            if (dns.Count == 0)
                dns = UpstreamDnsServers(upstream).ToList();
            _dhcp.Start(new Services.DhcpServer.Config
            {
                ServerIp = RouterIp.Trim(),
                SubnetMask = RouterSubnet.Trim(),
                PoolStart = DhcpStart.Trim(),
                PoolEnd = DhcpEnd.Trim(),
                DnsServers = dns,
                InterfaceIndex = ResolveInterfaceIndex(downstream)
            });
        }
        catch (Exception ex)
        {
            AdminStatus = $"Router active, but DHCP failed to start ({ex.Message}). Run elevated for client addressing.";
        }
    }

    /// <summary>The DNS servers configured on the upstream (internet) adapter.</summary>
    private static List<string> UpstreamDnsServers(NetAdapter upstream)
    {
        var result = new List<string>();
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.Name != upstream.Device && ni.Description != upstream.Device) continue;
                foreach (var d in ni.GetIPProperties().DnsAddresses)
                    if (d.AddressFamily == AddressFamily.InterNetwork)
                        result.Add(d.ToString());
                break;
            }
        }
        catch { }
        return result;
    }

    private void StopDhcp()
    {
        try { _dhcp?.Dispose(); } catch { }
        _dhcp = null;
    }

    private static int ResolveInterfaceIndex(NetAdapter adapter)
    {
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.Name == adapter.Device || ni.Description == adapter.Device)
                {
                    var p = ni.GetIPProperties().GetIPv4Properties();
                    if (p != null) return p.Index;
                }
            }
        }
        catch { }
        return 0;
    }

    private async Task<bool> RunAdminAsync(Func<Task<AdminResult>> op)
    {
        if (IsAdminBusy) return false;
        IsAdminBusy = true;
        AdminStatus = "Waiting for administrator authorization…";
        try
        {
            var result = await op();
            AdminStatus = result.Message;
            return result.Ok;
        }
        catch (Exception ex)
        {
            AdminStatus = ex.Message;
            return false;
        }
        finally
        {
            IsAdminBusy = false;
        }
    }

    [RelayCommand]
    private async Task Refresh() => await RefreshAsync();

    private async Task RefreshAsync()
    {
        IsRefreshing = true;
        try
        {
            Interfaces.Clear();
            string? gateway = null;
            var dns = new List<string>();
            string? scanGuess = null;

            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces()
                         .Where(n => n.NetworkInterfaceType != NetworkInterfaceType.Loopback))
            {
                var props = nic.GetIPProperties();
                var v4 = props.UnicastAddresses
                    .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
                    .Select(a => a.Address.ToString()).ToList();
                var v6 = props.UnicastAddresses
                    .Where(a => a.Address.AddressFamily == AddressFamily.InterNetworkV6)
                    .Select(a => a.Address.ToString()).ToList();

                Interfaces.Add(new InterfaceRow
                {
                    Name = nic.Name,
                    TypeLabel = TypeLabel(nic.NetworkInterfaceType),
                    IsUp = nic.OperationalStatus == OperationalStatus.Up,
                    Ipv4 = string.Join(", ", v4),
                    Ipv6 = v6.FirstOrDefault() ?? "",
                    Mac = FormatMac(nic.GetPhysicalAddress())
                });

                if (gateway is null)
                {
                    var gw = props.GatewayAddresses
                        .Select(g => g.Address)
                        .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork
                                             && !a.Equals(IPAddress.Any));
                    if (gw != null) gateway = gw.ToString();
                }

                foreach (var d in props.DnsAddresses
                             .Where(a => a.AddressFamily == AddressFamily.InterNetwork))
                    if (!dns.Contains(d.ToString())) dns.Add(d.ToString());

                if (scanGuess is null && nic.OperationalStatus == OperationalStatus.Up && v4.Count > 0)
                    scanGuess = SubnetPrefix(v4[0]);
            }

            DefaultGateway = gateway ?? "—";
            DnsServers = dns.Count > 0 ? string.Join(", ", dns) : "—";
            HostName = Dns.GetHostName();
            if (string.IsNullOrEmpty(ScanSubnet) && scanGuess != null)
                ScanSubnet = scanGuess;

            _ = FetchPublicIpAsync();
            _ = UpdateWifiAsync();
            _ = LoadAdaptersAsync();
        }
        finally
        {
            IsRefreshing = false;
        }
        await Task.CompletedTask;
    }

    /// <summary>Populate the Wi-Fi section on macOS by parsing
    /// <c>system_profiler SPAirPortDataType</c>. No-op on other platforms.</summary>
    private async Task UpdateWifiAsync()
    {
        if (!OperatingSystem.IsMacOS()) { HasWifi = false; return; }
        try
        {
            var output = await RunAsync("/usr/sbin/system_profiler", "SPAirPortDataType");
            var (ssid, signal, channel, txRate) = ParseAirport(output);
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                WifiSsid = ssid;
                WifiSignal = signal;
                WifiChannel = channel;
                WifiTxRate = txRate;
                HasWifi = !string.IsNullOrEmpty(ssid);
            });
        }
        catch
        {
            await Dispatcher.UIThread.InvokeAsync(() => HasWifi = false);
        }
    }

    private static (string Ssid, string Signal, string Channel, string TxRate) ParseAirport(string output)
    {
        var lines = output.Replace("\r", "").Split('\n');
        string ssid = "", signal = "", channel = "", txRate = "";
        int start = Array.FindIndex(lines, l => l.TrimEnd().EndsWith("Current Network Information:"));
        if (start < 0) return (ssid, signal, channel, txRate);

        // The SSID is the first indented "Name:" line after the header.
        for (int i = start + 1; i < lines.Length; i++)
        {
            var trimmed = lines[i].Trim();
            if (trimmed.Length == 0) continue;
            if (trimmed.EndsWith(":") && !trimmed.Contains(": "))
            {
                ssid = trimmed.TrimEnd(':');
                break;
            }
            break;
        }

        foreach (var raw in lines.Skip(start))
        {
            var line = raw.Trim();
            if (line.StartsWith("Signal / Noise:", StringComparison.OrdinalIgnoreCase))
                signal = line["Signal / Noise:".Length..].Trim();
            else if (line.StartsWith("Channel:", StringComparison.OrdinalIgnoreCase) && channel.Length == 0)
                channel = line["Channel:".Length..].Trim();
            else if (line.StartsWith("Transmit Rate:", StringComparison.OrdinalIgnoreCase))
                txRate = line["Transmit Rate:".Length..].Trim();
        }
        return (ssid, signal, channel, txRate);
    }

    private static async Task<string> RunAsync(string file, string args)
    {
        var psi = new ProcessStartInfo(file, args)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var proc = Process.Start(psi);
        if (proc is null) return "";
        var stdout = await proc.StandardOutput.ReadToEndAsync();
        await proc.WaitForExitAsync();
        return stdout;
    }

    private async Task FetchPublicIpAsync()
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(6) };
            var ip = (await http.GetStringAsync("https://api.ipify.org")).Trim();
            await Dispatcher.UIThread.InvokeAsync(() => PublicIp = string.IsNullOrEmpty(ip) ? "—" : ip);
        }
        catch
        {
            await Dispatcher.UIThread.InvokeAsync(() => PublicIp = "unavailable");
        }
    }

    [RelayCommand]
    private async Task Scan()
    {
        if (IsScanning) { _scanCts?.Cancel(); return; }
        var prefix = ScanSubnet.Trim().TrimEnd('.');
        if (prefix.Split('.').Length != 3)
        {
            ScanStatus = "Enter a /24 subnet prefix like 192.168.1";
            return;
        }

        ScanResults.Clear();
        IsScanning = true;
        ScanProgress = 0;
        ScanStatus = "Scanning…";
        _scanCts = new CancellationTokenSource();
        var token = _scanCts.Token;

        try
        {
            var done = 0;
            using var throttle = new SemaphoreSlim(64);
            var tasks = Enumerable.Range(1, 254).Select(async host =>
            {
                await throttle.WaitAsync(token);
                try
                {
                    var ip = $"{prefix}.{host}";
                    using var ping = new Ping();
                    var reply = await ping.SendPingAsync(ip, 500);
                    if (reply.Status == IPStatus.Success)
                    {
                        var hit = new ScanHit { Ip = ip, LatencyMs = reply.RoundtripTime };
                        await Dispatcher.UIThread.InvokeAsync(() => InsertSorted(hit));
                        _ = ResolveHostAsync(hit);
                    }
                }
                catch { /* host unreachable */ }
                finally
                {
                    throttle.Release();
                    var n = Interlocked.Increment(ref done);
                    if (n % 8 == 0)
                        await Dispatcher.UIThread.InvokeAsync(() => ScanProgress = n / 254.0 * 100.0);
                }
            });
            await Task.WhenAll(tasks);
            ScanStatus = token.IsCancellationRequested
                ? $"Stopped — {ScanResults.Count} host(s)"
                : $"Done — {ScanResults.Count} host(s) responded";
        }
        catch (OperationCanceledException)
        {
            ScanStatus = $"Stopped — {ScanResults.Count} host(s)";
        }
        finally
        {
            ScanProgress = 100;
            IsScanning = false;
            _scanCts = null;
        }
    }

    private void InsertSorted(ScanHit hit)
    {
        var octet = LastOctet(hit.Ip);
        var i = 0;
        while (i < ScanResults.Count && LastOctet(ScanResults[i].Ip) < octet) i++;
        ScanResults.Insert(i, hit);
    }

    public override void Dispose()
    {
        StopDhcp();
        base.Dispose();
    }

    private static async Task ResolveHostAsync(ScanHit hit)
    {
        try
        {
            var entry = await Dns.GetHostEntryAsync(hit.Ip);
            if (!string.IsNullOrEmpty(entry.HostName) && entry.HostName != hit.Ip)
                await Dispatcher.UIThread.InvokeAsync(() => hit.HostName = entry.HostName);
        }
        catch { /* no reverse DNS */ }
    }

    private static int LastOctet(string ip)
    {
        var parts = ip.Split('.');
        return parts.Length == 4 && int.TryParse(parts[3], out var v) ? v : 0;
    }

    private static string SubnetPrefix(string ipv4)
    {
        var p = ipv4.Split('.');
        return p.Length == 4 ? $"{p[0]}.{p[1]}.{p[2]}" : "";
    }

    private static string TypeLabel(NetworkInterfaceType t) => t switch
    {
        NetworkInterfaceType.Ethernet => "Ethernet",
        NetworkInterfaceType.Wireless80211 => "Wi-Fi",
        NetworkInterfaceType.Tunnel => "Tunnel",
        NetworkInterfaceType.Ppp => "PPP",
        _ => t.ToString()
    };

    private static string FormatMac(PhysicalAddress mac)
    {
        var bytes = mac.GetAddressBytes();
        return bytes.Length == 0 ? "" : string.Join(":", bytes.Select(b => b.ToString("X2")));
    }

    /// <summary>Published when NAT sharing starts so the ZeroTier IP picker can list router clients.</summary>
    public static RouterState? ActiveRouter { get; private set; }
}

/// <summary>Tracks the active router subnet so the ZeroTier picker can list ARP-discovered clients.</summary>
public sealed record RouterState(string RouterIp, int PrefixLength);
