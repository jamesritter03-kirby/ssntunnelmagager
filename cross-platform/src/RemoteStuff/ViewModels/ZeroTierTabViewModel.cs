using System;
using System.Collections.ObjectModel;
using System.Threading.Tasks;
using Avalonia.Threading;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>A connection type that can be opened against a ZeroTier device.</summary>
public enum ZtDeviceAction
{
    SshTerminal,
    Sftp,
    Vnc,
    Mqtt,
    Redis,
    NewProfile,
}

/// <summary>One device row inside a ZeroTier network.</summary>
public sealed partial class ZtMemberRowViewModel : ObservableObject
{
    private readonly ZeroTierService _service;
    private readonly ZeroTierTabViewModel _owner;
    public ZeroTierMember Member { get; }

    public ZtMemberRowViewModel(ZeroTierMember member, ZeroTierService service, ZeroTierTabViewModel owner)
    {
        Member = member;
        _service = service;
        _owner = owner;
        _authorized = member.Authorized;
    }

    public string Name => Member.DisplayName;
    public string Ip => Member.PrimaryIp;
    public string NodeId => Member.NodeId;
    public bool IsOnline => Member.IsOnline;
    public string StatusText => Member.IsOnline ? "online" : "offline";

    [ObservableProperty] private bool _authorized;
    [ObservableProperty] private bool _authBusy;

    /// <summary>A high-contrast status glyph: ✓ (authorized) or ✕ (not) — honours Foreground.</summary>
    public string LockGlyph => Authorized ? "\u2714" : "\u2718";

    /// <summary>Short badge label shown beside the glyph.</summary>
    public string AuthLabel => Authorized ? "Authorized" : "Blocked";

    public string AuthTooltip => Authorized
        ? "Authorized on this network (change from the ⚙ menu)"
        : "Not authorized (authorize from the ⚙ menu)";

    public Avalonia.Media.IBrush LockBrush => Authorized
        ? new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#3FB950"))
        : new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#F85149"));

    /// <summary>Subtle tinted pill background behind the badge.</summary>
    public Avalonia.Media.IBrush AuthBadgeBackground => Authorized
        ? new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#1F3FB950"))
        : new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#1FF85149"));

    partial void OnAuthorizedChanged(bool value)
    {
        OnPropertyChanged(nameof(LockGlyph));
        OnPropertyChanged(nameof(AuthLabel));
        OnPropertyChanged(nameof(AuthTooltip));
        OnPropertyChanged(nameof(LockBrush));
        OnPropertyChanged(nameof(AuthBadgeBackground));
    }

    /// <summary>Flip authorization via the controller, reverting and reporting on failure.</summary>
    [RelayCommand]
    private async Task ToggleAuthorized()
    {
        if (AuthBusy) return;
        var target = !Authorized;
        AuthBusy = true;
        try
        {
            await _service.SetAuthorizedAsync(Member, target);
            Authorized = target;
            _owner.SetStatus(target ? $"Authorized {Name}." : $"Deauthorized {Name}.");
        }
        catch (Exception ex)
        {
            _owner.SetStatus($"Couldn't change authorization for {Name}: {ex.Message}");
        }
        finally
        {
            AuthBusy = false;
        }
    }

    [RelayCommand]
    private async Task CopyNodeId()
    {
        if (!string.IsNullOrEmpty(NodeId) && DialogService.Top?.Clipboard is { } cb)
        {
            await cb.SetTextAsync(NodeId);
            _owner.SetStatus($"Copied node ID {NodeId}.");
        }
    }

    /// <summary>Prompt for and apply a new description on the ZeroTier controller.</summary>
    [RelayCommand]
    private async Task SetDescription()
    {
        var text = await DialogService.PromptTextAsync(
            "Set Description", $"Description for {Name}:", Member.Description ?? "");
        if (text is null) return; // cancelled
        try
        {
            await _service.SetDescriptionAsync(Member, text);
            _owner.SetStatus($"Updated description for {Name}.");
        }
        catch (Exception ex)
        {
            _owner.SetStatus($"Couldn't set description for {Name}: {ex.Message}");
        }
    }

    [RelayCommand]
    private async Task CopyIp()
    {
        if (!string.IsNullOrEmpty(Ip) && DialogService.Top?.Clipboard is { } cb)
            await cb.SetTextAsync(Ip);
    }

    [RelayCommand]
    private void OpenSsh() => _owner.RequestDeviceAction(ZtDeviceAction.SshTerminal, Name, Ip);

    [RelayCommand]
    private void OpenSftp() => _owner.RequestDeviceAction(ZtDeviceAction.Sftp, Name, Ip);

