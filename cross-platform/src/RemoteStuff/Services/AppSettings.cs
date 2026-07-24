using System;
using System.IO;
using System.Text.Json;

namespace RemoteStuff.Services;

/// <summary>
/// Persisted application preferences, stored as JSON alongside the profiles.
/// A cross-platform port of the macOS <c>AppSettings</c>.
/// </summary>
public sealed class AppSettings
{
    private readonly string _path;

    /// <summary>Absolute path to the settings.json file on disk.</summary>
    public string FilePath => _path;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    // --- Persisted values ---
    public bool ResumeLastSession { get; set; } = true;
    public bool StartAtLogin { get; set; }
    public bool MenuBarOnly { get; set; }
    public bool ConfirmBeforeClosing { get; set; } = true;

    /// <summary>Application colour theme: "Dark" or "Light".</summary>
    public string AppTheme { get; set; } = "Dark";

    /// <summary>Remembered width of the profile sidebar panel (px).</summary>
    public double SidebarWidth { get; set; } = 280;

    /// <summary>Default terminal theme id for new sessions ("" = per-profile).</summary>
    public string DefaultTerminalTheme { get; set; } = "";
    public double DefaultTerminalFontSize { get; set; } = 13;

    /// <summary>Right-click a sidebar row to connect immediately (vs. show menu).</summary>
    public bool RightClickConnects { get; set; }

    /// <summary>Automatically check for updates.</summary>
    public bool AutoCheckUpdates { get; set; } = true;

    /// <summary>The "Connect as" username used for one-click ZeroTier device
    /// connections (SSH / SFTP). Remembered across launches.</summary>
    public string ZeroTierConnectUsername { get; set; } = Environment.UserName;

    /// <summary>ZeroTier panel: show only online devices (vs. all). Remembered.</summary>
    public bool ZeroTierShowOnlineOnly { get; set; }

    /// <summary>ZeroTier panel: show only networks this device has joined (vs. all). Remembered.</summary>
    public bool ZeroTierShowMemberOfOnly { get; set; }

    public AppSettings()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir))
            baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var dir = Path.Combine(baseDir, "RemoteStuff");
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, "settings.json");
        Load();
    }

    private void Load()
    {
        try
        {
            if (File.Exists(_path))
            {
                // Deserialize into a plain DTO — deserializing into AppSettings
                // itself would re-invoke this constructor and recurse infinitely.
                var loaded = JsonSerializer.Deserialize<PersistedSettings>(File.ReadAllText(_path), JsonOptions);
                if (loaded != null)
                {
                    ResumeLastSession = loaded.ResumeLastSession;
                    StartAtLogin = loaded.StartAtLogin;
                    MenuBarOnly = loaded.MenuBarOnly;
                    ConfirmBeforeClosing = loaded.ConfirmBeforeClosing;
                    if (!string.IsNullOrWhiteSpace(loaded.AppTheme))
                        AppTheme = loaded.AppTheme;
                    if (loaded.SidebarWidth > 0)
                        SidebarWidth = loaded.SidebarWidth;
                    DefaultTerminalTheme = loaded.DefaultTerminalTheme;
                    DefaultTerminalFontSize = loaded.DefaultTerminalFontSize;
                    RightClickConnects = loaded.RightClickConnects;
                    AutoCheckUpdates = loaded.AutoCheckUpdates;
                    if (!string.IsNullOrWhiteSpace(loaded.ZeroTierConnectUsername))
                        ZeroTierConnectUsername = loaded.ZeroTierConnectUsername;
                    ZeroTierShowOnlineOnly = loaded.ZeroTierShowOnlineOnly;
                    ZeroTierShowMemberOfOnly = loaded.ZeroTierShowMemberOfOnly;
                }
            }
        }
        catch { /* keep defaults */ }
    }

    /// <summary>
    /// Flat data-transfer object mirroring the persisted values. Used solely for
    /// (de)serialization so that reading settings never re-enters the
    /// <see cref="AppSettings"/> constructor.
    /// </summary>
    private sealed class PersistedSettings
    {
        public bool ResumeLastSession { get; set; } = true;
        public bool StartAtLogin { get; set; }
        public bool MenuBarOnly { get; set; }
        public bool ConfirmBeforeClosing { get; set; } = true;
        public string AppTheme { get; set; } = "Dark";
        public double SidebarWidth { get; set; } = 280;
        public string DefaultTerminalTheme { get; set; } = "";
        public double DefaultTerminalFontSize { get; set; } = 13;
        public bool RightClickConnects { get; set; }
        public bool AutoCheckUpdates { get; set; } = true;
        public string ZeroTierConnectUsername { get; set; } = "";
        public bool ZeroTierShowOnlineOnly { get; set; }
        public bool ZeroTierShowMemberOfOnly { get; set; }
    }

    public void Save()
    {
        try
        {
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, JsonOptions));
            File.Move(tmp, _path, overwrite: true);
        }
        catch { /* best-effort */ }
    }
}
