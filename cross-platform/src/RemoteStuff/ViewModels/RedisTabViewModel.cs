using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;
using RemoteStuff.Util;
using StackExchange.Redis;

namespace RemoteStuff.ViewModels;

/// <summary>A Redis key browser tab backed by StackExchange.Redis.</summary>
public sealed partial class RedisTabViewModel : TabViewModel
{
    private string _host;
    private int _port;
    private string? _password;
    private ConnectionMultiplexer? _mux;

    public override string Glyph => "database";

    public override string? Host => _host;
    public int Port => _port;
    public override (string Host, int Port)? ConnectionEndpoint =>
        string.IsNullOrWhiteSpace(_host) ? null : (_host, _port);

    /// <summary>A stable id used to key this tab's credentials in the secret store
    /// so a saved workspace can remember them.</summary>
    public Guid CredentialId { get; }

    /// <summary>The password currently in use (for workspace persistence).</summary>
    public string? ConnectionPassword => _password;

    /// <summary>Redis tabs offer "Edit Connection Settings…" to re-point the server.</summary>
    public override bool SupportsEditConnection => true;

    public override RemoteStuff.Services.TabSnapshot? CreateSnapshot() => new RemoteStuff.Services.TabSnapshot
    {
        Id = CredentialId,
        Kind = "redis",
        Title = Title,
        Host = _host,
        Port = _port
    };

    public ObservableCollection<string> Keys { get; } = new();

    /// <summary>Live graph of the selected key's numeric history (shared with MQTT).
    /// Turn on Live to sample a changing key over time.</summary>
    public NumericGraphViewModel Graph { get; } = new()
    {
        EmptyMessage = "Select a string key that holds a number, or JSON with numeric fields, to graph it. Turn on Live to sample it over time."
    };

    private readonly Dictionary<string, List<NumericGraphSample>> _history = new();
    private const int MaxSamplesPerKey = 600;

    [ObservableProperty] private bool _isConnected;
    [ObservableProperty] private string _statusText = "Not connected";
    [ObservableProperty] private string _keyFilter = "*";
    [ObservableProperty] private string? _selectedKey;
    [ObservableProperty] private string _selectedValue = "";
    [ObservableProperty] private string _keyType = "";
    [ObservableProperty] private string _keyTtl = "";
    [ObservableProperty] private string _commandText = "";
    [ObservableProperty] private string _commandResult = "";
    [ObservableProperty] private bool _liveRefresh;

    private readonly System.Timers.Timer _liveTimer;

    partial void OnLiveRefreshChanged(bool value)
    {
        if (value) _liveTimer.Start();
        else _liveTimer.Stop();
    }

