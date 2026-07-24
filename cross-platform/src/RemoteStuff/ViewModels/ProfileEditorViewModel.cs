using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>Editable wrapper around one <see cref="PortForward"/> row.</summary>
public sealed partial class ForwardRowViewModel : ObservableObject
{
    public Guid Id { get; }
    [ObservableProperty] private ForwardType _type;
    [ObservableProperty] private ForwardCategory _category;
    [ObservableProperty] private string _bindAddress;
    [ObservableProperty] private string _listenPort;
    [ObservableProperty] private string _targetHost;
    [ObservableProperty] private string _targetPort;
    [ObservableProperty] private string _name;
    [ObservableProperty] private string _serviceUsername;

    public IReadOnlyList<ForwardType> ForwardTypes { get; } = Enum.GetValues<ForwardType>();
    public IReadOnlyList<ForwardCategory> Categories { get; } = Enum.GetValues<ForwardCategory>();

    public ForwardRowViewModel(PortForward f)
    {
        Id = f.Id;
        _type = f.Type;
        _category = f.Category;
        _bindAddress = f.BindAddress;
        _listenPort = f.ListenPort;
        _targetHost = f.TargetHost;
        _targetPort = f.TargetPort;
        _name = f.Name;
        _serviceUsername = f.ServiceUsername;
        _servicePassword = f.PendingServicePassword ?? "";
    }

    /// <summary>Password typed for this service (blank = unchanged / none).</summary>
    [ObservableProperty] private string _servicePassword;

    public PortForward ToModel() => new()
    {
        Id = Id,
        Type = Type,
        Category = Category,
        BindAddress = BindAddress?.Trim() ?? "",
        ListenPort = ListenPort?.Trim() ?? "",
        TargetHost = string.IsNullOrWhiteSpace(TargetHost) ? "localhost" : TargetHost.Trim(),
        TargetPort = TargetPort?.Trim() ?? "",
        Name = Name?.Trim() ?? "",
        ServiceUsername = ServiceUsername?.Trim() ?? "",
        PendingServicePassword = string.IsNullOrEmpty(ServicePassword) ? null : ServicePassword
    };
}

/// <summary>Editable wrapper around one <see cref="EnvVar"/> row.</summary>
public sealed partial class EnvVarRowViewModel : ObservableObject
{
    public Guid Id { get; }
    [ObservableProperty] private string _name;
    [ObservableProperty] private string _value;

    public EnvVarRowViewModel(EnvVar e)
    {
        Id = e.Id;
        _name = e.Name;
        _value = e.Value;
    }

    public EnvVar ToModel() => new()
    {
        Id = Id,
        Name = Name?.Trim() ?? "",
        Value = Value?.Trim() ?? ""
    };
}

/// <summary>Editable wrapper around one <see cref="ProfileLink"/> row.</summary>
public sealed partial class LinkRowViewModel : ObservableObject
{
    public Guid Id { get; }
    [ObservableProperty] private string _label;
    [ObservableProperty] private string _url;

    public LinkRowViewModel(ProfileLink l)
    {
        Id = l.Id;
        _label = l.Label;
        _url = l.Url;
    }

    public ProfileLink ToModel() => new()
    {
        Id = Id,
        Label = string.IsNullOrWhiteSpace(Label) ? Url?.Trim() ?? "" : Label.Trim(),
        Url = Url?.Trim() ?? ""
    };
}

/// <summary>Editable wrapper around one <see cref="CommandSnippet"/> row.</summary>
public sealed partial class SnippetRowViewModel : ObservableObject
{
    public Guid Id { get; }
    [ObservableProperty] private string _label;
    [ObservableProperty] private string _command;

    public SnippetRowViewModel(CommandSnippet s)
    {
        Id = s.Id;
        _label = s.Label;
        _command = s.Command;
    }

    public CommandSnippet ToModel() => new()
    {
        Id = Id,
        Label = string.IsNullOrWhiteSpace(Label) ? Command?.Trim() ?? "" : Label.Trim(),
        Command = Command?.Trim() ?? ""
    };
}

