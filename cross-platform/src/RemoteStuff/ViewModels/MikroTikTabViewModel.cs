using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>One entry row shown in the WinBox-style config explorer.</summary>
public sealed class MtEntryRow
{
    public string Id { get; init; } = "";
    public string Title { get; init; } = "";
    public string Summary { get; init; } = "";
    public bool Disabled { get; init; }
    public string StatusGlyph => Disabled ? "○" : "●";
    public IReadOnlyDictionary<string, string> Fields { get; init; } = new Dictionary<string, string>();
}

/// <summary>One editable field in the add/edit form, bound to an input row.</summary>
public sealed partial class MtFieldEntry : ObservableObject
{
    public string Key { get; }
    public string Label { get; }
    public bool IsBool { get; }
    public string Placeholder { get; }
    public IReadOnlyList<string> Choices { get; }
    public bool HasChoices => Choices.Count > 0;
    public bool IsPlainText => !IsBool && !HasChoices;

    [ObservableProperty] private string _value = "";
    [ObservableProperty] private bool _boolValue;

    public MtFieldEntry(MtField field, string? current)
    {
        Key = field.Key;
        Label = field.Label;
        IsBool = field.Kind == MtField.FieldKind.Bool;
        Placeholder = field.Placeholder;
        Choices = field.Choices;
        if (IsBool) _boolValue = current is "true" or "yes";
        else _value = current ?? "";
    }

    public MtFieldEntry(string key, string label, string? current)
    {
        Key = key;
        Label = label;
        IsBool = false;
        Placeholder = "";
        Choices = Array.Empty<string>();
        _value = current ?? "";
    }

    public string Serialized => IsBool ? (BoolValue ? "yes" : "no") : Value.Trim();
}

/// <summary>
/// A MikroTik RouterOS explorer tab. Manages saved routers (persisted, with
/// passwords in the shared secret store), discovers routers on the LAN via MNDP,
/// and provides a WinBox-style config explorer plus resource / interface / lease
/// views and export / apply-script / reboot actions.
/// </summary>
public sealed partial class MikroTikTabViewModel : TabViewModel
{
    public override string Glyph => "router";

    public override (string Host, int Port)? ConnectionEndpoint =>
        string.IsNullOrWhiteSpace(Host) ? null : (Host.Trim(), Port);

    public override RemoteStuff.Services.TabSnapshot? CreateSnapshot() =>
        new RemoteStuff.Services.TabSnapshot { Kind = "mikrotik", Title = Title };

    private readonly MikroTikRouterStore? _store;
    private MikroTikApi? _api;

    // ---- Live data ----
    public ObservableCollection<MtInterface> Interfaces { get; } = new();
    public ObservableCollection<MtAddress> Addresses { get; } = new();
    public ObservableCollection<MtLease> Leases { get; } = new();

    // ---- Saved routers & discovery ----
    public ObservableCollection<MikroTikRouter> SavedRouters { get; } = new();
    public ObservableCollection<DiscoveredRouter> Discovered { get; } = new();

    // ---- Config explorer ----
    public ObservableCollection<MtMenu> Menus { get; } = new(MtMenu.Catalog);
    public ObservableCollection<MtEntryRow> MenuEntries { get; } = new();
    public ObservableCollection<MtFieldEntry> EditFields { get; } = new();

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

    [ObservableProperty] private bool _includeSensitive;

    [ObservableProperty] private string _routerFileName = "config";

    [ObservableProperty] private bool _isDiscovering;
    public bool HasSavedRouters => SavedRouters.Count > 0;
    public bool HasDiscovered => Discovered.Count > 0;

    [ObservableProperty] private MikroTikRouter? _selectedRouter;
    [ObservableProperty] private MtMenu? _selectedMenu;
    [ObservableProperty] private string _menuStatus = "";

    // ---- Router add/edit form ----
    [ObservableProperty] private bool _isEditingRouter;
    [ObservableProperty] private string _editName = "";
    [ObservableProperty] private string _editHost = "";
    [ObservableProperty] private int _editPort = 443;
    [ObservableProperty] private string _editUser = "admin";
    [ObservableProperty] private string _editPassword = "";
    [ObservableProperty] private bool _editUseHttps = true;
    private Guid? _editingRouterId;

    // ---- Entry add/edit form ----
    [ObservableProperty] private bool _isEditingEntry;
    [ObservableProperty] private string _entryEditorTitle = "";
    private string? _editingEntryId;
    private MtMenu? _editingMenu;

