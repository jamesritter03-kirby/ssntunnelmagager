using System.Threading.Tasks;
using System.Collections.Generic;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using RemoteStuff.Models;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Views;

/// <summary>A small modal setup sheet for opening a profile-free ("ad-hoc")
/// connection — the cross-platform counterpart of the macOS app's
/// "New Remote Terminal… / New SFTP Connection…" sheets. Collects host, port and
/// optional credentials, returning them or null on cancel.</summary>
public sealed class AdHocConnectionWindow : Window
{
    private readonly TextBox _host;
    private readonly TextBox _port;
    private readonly TextBox? _username;
    private readonly TextBox? _password;
    private readonly TextBox? _runOnConnect;
    private readonly StackPanel? _snippetRows;
    private readonly Panel? _snippetsSection;
    private readonly List<(TextBox label, TextBox command)> _snippets = new();
    private AdHocConnectionResult? _result;

    private AdHocConnectionWindow(AdHocConnectionKind kind, AdHocConnectionPrefill? prefill = null)
    {
        (string title, string blurb, int defaultPort, bool showCreds, string hint) = Describe(kind);
        var isEdit = prefill?.IsEdit == true;
        if (isEdit)
        {
            title = "Edit Connection Settings";
            blurb = "Change this tab's connection and reconnect it in place.";
        }
        // ssh tabs also carry a per-tab "run on connect" command.
        var showRunOnConnect = kind == AdHocConnectionKind.Ssh;

        Title = title;
        Width = 400;
        SizeToContent = SizeToContent.Height;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        CanResize = false;
        Background = new SolidColorBrush(Color.Parse("#1E1E1E"));

        _host = new TextBox { Watermark = "Host or IP address", Text = prefill?.Host ?? "" };
        _port = new TextBox { Text = (prefill?.Port ?? defaultPort).ToString(), Watermark = "Port" };

        // A globe button beside the host field to pick an IP from ZeroTier devices,
        // matching the profile editor and other host/IP fields.
        var picker = new ZeroTierPicker
        {
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(2, 0, 0, 0)
        };
        picker.PropertyChanged += (_, e) =>
        {
            if (e.Property == ZeroTierPicker.TextProperty
                && e.NewValue is string s && !string.IsNullOrEmpty(s))
                _host.Text = s;
        };
        var hostRow = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        Grid.SetColumn(_host, 0);
        Grid.SetColumn(picker, 1);
        hostRow.Children.Add(_host);
        hostRow.Children.Add(picker);

        var form = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*")
        };

        AddRow(form, 0, "Host", hostRow);
        AddRow(form, 1, "Port", _port);

        if (showCreds)
        {
            _username = new TextBox { Watermark = "Optional", Text = prefill?.Username ?? "" };
            _password = new TextBox { PasswordChar = '\u2022', Watermark = "Optional" };
            AddRow(form, 2, "Username", _username);
            AddRow(form, 3, "Password", _password);
        }

        if (showRunOnConnect)
        {
            _runOnConnect = new TextBox
            {
                Watermark = "e.g. tmux attach || tmux new",
                Text = prefill?.RunOnConnect ?? ""
            };
            AddRow(form, 4, "On connect", _runOnConnect);
        }

        foreach (var box in new[] { _host, _port, _username, _password, _runOnConnect })
        {
            if (box is null) continue;
            box.KeyDown += (_, e) =>
            {
                if (e.Key == Key.Enter) Accept();
                else if (e.Key == Key.Escape) Close();
            };
        }

        // ssh tabs can carry per-tab command snippets, editable here too (not just
        // in the full profile editor).
        if (kind == AdHocConnectionKind.Ssh)
        {
            _snippetRows = new StackPanel { Spacing = 0 };

            var caption = new TextBlock
            {
                Text = "Command snippets",
                FontWeight = FontWeight.SemiBold,
                VerticalAlignment = VerticalAlignment.Center
            };
            var addBtn = new Button { Content = "+ Add", Padding = new Thickness(10, 3) };
            addBtn.Click += (_, _) => AddSnippetRow("", "");
            var header = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
            Grid.SetColumn(caption, 0);
            Grid.SetColumn(addBtn, 1);
            header.Children.Add(caption);
            header.Children.Add(addBtn);

            var section = new StackPanel { Spacing = 6 };
            section.Children.Add(header);
            section.Children.Add(_snippetRows);
            _snippetsSection = section;

            if (prefill?.Snippets is { } existing)
                foreach (var s in existing) AddSnippetRow(s.Label, s.Command);
        }

