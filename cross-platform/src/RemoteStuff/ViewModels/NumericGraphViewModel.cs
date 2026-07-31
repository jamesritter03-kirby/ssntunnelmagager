using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using Avalonia.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using RemoteStuff.Models;
using RemoteStuff.Views.Controls;

namespace RemoteStuff.ViewModels;

/// <summary>One graphable series toggle (a coloured chip). Toggling <see cref="Selected"/>
/// asks the owning graph to rebuild.</summary>
public sealed partial class GraphField : ObservableObject
{
    public string Name { get; }
    public IBrush Color { get; }
    private readonly Action _changed;

    [ObservableProperty] private bool _selected = true;

    partial void OnSelectedChanged(bool value) => _changed();

    public GraphField(string name, IBrush color, Action changed)
    {
        Name = name;
        Color = color;
        _changed = changed;
    }
}

/// <summary>Backing model for the shared numeric graph shown by the MQTT and Redis
/// tabs — a live multi-series line chart with per-field toggle chips, a Stack switch,
/// and CSV/JSON/image export. Mirrors the macOS app's NumericSeriesGraph.</summary>
public sealed partial class NumericGraphViewModel : ObservableObject
{
    private static readonly IBrush[] Palette =
    {
        new SolidColorBrush(Color.FromRgb(0x7F, 0xB0, 0xDE)), // blue
        new SolidColorBrush(Color.FromRgb(0x9F, 0xD3, 0xA0)), // green
        new SolidColorBrush(Color.FromRgb(0xE5, 0xA0, 0x5A)), // orange
        new SolidColorBrush(Color.FromRgb(0xC8, 0x8C, 0xE0)), // purple
        new SolidColorBrush(Color.FromRgb(0xE5, 0x78, 0x7D)), // red
        new SolidColorBrush(Color.FromRgb(0x6A, 0xC7, 0xC7)), // teal
        new SolidColorBrush(Color.FromRgb(0xE0, 0xC8, 0x6A)), // yellow
        new SolidColorBrush(Color.FromRgb(0xB0, 0x9C, 0xF0)), // indigo
    };

    /// <summary>A human name for the graphed source (MQTT topic / Redis key), used as
    /// the export title and default filename.</summary>
    public string ExportName { get; private set; } = "graph";

    public string EmptyMessage { get; set; } = "Numeric values will graph here as they arrive.";

    private List<NumericGraphSample> _samples = new();
    private List<string> _fieldNames = new();

    public ObservableCollection<GraphField> Fields { get; } = new();

    [ObservableProperty] private bool _hasData;
    [ObservableProperty] private bool _hasMultipleFields;
    [ObservableProperty] private bool _stack;
    [ObservableProperty] private bool _showStacked;
    [ObservableProperty] private bool _showOverlay;
    [ObservableProperty] private string _footer = "";

    private IReadOnlyList<GraphSeries> _overlaySeries = Array.Empty<GraphSeries>();
    public IReadOnlyList<GraphSeries> OverlaySeries
    {
        get => _overlaySeries;
        private set { _overlaySeries = value; OnPropertyChanged(); }
    }

    private IReadOnlyList<GraphPane> _stackPanes = Array.Empty<GraphPane>();
    public IReadOnlyList<GraphPane> StackPanes
    {
        get => _stackPanes;
        private set { _stackPanes = value; OnPropertyChanged(); }
    }

    /// <summary>True when there is something to export (data + at least one selected series).</summary>
    public bool CanExport => HasData && Fields.Any(f => f.Selected);

    partial void OnStackChanged(bool value) => Rebuild();
    partial void OnHasDataChanged(bool value) => OnPropertyChanged(nameof(CanExport));

    /// <summary>Replace the graphed history for a source (topic/key) and rebuild.</summary>
    public void SetSamples(string exportName, IReadOnlyList<NumericGraphSample>? samples)
    {
        ExportName = string.IsNullOrWhiteSpace(exportName) ? "graph" : exportName;
        _samples = samples is null ? new List<NumericGraphSample>() : samples.ToList();
        SyncFields();
        Rebuild();
    }

    private void SyncFields()
    {
        var names = new SortedSet<string>(StringComparer.Ordinal);
        foreach (var s in _samples)
            foreach (var k in s.Values.Keys)
                names.Add(k);
        var list = names.ToList();
        if (list.SequenceEqual(_fieldNames)) return; // unchanged — keep chip toggle state

        var prev = Fields.ToDictionary(f => f.Name, f => f.Selected);
        _fieldNames = list;
        Fields.Clear();
        for (var i = 0; i < list.Count; i++)
        {
            var field = new GraphField(list[i], Palette[i % Palette.Length], Rebuild);
            if (prev.TryGetValue(list[i], out var sel)) field.Selected = sel;
            Fields.Add(field);
        }
        HasMultipleFields = list.Count > 1;
    }