    public RedisTabViewModel(string host, int port, string? password, string title, Guid? id = null)
    {
        CredentialId = id ?? Guid.NewGuid();
        _host = host;
        _port = port;
        _password = password;
        Title = "Redis · " + title;
        _liveTimer = new System.Timers.Timer(2_000) { AutoReset = true };
        _liveTimer.Elapsed += (_, _) => Dispatcher.UIThread.Post(() =>
        {
            if (!string.IsNullOrEmpty(SelectedKey)) _ = LoadValue(SelectedKey!);
        });
        Graph.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NumericGraphViewModel.HasData)) RaiseGraphLayout();
        };
        _ = ConnectAsync();
    }

    // ----- Value/Graph section layout (mirrors the MQTT tab) -----
    // Each section can be collapsed to just its header, or maximized to fill the
    // whole value area (the other section shrinks to its header).
    private static readonly Avalonia.Controls.GridLength Star = new(1, Avalonia.Controls.GridUnitType.Star);

    [ObservableProperty] private string _maximizedPane = "";
    [ObservableProperty] private bool _valueCollapsed;
    [ObservableProperty] private bool _graphCollapsed;

    public Avalonia.Controls.GridLength ValueRowHeight => RowFor("value", ValueCollapsed, true);
    public Avalonia.Controls.GridLength GraphRowHeight => RowFor("graph", GraphCollapsed, Graph.HasData);

    private Avalonia.Controls.GridLength RowFor(string pane, bool collapsed, bool visible)
    {
        if (!visible) return Avalonia.Controls.GridLength.Auto;      // hidden section takes no space
        if (MaximizedPane == pane) return Star;
        if (MaximizedPane.Length > 0) return Avalonia.Controls.GridLength.Auto; // another pane owns the area
        return collapsed ? Avalonia.Controls.GridLength.Auto : Star;
    }

    public bool ValueContentVisible => ContentVisible("value", ValueCollapsed);
    public bool GraphContentVisible => ContentVisible("graph", GraphCollapsed);

    private bool ContentVisible(string pane, bool collapsed)
    {
        if (MaximizedPane == pane) return true;
        if (MaximizedPane.Length > 0) return false;
        return !collapsed;
    }

    public bool ValueMaximized => MaximizedPane == "value";
    public bool GraphMaximized => MaximizedPane == "graph";

    public string ValueCollapseIcon => ValueCollapsed ? "chevron-right" : "chevron-down";
    public string GraphCollapseIcon => GraphCollapsed ? "chevron-right" : "chevron-down";
    public string ValueMaxIcon => ValueMaximized ? "minimize-2" : "maximize-2";
    public string GraphMaxIcon => GraphMaximized ? "minimize-2" : "maximize-2";

    partial void OnMaximizedPaneChanged(string value) => RaisePaneLayout();
    partial void OnValueCollapsedChanged(bool value)
    {
        OnPropertyChanged(nameof(ValueRowHeight));
        OnPropertyChanged(nameof(ValueContentVisible));
        OnPropertyChanged(nameof(ValueCollapseIcon));
    }
    partial void OnGraphCollapsedChanged(bool value)
    {
        OnPropertyChanged(nameof(GraphRowHeight));
        OnPropertyChanged(nameof(GraphContentVisible));
        OnPropertyChanged(nameof(GraphCollapseIcon));
    }

    private void RaiseGraphLayout()
    {
        OnPropertyChanged(nameof(GraphRowHeight));
        OnPropertyChanged(nameof(GraphContentVisible));
    }

    private void RaisePaneLayout()
    {
        OnPropertyChanged(nameof(ValueRowHeight));
        OnPropertyChanged(nameof(GraphRowHeight));
        OnPropertyChanged(nameof(ValueContentVisible));
        OnPropertyChanged(nameof(GraphContentVisible));
        OnPropertyChanged(nameof(ValueMaximized));
        OnPropertyChanged(nameof(GraphMaximized));
        OnPropertyChanged(nameof(ValueMaxIcon));
        OnPropertyChanged(nameof(GraphMaxIcon));
    }

    [RelayCommand] private void ToggleValueCollapsed() => ValueCollapsed = !ValueCollapsed;
    [RelayCommand] private void ToggleGraphCollapsed() => GraphCollapsed = !GraphCollapsed;
    [RelayCommand] private void MaximizeValue() => MaximizedPane = MaximizedPane == "value" ? "" : "value";
    [RelayCommand] private void MaximizeGraph() => MaximizedPane = MaximizedPane == "graph" ? "" : "graph";

    private async Task ConnectAsync()
    {
        StatusText = $"Connecting to {_host}:{_port}…";
        try
        {
            var options = new ConfigurationOptions
            {
                EndPoints = { { _host, _port } },
                AbortOnConnectFail = false,
                ConnectTimeout = 5000
            };
            if (!string.IsNullOrEmpty(_password)) options.Password = _password;

            _mux = await ConnectionMultiplexer.ConnectAsync(options);
            IsConnected = _mux.IsConnected;
            StatusText = IsConnected ? $"Connected to {_host}:{_port}" : "Could not connect";
            if (IsConnected) await RefreshKeys();
        }
        catch (Exception ex)
        {
            IsConnected = false;
            StatusText = "Connection failed: " + ex.Message;
        }
    }

    [RelayCommand]
    private async Task RefreshKeys()
    {
        if (_mux is null || !_mux.IsConnected) return;
        try
        {
            var pattern = string.IsNullOrWhiteSpace(KeyFilter) ? "*" : KeyFilter.Trim();
            var keys = await Task.Run(() =>
            {
                var endpoint = _mux.GetEndPoints().First();
                var server = _mux.GetServer(endpoint);
                return server.Keys(pattern: pattern, pageSize: 500)
                             .Select(k => k.ToString())
                             .Take(1000)
                             .OrderBy(k => k, StringComparer.Ordinal)
                             .ToList();
            });
            Dispatcher.UIThread.Post(() =>
            {
                Keys.Clear();
                foreach (var k in keys) Keys.Add(k);
                StatusText = $"{Keys.Count} keys";
            });
        }
        catch (Exception ex) { StatusText = "Scan failed: " + ex.Message; }
    }

    partial void OnSelectedKeyChanged(string? value)
    {
        Graph.SetSamples(value ?? "",
            value is not null && _history.TryGetValue(value, out var series) ? series : null);
        if (!string.IsNullOrEmpty(value)) _ = LoadValue(value);
    }

    private async Task LoadValue(string key)
    {
        if (_mux is null) return;
        try
        {
            var db = _mux.GetDatabase();
            var type = await db.KeyTypeAsync(key);
            KeyType = type.ToString();
            var ttl = await db.KeyTimeToLiveAsync(key);
            KeyTtl = ttl.HasValue ? FormatTtl(ttl.Value) : "no expiry";
            string text = type switch
            {
                RedisType.String => (string?)await db.StringGetAsync(key) ?? "",
                RedisType.List => string.Join("\n", await db.ListRangeAsync(key)),
                RedisType.Set => string.Join("\n", await db.SetMembersAsync(key)),
                RedisType.Hash => string.Join("\n", (await db.HashGetAllAsync(key)).Select(h => $"{h.Name} = {h.Value}")),
                RedisType.SortedSet => string.Join("\n", (await db.SortedSetRangeByRankWithScoresAsync(key)).Select(z => $"{z.Element} ({z.Score})")),
                _ => "(unsupported type)"
            };
            // Pretty-print JSON string values automatically (mirrors the macOS app).
            SelectedValue = type == RedisType.String ? JsonText.Pretty(text) : text;
            if (type == RedisType.String) RecordNumeric(key, text);
        }
        catch (Exception ex) { StatusText = "Load failed: " + ex.Message; }
    }

    /// <summary>Append a timestamped sample from a string value's numeric leaves
    /// (a bare number, or JSON numeric fields) so the key can be graphed live.
    /// Turning on Live re-loads periodically, growing the series over time.</summary>
    private void RecordNumeric(string key, string raw)
    {
        var values = JsonText.NumericValues(raw);
        if (values.Count == 0) return;
        if (!_history.TryGetValue(key, out var series))
        {
            series = new List<NumericGraphSample>();
            _history[key] = series;
        }
        series.Add(new NumericGraphSample(DateTime.Now, values));
        while (series.Count > MaxSamplesPerKey) series.RemoveAt(0);
        if (SelectedKey == key) Graph.SetSamples(key, series);
    }

    [RelayCommand]
    private async Task SaveValue()
    {
        if (_mux is null || string.IsNullOrEmpty(SelectedKey)) return;
        try
        {
            var db = _mux.GetDatabase();
            var type = await db.KeyTypeAsync(SelectedKey);
            if (type is RedisType.String or RedisType.None)
            {
                await db.StringSetAsync(SelectedKey, SelectedValue);
                StatusText = "Saved " + SelectedKey;
            }
            else
            {
                StatusText = "Editing " + type + " values is read-only";
            }
        }
        catch (Exception ex) { StatusText = "Save failed: " + ex.Message; }
    }

    /// <summary>Re-format the currently shown value as pretty JSON (no-op when the
    /// value isn't valid JSON).</summary>
    [RelayCommand]
    private void FormatJson() => SelectedValue = JsonText.Pretty(SelectedValue);

    [RelayCommand]
    private async Task DeleteKey()
    {
        if (_mux is null || string.IsNullOrEmpty(SelectedKey)) return;
        try
        {
            await _mux.GetDatabase().KeyDeleteAsync(SelectedKey);
            var removed = SelectedKey;
            Keys.Remove(removed);
            _history.Remove(removed);
            SelectedKey = null;
            SelectedValue = "";
            KeyTtl = "";
            Graph.SetSamples("", null);
            StatusText = "Deleted " + removed;
        }
        catch (Exception ex) { StatusText = "Delete failed: " + ex.Message; }
    }

    [RelayCommand]
    private async Task Reconnect()
    {
        Dispose();
        await ConnectAsync();
    }

    /// <summary>Re-point this Redis tab at a new server (from the tab's right-click
    /// "Edit Connection Settings…") and reconnect it in place.</summary>
    public async Task ReconnectWith(string host, int port, string? password)
    {
        _host = host;
        _port = port;
        // A blank password means “keep the existing one” — the edit sheet never
        // pre-fills the stored secret, so we don't clobber it when left empty.
        _password = string.IsNullOrEmpty(password) ? _password : password;
        Title = "Redis · " + host + ":" + port;
        OnPropertyChanged(nameof(Host));
        OnPropertyChanged(nameof(Port));
        Dispose();
        await ConnectAsync();
    }

    private static string FormatTtl(TimeSpan ttl)
    {
        if (ttl.TotalDays >= 1) return $"{(int)ttl.TotalDays}d {ttl.Hours}h";
        if (ttl.TotalHours >= 1) return $"{(int)ttl.TotalHours}h {ttl.Minutes}m";
        if (ttl.TotalMinutes >= 1) return $"{(int)ttl.TotalMinutes}m {ttl.Seconds}s";
        return $"{(int)ttl.TotalSeconds}s";
    }

    /// <summary>Run an arbitrary Redis command (space-separated), e.g. "INCR counter".</summary>
    [RelayCommand]
    private async Task RunCommand()
    {
        if (_mux is null || !_mux.IsConnected || string.IsNullOrWhiteSpace(CommandText)) return;
        try
        {
            var parts = CommandText.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 0) return;
            var db = _mux.GetDatabase();
            var args = parts.Skip(1).Select(p => (object)p).ToArray();
            var result = await db.ExecuteAsync(parts[0], args);
            CommandResult = result.IsNull ? "(nil)" : result.ToString();
            StatusText = "Ran " + parts[0].ToUpperInvariant();
        }
        catch (Exception ex) { CommandResult = "Error: " + ex.Message; }
    }

    public override void Dispose()
    {
        _liveTimer.Stop();
        _liveTimer.Dispose();
        try { _mux?.Dispose(); } catch { /* ignore */ }
        _mux = null;
    }

    protected override void Close()
    {
        Dispose();
        base.Close();
    }
}