    [RelayCommand]
    private void OpenVnc() => _owner.RequestDeviceAction(ZtDeviceAction.Vnc, Name, Ip);

    [RelayCommand]
    private void OpenMqtt() => _owner.RequestDeviceAction(ZtDeviceAction.Mqtt, Name, Ip);

    [RelayCommand]
    private void OpenRedis() => _owner.RequestDeviceAction(ZtDeviceAction.Redis, Name, Ip);

    [RelayCommand]
    private void NewProfile() => _owner.RequestDeviceAction(ZtDeviceAction.NewProfile, Name, Ip);
}

/// <summary>One network section with its member rows.</summary>
public sealed partial class ZtNetworkRowViewModel : ObservableObject
{
    public ZeroTierNetwork Network { get; }
    public ObservableCollection<ZtMemberRowViewModel> Members { get; } = new();

    /// <summary>This device's live join status for the network (e.g. "OK"), or null.</summary>
    public string? LocalStatus { get; }

    public ZtNetworkRowViewModel(ZeroTierNetwork network, string? localStatus)
    {
        Network = network;
        LocalStatus = localStatus;
    }

    public string Name => Network.DisplayName;
    public string Id => Network.Id;
    public string DeviceCountText => $"{Members.Count} devices";

    // ---- This device's connection to the network ----

    public bool IsLocallyJoined => !string.IsNullOrEmpty(LocalStatus);
    public bool IsLocallyConnected =>
        string.Equals(LocalStatus, "OK", StringComparison.OrdinalIgnoreCase);

    public string LocalStatusText => IsLocallyConnected
        ? "This device connected"
        : IsLocallyJoined ? FriendlyStatus(LocalStatus!) : "Not joined on this device";

    public Avalonia.Media.IBrush LocalStatusBrush => IsLocallyConnected
        ? new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#3FB950"))
        : IsLocallyJoined
            ? new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#E3B341"))
            : new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.Parse("#666666"));

    private static string FriendlyStatus(string status) => status.ToUpperInvariant() switch
    {
        "OK" => "Connected",
        "ACCESS_DENIED" => "Access denied",
        "REQUESTING_CONFIGURATION" => "Requesting configuration",
        "NOT_FOUND" => "Network not found",
        "PORT_ERROR" => "Port error",
        "CLIENT_TOO_OLD" => "Client too old",
        "" => "Unknown",
        _ => status,
    };

    [ObservableProperty] private bool _isExpanded = true;

    public string ChevronGlyph => IsExpanded ? "\u25BE" : "\u25B8";

    partial void OnIsExpandedChanged(bool value) => OnPropertyChanged(nameof(ChevronGlyph));

    [RelayCommand]
    private void ToggleCollapse() => IsExpanded = !IsExpanded;

    [RelayCommand]
    private async Task CopyId()
    {
        if (!string.IsNullOrEmpty(Id) && DialogService.Top?.Clipboard is { } cb)
            await cb.SetTextAsync(Id);
    }
}

/// <summary>A ZeroTier account with the networks that belong to it.</summary>
public sealed partial class ZtAccountGroupViewModel : ObservableObject
{
    public ZeroTierAccount Account { get; }
    public ObservableCollection<ZtNetworkRowViewModel> Networks { get; } = new();

    public ZtAccountGroupViewModel(ZeroTierAccount account) => Account = account;

    public string Name => Account.DisplayLabel;
    public string Server => Account.ServerDisplay;
    public string Subtitle => $"{Account.ServerDisplay}  ·  {Networks.Count} networks";

    [ObservableProperty] private bool _isExpanded = true;

    public string ChevronGlyph => IsExpanded ? "\u25BE" : "\u25B8";

    partial void OnIsExpandedChanged(bool value) => OnPropertyChanged(nameof(ChevronGlyph));

    [RelayCommand]
    private void ToggleCollapse() => IsExpanded = !IsExpanded;
}

public sealed partial class ZeroTierTabViewModel : TabViewModel
{
    private readonly ZeroTierService _service;

    public override string Glyph => "\U0001F310";

    public ObservableCollection<ZtAccountGroupViewModel> AccountGroups { get; } = new();
    public ObservableCollection<ZeroTierAccount> Accounts { get; } = new();

    [ObservableProperty] private bool _isBusy;
    [ObservableProperty] private string _statusText = "";
    [ObservableProperty] private string _newLabel = "";
    [ObservableProperty] private string _newBaseUrl = ZeroTierAccount.CentralBaseUrl;
    [ObservableProperty] private string _newToken = "";

