using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;

namespace RemoteStuff.ViewModels;

/// <summary>The type of editor a <see cref="ProfileField"/> needs.</summary>
public enum ProfileFieldKind { Text, Number, Bool, Options }

/// <summary>
/// One comparable / bulk-editable setting on an <see cref="SshProfile"/>. The same list
/// drives both the comparison table columns and the "apply to selected" picker, so the two
/// can never drift out of sync.
/// </summary>
public sealed class ProfileField
{
    public string Name { get; }
    public ProfileFieldKind Kind { get; }
    public Func<SshProfile, string> Get { get; }
    /// <summary>Null for compare-only columns (e.g. collection counts) that can't be bulk-set.</summary>
    public Action<SshProfile, string>? Set { get; }
    public IReadOnlyList<string>? Options { get; }

    /// <summary>True when this setting can be bulk-applied (has a setter).</summary>
    public bool IsEditable => Set is not null;

    public ProfileField(string name, ProfileFieldKind kind,
        Func<SshProfile, string> get, Action<SshProfile, string>? set,
        IReadOnlyList<string>? options = null)
    {
        Name = name;
        Kind = kind;
        Get = get;
        Set = set;
        Options = options;
    }

    /// <summary>Shown as the ComboBox label.</summary>
    public override string ToString() => Name;
}

/// <summary>A single profile row in the comparison table (checkbox + its per-field values).</summary>
public sealed partial class ProfileCompareRow : ObservableObject
{
    private readonly IReadOnlyList<ProfileField> _fields;

    public SshProfile Profile { get; }

    [ObservableProperty] private bool _isSelected;

    public ProfileCompareRow(SshProfile profile, IReadOnlyList<ProfileField> fields)
    {
        Profile = profile;
        _fields = fields;
    }

    public string Name => Profile.Name;
    public string Icon => Profile.DisplayIcon;
    public string Host => Profile.IsLocal ? "local shell" : Profile.Subtitle;

    /// <summary>The field values in the same order as the table's column headers.</summary>
    public IReadOnlyList<string> Values => _fields.Select(f => f.Get(Profile)).ToList();

    /// <summary>Re-read the profile after a bulk edit so the row's cells update.</summary>
    public void Refresh()
    {
        OnPropertyChanged(nameof(Name));
        OnPropertyChanged(nameof(Host));
        OnPropertyChanged(nameof(Values));
    }
}

/// <summary>
/// Backs the "Compare &amp; Bulk Edit Profiles" window: shows every profile side by side and
/// lets the user apply one setting's value to a group of selected profiles at once.
/// </summary>
public sealed partial class ProfileComparisonViewModel : ObservableObject
{
    private static readonly string[] BoolOptions = { "Off", "On" };

    private readonly Action _onSaved;

    public IReadOnlyList<ProfileField> Fields { get; }
    /// <summary>The subset shown in the "apply setting" picker (compare-only columns excluded).</summary>
    public IReadOnlyList<ProfileField> EditableFields { get; }
    public ObservableCollection<ProfileCompareRow> Rows { get; } = new();

    [ObservableProperty] private ProfileField? _selectedField;
    [ObservableProperty] private string _textValue = "";
    [ObservableProperty] private string? _optionValue;
    [ObservableProperty] private string _statusText = "";

    public bool FieldIsOptions => SelectedField?.Kind is ProfileFieldKind.Options or ProfileFieldKind.Bool;
    public bool FieldIsText => SelectedField is not null && !FieldIsOptions;
    public IReadOnlyList<string> CurrentOptions => SelectedField?.Options ?? Array.Empty<string>();

    public int SelectedCount => Rows.Count(r => r.IsSelected);
    public string SelectionSummary => $"{SelectedCount} of {Rows.Count} selected";

    public ProfileComparisonViewModel(IEnumerable<SshProfile> profiles, Action onSaved)
    {
        _onSaved = onSaved;
        Fields = BuildFields();
        EditableFields = Fields.Where(f => f.IsEditable).ToList();

        foreach (var p in profiles.OrderBy(p => p.Group, StringComparer.OrdinalIgnoreCase)
                                   .ThenBy(p => p.Name, StringComparer.OrdinalIgnoreCase))
        {
            var row = new ProfileCompareRow(p, Fields);
            row.PropertyChanged += OnRowChanged;
            Rows.Add(row);
        }

        SelectedField = EditableFields.FirstOrDefault();
    }