    public bool CanUseRouter => IsConnected;

    public MikroTikTabViewModel(MikroTikRouterStore? store = null, MikroTikRouter? preset = null)
    {
        Title = "MikroTik";
        _store = store;
        ReloadSavedRouters();
        if (preset != null)
        {
            Host = preset.Host;
            Port = preset.Port;
            Username = preset.Username;
            UseHttps = preset.UseHttps;
        }
    }

    private void ReloadSavedRouters()
    {
        SavedRouters.Clear();
        if (_store is not null)
            foreach (var r in _store.Routers) SavedRouters.Add(r);
        OnPropertyChanged(nameof(HasSavedRouters));
    }

    private MikroTikRouter BuildRouter() => new()
    {
        Host = Host.Trim(),
        Port = Port,
        Username = Username.Trim(),
        UseHttps = UseHttps
    };

    // ------------------------------------------------------------------
    // Connecting
    // ------------------------------------------------------------------

    partial void OnSelectedRouterChanged(MikroTikRouter? value)
    {
        if (value is null) return;
        Host = value.Host;
        Port = value.Port;
        Username = value.Username;
        UseHttps = value.UseHttps;
        Password = _store?.Password(value.Id) ?? "";
        _ = ConnectAsync(value);
    }

    [RelayCommand]
    private Task Connect() => ConnectAsync(null);

