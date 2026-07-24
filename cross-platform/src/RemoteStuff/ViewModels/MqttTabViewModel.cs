using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using MQTTnet;
using MQTTnet.Client;
using RemoteStuff.Util;

namespace RemoteStuff.ViewModels;

public sealed class MqttMessage
{
    public required string Topic { get; init; }
    public required string Payload { get; init; }
    public DateTime Time { get; init; } = DateTime.Now;
    public string TimeText => Time.ToString("HH:mm:ss");
}

/// <summary>A node in the MQTT topic tree (one path segment). Parents hold child
/// segments; the node for a full topic carries its latest payload and hit count.</summary>
public sealed partial class MqttTopicNode : ObservableObject
{
    public string Name { get; }
    public string FullTopic { get; }
    public ObservableCollection<MqttTopicNode> Children { get; } = new();

    [ObservableProperty] private bool _isExpanded = true;
    [ObservableProperty] private string _latestPayload = "";
    [ObservableProperty] private int _messageCount;

    public string CountText => MessageCount > 0 ? MessageCount.ToString() : "";

    partial void OnMessageCountChanged(int value) => OnPropertyChanged(nameof(CountText));

    public MqttTopicNode(string name, string fullTopic)
    {
        Name = name;
        FullTopic = fullTopic;
    }
}

/// <summary>An MQTT broker explorer tab backed by MQTTnet.</summary>
public sealed partial class MqttTabViewModel : TabViewModel
{
    private string _host;
    private int _port;
    private string? _user;
    private string? _pass;
    private IMqttClient? _client;

    public override string Glyph => "📡";

    public override string? Host => _host;
    public int Port => _port;
    public override (string Host, int Port)? ConnectionEndpoint =>
        string.IsNullOrWhiteSpace(_host) ? null : (_host, _port);
    public string? User => _user;

    /// <summary>A stable id used to key this tab's credentials in the secret store
    /// so a saved workspace can remember them.</summary>
    public Guid CredentialId { get; }

    /// <summary>The broker password currently in use (for workspace persistence).</summary>
    public string? ConnectionPassword => _pass;

    /// <summary>MQTT tabs offer "Edit Connection Settings…" to re-point the broker.</summary>
    public override bool SupportsEditConnection => true;

    public override RemoteStuff.Services.TabSnapshot? CreateSnapshot() => new RemoteStuff.Services.TabSnapshot
    {
        Id = CredentialId,
        Kind = "mqtt",
        Title = Title,
        Host = _host,
        Port = _port,
        Username = _user
    };

    public ObservableCollection<MqttMessage> Messages { get; } = new();

    /// <summary>Root nodes of the hierarchical topic tree shown in the left panel.</summary>
    public ObservableCollection<MqttTopicNode> TopicTree { get; } = new();
    private readonly Dictionary<string, MqttTopicNode> _topicIndex = new();

    [ObservableProperty] private MqttTopicNode? _selectedTopic;

    /// <summary>The selected topic's latest payload, pretty-printed as JSON when it
    /// parses (otherwise shown verbatim). Powers the detail pane.</summary>
    [ObservableProperty] private string _selectedPayloadPretty = "";

    partial void OnSelectedTopicChanged(MqttTopicNode? value)
    {
        if (value is not null) PublishTopic = value.FullTopic;
        SelectedPayloadPretty = value is null ? "" : JsonText.Pretty(value.LatestPayload);
        OnPropertyChanged(nameof(HasSelectedTopic));
    }

    public bool HasSelectedTopic => SelectedTopic is not null;

    /// <summary>Expand every node in the topic tree.</summary>
    [RelayCommand]
    private void ExpandAllTopics() => SetAllExpanded(TopicTree, true);

    /// <summary>Collapse every node in the topic tree.</summary>
    [RelayCommand]
    private void CollapseAllTopics() => SetAllExpanded(TopicTree, false);

    private static void SetAllExpanded(IEnumerable<MqttTopicNode> nodes, bool expanded)
    {
        foreach (var n in nodes)
        {
            n.IsExpanded = expanded;
            SetAllExpanded(n.Children, expanded);
        }
    }

    /// <summary>Topics that have produced at least one numeric payload (graphable).</summary>
    public ObservableCollection<string> NumericTopics { get; } = new();

    private readonly Dictionary<string, List<double>> _series = new();
    private const int MaxSamples = 120;

    [ObservableProperty] private bool _isConnected;
    [ObservableProperty] private string _statusText = "Not connected";
    [ObservableProperty] private string _subscribeTopic = "#";
    [ObservableProperty] private string _publishTopic = "";
    [ObservableProperty] private string _publishPayload = "";

