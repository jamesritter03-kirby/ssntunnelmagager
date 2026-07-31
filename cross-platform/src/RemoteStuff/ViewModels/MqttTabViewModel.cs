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
using RemoteStuff.Models;
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

    public override string Glyph => "radio";

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
        Graph.SetSamples(value?.FullTopic ?? "",
            value is not null && _history.TryGetValue(value.FullTopic, out var series) ? series : null);
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

    /// <summary>Live graph of the selected topic's numeric history (shared with Redis).</summary>
    public NumericGraphViewModel Graph { get; } = new()
    {
        EmptyMessage = "Select a topic that carries a number, or JSON with numeric fields, to graph its readings over time."
    };

    private readonly Dictionary<string, List<NumericGraphSample>> _history = new();
    private const int MaxSamplesPerTopic = 600;

    [ObservableProperty] private bool _isConnected;
    [ObservableProperty] private string _statusText = "Not connected";
    [ObservableProperty] private string _subscribeTopic = "#";
    [ObservableProperty] private string _publishTopic = "";
    [ObservableProperty] private string _publishPayload = "";

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
        _history.Clear();
        SelectedTopic = null;
        Graph.SetSamples("", null);
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
        // Build one timestamped sample per message from the payload's numeric leaves
        // (a bare number, JSON numeric fields, or a number-with-unit), mirroring the
        // macOS app so each field graphs as its own series.
        var values = JsonText.NumericValues(payload);
        if (values.Count == 0) return;
        if (!_history.TryGetValue(topic, out var series))
        {
            series = new List<NumericGraphSample>();
            _history[topic] = series;
        }
        series.Add(new NumericGraphSample(DateTime.Now, values));
        while (series.Count > MaxSamplesPerTopic) series.RemoveAt(0);
        if (SelectedTopic?.FullTopic == topic) Graph.SetSamples(topic, series);
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