    /// <summary>Free-text filter over networks and devices (name, IP, or node ID).</summary>
    [ObservableProperty] private string _filterText = "";

    partial void OnFilterTextChanged(string value) => Rebuild();

    /// <summary>When true, only online devices are shown.</summary>
    [ObservableProperty] private bool _showOnlineOnly;

    partial void OnShowOnlineOnlyChanged(bool value)
    {
        Rebuild();
        if (_settings is { } s && s.ZeroTierShowOnlineOnly != value)
        {
            s.ZeroTierShowOnlineOnly = value;
            s.Save();
        }
    }

    /// <summary>When true, only networks this device has joined are shown.</summary>
    [ObservableProperty] private bool _showMemberOfOnly;

    partial void OnShowMemberOfOnlyChanged(bool value)
    {
        Rebuild();
        if (_settings is { } s && s.ZeroTierShowMemberOfOnly != value)
        {
            s.ZeroTierShowMemberOfOnly = value;
            s.Save();
        }
    }

    public bool HasAccounts => Accounts.Count > 0;

    /// <summary>The "Connect as" username used for one-click device connections,
    /// persisted across launches via <see cref="AppSettings"/>.</summary>
    [ObservableProperty] private string _connectUsername = "";

    /// <summary>Optional password sent when connecting to a device, remembered
    /// (encrypted) in the <see cref="SecretStore"/> across launches.</summary>
    [ObservableProperty] private string _connectPassword = "";
    /// <summary>When true, the password field shows its characters.</summary>
    [ObservableProperty] private bool _showPassword;

    public char PasswordChar => ShowPassword ? '\0' : '\u2022';

    partial void OnShowPasswordChanged(bool value) => OnPropertyChanged(nameof(PasswordChar));

    partial void OnConnectUsernameChanged(string value)
    {
        if (_settings is { } s && s.ZeroTierConnectUsername != value)
        {
            s.ZeroTierConnectUsername = value;
            s.Save();
        }
    }

    partial void OnConnectPasswordChanged(string value)
        => _service.SetConnectPassword(string.IsNullOrEmpty(value) ? null : value);

    /// <summary>Raised to prefill a new SSH profile from a device: (name, host).</summary>
    public event Action<string, string>? NewProfileRequested;

    /// <summary>Raised to open a connection to a device: (action, name, host, username, password).</summary>
    public event Action<ZtDeviceAction, string, string, string, string>? DeviceActionRequested;

    public void RequestDeviceAction(ZtDeviceAction action, string name, string host)
    {
        var user = ConnectUsername?.Trim() ?? "";
        var pass = ConnectPassword ?? "";
        if (action == ZtDeviceAction.NewProfile)
            NewProfileRequested?.Invoke(name, host);
        DeviceActionRequested?.Invoke(action, name, host, user, pass);
    }

    /// <summary>Surface a transient message in the ZeroTier status bar (used by device rows).</summary>
    public void SetStatus(string message) => StatusText = message;

    private readonly AppSettings? _settings;
    private readonly System.Timers.Timer _refreshTimer;

    public ZeroTierTabViewModel(ZeroTierService service, AppSettings? settings = null)
    {
        _service = service;
        _settings = settings;
        _showOnlineOnly = settings?.ZeroTierShowOnlineOnly ?? false;
        _showMemberOfOnly = settings?.ZeroTierShowMemberOfOnly ?? false;
        _connectUsername = string.IsNullOrWhiteSpace(settings?.ZeroTierConnectUsername)
            ? Environment.UserName
            : settings!.ZeroTierConnectUsername;
        _connectPassword = service.GetConnectPassword() ?? "";
        Title = "ZeroTier";
        _service.Updated += OnServiceUpdated;
        ReloadAccounts();
        _ = Refresh();

        // Periodically refresh device/network status so the panel stays current
        // without a manual reload.
        _refreshTimer = new System.Timers.Timer(30_000) { AutoReset = true };
        _refreshTimer.Elapsed += (_, _) => Dispatcher.UIThread.Post(async () =>
        {
            if (!IsBusy) await Refresh();
        });
        _refreshTimer.Start();
    }

    private void OnServiceUpdated() => Dispatcher.UIThread.Post(Rebuild);

    private void ReloadAccounts()
    {
        Accounts.Clear();
        foreach (var a in _service.Accounts)
            Accounts.Add(a);
        OnPropertyChanged(nameof(HasAccounts));
    }