    private static IReadOnlyList<ProfileField> BuildFields()
    {
        var themeNames = TerminalTheme.All.Select(t => t.Name).ToArray();
        var strictNames = Enum.GetNames<StrictHostKeyChecking>();
        var launchNames = Enum.GetNames<WorkspaceLaunch>();

        return new List<ProfileField>
        {
            new("Group", ProfileFieldKind.Text, p => p.Group, (p, v) => p.Group = v.Trim()),
            new("Username", ProfileFieldKind.Text, p => p.Username, (p, v) => p.Username = v.Trim()),
            new("Port", ProfileFieldKind.Text, p => p.Port,
                (p, v) => p.Port = string.IsNullOrWhiteSpace(v) ? "22" : v.Trim()),
            new("Identity File", ProfileFieldKind.Text, p => p.IdentityFile, (p, v) => p.IdentityFile = v.Trim()),
            new("Jump Host", ProfileFieldKind.Text, p => p.JumpHost, (p, v) => p.JumpHost = v.Trim()),
            new("Run On Connect", ProfileFieldKind.Text, p => p.RunOnConnect, (p, v) => p.RunOnConnect = v),
            new("Remote Command", ProfileFieldKind.Text, p => p.RemoteCommand, (p, v) => p.RemoteCommand = v),
            new("Extra Options", ProfileFieldKind.Text, p => p.ExtraOptions, (p, v) => p.ExtraOptions = v),
            new("Icon", ProfileFieldKind.Text, p => p.Icon, (p, v) => p.Icon = v.Trim()),
            new("Tab Color", ProfileFieldKind.Text, p => p.TabColor, (p, v) => p.TabColor = v.Trim()),
            new("Theme", ProfileFieldKind.Options, p => TerminalTheme.ById(p.Theme).Name,
                (p, v) => p.Theme = TerminalTheme.All.FirstOrDefault(t => t.Name == v)?.Id ?? p.Theme, themeNames),
            new("Font Size", ProfileFieldKind.Number, p => p.FontSize.ToString("0"),
                (p, v) => { if (double.TryParse(v, out var d)) p.FontSize = TerminalFontMetrics.Clamp(d); }),
            new("Connect Timeout", ProfileFieldKind.Number, p => p.ConnectTimeout.ToString(),
                (p, v) => { if (int.TryParse(v, out var n) && n >= 0) p.ConnectTimeout = n; }),
            new("Favorite", ProfileFieldKind.Bool, p => p.IsFavorite ? "On" : "Off",
                (p, v) => p.IsFavorite = v == "On", BoolOptions),
            new("Keep Alive", ProfileFieldKind.Bool, p => p.KeepAlive ? "On" : "Off",
                (p, v) => p.KeepAlive = v == "On", BoolOptions),
            new("Compression", ProfileFieldKind.Bool, p => p.Compression ? "On" : "Off",
                (p, v) => p.Compression = v == "On", BoolOptions),
            new("Forward Agent", ProfileFieldKind.Bool, p => p.ForwardAgent ? "On" : "Off",
                (p, v) => p.ForwardAgent = v == "On", BoolOptions),
            new("Add Keys To Agent", ProfileFieldKind.Bool, p => p.AddKeysToAgent ? "On" : "Off",
                (p, v) => p.AddKeysToAgent = v == "On", BoolOptions),
            new("Request TTY", ProfileFieldKind.Bool, p => p.RequestTty ? "On" : "Off",
                (p, v) => p.RequestTty = v == "On", BoolOptions),
            new("Open Shell", ProfileFieldKind.Bool, p => p.OpenShell ? "On" : "Off",
                (p, v) => p.OpenShell = v == "On", BoolOptions),
            new("Use Mosh", ProfileFieldKind.Bool, p => p.UseMosh ? "On" : "Off",
                (p, v) => p.UseMosh = v == "On", BoolOptions),
            new("Auto Reconnect", ProfileFieldKind.Bool, p => p.AutoReconnect ? "On" : "Off",
                (p, v) => p.AutoReconnect = v == "On", BoolOptions),
            new("Auto Connect", ProfileFieldKind.Bool, p => p.AutoConnectOnLaunch ? "On" : "Off",
                (p, v) => p.AutoConnectOnLaunch = v == "On", BoolOptions),
            new("Log Session", ProfileFieldKind.Bool, p => p.LogSession ? "On" : "Off",
                (p, v) => p.LogSession = v == "On", BoolOptions),
            new("Verbose", ProfileFieldKind.Bool, p => p.Verbose ? "On" : "Off",
                (p, v) => p.Verbose = v == "On", BoolOptions),
            new("Strict Host Key", ProfileFieldKind.Options, p => p.StrictHostKeyChecking.ToString(),
                (p, v) => { if (Enum.TryParse<StrictHostKeyChecking>(v, out var s)) p.StrictHostKeyChecking = s; }, strictNames),
            new("Workspace Launch", ProfileFieldKind.Options, p => p.WorkspaceLaunch.ToString(),
                (p, v) => { if (Enum.TryParse<WorkspaceLaunch>(v, out var w)) p.WorkspaceLaunch = w; }, launchNames),
            new("Workspace Name", ProfileFieldKind.Text, p => p.WorkspaceName, (p, v) => p.WorkspaceName = v.Trim()),
            new("Workspace Template", ProfileFieldKind.Text, p => p.WorkspaceTemplateName,
                (p, v) => p.WorkspaceTemplateName = v.Trim()),
            new("Start Path", ProfileFieldKind.Text, p => p.StartPath, (p, v) => p.StartPath = v.Trim()),

            // Compare-only columns (collections) — shown but not bulk-editable.
            new("Snippets", ProfileFieldKind.Text, p => p.Snippets.Count.ToString(), null),
            new("Links", ProfileFieldKind.Text, p => p.Links.Count.ToString(), null),
            new("Forwards", ProfileFieldKind.Text, p => p.Forwards.Count.ToString(), null),
            new("Env Vars", ProfileFieldKind.Text, p => p.Environment.Count.ToString(), null),
        };
    }