public sealed partial class ProfileEditorViewModel : ViewModelBase
{
    private readonly SshProfile _original;
    private readonly Action<SshProfile, bool> _onSave;

    public bool IsNew { get; }
    public string WindowTitle => IsNew ? "New Profile" : "Edit Profile";

    public event Action? CloseRequested;

    // ---- Fields ----
    [ObservableProperty] private string _name;
    [ObservableProperty] private bool _isLocal;
    [ObservableProperty] private string _startPath;
    [ObservableProperty] private string _host;
    [ObservableProperty] private string _port;
    [ObservableProperty] private string _username;
    [ObservableProperty] private string _identityFile;
    [ObservableProperty] private string _jumpHost;
    [ObservableProperty] private bool _openShell;
    [ObservableProperty] private bool _compression;
    [ObservableProperty] private bool _keepAlive;
    [ObservableProperty] private bool _verbose;
    [ObservableProperty] private bool _forwardAgent;
    [ObservableProperty] private bool _addKeysToAgent;
    [ObservableProperty] private bool _requestTty;
    [ObservableProperty] private string _connectTimeout;
    [ObservableProperty] private StrictHostKeyChecking _strictHostKeyChecking;
    [ObservableProperty] private string _remoteCommand;
    [ObservableProperty] private string _runOnConnect;
    [ObservableProperty] private string _extraOptions;
    [ObservableProperty] private bool _isFavorite;
    [ObservableProperty] private string _group;
    [ObservableProperty] private bool _autoConnectOnLaunch;
    [ObservableProperty] private double _fontSize;
    [ObservableProperty] private TerminalTheme _selectedTheme;
    [ObservableProperty] private string _password = "";
    [ObservableProperty] private bool _clearSavedPassword;
    [ObservableProperty] private string _commandPreview = "";

    [ObservableProperty] private string _icon;
    [ObservableProperty] private string _tabColor;
    [ObservableProperty] private bool _useMosh;
    [ObservableProperty] private bool _autoReconnect;
    [ObservableProperty] private bool _logSession;
    [ObservableProperty] private WorkspaceLaunch _workspaceLaunch;
    [ObservableProperty] private string _workspaceName;
    [ObservableProperty] private string _workspaceTemplateName;

    public bool HasSavedPassword { get; }

    public ObservableCollection<ForwardRowViewModel> Forwards { get; } = new();
    public ObservableCollection<SnippetRowViewModel> Snippets { get; } = new();
    public ObservableCollection<EnvVarRowViewModel> EnvVars { get; } = new();
    public ObservableCollection<LinkRowViewModel> Links { get; } = new();

    public IReadOnlyList<string> IconChoices { get; } = new[]
    {
        "",
        // Machines & compute
        "\U0001F5A5", "\U0001F4BB", "\U0001F5A5\uFE0F", "\U0001F4F1", "\u2328\uFE0F", "\U0001F5B1\uFE0F",
        // Servers, storage & databases
        "\U0001F5C4", "\U0001F5C2", "\U0001F4BE", "\U0001F4C0", "\U0001F9F1", "\U0001F4E6",
        // Network & cloud
        "\U0001F310", "\u2601\uFE0F", "\U0001F4E1", "\U0001F517", "\U0001F4F6", "\U0001F6F0\uFE0F", "\U0001F4E0",
        // Security
        "\U0001F512", "\U0001F510", "\U0001F511", "\U0001F6E1\uFE0F", "\U0001F464",
        // Tools & status
        "\U0001F527", "\u2699\uFE0F", "\U0001F6E0\uFE0F", "\U0001F9EA", "\U0001F41E", "\U0001F4CA",
        "\U0001F680", "\u26A1", "\U0001F525", "\u2B50", "\U0001F3E0", "\U0001F3E2", "\U0001F30D",
        // Colour dots for quick tagging
        "\U0001F534", "\U0001F7E0", "\U0001F7E1", "\U0001F7E2", "\U0001F535", "\U0001F7E3"
    };