        var ok = new Button { Content = isEdit ? "Save" : "Connect", Padding = new Thickness(16, 6), IsDefault = true };
        ok.Click += (_, _) => Accept();
        var cancel = new Button { Content = "Cancel", Padding = new Thickness(16, 6), IsCancel = true };
        cancel.Click += (_, _) => Close();

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Spacing = 8
        };
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);

        var root = new StackPanel { Margin = new Thickness(18), Spacing = 12 };
        root.Children.Add(new TextBlock { Text = title, FontWeight = FontWeight.Bold, FontSize = 15 });
        root.Children.Add(new TextBlock
        {
            Text = blurb,
            Foreground = new SolidColorBrush(Color.Parse("#AAAAAA")),
            TextWrapping = TextWrapping.Wrap
        });
        root.Children.Add(form);
        if (!string.IsNullOrEmpty(hint))
            root.Children.Add(new TextBlock
            {
                Text = hint,
                FontSize = 11,
                Foreground = new SolidColorBrush(Color.Parse("#888888")),
                TextWrapping = TextWrapping.Wrap
            });
        if (_snippetsSection is not null)
            root.Children.Add(_snippetsSection);
        root.Children.Add(buttons);
        Content = root;

        Opened += (_, _) => _host.Focus();
    }

    private void AddSnippetRow(string label, string command)
    {
        if (_snippetRows is null) return;
        var lbl = new TextBox { Watermark = "Label", Text = label, Width = 110 };
        var cmd = new TextBox { Watermark = "Command", Text = command, Margin = new Thickness(6, 0, 6, 0) };
        var remove = new Button
        {
            Content = "\u2715",
            Padding = new Thickness(8, 2),
            VerticalAlignment = VerticalAlignment.Center
        };
        var row = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"),
            Margin = new Thickness(0, 0, 0, 6)
        };
        Grid.SetColumn(lbl, 0);
        Grid.SetColumn(cmd, 1);
        Grid.SetColumn(remove, 2);
        row.Children.Add(lbl);
        row.Children.Add(cmd);
        row.Children.Add(remove);

        var entry = (lbl, cmd);
        _snippets.Add(entry);
        remove.Click += (_, _) =>
        {
            _snippetRows.Children.Remove(row);
            _snippets.Remove(entry);
        };
        _snippetRows.Children.Add(row);
    }

    private static void AddRow(Grid grid, int row, string label, Control field)
    {
        if (grid.RowDefinitions.Count <= row)
            grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));

        var text = new TextBlock
        {
            Text = label,
            VerticalAlignment = VerticalAlignment.Center,
            MinWidth = 68,
            Margin = new Thickness(0, 0, 10, 8)
        };
        field.Margin = new Thickness(0, 0, 0, 8);
        Grid.SetRow(text, row);
        Grid.SetColumn(text, 0);
        Grid.SetRow(field, row);
        Grid.SetColumn(field, 1);
        grid.Children.Add(text);
        grid.Children.Add(field);
    }

    private static (string title, string blurb, int port, bool creds, string hint) Describe(AdHocConnectionKind kind) => kind switch
    {
        AdHocConnectionKind.Ssh => ("New Remote Terminal",
            "Open an SSH terminal on a server without a saved profile.", 22, true,
            "Your SSH keys are tried first; a typed password is sent at the prompt but isn't saved."),
        AdHocConnectionKind.Sftp => ("New SFTP Connection",
            "Browse and transfer files over SFTP without a saved profile.", 22, true,
            "Your SSH keys are tried first; a typed password is sent but isn't saved."),
        AdHocConnectionKind.Vnc => ("New VNC Connection",
            "Point the built-in viewer directly at a VNC server (no SSH tunnel).", 5900, false,
            "The viewer will prompt for a password if the server requires one."),
        AdHocConnectionKind.Mqtt => ("New MQTT Connection",
            "Explore an MQTT broker without a saved profile.", 1883, true, ""),
        AdHocConnectionKind.Redis => ("New Redis Connection",
            "Browse a Redis database without a saved profile.", 6379, true, ""),
        _ => ("New Connection", "", 0, true, "")
    };

    private void Accept()
    {
        var host = (_host.Text ?? "").Trim();
        if (host.Length == 0) { _host.Focus(); return; }
        if (!int.TryParse((_port.Text ?? "").Trim(), out var port) || port <= 0 || port > 65535)
        {
            _port.Focus();
            _port.SelectAll();
            return;
        }
        _result = new AdHocConnectionResult(host, port, _username?.Text ?? "", _password?.Text ?? "",
            _runOnConnect?.Text ?? "", CollectSnippets());
        Close();
    }

    /// <summary>The snippet rows as a list (empty allowed) when the editor is shown
    /// (ssh), or null otherwise so non-ssh kinds never touch snippets.</summary>
    private List<CommandSnippet>? CollectSnippets()
    {
        if (_snippetsSection is null) return null;
        var list = new List<CommandSnippet>();
        foreach (var (lbl, cmd) in _snippets)
        {
            var l = (lbl.Text ?? "").Trim();
            var c = (cmd.Text ?? "").Trim();
            if (l.Length == 0 && c.Length == 0) continue;
            list.Add(new CommandSnippet { Label = l.Length == 0 ? c : l, Command = c });
        }
        return list;
    }

    public static async Task<AdHocConnectionResult?> ShowAsync(Window owner, AdHocConnectionKind kind,
        AdHocConnectionPrefill? prefill = null)
    {
        var dlg = new AdHocConnectionWindow(kind, prefill);
        await dlg.ShowDialog(owner);
        return dlg._result;
    }
}