    private void OnRowChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ProfileCompareRow.IsSelected))
        {
            OnPropertyChanged(nameof(SelectedCount));
            OnPropertyChanged(nameof(SelectionSummary));
        }
    }

    partial void OnSelectedFieldChanged(ProfileField? value)
    {
        OnPropertyChanged(nameof(FieldIsOptions));
        OnPropertyChanged(nameof(FieldIsText));
        OnPropertyChanged(nameof(CurrentOptions));
        OptionValue = value?.Options?.FirstOrDefault();
        TextValue = "";
    }

    [RelayCommand]
    private void SelectAll()
    {
        foreach (var r in Rows) r.IsSelected = true;
    }

    [RelayCommand]
    private void SelectNone()
    {
        foreach (var r in Rows) r.IsSelected = false;
    }

    /// <summary>Pre-fill the value editor from the first selected profile's current value.</summary>
    [RelayCommand]
    private void UseFirstSelectedValue()
    {
        var f = SelectedField;
        if (f is null) return;
        var row = Rows.FirstOrDefault(r => r.IsSelected);
        if (row is null) { StatusText = "Select a profile first."; return; }

        var val = f.Get(row.Profile);
        if (FieldIsOptions) OptionValue = val;
        else TextValue = val;
    }

    [RelayCommand]
    private void Apply()
    {
        var f = SelectedField;
        if (f?.Set is null) { StatusText = "Pick a setting to apply."; return; }

        var targets = Rows.Where(r => r.IsSelected).ToList();
        if (targets.Count == 0) { StatusText = "No profiles selected — tick one or more rows first."; return; }

        var value = FieldIsOptions ? (OptionValue ?? "") : (TextValue ?? "");
        foreach (var r in targets)
        {
            f.Set(r.Profile, value);
            r.Refresh();
        }

        _onSaved();
        StatusText = $"Applied {f.Name} = \"{value}\" to {targets.Count} profile(s).";
    }
}