    public IReadOnlyList<string> ColorChoices { get; } = new[]
    {
        "", "#E5484D", "#F5A623", "#F2D600", "#3FB950", "#4C8BF5", "#A26BF5", "#EC6FB0", "#8A8F98"
    };

    public IReadOnlyList<WorkspaceLaunch> WorkspaceLaunchOptions { get; } = Enum.GetValues<WorkspaceLaunch>();

    /// <summary>One entry in the “Launch into” picker: the current workspace, a new
    /// dedicated workspace, or one of the saved workspaces to recreate as a template.
    /// Mirrors the macOS profile editor's richer launch dropdown.</summary>
    public sealed class WorkspaceLaunchChoice
    {
        public string Label { get; }
        public WorkspaceLaunch Launch { get; }
        /// <summary>Non-null when this choice recreates a saved workspace by name.</summary>
        public string? TemplateName { get; }
        public WorkspaceLaunchChoice(string label, WorkspaceLaunch launch, string? templateName = null)
        {
            Label = label;
            Launch = launch;
            TemplateName = templateName;
        }
        public override string ToString() => Label;
    }

    public ObservableCollection<WorkspaceLaunchChoice> WorkspaceLaunchChoices { get; } = new();
    [ObservableProperty] private WorkspaceLaunchChoice? _selectedLaunchChoice;

    /// <summary>The workspace-name field only applies when not launching into the
    /// current workspace.</summary>
    public bool ShowWorkspaceName => WorkspaceLaunch != WorkspaceLaunch.Current;

    partial void OnSelectedLaunchChoiceChanged(WorkspaceLaunchChoice? value)
    {
        if (value is null) return;
        WorkspaceLaunch = value.Launch;
        // Record which saved workspace to recreate (if any). The workspace *name*
        // field is left untouched so the user can leave it blank to fall back to the
        // profile's own name — several profiles can recreate the same template and
        // still open under distinct, recognisable workspace names.
        WorkspaceTemplateName = value.TemplateName ?? "";
        OnPropertyChanged(nameof(ShowWorkspaceName));
    }

    public IReadOnlyList<TerminalTheme> Themes { get; } = TerminalTheme.All;
    public IReadOnlyList<double> FontSizes { get; } =
        Enumerable.Range((int)TerminalFontMetrics.Min, (int)(TerminalFontMetrics.Max - TerminalFontMetrics.Min) + 1)
                  .Select(i => (double)i).ToArray();

    public IReadOnlyList<StrictHostKeyChecking> HostKeyOptions { get; } = Enum.GetValues<StrictHostKeyChecking>();

