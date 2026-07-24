using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Controls.Templates;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using RemoteStuff.Services;

namespace RemoteStuff.Views;

/// <summary>
/// A small globe button placed next to a host/IP field. Clicking it opens a
/// filterable list of your ZeroTier devices and their IP addresses; choosing an
/// IP writes it into <see cref="Text"/> (typically two-way bound to the field).
///
/// Built entirely in code so the flyout's controls live in this control's own
/// scope, avoiding XAML name-scope pitfalls with flyout content.
/// </summary>
public sealed class ZeroTierPicker : UserControl
{
    /// <summary>The chosen IP address. Bind this two-way to the host/IP field.</summary>
    public static readonly StyledProperty<string?> TextProperty =
        AvaloniaProperty.Register<ZeroTierPicker, string?>(
            nameof(Text), defaultBindingMode: Avalonia.Data.BindingMode.TwoWay);

    public string? Text
    {
        get => GetValue(TextProperty);
        set => SetValue(TextProperty, value);
    }

    private static readonly IBrush OnlineBrush = new SolidColorBrush(Color.Parse("#3FB950"));
    private static readonly IBrush OfflineBrush = new SolidColorBrush(Color.Parse("#484848"));
    private static readonly IBrush JoinedBrush = new SolidColorBrush(Color.Parse("#E3B341"));

    private readonly ObservableCollection<PickRow> _rows = new();
    private readonly List<PickRow> _all = new();

    private readonly TextBox _searchBox;
    private readonly CheckBox _onlineOnly;
    private readonly CheckBox _myNetworks;
    private readonly ProgressBar _busy;
    private readonly TextBlock _empty;
    private readonly Flyout _flyout;
    private bool _loadedOnce;

    public ZeroTierPicker()
    {
        _searchBox = new TextBox { Watermark = "Filter by name or IP" };
        _searchBox.TextChanged += (_, _) => ApplyFilter();

        _onlineOnly = new CheckBox { Content = "Online only", FontSize = 11 };
        _onlineOnly.IsCheckedChanged += (_, _) => ApplyFilter();

        _myNetworks = new CheckBox
        {
            Content = "My networks", FontSize = 11,
            [ToolTip.TipProperty] = "Only networks this computer has joined"
        };
        _myNetworks.IsCheckedChanged += (_, _) => ApplyFilter();

        var refreshBtn = new Button { Content = "⟳", FontSize = 11, Padding = new Thickness(6, 1) };
        ToolTip.SetTip(refreshBtn, "Refresh");
        refreshBtn.Click += (_, _) => _ = LoadAsync(force: true);

        _busy = new ProgressBar
        {
            IsIndeterminate = true, Width = 60, Height = 5,
            IsVisible = false, VerticalAlignment = VerticalAlignment.Center
        };

        _empty = new TextBlock
        {
            Text = "No devices with an IP found.",
            Foreground = new SolidColorBrush(Color.Parse("#888")),
            FontSize = 12, Margin = new Thickness(10, 8),
            TextWrapping = TextWrapping.Wrap, IsVisible = false
        };

        var list = new ItemsControl
        {
            ItemsSource = _rows,
            Margin = new Thickness(6, 0, 6, 8),
            ItemTemplate = new FuncDataTemplate<PickRow>((row, _) => BuildRow(row), supportsRecycling: false)
        };

        var controls = new WrapPanel { Orientation = Orientation.Horizontal };
        _onlineOnly.Margin = new Thickness(0, 0, 10, 2);
        _myNetworks.Margin = new Thickness(0, 0, 10, 2);
        refreshBtn.Margin = new Thickness(0, 0, 8, 2);
        controls.Children.Add(_onlineOnly);
        controls.Children.Add(_myNetworks);
        controls.Children.Add(refreshBtn);
        controls.Children.Add(_busy);

        var header = new StackPanel { Spacing = 6, Margin = new Thickness(8, 8, 8, 6) };
        header.Children.Add(new TextBlock { Text = "🌎 ZeroTier Devices", FontWeight = FontWeight.SemiBold });
        header.Children.Add(_searchBox);
        header.Children.Add(controls);

        var dock = new DockPanel { MaxHeight = 420 };
        DockPanel.SetDock(header, Dock.Top);
        DockPanel.SetDock(_empty, Dock.Bottom);
        dock.Children.Add(header);
        dock.Children.Add(_empty);
        dock.Children.Add(new ScrollViewer { Content = list });

        var body = new Border { Width = 320, Child = dock };

        _flyout = new Flyout
        {
            Content = body,
            Placement = PlacementMode.Bottom
        };
        _flyout.Opened += (_, _) => { if (!_loadedOnce) _ = LoadAsync(force: false); };

        var globe = new Button
        {
            Content = "🌎",
            FontSize = 14,
            Padding = new Thickness(6, 2),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Flyout = _flyout
        };
        ToolTip.SetTip(globe, "Pick an IP from your ZeroTier devices");

        Content = globe;
    }