    [ObservableProperty] private string? _graphTopic;
    [ObservableProperty] private System.Collections.Generic.List<Avalonia.Point> _graphPoints = new();
    [ObservableProperty] private string _graphSummary = "";

    public bool HasNumericTopics => NumericTopics.Count > 0;

    partial void OnGraphTopicChanged(string? value) => RebuildGraph();

    public MqttTabViewModel(string host, int port, string? user, string? pass, string title, Guid? id = null)
    {
        CredentialId = id ?? Guid.NewGuid();
        _host = host;
        _port = port;
        _user = user;
        _pass = pass;
        Title = "MQTT · " + title;
        _ = ConnectAsync();
    }

    private async Task ConnectAsync()
    {
        StatusText = $"Connecting to {_host}:{_port}…";
        try
        {
            var factory = new MqttFactory();
            _client = factory.CreateMqttClient();

            _client.ApplicationMessageReceivedAsync += e =>
            {
                var topic = e.ApplicationMessage.Topic;
                var payload = e.ApplicationMessage.ConvertPayloadToString() ?? "";
                Dispatcher.UIThread.Post(() =>
                {
                    Messages.Insert(0, new MqttMessage { Topic = topic, Payload = payload });
                    while (Messages.Count > 500) Messages.RemoveAt(Messages.Count - 1);
                    RecordNumeric(topic, payload);
                    IndexTopic(topic, payload);
                });
                return Task.CompletedTask;
            };

            _client.DisconnectedAsync += _ =>
            {
                Dispatcher.UIThread.Post(() =>
                {
                    IsConnected = false;
                    StatusText = "Disconnected";
                });
                return Task.CompletedTask;
            };

            var builder = new MqttClientOptionsBuilder()
                .WithTcpServer(_host, _port)
                .WithClientId("RemoteStuff-" + Guid.NewGuid().ToString("N")[..8]);
            if (!string.IsNullOrEmpty(_user))
                builder = builder.WithCredentials(_user, _pass ?? "");

            await _client.ConnectAsync(builder.Build());
            IsConnected = true;
            StatusText = $"Connected to {_host}:{_port}";

            // Auto-subscribe so the topic tree fills in without a manual query.
            // A plain '#' wildcard never matches system topics ($SYS/...) per the
            // MQTT spec, so subscribe to those separately.
            try
            {
                await _client.SubscribeAsync("#");
                await _client.SubscribeAsync("$SYS/#");
            }
            catch { /* broker may forbid some wildcards; tree still fills from what we get */ }
        }
        catch (Exception ex)
        {
            IsConnected = false;
            StatusText = "Connection failed: " + ex.Message;
        }
    }

    [RelayCommand]
    private async Task Subscribe()
    {
        if (_client is null || !IsConnected || string.IsNullOrWhiteSpace(SubscribeTopic)) return;
        try
        {
            await _client.SubscribeAsync(SubscribeTopic.Trim());
            StatusText = "Subscribed to " + SubscribeTopic;
        }
        catch (Exception ex) { StatusText = "Subscribe failed: " + ex.Message; }
    }

    [RelayCommand]
    private async Task Publish()
    {
        if (_client is null || !IsConnected || string.IsNullOrWhiteSpace(PublishTopic)) return;
        try
        {
            var msg = new MqttApplicationMessageBuilder()
                .WithTopic(PublishTopic.Trim())
                .WithPayload(Encoding.UTF8.GetBytes(PublishPayload ?? ""))
                .Build();
            await _client.PublishAsync(msg);
            StatusText = "Published to " + PublishTopic;
        }
        catch (Exception ex) { StatusText = "Publish failed: " + ex.Message; }
    }

    [RelayCommand]
    private void ClearMessages()
    {
        Messages.Clear();
        TopicTree.Clear();
        _topicIndex.Clear();
        SelectedTopic = null;
    }

    [RelayCommand]
    private async Task Reconnect()
    {
        Dispose();
        await ConnectAsync();
    }

    /// <summary>Re-point this MQTT tab at a new broker (from the tab's right-click
    /// "Edit Connection Settings…") and reconnect it in place.</summary>
    public async Task ReconnectWith(string host, int port, string? user, string? pass)
    {
        _host = host;
        _port = port;
        _user = user;
        // A blank password means “keep the existing one” — the edit sheet never
        // pre-fills the stored secret, so we don't clobber it when left empty.
        _pass = string.IsNullOrEmpty(pass) ? _pass : pass;
        Title = "MQTT · " + host + ":" + port;
        OnPropertyChanged(nameof(Host));
        OnPropertyChanged(nameof(Port));
        OnPropertyChanged(nameof(User));
        Dispose();
        await ConnectAsync();
    }