    public ProfileEditorViewModel(SshProfile profile, bool isNew, Action<SshProfile, bool> onSave, bool hasSavedPassword = false,
        IReadOnlyList<string>? savedWorkspaceNames = null)
    {
        _original = profile;
        IsNew = isNew;
        _onSave = onSave;
        HasSavedPassword = hasSavedPassword;

        _name = profile.Name;
        _isLocal = profile.IsLocal;
        _startPath = profile.StartPath;
        _host = profile.Host;
        _port = profile.Port;
        _username = profile.Username;
        _identityFile = profile.IdentityFile;
        _jumpHost = profile.JumpHost;
        _openShell = profile.OpenShell;
        _compression = profile.Compression;
        _keepAlive = profile.KeepAlive;
        _verbose = profile.Verbose;
        _forwardAgent = profile.ForwardAgent;
        _addKeysToAgent = profile.AddKeysToAgent;
        _requestTty = profile.RequestTty;
        _connectTimeout = profile.ConnectTimeout > 0 ? profile.ConnectTimeout.ToString() : "";
        _strictHostKeyChecking = profile.StrictHostKeyChecking;
        _remoteCommand = profile.RemoteCommand;
        _runOnConnect = profile.RunOnConnect;
        _extraOptions = profile.ExtraOptions;
        _isFavorite = profile.IsFavorite;
        _group = profile.Group;
        _autoConnectOnLaunch = profile.AutoConnectOnLaunch;
        _fontSize = TerminalFontMetrics.Clamp(profile.FontSize);
        _selectedTheme = TerminalTheme.ById(profile.Theme);

        _icon = profile.Icon;
        _tabColor = profile.TabColor;
        _useMosh = profile.UseMosh;
        _autoReconnect = profile.AutoReconnect;
        _logSession = profile.LogSession;
        _workspaceLaunch = profile.WorkspaceLaunch;
        _workspaceName = profile.WorkspaceName;
        // Back-compat: older profiles stored the template name in WorkspaceName.
        _workspaceTemplateName = string.IsNullOrWhiteSpace(profile.WorkspaceTemplateName)
            ? profile.WorkspaceName
            : profile.WorkspaceTemplateName;

        // Build the “Launch into” choices: current, a new dedicated workspace, then one
        // “recreate” entry per saved workspace (used as a launch template by name).
        WorkspaceLaunchChoices.Add(new WorkspaceLaunchChoice("Current workspace", WorkspaceLaunch.Current));
        WorkspaceLaunchChoices.Add(new WorkspaceLaunchChoice("New workspace for this profile", WorkspaceLaunch.NewWorkspace));
        foreach (var wsName in savedWorkspaceNames ?? Array.Empty<string>())
            WorkspaceLaunchChoices.Add(new WorkspaceLaunchChoice($"Recreate saved workspace: {wsName}", WorkspaceLaunch.NewWorkspace, wsName));
        _selectedLaunchChoice = ResolveInitialLaunchChoice(profile);

        foreach (var f in profile.Forwards)
            AddForwardRow(new ForwardRowViewModel(f));

        foreach (var s in profile.Snippets)
            AddSnippetRow(new SnippetRowViewModel(s));

        foreach (var e in profile.Environment)
            EnvVars.Add(new EnvVarRowViewModel(e));

        foreach (var l in profile.Links)
            Links.Add(new LinkRowViewModel(l));

        UpdatePreview();
    }

    /// <summary>Pick the launch choice matching the loaded profile: a saved-workspace
    /// template when its name matches, otherwise the plain Current / New entries.</summary>
    private WorkspaceLaunchChoice ResolveInitialLaunchChoice(SshProfile profile)
    {
        var templateName = string.IsNullOrWhiteSpace(profile.WorkspaceTemplateName)
            ? profile.WorkspaceName
            : profile.WorkspaceTemplateName;
        if (profile.WorkspaceLaunch == WorkspaceLaunch.NewWorkspace &&
            !string.IsNullOrWhiteSpace(templateName))
        {
            var match = WorkspaceLaunchChoices.FirstOrDefault(
                c => c.TemplateName is { } t && t.Equals(templateName, StringComparison.OrdinalIgnoreCase));
            if (match is not null) return match;
        }
        return WorkspaceLaunchChoices.First(c => c.TemplateName is null && c.Launch == profile.WorkspaceLaunch);
    }

    private void AddForwardRow(ForwardRowViewModel row)
    {
        row.PropertyChanged += ForwardChanged;
        Forwards.Add(row);
    }

    private void ForwardChanged(object? sender, PropertyChangedEventArgs e) => UpdatePreview();

    [RelayCommand]
    private void AddForward() => AddForwardRow(new ForwardRowViewModel(new PortForward()));

    [RelayCommand]
    private void RemoveForward(ForwardRowViewModel row)
    {
        row.PropertyChanged -= ForwardChanged;
        Forwards.Remove(row);
        UpdatePreview();
    }

    private void AddSnippetRow(SnippetRowViewModel row) => Snippets.Add(row);

    [RelayCommand]
    private void AddSnippet() => AddSnippetRow(new SnippetRowViewModel(new CommandSnippet()));

    [RelayCommand]
    private void RemoveSnippet(SnippetRowViewModel row) => Snippets.Remove(row);

    [RelayCommand]
    private void AddEnvVar() => EnvVars.Add(new EnvVarRowViewModel(new EnvVar()));

