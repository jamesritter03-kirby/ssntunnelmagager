using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Linq;
using System.Net.Sockets;
using System.Threading.Tasks;
using Avalonia.Media;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace RemoteStuff.ViewModels;

/// <summary>Backs the workspace Connection Health dialog: a live view of every
/// networked tab in a workspace. Each connection is periodically TCP-probed for
/// reachability and round-trip latency; the results feed per-connection sparklines
/// and an aggregate average-latency graph. All probes run off the UI thread.</summary>
public sealed partial class WorkspaceStatsViewModel : ObservableObject
{
    private const int HistoryLength = 60;
    private const int ProbeTimeoutMs = 2500;

    private readonly Func<IReadOnlyList<TabViewModel>> _tabsProvider;
    private readonly System.Timers.Timer _timer;
    private readonly DateTime _openedAt = DateTime.Now;
    private bool _busy;

    public string WorkspaceName { get; }
    public ObservableCollection<ConnectionStatRow> Connections { get; } = new();
    public ObservableCollection<double> AggregateHistory { get; } = new();

    [ObservableProperty] private int _liveCount;
    [ObservableProperty] private int _totalTabs;
    [ObservableProperty] private string _statusText = "";
    [ObservableProperty] private double _averageLatency = -1;
    [ObservableProperty] private bool _autoRefresh = true;

    public string AverageLatencyText => AverageLatency < 0 ? "—" : $"{AverageLatency:0} ms";
    public string UptimeText => FormatSpan(DateTime.Now - _openedAt);
    public bool HasConnections => Connections.Count > 0;
    public string SummaryText => $"{LiveCount} of {Connections.Count} reachable · {TotalTabs} tabs";

    partial void OnAverageLatencyChanged(double value) => OnPropertyChanged(nameof(AverageLatencyText));
    partial void OnLiveCountChanged(int value) => OnPropertyChanged(nameof(SummaryText));
    partial void OnTotalTabsChanged(int value) => OnPropertyChanged(nameof(SummaryText));

    public WorkspaceStatsViewModel(string workspaceName, Func<IReadOnlyList<TabViewModel>> tabsProvider)
    {
        WorkspaceName = workspaceName;
        _tabsProvider = tabsProvider;
        _timer = new System.Timers.Timer(2_000) { AutoReset = true };
        _timer.Elapsed += (_, _) => Dispatcher.UIThread.Post(() => _ = RefreshAsync());
        _ = RefreshAsync();
        _timer.Start();
    }

    [RelayCommand]
    private async Task Refresh() => await RefreshAsync();

    private async Task RefreshAsync()
    {
        if (_busy) return;
        _busy = true;
        try
        {
            var tabs = _tabsProvider();
            var endpoints = tabs.Where(t => t.ConnectionEndpoint is not null).ToList();

            // Drop rows whose tab is gone.
            for (var i = Connections.Count - 1; i >= 0; i--)
                if (endpoints.All(t => t.Id != Connections[i].TabId))
                    Connections.RemoveAt(i);

            // Add rows for new connections, keeping tab order.
            for (var i = 0; i < endpoints.Count; i++)
            {
                var t = endpoints[i];
                if (Connections.Any(r => r.TabId == t.Id)) continue;
                var (host, port) = t.ConnectionEndpoint!.Value;
                var row = new ConnectionStatRow(t.Id, t.Title, t.Glyph, host, port);
                var insertAt = Math.Min(i, Connections.Count);
                Connections.Insert(insertAt, row);
            }

            // Refresh titles (they can change as a session names itself).
            foreach (var r in Connections)
                if (endpoints.FirstOrDefault(x => x.Id == r.TabId) is { } t)
                    r.Title = t.Title;

            TotalTabs = tabs.Count;
            OnPropertyChanged(nameof(HasConnections));
            OnPropertyChanged(nameof(UptimeText));

            // Probe every endpoint in parallel, off the UI thread.
            var snapshot = Connections.ToList();
            var results = await Task.WhenAll(snapshot.Select(async r =>
            {
                var ms = await ProbeAsync(r.Host, r.Port);
                return (Row: r, Ms: ms);
            }));

            double sum = 0;
            var live = 0;
            foreach (var (row, ms) in results)
            {
                row.Apply(ms);
                if (ms >= 0) { sum += ms; live++; }
            }

            LiveCount = live;
            AverageLatency = live > 0 ? sum / live : -1;
            Push(AggregateHistory, AverageLatency);
            StatusText = "Updated " + DateTime.Now.ToString("HH:mm:ss");
        }
        finally
        {
            _busy = false;
        }
    }

    private static async Task<double> ProbeAsync(string host, int port)
    {
        try
        {
            using var client = new TcpClient();
            var sw = Stopwatch.StartNew();
            var connect = client.ConnectAsync(host, port);
            var done = await Task.WhenAny(connect, Task.Delay(ProbeTimeoutMs));
            sw.Stop();
            if (done != connect || !client.Connected) return -1;
            await connect; // surface any connect exception
            return sw.Elapsed.TotalMilliseconds;
        }
        catch
        {
            return -1;
        }
    }

    private static void Push(ObservableCollection<double> series, double value)
    {
        series.Add(value);
        while (series.Count > HistoryLength) series.RemoveAt(0);
    }

    partial void OnAutoRefreshChanged(bool value)
    {
        if (value) _timer.Start();
        else _timer.Stop();
    }

    /// <summary>Stop the probe timer when the window closes.</summary>
    public void Stop()
    {
        _timer.Stop();
        _timer.Dispose();
    }