    /// <summary>Extract a leading numeric value from a payload (e.g. "21.5°C" → 21.5).</summary>
    private static bool TryParseNumeric(string payload, out double value)
    {
        value = 0;
        var s = payload.Trim();
        if (s.Length == 0) return false;
        var i = 0;
        if (s[0] is '+' or '-') i++;
        var seenDot = false;
        while (i < s.Length && (char.IsDigit(s[i]) || (s[i] == '.' && !seenDot)))
        {
            if (s[i] == '.') seenDot = true;
            i++;
        }
        var head = s[..i];
        return double.TryParse(head, NumberStyles.Float, CultureInfo.InvariantCulture, out value);
    }

    /// <summary>Insert or update a topic in the hierarchical tree, splitting on '/'.
    /// Runs on the UI thread (called from the message handler's dispatcher post).</summary>
    private void IndexTopic(string topic, string payload)
    {
        if (string.IsNullOrEmpty(topic)) return;
        var segments = topic.Split('/');
        var level = TopicTree;
        MqttTopicNode? node = null;
        var path = "";
        for (var i = 0; i < segments.Length; i++)
        {
            path = i == 0 ? segments[0] : path + "/" + segments[i];
            if (!_topicIndex.TryGetValue(path, out node))
            {
                node = new MqttTopicNode(segments[i], path);
                _topicIndex[path] = node;
                var idx = 0;
                while (idx < level.Count && string.CompareOrdinal(level[idx].Name, segments[i]) < 0) idx++;
                level.Insert(idx, node);
            }
            level = node.Children;
        }
        if (node is not null)
        {
            node.LatestPayload = payload;
            node.MessageCount++;
            if (ReferenceEquals(node, SelectedTopic))
                SelectedPayloadPretty = JsonText.Pretty(payload);
        }
    }

    private void RecordNumeric(string topic, string payload)
    {
        // Prefer numeric fields inside a JSON object (e.g. {"temp":21.5,"hum":40})
        // so each field graphs as its own series, mirroring the macOS app.
        var fields = new Dictionary<string, double>();
        if (JsonText.TryExtractNumericFields(payload, fields))
        {
            foreach (var (name, v) in fields)
                AddSample(topic + " \u00b7 " + name, v);
        }
        else if (TryParseNumeric(payload, out var value))
        {
            AddSample(topic, value);
        }
    }

    /// <summary>Append a sample to a named series (topic, or "topic · field"),
    /// registering it as graphable the first time it is seen.</summary>
    private void AddSample(string seriesKey, double value)
    {
        if (!_series.TryGetValue(seriesKey, out var list))
        {
            list = new List<double>();
            _series[seriesKey] = list;
            NumericTopics.Add(seriesKey);
            OnPropertyChanged(nameof(HasNumericTopics));
            GraphTopic ??= seriesKey;
        }
        list.Add(value);
        while (list.Count > MaxSamples) list.RemoveAt(0);
        if (seriesKey == GraphTopic) RebuildGraph();
    }

    private void RebuildGraph()
    {
        if (GraphTopic is null || !_series.TryGetValue(GraphTopic, out var list) || list.Count < 2)
        {
            GraphPoints = new System.Collections.Generic.List<Avalonia.Point>();
            GraphSummary = "";
            return;
        }
        const double w = 320, h = 90, pad = 4;
        var min = list.Min();
        var max = list.Max();
        var range = max - min;
        if (range <= 0) range = 1;
        var n = list.Count;
        var points = new System.Collections.Generic.List<Avalonia.Point>(n);
        for (var i = 0; i < n; i++)
        {
            var x = pad + (w - 2 * pad) * i / (n - 1);
            var y = pad + (h - 2 * pad) * (1 - (list[i] - min) / range);
            points.Add(new Avalonia.Point(x, y));
        }
        GraphPoints = points;
        GraphSummary = $"last {list[^1].ToString("0.##", CultureInfo.InvariantCulture)}  ·  "
            + $"min {min.ToString("0.##", CultureInfo.InvariantCulture)}  ·  "
            + $"max {max.ToString("0.##", CultureInfo.InvariantCulture)}  ·  {n} samples";
    }

    public override void Dispose()
    {
        try { _ = _client?.DisconnectAsync(); _client?.Dispose(); } catch { /* ignore */ }
        _client = null;
    }

    protected override void Close()
    {
        Dispose();
        base.Close();
    }
}