    private async Task ConnectAsync(MikroTikRouter? saved)
    {
        if (string.IsNullOrWhiteSpace(Host)) { StatusText = "Enter a host or IP."; return; }
        IsBusy = true;
        StatusText = $"Connecting to {Host}…";
        try
        {
            _api?.Dispose();
            var router = saved is not null
                ? new MikroTikRouter { Id = saved.Id, Name = saved.Name, Host = Host.Trim(), Port = Port, Username = Username.Trim(), UseHttps = UseHttps }
                : BuildRouter();
            _api = new MikroTikApi(router, Password);
            await RefreshAsync();
            IsConnected = true;
            var label = !string.IsNullOrEmpty(saved?.Name) ? saved!.Name
                      : string.IsNullOrEmpty(Identity) ? Host : Identity;
            Title = "MikroTik · " + label;
            StatusText = "Connected";
            if (SelectedMenu is not null) await LoadMenuAsync(SelectedMenu);
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

    // ------------------------------------------------------------------
    // Saved-router CRUD
    // ------------------------------------------------------------------

    [RelayCommand]
    private void NewRouter()
    {
        _editingRouterId = null;
        EditName = "";
        EditHost = Host;
        EditPort = Port;
        EditUser = Username;
        EditPassword = "";
        EditUseHttps = UseHttps;
        IsEditingRouter = true;
    }

    [RelayCommand]
    private void EditRouter(MikroTikRouter? router)
    {
        router ??= SelectedRouter;
        if (router is null) return;
        _editingRouterId = router.Id;
        EditName = router.Name;
        EditHost = router.Host;
        EditPort = router.Port;
        EditUser = router.Username;
        EditPassword = _store?.Password(router.Id) ?? "";
        EditUseHttps = router.UseHttps;
        IsEditingRouter = true;
    }

    [RelayCommand]
    private void SaveRouter()
    {
        if (_store is null || string.IsNullOrWhiteSpace(EditHost))
        {
            StatusText = "Enter a host or IP.";
            return;
        }
        var router = new MikroTikRouter
        {
            Id = _editingRouterId ?? Guid.NewGuid(),
            Name = string.IsNullOrWhiteSpace(EditName) ? EditHost.Trim() : EditName.Trim(),
            Host = EditHost.Trim(),
            Port = EditPort,
            Username = string.IsNullOrWhiteSpace(EditUser) ? "admin" : EditUser.Trim(),
            UseHttps = EditUseHttps
        };
        if (_editingRouterId is null) _store.Add(router, EditPassword);
        else _store.Update(router, string.IsNullOrEmpty(EditPassword) ? null : EditPassword);
        ReloadSavedRouters();
        IsEditingRouter = false;
        SelectedRouter = SavedRouters.FirstOrDefault(r => r.Id == router.Id);
    }

    [RelayCommand]
    private void CancelRouterEdit() => IsEditingRouter = false;

    [RelayCommand]
    private void RemoveRouter(MikroTikRouter? router)
    {
        router ??= SelectedRouter;
        if (_store is null || router is null) return;
        _store.Remove(router.Id);
        if (SelectedRouter?.Id == router.Id) SelectedRouter = null;
        ReloadSavedRouters();
        StatusText = "Router removed";
    }

    // ------------------------------------------------------------------
    // Discovery (MNDP)
    // ------------------------------------------------------------------

    [RelayCommand]
    private async Task Discover()
    {
        if (IsDiscovering) return;
        IsDiscovering = true;
        StatusText = "Scanning the LAN for MikroTik devices…";
        try
        {
            var found = await MndpDiscovery.DiscoverAsync(3.0);
            var savedHosts = new HashSet<string>(SavedRouters.Select(r => r.Host), StringComparer.OrdinalIgnoreCase);
            Discovered.Clear();
            foreach (var d in found.Where(d => d.Ipv4 is null || !savedHosts.Contains(d.Ipv4)))
                Discovered.Add(d);
            OnPropertyChanged(nameof(HasDiscovered));
            StatusText = Discovered.Count > 0
                ? $"Found {Discovered.Count} device(s)"
                : "No new MikroTik devices found on the LAN";
        }
        catch (Exception ex) { StatusText = ex.Message; }
        finally { IsDiscovering = false; }
    }

    [RelayCommand]
    private void AddDiscovered(DiscoveredRouter? device)
    {
        if (_store is null || device?.Ipv4 is null) return;
        _editingRouterId = null;
        EditName = device.Identity ?? device.Board ?? device.Ipv4;
        EditHost = device.Ipv4;
        EditPort = 443;
        EditUser = "admin";
        EditPassword = "";
        EditUseHttps = true;
        IsEditingRouter = true;
    }

    // ------------------------------------------------------------------
    // Config explorer (WinBox-style)
    // ------------------------------------------------------------------

    partial void OnSelectedMenuChanged(MtMenu? value)
    {
        CancelEntryEdit();
        if (value is not null && _api is not null) _ = LoadMenuAsync(value);
        else MenuEntries.Clear();
    }

    private async Task LoadMenuAsync(MtMenu menu)
    {
        if (_api is null) return;
        IsBusy = true;
        MenuStatus = $"Loading {menu.Title}…";
        try
        {
            var rows = await _api.ListRawAsync(menu.Path);
            MenuEntries.Clear();
            foreach (var row in rows)
            {
                var fields = new Dictionary<string, string>();
                foreach (var kv in row)
                    if (kv.Key != ".id") fields[kv.Key] = ValueOf(kv.Value);
                var id = row.TryGetValue(".id", out var idv) ? ValueOf(idv) : "";
                var entry = new MtEntry(id, fields);
                MenuEntries.Add(new MtEntryRow
                {
                    Id = id,
                    Title = entry.TitleFor(menu.Columns),
                    Summary = string.Join("   ", menu.Columns
                        .Select(c => fields.TryGetValue(c, out var v) && v.Length > 0 ? $"{c}={v}" : null)
                        .Where(s => s is not null)!),
                    Disabled = entry.Disabled,
                    Fields = fields
                });
            }
            MenuStatus = $"{MenuEntries.Count} row(s) · /{menu.Path}";
        }
        catch (Exception ex) { MenuStatus = ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private async Task ReloadMenu()
    {
        if (SelectedMenu is not null) await LoadMenuAsync(SelectedMenu);
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private void AddEntry()
    {
        if (SelectedMenu is null || !SelectedMenu.Editable) return;
        _editingMenu = SelectedMenu;
        _editingEntryId = null;
        EditFields.Clear();
        foreach (var f in SelectedMenu.AddFields) EditFields.Add(new MtFieldEntry(f, null));
        EntryEditorTitle = $"Add to {SelectedMenu.Title}";
        IsEditingEntry = true;
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private void EditEntry(MtEntryRow? row)
    {
        if (SelectedMenu is null || row is null) return;
        _editingMenu = SelectedMenu;
        _editingEntryId = SelectedMenu.IsSingleton ? "" : row.Id;
        EditFields.Clear();
        // Show every field the router returned, so anything is editable.
        var seen = new HashSet<string>();
        foreach (var f in SelectedMenu.AddFields)
        {
            EditFields.Add(new MtFieldEntry(f, row.Fields.TryGetValue(f.Key, out var v) ? v : null));
            seen.Add(f.Key);
        }
        foreach (var kv in row.Fields.OrderBy(k => k.Key))
        {
            if (seen.Contains(kv.Key) || kv.Key is ".id") continue;
            EditFields.Add(new MtFieldEntry(kv.Key, kv.Key, kv.Value));
        }
        EntryEditorTitle = $"Edit {row.Title}";
        IsEditingEntry = true;
    }

    [RelayCommand]
    private async Task SaveEntry()
    {
        if (_api is null || _editingMenu is null) { IsEditingEntry = false; return; }
        var fields = new Dictionary<string, object>();
        foreach (var f in EditFields)
        {
            var val = f.Serialized;
            // Skip empty text fields on add so RouterOS uses its defaults.
            if (_editingEntryId is null && !f.IsBool && val.Length == 0) continue;
            fields[f.Key] = val;
        }
        IsBusy = true;
        try
        {
            if (_editingEntryId is null)
                await _api.AddEntryAsync(_editingMenu.Path, fields);
            else
                await _api.UpdateEntryAsync(_editingMenu.Path, _editingEntryId, fields);
            IsEditingEntry = false;
            await LoadMenuAsync(_editingMenu);
            MenuStatus = _editingEntryId is null ? "Entry added" : "Entry saved";
        }
        catch (Exception ex) { MenuStatus = ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand]
    private void CancelEntryEdit()
    {
        IsEditingEntry = false;
        EditFields.Clear();
        _editingEntryId = null;
        _editingMenu = null;
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private async Task ToggleEntry(MtEntryRow? row)
    {
        if (_api is null || SelectedMenu is null || row is null || string.IsNullOrEmpty(row.Id)) return;
        IsBusy = true;
        try
        {
            await _api.SetEntryDisabledAsync(SelectedMenu.Path, row.Id, !row.Disabled);
            await LoadMenuAsync(SelectedMenu);
        }
        catch (Exception ex) { MenuStatus = ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private async Task DeleteEntry(MtEntryRow? row)
    {
        if (_api is null || SelectedMenu is null || row is null || string.IsNullOrEmpty(row.Id)) return;
        IsBusy = true;
        try
        {
            await _api.RemoveEntryAsync(SelectedMenu.Path, row.Id);
            await LoadMenuAsync(SelectedMenu);
            MenuStatus = "Entry deleted";
        }
        catch (Exception ex) { MenuStatus = ex.Message; }
        finally { IsBusy = false; }
    }

    // ------------------------------------------------------------------
    // Interface / config actions
    // ------------------------------------------------------------------

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
        StatusText = IncludeSensitive ? "Exporting configuration (with secrets)…" : "Exporting configuration…";
        try
        {
            ConfigText = await _api.ExportConfigAsync(IncludeSensitive);
            StatusText = IncludeSensitive ? "Configuration exported (includes credentials)" : "Configuration exported";
        }
        catch (Exception ex) { StatusText = ex.Message; }
        finally { IsBusy = false; }
    }

    /// <summary>Raised when the user clicks "Save file…" — the view shows a save
    /// dialog and returns the chosen path, or null if cancelled.</summary>
    public event Func<string, Task<string?>>? SaveFileRequested;

    [RelayCommand]
    private async Task SaveConfigFile()
    {
        if (SaveFileRequested is null || string.IsNullOrWhiteSpace(ConfigText))
        {
            if (string.IsNullOrWhiteSpace(ConfigText)) StatusText = "Nothing to save — export first.";
            return;
        }
        var suggested = (SelectedRouter?.Name is { Length: > 0 } n
            ? new string(n.Select(c => char.IsLetterOrDigit(c) ? c : '-').ToArray())
            : "mikrotik") + ".rsc";
        try
        {
            var path = await SaveFileRequested.Invoke(suggested);
            if (path is null) return;
            await System.IO.File.WriteAllTextAsync(path, ConfigText);
            StatusText = "Saved " + System.IO.Path.GetFileName(path);
        }
        catch (Exception ex) { StatusText = "Save failed: " + ex.Message; }
    }

    [RelayCommand(CanExecute = nameof(CanUseRouter))]
    private async Task SaveConfigToRouter()
    {
        if (_api is null) return;
        var name = string.IsNullOrWhiteSpace(RouterFileName) ? "config" : RouterFileName.Trim();
        if (name.EndsWith(".rsc", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
        IsBusy = true;
        StatusText = $"Exporting {name}.rsc on the router…";
        try
        {
            await _api.ExportToRouterAsync(name, IncludeSensitive);
            StatusText = $"Saved {name}.rsc on the router" + (IncludeSensitive ? " (with credentials)" : "");
        }
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