    private static string FormatSpan(TimeSpan t) =>
        t.TotalHours >= 1 ? $"{(int)t.TotalHours}h {t.Minutes}m"
        : t.TotalMinutes >= 1 ? $"{t.Minutes}m {t.Seconds}s"
        : $"{t.Seconds}s";
}

/// <summary>One connection row in the Connection Health dialog: its endpoint, live
/// reachability, latest/rolling latency, and a bounded history for its sparkline.</summary>
public sealed partial class ConnectionStatRow : ObservableObject
{
    private const int HistoryLength = 60;

    public Guid TabId { get; }
    public string Glyph { get; }
    public string Host { get; }
    public int Port { get; }
    public string Endpoint => $"{Host}:{Port}";
    public ObservableCollection<double> History { get; } = new();

    private bool _firstProbe = true;
    private bool _previousLive;
    private int _totalProbes;
    private int _liveProbes;
    private DateTime? _lastConnectedAt;
    private DateTime? _lastDroppedAt;

    [ObservableProperty] private string _title;
    [ObservableProperty] private double _latencyMs = -1;
    [ObservableProperty] private bool _isLive;
    [ObservableProperty] private double _minMs = -1;
    [ObservableProperty] private double _maxMs = -1;
    [ObservableProperty] private double _avgMs = -1;
    [ObservableProperty] private int _connectCount;
    [ObservableProperty] private int _dropCount;
    [ObservableProperty] private double _uptimePct = -1;

    public string LatencyText => LatencyMs < 0 ? "timeout" : $"{LatencyMs:0} ms";
    public string StatusText => IsLive ? "● reachable" : "● unreachable";
    public IBrush StatusBrush => new SolidColorBrush(Color.Parse(IsLive ? "#3FB950" : "#E5484D"));
    public IBrush LineBrush => new SolidColorBrush(Color.Parse(IsLive ? "#4C8BF5" : "#E5484D"));
    public string RangeText => MinMs < 0 ? "no samples yet" : $"min {MinMs:0} · avg {AvgMs:0} · max {MaxMs:0} ms";
    public bool HasSessionStats => _totalProbes > 0;
    public bool HasLastEvent => _lastConnectedAt.HasValue || _lastDroppedAt.HasValue;
    public string ConnectStatsText =>
        $"↑ {ConnectCount} connect{(ConnectCount == 1 ? "" : "s")}  ↓ {DropCount} drop{(DropCount == 1 ? "" : "s")}  {(UptimePct >= 0 ? $"{UptimePct:0}% uptime" : "")}";
    public string LastEventText
    {
        get
        {
            var parts = new System.Collections.Generic.List<string>();
            if (_lastConnectedAt is { } c) parts.Add("last up " + FormatAgo(c));
            if (_lastDroppedAt is { } d) parts.Add("last drop " + FormatAgo(d));
            return string.Join("  ·  ", parts);
        }
    }

    private static string FormatAgo(DateTime t)
    {
        var span = DateTime.Now - t;
        if (span.TotalSeconds < 5) return "just now";
        if (span.TotalSeconds < 60) return $"{(int)span.TotalSeconds}s ago";
        if (span.TotalMinutes < 60) return $"{(int)span.TotalMinutes}m ago";
        return $"{(int)span.TotalHours}h {span.Minutes}m ago";
    }

    public ConnectionStatRow(Guid tabId, string title, string glyph, string host, int port)
    {
        TabId = tabId;
        _title = string.IsNullOrWhiteSpace(title) ? host : title;
        Glyph = glyph;
        Host = host;
        Port = port;
    }

    /// <summary>Record a probe result (negative = timeout/unreachable) and roll history.</summary>
    public void Apply(double ms)
    {
        _totalProbes++;
        bool nowLive = ms >= 0;
        if (nowLive) _liveProbes++;
        UptimePct = (double)_liveProbes / _totalProbes * 100;

        if (!_firstProbe)
        {
            if (!_previousLive && nowLive) { ConnectCount++; _lastConnectedAt = DateTime.Now; }
            else if (_previousLive && !nowLive) { DropCount++; _lastDroppedAt = DateTime.Now; }
        }
        else
        {
            _firstProbe = false;
            if (nowLive) _lastConnectedAt = DateTime.Now;
        }
        _previousLive = nowLive;

        LatencyMs = ms;
        IsLive = nowLive;

        History.Add(ms);
        while (History.Count > HistoryLength) History.RemoveAt(0);

        var valid = History.Where(v => v >= 0).ToList();
        if (valid.Count > 0)
        {
            MinMs = valid.Min();
            MaxMs = valid.Max();
            AvgMs = valid.Average();
        }

        OnPropertyChanged(nameof(LatencyText));
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(StatusBrush));
        OnPropertyChanged(nameof(LineBrush));
        OnPropertyChanged(nameof(ConnectStatsText));
        OnPropertyChanged(nameof(LastEventText));
        OnPropertyChanged(nameof(HasSessionStats));
        OnPropertyChanged(nameof(HasLastEvent));
    }

    partial void OnMinMsChanged(double value) => OnPropertyChanged(nameof(RangeText));
    partial void OnMaxMsChanged(double value) => OnPropertyChanged(nameof(RangeText));
    partial void OnAvgMsChanged(double value) => OnPropertyChanged(nameof(RangeText));
    partial void OnConnectCountChanged(int value) => OnPropertyChanged(nameof(ConnectStatsText));
    partial void OnDropCountChanged(int value) => OnPropertyChanged(nameof(ConnectStatsText));
    partial void OnUptimePctChanged(double value) => OnPropertyChanged(nameof(ConnectStatsText));
}