    private void Rebuild()
    {
        var filter = FilterText?.Trim() ?? "";
        bool filtering = filter.Length > 0;
        bool onlineOnly = ShowOnlineOnly;
        bool memberOfOnly = ShowMemberOfOnly;
        bool anyFilter = filtering || onlineOnly || memberOfOnly;

        AccountGroups.Clear();
        int networkCount = 0;
        foreach (var account in _service.Accounts)
        {
            var group = new ZtAccountGroupViewModel(account);
            foreach (var n in _service.Networks)
            {
                if (n.AccountId != account.Id) continue;

                bool networkMatches = !filtering || Contains(n.DisplayName, filter) || Contains(n.Id, filter);
                var row = new ZtNetworkRowViewModel(n, _service.LocalStatusFor(n.Id));

                // Member-of filter: only keep networks this device has joined.
                if (memberOfOnly && !row.IsLocallyJoined)
                    continue;

                foreach (var m in _service.MembersOf(n))
                {
                    if (onlineOnly && !m.IsOnline)
                        continue;
                    if (filtering && !networkMatches &&
                        !Contains(m.DisplayName, filter) && !Contains(m.PrimaryIp, filter) &&
                        !Contains(m.NodeId, filter))
                        continue;
                    row.Members.Add(new ZtMemberRowViewModel(m, _service, this));
                }

                // With any filter active, keep a network only if it still has visible
                // devices, its own name/id matched, or it qualifies for the member-of
                // filter (this device has joined it).
                bool keep = !anyFilter
                    || row.Members.Count > 0
                    || (networkMatches && !onlineOnly)
                    || (memberOfOnly && !onlineOnly && !filtering);
                if (!keep) continue;

                if (anyFilter)
                    row.IsExpanded = true;
                group.Networks.Add(row);
                networkCount++;
            }

            // With any filter active, hide accounts that have no visible networks.
            if (anyFilter && group.Networks.Count == 0)
                continue;
            if (anyFilter)
                group.IsExpanded = true;
            AccountGroups.Add(group);
        }

        if (!_service.HasAccounts)
            StatusText = "Add a ZeroTier account to begin.";
        else if (filtering)
            StatusText = $"{networkCount} networks match “{filter}”";
        else if (onlineOnly)
            StatusText = $"{networkCount} networks with online devices";
        else if (memberOfOnly)
            StatusText = $"{networkCount} networks joined on this device";
        else
            StatusText = $"{AccountGroups.Count} accounts · {networkCount} networks";
        OnPropertyChanged(nameof(HasNetworks));
    }

    private static bool Contains(string? text, string filter) =>
        !string.IsNullOrEmpty(text) &&
        text.Contains(filter, StringComparison.OrdinalIgnoreCase);

    /// <summary>True when there is at least one network to expand/collapse.</summary>
    public bool HasNetworks
    {
        get
        {
            foreach (var g in AccountGroups)
                if (g.Networks.Count > 0) return true;
            return false;
        }
    }

    [RelayCommand]
    private void ExpandAll() => SetAllExpanded(true);

    [RelayCommand]
    private void CollapseAll() => SetAllExpanded(false);

    [RelayCommand]
    private void ClearFilter() => FilterText = "";

    private void SetAllExpanded(bool expanded)
    {
        foreach (var g in AccountGroups)
        {
            g.IsExpanded = expanded;
            foreach (var n in g.Networks)
                n.IsExpanded = expanded;
        }
    }

    [RelayCommand]
    private async Task Refresh()
    {
        if (!_service.HasAccounts) { Rebuild(); return; }
        IsBusy = true;
        StatusText = "Loading…";
        try { await _service.RefreshAsync(); }
        catch (Exception ex) { StatusText = "Error: " + ex.Message; }
        finally { IsBusy = false; }
    }

    [RelayCommand]
    private async Task AddAccount()
    {
        if (string.IsNullOrWhiteSpace(NewToken))
        {
            StatusText = "Enter an API token.";
            return;
        }
        var label = string.IsNullOrWhiteSpace(NewLabel) ? "ZeroTier" : NewLabel.Trim();
        _service.AddAccount(label, NewBaseUrl, NewToken.Trim());
        NewLabel = "";
        NewToken = "";
        NewBaseUrl = ZeroTierAccount.CentralBaseUrl;
        ReloadAccounts();
        await Refresh();
    }

    [RelayCommand]
    private async Task RemoveAccount(ZeroTierAccount? account)
    {
        if (account is null) return;
        _service.RemoveAccount(account.Id);
        ReloadAccounts();
        await Refresh();
    }

    public override void Dispose()
    {
        _refreshTimer.Stop();
        _refreshTimer.Dispose();
        _service.Updated -= OnServiceUpdated;
        base.Dispose();
    }
}
