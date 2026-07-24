using System;
using System.Reflection;
using CommunityToolkit.Mvvm.ComponentModel;
using RemoteStuff.Models;
using RemoteStuff.Services;

namespace RemoteStuff.ViewModels;

/// <summary>Editable wrapper around <see cref="AppSettings"/> for the Settings window.</summary>
public sealed partial class SettingsViewModel : ViewModelBase
{
    private readonly AppSettings _settings;

    [ObservableProperty] private bool _resumeLastSession;
    [ObservableProperty] private bool _startAtLogin;
    [ObservableProperty] private bool _menuBarOnly;
    [ObservableProperty] private bool _confirmBeforeClosing;
    [ObservableProperty] private bool _rightClickConnects;
    [ObservableProperty] private bool _autoCheckUpdates;
    [ObservableProperty] private double _defaultTerminalFontSize;
    [ObservableProperty] private TerminalTheme _defaultTerminalTheme;
    [ObservableProperty] private string _appTheme = "Dark";

    /// <summary>Theme choices shown in the picker.</summary>
    public System.Collections.Generic.IReadOnlyList<string> Themes { get; } = new[] { "Dark", "Light" };

    /// <summary>All terminal colour themes, for the default-terminal-theme picker.</summary>
    public System.Collections.Generic.IReadOnlyList<TerminalTheme> TerminalThemes { get; } = TerminalTheme.All;

    /// <summary>App version string shown at the bottom of the dialog.</summary>
    public string AppVersion
    {
        get
        {
            var asm = Assembly.GetExecutingAssembly();
            var info = asm.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            var ver = info ?? asm.GetName().Version?.ToString() ?? "?";
            var plus = ver.IndexOf('+');
            if (plus >= 0) ver = ver[..plus];
            return "Version " + ver;
        }
    }

    public SettingsViewModel(AppSettings settings)
    {
        _settings = settings;
        _resumeLastSession = settings.ResumeLastSession;
        _startAtLogin = settings.StartAtLogin;
        _menuBarOnly = settings.MenuBarOnly;
        _confirmBeforeClosing = settings.ConfirmBeforeClosing;
        _rightClickConnects = settings.RightClickConnects;
        _autoCheckUpdates = settings.AutoCheckUpdates;
        _defaultTerminalFontSize = settings.DefaultTerminalFontSize;
        _defaultTerminalTheme = TerminalTheme.ById(settings.DefaultTerminalTheme);
        _appTheme = settings.AppTheme;
    }

    /// <summary>Preview the theme immediately as the user changes the picker.</summary>
    partial void OnAppThemeChanged(string value) => App.ApplyTheme(value);

    /// <summary>Restore the previously saved theme (used when the dialog is cancelled).</summary>
    public void RevertThemePreview() => App.ApplyTheme(_settings.AppTheme);

    /// <summary>Copy the edited values back and persist them.</summary>
    public void Apply()
    {
        _settings.ResumeLastSession = ResumeLastSession;
        _settings.StartAtLogin = StartAtLogin;
        _settings.MenuBarOnly = MenuBarOnly;
        _settings.ConfirmBeforeClosing = ConfirmBeforeClosing;
        _settings.RightClickConnects = RightClickConnects;
        _settings.AutoCheckUpdates = AutoCheckUpdates;
        _settings.DefaultTerminalFontSize = DefaultTerminalFontSize;
        _settings.DefaultTerminalTheme = DefaultTerminalTheme?.Id ?? "";
        _settings.AppTheme = AppTheme;
        _settings.Save();
    }
}
