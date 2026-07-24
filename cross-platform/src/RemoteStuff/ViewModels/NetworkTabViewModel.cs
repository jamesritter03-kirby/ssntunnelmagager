using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
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

namespace RemoteStuff.ViewModels;

/// <summary>
/// A cross-platform network browser: lists this machine's interfaces, gateway,
/// DNS servers, hostname and public IP, and offers a LAN ping-sweep scanner.
/// (macOS-only features from the original — Internet Sharing, "Mac as router",
/// Wi-Fi RSSI — are not portable and are omitted.)
/// </summary>
public sealed partial class NetworkTabViewModel : TabViewModel
{
    public override string Glyph => "🌐";

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
        _ = RefreshAsync();
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
        }
        finally
        {
            IsRefreshing = false;
        }
        await Task.CompletedTask;
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
}
