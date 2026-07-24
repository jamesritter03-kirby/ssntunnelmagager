using System;
using Avalonia.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace RemoteStuff.ViewModels;

/// <summary>
/// One top-level workspace pill: a named collection of tabs the user can switch
/// between, close, rename, tint, and save as a reusable template.
/// </summary>
public sealed partial class WorkspaceViewModel : ObservableObject
{
    private readonly MainWindowViewModel _owner;

    public Guid Id { get; }

    [ObservableProperty] private string _name;
    [ObservableProperty] private bool _isCurrent;
    [ObservableProperty] private bool _isSaved;

    /// <summary>Optional hex tint for the pill (empty = default accent).</summary>
    [ObservableProperty] private string _color = "";

    /// <summary>When set, the profile whose dedicated workspace this is.</summary>
    public Guid? SourceProfileId { get; set; }

    /// <summary>Id of the tab that was selected the last time this workspace was
    /// current, so switching back to it restores the same tab instead of resetting
    /// to the first one.</summary>
    public Guid? LastSelectedTabId { get; set; }

    public WorkspaceViewModel(MainWindowViewModel owner, Guid id, string name)
    {
        _owner = owner;
        Id = id;
        _name = name;
    }

    public IBrush PillBrush =>
        !string.IsNullOrWhiteSpace(Color) && Avalonia.Media.Color.TryParse(Color, out var c)
            ? new SolidColorBrush(c)
            : Brushes.Transparent;

    partial void OnColorChanged(string value) => OnPropertyChanged(nameof(PillBrush));

    [RelayCommand] private void Select() => _owner.SelectWorkspace(this);
    [RelayCommand] private void Close() => _owner.CloseWorkspace(this);
    [RelayCommand] private void Rename() => _owner.BeginRenameWorkspace(this);
    [RelayCommand] private void Save() => _owner.SaveWorkspace(this);
    [RelayCommand] private void SaveAs() => _owner.SaveWorkspaceAs(this);
    [RelayCommand] private void SaveAsProfile() => _owner.SaveWorkspaceAsProfile(this);
    [RelayCommand] private void ConnectionHealth() => _owner.ShowWorkspaceStats(this);
}

/// <summary>One entry in the Workspace menu's "Open / Delete Saved Workspace"
/// submenus. Carries its own commands so the menu binds only to the item's own
/// DataContext — never across the popup boundary.</summary>
public sealed class SavedWorkspaceMenuItem
{
    public string Name { get; }
    public IRelayCommand OpenCommand { get; }
    public IRelayCommand DeleteCommand { get; }

    public SavedWorkspaceMenuItem(string name, IRelayCommand openCommand, IRelayCommand deleteCommand)
    {
        Name = name;
        OpenCommand = openCommand;
        DeleteCommand = deleteCommand;
    }
}
