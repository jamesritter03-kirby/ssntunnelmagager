using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;

namespace RemoteStuff.ViewModels;

/// <summary>
/// A MikroTik RouterOS explorer tab: connects to a router's REST API and shows
/// system resource, interfaces, IP addresses and DHCP leases, with export /
/// apply-script / reboot actions and a generic menu explorer. Ported from the
/// macOS MikroTikStore (MNDP/ZeroTier discovery is not ported).
/// </summary>
public sealed partial class MikroTikTabViewModel : TabViewModel
{
    public override string Glyph => "📡";

    public override (string Host, int Port)? ConnectionEndpoint =>
        string.IsNullOrWhiteSpace(Host) ? null : (Host.Trim(), Port);

    public override RemoteStuff.Services.TabSnapshot? CreateSnapshot() =>
        new RemoteStuff.Services.TabSnapshot { Kind = "mikrotik", Title = Title };

    private MikroTikApi? _api;

    public ObservableCollection<MtInterface> Interfaces { get; } = new();
    public ObservableCollection<MtAddress> Addresses { get; } = new();
    public ObservableCollection<MtLease> Leases { get; } = new();
    public ObservableCollection<string> MenuRows { get; } = new();

    [ObservableProperty] private string _host = "";
    [ObservableProperty] private int _port = 443;
    [ObservableProperty] private string _username = "admin";
    [ObservableProperty] private string _password = "";
    [ObservableProperty] private bool _useHttps = true;

    [NotifyPropertyChangedFor(nameof(CanUseRouter))]
    [ObservableProperty] private bool _isConnected;
    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string _statusText = "Not connected";

    [ObservableProperty] private string _identity = "";
    [ObservableProperty] private string _boardName = "";
    [ObservableProperty] private string _version = "";
    [ObservableProperty] private string _uptime = "";
    [ObservableProperty] private string _cpuLoad = "";
    [ObservableProperty] private string _memory = "";

    [ObservableProperty] private string _configText = "";
    [ObservableProperty] private string _menuPath = "ip/firewall/filter";

    public bool CanUseRouter => IsConnected;

    public MikroTikTabViewModel(MikroTikRouter? preset = null)
    {
        Title = "MikroTik";
        if (preset != null)
        {
            Host = preset.Host;
            Port = preset.Port;
            Username = preset.Username;
            UseHttps = preset.UseHttps;
        }
    }

    private MikroTikRouter BuildRouter() => new()
    {
        Host = Host.Trim(),
        Port = Port,
        Username = Username.Trim(),
        UseHttps = UseHttps
    };

    [RelayCommand]
    private async Task Connect()
    {
        if (string.IsNullOrWhiteSpace(Host)) { StatusText = "Enter a host or IP."; return; }
        IsBusy = true;
        StatusText = $"Connecting to {Host}…";
        try
        {
            _api?.Dispose();
            _api = new MikroTikApi(BuildRouter(), Password);
            await RefreshAsync();
            IsConnected = true;
            Title = "MikroTik · " + (string.IsNullOrEmpty(Identity) ? Host : Identity);
            StatusText = "Connected";
        }
        catch (Exception ex)
        {
            IsConnected = false;
            StatusText = ex.Message;
        }
        finally { IsBusy = false; }
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private async Task Refresh()
    {
        if (_api is null) return;
        IsBusy = true;
        try { await RefreshAsync(); StatusText = "Refreshed"; }
        catch (Exception ex) { StatusText = ex.Message; }
        finally { IsBusy = false; }
    }

    private async Task RefreshAsync()
    {
        if (_api is null) return;
        var res = await _api.GetResourceAsync();
        Identity = res.Identity ?? "";
        BoardName = res.BoardName ?? "";
        Version = res.Version ?? "";
        Uptime = res.Uptime ?? "";
        CpuLoad = res.CpuLoad.HasValue ? res.CpuLoad + "%" : "";
        Memory = res.MemoryUsedPercent.HasValue ? res.MemoryUsedPercent + "% used" : "";

        Interfaces.Clear();
        foreach (var i in await _api.GetInterfacesAsync()) Interfaces.Add(i);
        Addresses.Clear();
        foreach (var a in await _api.GetAddressesAsync()) Addresses.Add(a);
        Leases.Clear();
        foreach (var l in await _api.GetLeasesAsync()) Leases.Add(l);
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private async Task ToggleInterface(MtInterface? iface)
    {
        if (_api is null || iface is null) return;
        IsBusy = true;
        try
        {
            await _api.SetInterfaceDisabledAsync(iface.Id, !iface.Disabled);
            await RefreshAsync();
            StatusText = (iface.Disabled ? "Enabled " : "Disabled ") + iface.Name;
        }
        catch (Exception ex) { StatusText = ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private async Task ExportConfig()
    {
        if (_api is null) return;
        IsBusy = true;
        StatusText = "Exporting configuration…";
        try { ConfigText = await _api.ExportConfigAsync(); StatusText = "Configuration exported"; }
        catch (Exception ex) { StatusText = ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private async Task ApplyConfig()
    {
        if (_api is null || string.IsNullOrWhiteSpace(ConfigText)) return;
        IsBusy = true;
        StatusText = "Applying script…";
        try { await _api.ApplyConfigAsync(ConfigText); await RefreshAsync(); StatusText = "Script applied"; }
        catch (Exception ex) { StatusText = ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private async Task Reboot()
    {
        if (_api is null) return;
        IsBusy = true;
        try { await _api.RebootAsync(); StatusText = "Reboot requested"; IsConnected = false; }
        catch (Exception ex) { StatusText = ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private async Task ListMenu()
    {
        if (_api is null || string.IsNullOrWhiteSpace(MenuPath)) return;
        IsBusy = true;
        StatusText = $"Listing /{MenuPath}…";
        try
        {
            var rows = await _api.ListRawAsync(MenuPath.Trim());
            MenuRows.Clear();
            foreach (var row in rows) MenuRows.Add(FormatRow(row));
            StatusText = $"{rows.Count} row(s) in /{MenuPath}";
        }
        catch (Exception ex) { StatusText = ex.Message; }
        finally { IsBusy = false; }
    }

    private static string FormatRow(Dictionary<string, JsonElement> row) =>
        string.Join("  ", row.Where(kv => kv.Key != ".id")
            .Select(kv => $"{kv.Key}={ValueOf(kv.Value)}"));

    private static string ValueOf(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.String => e.GetString() ?? "",
        _ => e.ToString()
    };

    public override void Dispose()
    {
        _api?.Dispose();
        base.Dispose();
    }
}