    [RelayCommand]
    private void RemoveEnvVar(EnvVarRowViewModel row) => EnvVars.Remove(row);

    [RelayCommand]
    private void AddLink() => Links.Add(new LinkRowViewModel(new ProfileLink()));

    [RelayCommand]
    private void RemoveLink(LinkRowViewModel row) => Links.Remove(row);

    protected override void OnPropertyChanged(PropertyChangedEventArgs e)
    {
        base.OnPropertyChanged(e);
        if (e.PropertyName != nameof(CommandPreview))
            UpdatePreview();
    }

    private void UpdatePreview()
    {
        CommandPreview = IsLocal ? "(local shell)" : SshCommandBuilder.CommandPreview(BuildProfile());
    }

    public SshProfile BuildProfile()
    {
        var p = _original.Clone();
        p.Id = _original.Id;
        p.Name = string.IsNullOrWhiteSpace(Name) ? "New Profile" : Name.Trim();
        p.IsLocal = IsLocal;
        p.StartPath = StartPath?.Trim() ?? "";
        p.Host = Host?.Trim() ?? "";
        p.Port = string.IsNullOrWhiteSpace(Port) ? "22" : Port.Trim();
        p.Username = Username?.Trim() ?? "";
        p.IdentityFile = IdentityFile?.Trim() ?? "";
        p.JumpHost = JumpHost?.Trim() ?? "";
        p.OpenShell = OpenShell;
        p.Compression = Compression;
        p.KeepAlive = KeepAlive;
        p.Verbose = Verbose;
        p.ForwardAgent = ForwardAgent;
        p.AddKeysToAgent = AddKeysToAgent;
        p.RequestTty = RequestTty;
        p.ConnectTimeout = int.TryParse(ConnectTimeout?.Trim(), out var t) ? t : 0;
        p.StrictHostKeyChecking = StrictHostKeyChecking;
        p.RemoteCommand = RemoteCommand?.Trim() ?? "";
        p.RunOnConnect = RunOnConnect?.Trim() ?? "";
        p.ExtraOptions = ExtraOptions?.Trim() ?? "";
        p.IsFavorite = IsFavorite;
        p.Group = Group?.Trim() ?? "";
        p.AutoConnectOnLaunch = AutoConnectOnLaunch;
        p.FontSize = TerminalFontMetrics.Clamp(FontSize);
        p.Theme = SelectedTheme?.Id ?? TerminalTheme.DefaultId;
        p.Forwards = Forwards.Select(f => f.ToModel()).ToList();
        p.Snippets = Snippets.Where(s => !string.IsNullOrWhiteSpace(s.Command))
                             .Select(s => s.ToModel()).ToList();
        p.Environment = EnvVars.Where(e => !string.IsNullOrWhiteSpace(e.Name))
                               .Select(e => e.ToModel()).ToList();
        p.Links = Links.Where(l => !string.IsNullOrWhiteSpace(l.Url))
                       .Select(l => l.ToModel()).ToList();

        p.Icon = Icon?.Trim() ?? "";
        p.TabColor = TabColor?.Trim() ?? "";
        p.UseMosh = UseMosh;
        p.AutoReconnect = AutoReconnect;
        p.LogSession = LogSession;
        p.WorkspaceLaunch = WorkspaceLaunch;
        p.WorkspaceName = WorkspaceName?.Trim() ?? "";
        p.WorkspaceTemplateName = WorkspaceTemplateName?.Trim() ?? "";

        // Password: null = unchanged, "" = clear, non-empty = set.
        if (ClearSavedPassword) p.PendingPassword = "";
        else if (!string.IsNullOrEmpty(Password)) p.PendingPassword = Password;
        else p.PendingPassword = null;

        return p;
    }

    [RelayCommand]
    private void Save()
    {
        _onSave(BuildProfile(), IsNew);
        CloseRequested?.Invoke();
    }

    [RelayCommand]
    private void Cancel() => CloseRequested?.Invoke();
}
