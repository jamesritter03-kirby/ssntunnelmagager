using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using RemoteStuff.Models;
using RemoteStuff.ViewModels;

namespace RemoteStuff.Services;

/// <summary>
/// Builds and maintains a system tray / menu-bar icon offering quick-connect
/// to profiles, plus show / quit actions.
/// </summary>
public sealed class TrayService : IDisposable
{
    private readonly Application _app;
    private readonly MainWindowViewModel _vm;
    private readonly IClassicDesktopStyleApplicationLifetime _desktop;
    private TrayIcon? _tray;
    private NativeMenu? _connectSub;
    private NativeMenu? _workspaceSub;

    /// <summary>Maps each Connect submenu item to its profile id, for live checkmarks.</summary>
    private readonly Dictionary<NativeMenuItem, Guid> _connectItemProfiles = new();

    public TrayService(Application app, MainWindowViewModel vm, IClassicDesktopStyleApplicationLifetime desktop)
    {
        _app = app;
        _vm = vm;
        _desktop = desktop;
    }

    public void Install()
    {
        _tray = new TrayIcon
        {
            Icon = MakeIcon(0),
            ToolTipText = "Remote Stuff CP",
            IsVisible = true
        };
        BuildMenu();
        _vm.Profiles.CollectionChanged += (_, _) => RebuildConnectItems();
        _vm.Workspaces.CollectionChanged += (_, _) => RebuildWorkspaceItems();
        _vm.ConnectionsChanged += UpdateConnectionState;

        var icons = new TrayIcons { _tray };
        TrayIcon.SetIcons(_app, icons);
    }

    /// <summary>
    /// Builds the static menu structure exactly once. The macOS native menu
    /// exporter tracks the assigned <see cref="NativeMenu"/> instance, so we must
    /// never replace it — only mutate the submenus' items in place.
    /// </summary>
    private void BuildMenu()
    {
        if (_tray is null) return;
        var menu = new NativeMenu();

        var show = new NativeMenuItem("Show Remote Stuff CP");
        show.Click += (_, _) => ShowWindow();
        menu.Add(show);
        menu.Add(new NativeMenuItemSeparator());

        var connect = new NativeMenuItem("Connect");
        _connectSub = new NativeMenu();
        connect.Menu = _connectSub;
        menu.Add(connect);

        var workspaces = new NativeMenuItem("Workspaces");
        _workspaceSub = new NativeMenu();
        workspaces.Menu = _workspaceSub;
        menu.Add(workspaces);

        var disconnectAll = new NativeMenuItem("Disconnect All");
        disconnectAll.Click += (_, _) => _vm.DisconnectAllCommand.Execute(null);
        menu.Add(disconnectAll);

        menu.Add(new NativeMenuItemSeparator());
        var quit = new NativeMenuItem("Quit");
        quit.Click += (_, _) => _desktop.Shutdown();
        menu.Add(quit);

        _tray.Menu = menu;
        RebuildConnectItems();
        RebuildWorkspaceItems();
    }

    private void RebuildConnectItems()
    {
        if (_connectSub is null) return;
        _connectSub.Items.Clear();
        _connectItemProfiles.Clear();
        foreach (var p in _vm.Profiles)
        {
            var profile = p;
            var item = new NativeMenuItem(profile.Name)
            {
                ToggleType = NativeMenuItemToggleType.CheckBox,
                IsChecked = _vm.IsProfileConnected(profile.Id)
            };
            item.Click += (_, _) =>
            {
                ShowWindow();
                _vm.OpenSession(profile);
            };
            _connectItemProfiles[item] = profile.Id;
            _connectSub.Items.Add(item);
        }
    }

    private void RebuildWorkspaceItems()
    {
        if (_workspaceSub is null) return;
        _workspaceSub.Items.Clear();
        foreach (var w in _vm.Workspaces)
        {
            var ws = w;
            var item = new NativeMenuItem(ws.Name)
            {
                ToggleType = NativeMenuItemToggleType.CheckBox,
                IsChecked = ws.IsCurrent
            };
            item.Click += (_, _) =>
            {
                ShowWindow();
                _vm.SelectWorkspace(ws);
                RebuildWorkspaceItems();
            };
            _workspaceSub.Items.Add(item);
        }
    }

    /// <summary>Refresh checkmarks, the tooltip and the count badge when sessions change.</summary>
    private void UpdateConnectionState()
    {
        foreach (var (item, id) in _connectItemProfiles)
            item.IsChecked = _vm.IsProfileConnected(id);

        if (_workspaceSub is not null)
            foreach (var item in _workspaceSub.Items.OfType<NativeMenuItem>())
                item.IsChecked = _vm.Workspaces.FirstOrDefault(w => w.Name == item.Header)?.IsCurrent ?? false;

        var count = _vm.LiveSessionCount;
        if (_tray is not null)
        {
            _tray.ToolTipText = count == 0 ? "Remote Stuff CP" : $"Remote Stuff CP — {count} connected";
            _tray.Icon = MakeIcon(count);
        }
    }

    private void ShowWindow()
    {
        if (_desktop.MainWindow is { } w)
        {
            w.Show();
            w.WindowState = WindowState.Normal;
            w.Activate();
        }
    }

    private static WindowIcon MakeIcon(int badge)
    {
        // Draw a simple 32×32 icon (accent square + "›_" glyph) at runtime so we
        // don't require a bundled asset file. When sessions are live, overlay a
        // small count badge in the top-right corner.
        var pixel = new PixelSize(32, 32);
        var dpi = new Vector(96, 96);
        var rtb = new RenderTargetBitmap(pixel, dpi);
        using (var ctx = rtb.CreateDrawingContext())
        {
            ctx.DrawRectangle(new SolidColorBrush(Color.FromRgb(0x0E, 0x63, 0x9C)), null,
                new Rect(0, 0, 32, 32), 6, 6);
            var text = new FormattedText("›_", System.Globalization.CultureInfo.InvariantCulture,
                FlowDirection.LeftToRight, Typeface.Default, 18, Brushes.White);
            ctx.DrawText(text, new Point(6, 4));

            if (badge > 0)
            {
                ctx.DrawEllipse(new SolidColorBrush(Color.FromRgb(0x3F, 0xB9, 0x50)), null,
                    new Point(24, 8), 8, 8);
                var label = badge > 9 ? "9+" : badge.ToString();
                var badgeText = new FormattedText(label, System.Globalization.CultureInfo.InvariantCulture,
                    FlowDirection.LeftToRight, Typeface.Default, badge > 9 ? 9 : 11, Brushes.White);
                ctx.DrawText(badgeText, new Point(24 - badgeText.Width / 2, 8 - badgeText.Height / 2));
            }
        }

        using var ms = new MemoryStream();
        rtb.Save(ms);
        ms.Position = 0;
        return new WindowIcon(ms);
    }

    public void Dispose() => _tray?.Dispose();
}