    private Control BuildRow(PickRow row)
    {
        var dot = new Ellipse
        {
            Width = 8, Height = 8, Margin = new Thickness(0, 0, 8, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Fill = row.IsOnline ? OnlineBrush : OfflineBrush
        };

        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(new TextBlock { Text = row.Name, FontWeight = FontWeight.SemiBold, FontSize = 12 });
        texts.Children.Add(new TextBlock
        {
            Text = row.Ip,
            Foreground = new SolidColorBrush(Color.Parse("#9FD3A0")),
            FontFamily = new FontFamily("Menlo, Consolas, monospace"),
            FontSize = 11
        });
        var networkLine = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center
        };
        if (!string.IsNullOrEmpty(row.Network))
            networkLine.Children.Add(new TextBlock
            {
                Text = row.Network,
                Foreground = new SolidColorBrush(Color.Parse("#888")),
                FontSize = 10,
                VerticalAlignment = VerticalAlignment.Center
            });
        if (row.IsLocalMember)
            networkLine.Children.Add(BuildLocalBadge(row));
        if (networkLine.Children.Count > 0)
            texts.Children.Add(networkLine);

        var arrow = new TextBlock
        {
            Text = "➜",
            Foreground = new SolidColorBrush(Color.Parse("#7FB0DE")),
            VerticalAlignment = VerticalAlignment.Center
        };

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        Grid.SetColumn(dot, 0);
        Grid.SetColumn(texts, 1);
        Grid.SetColumn(arrow, 2);
        grid.Children.Add(dot);
        grid.Children.Add(texts);
        grid.Children.Add(arrow);

        var btn = new Button
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(6, 3),
            Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
            Content = grid,
            Tag = row.Ip
        };
        btn.Click += OnPickRow;
        return btn;
    }

    /// <summary>A small pill marking that this computer has joined the row's network.</summary>
    private static Control BuildLocalBadge(PickRow row)
    {
        var brush = row.IsLocalConnected ? OnlineBrush : JoinedBrush;
        var badge = new Border
        {
            Background = new SolidColorBrush(((SolidColorBrush)brush).Color, 0.18),
            BorderBrush = brush,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(3),
            Padding = new Thickness(4, 0),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = row.IsLocalConnected ? "● This PC" : "● This PC (joined)",
                Foreground = brush,
                FontSize = 9,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        ToolTip.SetTip(badge, row.IsLocalConnected
            ? "This computer is connected to this network"
            : "This computer has joined this network");
        return badge;
    }

    private async Task LoadAsync(bool force)
    {
        var svc = ZeroTierService.Shared;
        if (svc is null)
        {
            _all.Clear();
            ApplyFilter();
            return;
        }

        if (force || svc.Members.Count == 0)
        {
            _busy.IsVisible = true;
            try { await svc.RefreshAsync(); }
            catch { /* show whatever is cached */ }
            finally { _busy.IsVisible = false; }
        }

        _loadedOnce = true;
        Rebuild(svc);
    }

    private void Rebuild(ZeroTierService svc)
    {
        var networkNames = svc.Networks
            .GroupBy(n => n.Id)
            .ToDictionary(g => g.Key, g => g.First().DisplayName);

        _all.Clear();
        foreach (var m in svc.Members)
        {
            var localStatus = svc.LocalStatusFor(m.NetworkId);
            foreach (var ip in m.IpAssignments)
            {
                if (string.IsNullOrWhiteSpace(ip)) continue;
                _all.Add(new PickRow
                {
                    Name = m.DisplayName,
                    Ip = ip,
                    Network = networkNames.TryGetValue(m.NetworkId, out var nn) ? nn : m.NetworkId,
                    IsOnline = m.IsOnline,
                    LocalStatus = localStatus
                });
            }
        }

        _all.Sort((a, b) =>
        {
            if (a.IsLocalMember != b.IsLocalMember) return a.IsLocalMember ? -1 : 1;
            if (a.IsOnline != b.IsOnline) return a.IsOnline ? -1 : 1;
            return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
        });

        ApplyFilter();
    }

    private void ApplyFilter()
    {
        var needle = _searchBox.Text?.Trim() ?? "";
        var onlineOnly = _onlineOnly.IsChecked == true;
        var myNetworks = _myNetworks.IsChecked == true;

        _rows.Clear();
        foreach (var r in _all)
        {
            if (onlineOnly && !r.IsOnline) continue;
            if (myNetworks && !r.IsLocalMember) continue;
            if (needle.Length > 0 &&
                r.Name.IndexOf(needle, StringComparison.OrdinalIgnoreCase) < 0 &&
                r.Ip.IndexOf(needle, StringComparison.OrdinalIgnoreCase) < 0 &&
                r.Network.IndexOf(needle, StringComparison.OrdinalIgnoreCase) < 0)
                continue;
            _rows.Add(r);
        }

        _empty.IsVisible = _rows.Count == 0;
        _empty.Text = _all.Count == 0
            ? "No ZeroTier devices found. Add an account in the ZeroTier tab."
            : myNetworks
                ? "No devices on networks this computer has joined."
                : "No matching devices.";
    }

    private void OnPickRow(object? sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string ip } && !string.IsNullOrEmpty(ip))
        {
            Text = ip;
            _flyout.Hide();
        }
    }

    private sealed class PickRow
    {
        public string Name { get; init; } = "";
        public string Ip { get; init; } = "";
        public string Network { get; init; } = "";
        public bool IsOnline { get; init; }

        /// <summary>This computer's join status for the row's network (e.g. "OK"), or null.</summary>
        public string? LocalStatus { get; init; }
        public bool IsLocalMember => !string.IsNullOrEmpty(LocalStatus);
        public bool IsLocalConnected =>
            string.Equals(LocalStatus, "OK", StringComparison.OrdinalIgnoreCase);
    }
}