    private IBrush ColorFor(string name)
    {
        var i = _fieldNames.IndexOf(name);
        return Palette[(i < 0 ? 0 : i) % Palette.Length];
    }

    private void Rebuild()
    {
        HasData = _samples.Count > 0 && _fieldNames.Count > 0;
        var selected = Fields.Where(f => f.Selected).Select(f => f.Name).ToList();
        if (!HasData || selected.Count == 0)
        {
            OverlaySeries = Array.Empty<GraphSeries>();
            StackPanes = Array.Empty<GraphPane>();
            ShowStacked = false;
            ShowOverlay = false;
            Footer = "";
            OnPropertyChanged(nameof(CanExport));
            return;
        }

        var overlay = new List<GraphSeries>(selected.Count);
        var panes = new List<GraphPane>(selected.Count);
        foreach (var name in selected)
        {
            var pts = new List<GraphPoint>(_samples.Count);
            foreach (var s in _samples)
                if (s.Values.TryGetValue(name, out var v))
                    pts.Add(new GraphPoint(s.Time, v));
            var gs = new GraphSeries(name, ColorFor(name), pts);
            overlay.Add(gs);
            panes.Add(new GraphPane(name, gs));
        }

        OverlaySeries = overlay;
        StackPanes = panes;
        ShowStacked = Stack && selected.Count > 1;
        ShowOverlay = !ShowStacked;
        Footer = $"{_samples.Count} sample{(_samples.Count == 1 ? "" : "s")}  ·  "
               + $"{selected.Count} of {_fieldNames.Count} item{(_fieldNames.Count == 1 ? "" : "s")} shown";
        OnPropertyChanged(nameof(CanExport));
    }

    private List<string> SelectedFields() =>
        Fields.Where(f => f.Selected).Select(f => f.Name)
            .OrderBy(n => n, StringComparer.Ordinal).ToList();

    /// <summary>The plotted history as CSV: an ISO-8601 Time column plus one column
    /// per selected series.</summary>
    public string BuildCsv()
    {
        var fields = SelectedFields();
        var sb = new StringBuilder();
        sb.Append(string.Join(",", new[] { "Time" }.Concat(fields).Select(Escape)));
        sb.Append('\n');
        foreach (var s in _samples)
        {
            var cells = new List<string> { s.Time.ToString("o", CultureInfo.InvariantCulture) };
            foreach (var f in fields)
                cells.Add(s.Values.TryGetValue(f, out var v) ? FormatNumber(v) : "");
            sb.Append(string.Join(",", cells.Select(Escape)));
            sb.Append('\n');
        }
        return sb.ToString();

        static string Escape(string s) =>
            s.Contains(',') || s.Contains('"') || s.Contains('\n')
                ? "\"" + s.Replace("\"", "\"\"") + "\""
                : s;
    }

    /// <summary>The plotted history as a JSON document describing the source and its
    /// sample history.</summary>
    public string BuildJson()
    {
        var fields = SelectedFields();
        var samples = _samples.Select(s =>
        {
            var values = new Dictionary<string, double>();
            foreach (var f in fields)
                if (s.Values.TryGetValue(f, out var v))
                    values[f] = v;
            return new
            {
                time = s.Time.ToString("o", CultureInfo.InvariantCulture),
                values
            };
        }).ToList();
        var root = new
        {
            name = ExportName,
            exportedAt = DateTime.Now.ToString("o", CultureInfo.InvariantCulture),
            series = fields,
            samples
        };
        return JsonSerializer.Serialize(root, new JsonSerializerOptions { WriteIndented = true });
    }

    /// <summary>A filename-safe version of the export name (topic paths carry slashes).</summary>
    public string SanitizedName
    {
        get
        {
            var cleaned = new string(ExportName.Select(c =>
                "/\\:*?\"<>|".IndexOf(c) >= 0 ? '_' : c).ToArray()).Trim();
            return string.IsNullOrEmpty(cleaned) ? "graph" : cleaned;
        }
    }

    private static string FormatNumber(double value) =>
        value == Math.Round(value) && Math.Abs(value) < 1e15
            ? ((long)value).ToString(CultureInfo.InvariantCulture)
            : value.ToString("R", CultureInfo.InvariantCulture);
}
