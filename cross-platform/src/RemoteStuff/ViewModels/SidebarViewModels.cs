using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using RemoteStuff.Models;

namespace RemoteStuff.ViewModels;

/// <summary>
/// One profile row in the sidebar, with live connection + favourite state and
/// the per-row actions the Mac app exposes via its right-click menu.
/// </summary>
public sealed partial class ProfileRowViewModel : ObservableObject
{
    private readonly MainWindowViewModel _owner;

    public SshProfile Profile { get; }

    public ProfileRowViewModel(SshProfile profile, MainWindowViewModel owner)
    {
        Profile = profile;
        _owner = owner;
    }

    public string Name => Profile.Name;
    public string Subtitle => Profile.RowSubtitle;
    public bool IsLocal => Profile.IsLocal;

    /// <summary>The profile's emoji/glyph icon, shown in the sidebar row.</summary>
    public string Icon => Profile.DisplayIcon;
    public bool HasIcon => Profile.IconIsEmoji;

    /// <summary>True while at least one live session for this profile is open.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowHealthDot))]
    private bool _isConnected;

    /// <summary>Live tunnel health, driving the sidebar status dot colour.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HealthBrush))]
    [NotifyPropertyChangedFor(nameof(HealthTip))]
    [NotifyPropertyChangedFor(nameof(ShowHealthDot))]
    private TunnelHealth _health = TunnelHealth.Unknown;

    /// <summary>Dot colour: green healthy, orange degraded, grey/transparent otherwise.</summary>
    public Avalonia.Media.IBrush HealthBrush => Health switch
    {
        TunnelHealth.Healthy => new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.FromRgb(0x3F, 0xB9, 0x50)),
        TunnelHealth.Degraded => new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.FromRgb(0xD2, 0x9C, 0x2A)),
        _ => Avalonia.Media.Brushes.Transparent
    };

    public string HealthTip => Health switch
    {
        TunnelHealth.Healthy => "All forwarded ports are listening.",
        TunnelHealth.Degraded => "A forwarded port stopped answering.",
        _ => ""
    };

    public bool ShowHealthDot => IsConnected && Health != TunnelHealth.Unknown;

    /// <summary>True when the profile's host is an online ZeroTier device.</summary>
    [ObservableProperty] private bool _isOnline;

    public bool IsFavorite => Profile.IsFavorite;
    public string FavoriteGlyph => Profile.IsFavorite ? "★" : "☆";

    /// <summary>Bright gold when favourited, dim grey otherwise — a strong colour
    /// contrast so favourites stand out at a glance (the filled/hollow star alone
    /// was too subtle).</summary>
    public Avalonia.Media.IBrush FavoriteBrush => Profile.IsFavorite
        ? new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.FromRgb(0xFF, 0xC4, 0x1E))
        : new Avalonia.Media.SolidColorBrush(Avalonia.Media.Color.FromRgb(0x4A, 0x4A, 0x4A));

    /// <summary>Bigger, bolder star for favourites so they pop out of the list.</summary>
    public double FavoriteFontSize => Profile.IsFavorite ? 17 : 14;

    /// <summary>Re-read favourite state from the underlying model after a toggle.</summary>
    public void RefreshFavorite()
    {
        OnPropertyChanged(nameof(IsFavorite));
        OnPropertyChanged(nameof(FavoriteGlyph));
        OnPropertyChanged(nameof(FavoriteBrush));
        OnPropertyChanged(nameof(FavoriteFontSize));
    }

    [RelayCommand] private void Connect() => _owner.ConnectRow(this);
    [RelayCommand] private void Disconnect() => _owner.DisconnectRow(this);
    [RelayCommand] private void Sftp() => _owner.SftpRow(this);
    [RelayCommand] private void Vnc() => _owner.VncRow(this);
    [RelayCommand] private void Edit() => _owner.EditRow(this);
    [RelayCommand] private void Duplicate() => _owner.DuplicateRow(this);
    [RelayCommand] private void ToggleFavorite() => _owner.ToggleFavoriteRow(this);
    [RelayCommand] private void CopyIp() => _owner.CopyIpRow(this);
    [RelayCommand] private void Delete() => _owner.DeleteRow(this);
    [RelayCommand] private void MoveUp() => _owner.MoveRow(this, -1);
    [RelayCommand] private void MoveDown() => _owner.MoveRow(this, +1);
}

/// <summary>A collapsible sidebar section (Favourites or a named group).</summary>
public sealed partial class SidebarSectionViewModel : ObservableObject
{
    private readonly MainWindowViewModel? _owner;

    public string Title { get; }
    public string HeaderGlyph { get; }
    public bool ShowGlyph => !string.IsNullOrEmpty(HeaderGlyph);

    public ObservableCollection<ProfileRowViewModel> Rows { get; } = new();
    public int Count => Rows.Count;

    [ObservableProperty] private bool _isExpanded = true;

    public string ChevronGlyph => IsExpanded ? "\u25BE" : "\u25B8";

    public SidebarSectionViewModel(string title, string headerGlyph = "", MainWindowViewModel? owner = null)
    {
        Title = title;
        HeaderGlyph = headerGlyph;
        _owner = owner;
    }

    partial void OnIsExpandedChanged(bool value) => OnPropertyChanged(nameof(ChevronGlyph));

    [RelayCommand]
    private void ToggleCollapse() => IsExpanded = !IsExpanded;

    // Expand/Collapse all sections. Defined on the section (not the window VM) so the
    // header ContextMenu — which lives in its own popup tree and can't reach the window
    // VM via $parent bindings — can bind them through the section's own DataContext.
    [RelayCommand]
    private void ExpandAllGroups() => _owner?.ExpandAllGroupsCommand.Execute(null);

    [RelayCommand]
    private void CollapseAllGroups() => _owner?.CollapseAllGroupsCommand.Execute(null);
}
