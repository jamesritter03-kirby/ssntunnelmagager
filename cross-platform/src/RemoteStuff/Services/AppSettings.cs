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

    /// <summary>Remembered width of the ZeroTier side panel (px). Wider by default so
    /// its toolbar buttons don't wrap.</summary>
    public double ZeroTierPanelWidth { get; set; } = 400;

    /// <summary>Automatically refresh ZeroTier device/network status on an interval. Remembered.</summary>
    public bool ZeroTierAutoRefresh { get; set; } = true;

    /// <summary>How often (seconds) to auto-refresh ZeroTier status when enabled. Remembered.</summary>
    public int ZeroTierRefreshSeconds { get; set; } = 30;

    // --- Network tab: Router &amp; DNS (remembered across launches) ---
    public string RouterDnsAdapter { get; set; } = "";
    public string RouterDns { get; set; } = "";
    public string RouterGateway { get; set; } = "";
    public string RouterUpstreamAdapter { get; set; } = "";
    public string RouterDownstreamAdapter { get; set; } = "";
    public string RouterIp { get; set; } = "10.1.1.1";
    public string RouterSubnet { get; set; } = "255.255.255.0";
    public string RouterDhcpStart { get; set; } = "10.1.1.100";
    public string RouterDhcpEnd { get; set; } = "10.1.1.254";

    /// <summary>Automatically start internet sharing (the router) when the app launches.</summary>
    public bool RouterAutoStart { get; set; }

    /// <summary>True while internet sharing (NAT/ICS) is running. Persisted so an
    /// unclean exit (crash/kill) can be detected on the next launch and torn down,
    /// preventing a leftover that breaks networking.</summary>
    public bool RouterSharingActive { get; set; }

    // --- Key Vault edge-device auth (Azure Key Vault escrow + SSH user-CA) ---
    // Per-environment config: dev defaults are shown; prod uses a different
    // subscription + vault, so these are editable and NEVER hardcoded elsewhere.

    /// <summary>Azure Key Vault base URI holding the escrowed credentials / CA.</summary>
    public string KeyVaultUri { get; set; } = "https://s2l-dev-escrow-kv.vault.azure.net/";

    /// <summary>Azure subscription id (or name) the vault lives in. Used to scope the
    /// Azure CLI / interactive sign-in so the right tenant is selected.</summary>
    public string KeyVaultSubscriptionId { get; set; } = "kc-kds-s2labs-dev-001";

    /// <summary>Key Vault secret name of the SSH user-CA private key used to sign
    /// operator certificates (dev shortcut; prod should use a signing service).</summary>
    public string KeyVaultCaPrivateSecretName { get; set; } = "ssh-user-ca-private";

    /// <summary>Key Vault secret name of the SSH user-CA public key.</summary>
    public string KeyVaultCaPublicSecretName { get; set; } = "ssh-user-ca-public";

    /// <summary>Validity window passed to <c>ssh-keygen -V</c> when signing a cert.</summary>
    public string KeyVaultCertValidity { get; set; } = "+1d";

    /// <summary>Comma-separated principals embedded in signed certs (the device-side
    /// account(s) the cert is allowed to log in as).</summary>
    public string KeyVaultCertPrincipals { get; set; } = "snsadmin";

    /// <summary>Secret-name prefix for the per-device break-glass OS password
    /// (<c>&lt;prefix&gt;&lt;unit&gt;</c>, e.g. <c>os-snsadmin-myhost</c>).</summary>
    public string KeyVaultOsSecretPrefix { get; set; } = "os-snsadmin-";

    /// <summary>Secret-name prefix for the per-device app-stack (MQTT/Redis/Node-RED)
    /// password (<c>&lt;prefix&gt;&lt;unit&gt;</c>, e.g. <c>app-stack-myhost</c>).</summary>
    public string KeyVaultAppStackSecretPrefix { get; set; } = "app-stack-";

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
                    if (loaded.ZeroTierPanelWidth > 0)
                        ZeroTierPanelWidth = loaded.ZeroTierPanelWidth;
                    ZeroTierAutoRefresh = loaded.ZeroTierAutoRefresh;
                    if (loaded.ZeroTierRefreshSeconds > 0)
                        ZeroTierRefreshSeconds = loaded.ZeroTierRefreshSeconds;
                    RouterDnsAdapter = loaded.RouterDnsAdapter;
                    RouterDns = loaded.RouterDns;
                    RouterGateway = loaded.RouterGateway;
                    RouterUpstreamAdapter = loaded.RouterUpstreamAdapter;
                    RouterDownstreamAdapter = loaded.RouterDownstreamAdapter;
                    if (!string.IsNullOrWhiteSpace(loaded.RouterIp)) RouterIp = loaded.RouterIp;
                    if (!string.IsNullOrWhiteSpace(loaded.RouterSubnet)) RouterSubnet = loaded.RouterSubnet;
                    if (!string.IsNullOrWhiteSpace(loaded.RouterDhcpStart)) RouterDhcpStart = loaded.RouterDhcpStart;
                    if (!string.IsNullOrWhiteSpace(loaded.RouterDhcpEnd)) RouterDhcpEnd = loaded.RouterDhcpEnd;
                    RouterAutoStart = loaded.RouterAutoStart;
                    RouterSharingActive = loaded.RouterSharingActive;
                    if (!string.IsNullOrWhiteSpace(loaded.KeyVaultUri)) KeyVaultUri = loaded.KeyVaultUri;
                    if (!string.IsNullOrWhiteSpace(loaded.KeyVaultSubscriptionId)) KeyVaultSubscriptionId = loaded.KeyVaultSubscriptionId;
                    if (!string.IsNullOrWhiteSpace(loaded.KeyVaultCaPrivateSecretName)) KeyVaultCaPrivateSecretName = loaded.KeyVaultCaPrivateSecretName;
                    if (!string.IsNullOrWhiteSpace(loaded.KeyVaultCaPublicSecretName)) KeyVaultCaPublicSecretName = loaded.KeyVaultCaPublicSecretName;
                    if (!string.IsNullOrWhiteSpace(loaded.KeyVaultCertValidity)) KeyVaultCertValidity = loaded.KeyVaultCertValidity;
                    if (!string.IsNullOrWhiteSpace(loaded.KeyVaultCertPrincipals)) KeyVaultCertPrincipals = loaded.KeyVaultCertPrincipals;
                    if (!string.IsNullOrWhiteSpace(loaded.KeyVaultOsSecretPrefix)) KeyVaultOsSecretPrefix = loaded.KeyVaultOsSecretPrefix;
                    if (!string.IsNullOrWhiteSpace(loaded.KeyVaultAppStackSecretPrefix)) KeyVaultAppStackSecretPrefix = loaded.KeyVaultAppStackSecretPrefix;
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
        public double ZeroTierPanelWidth { get; set; } = 400;
        public bool ZeroTierAutoRefresh { get; set; } = true;
        public int ZeroTierRefreshSeconds { get; set; } = 30;
        public string RouterDnsAdapter { get; set; } = "";
        public string RouterDns { get; set; } = "";
        public string RouterGateway { get; set; } = "";
        public string RouterUpstreamAdapter { get; set; } = "";
        public string RouterDownstreamAdapter { get; set; } = "";
        public string RouterIp { get; set; } = "10.1.1.1";
        public string RouterSubnet { get; set; } = "255.255.255.0";
        public string RouterDhcpStart { get; set; } = "10.1.1.100";
        public string RouterDhcpEnd { get; set; } = "10.1.1.254";
        public bool RouterAutoStart { get; set; }
        public bool RouterSharingActive { get; set; }
        public string KeyVaultUri { get; set; } = "";
        public string KeyVaultSubscriptionId { get; set; } = "";
        public string KeyVaultCaPrivateSecretName { get; set; } = "";
        public string KeyVaultCaPublicSecretName { get; set; } = "";
        public string KeyVaultCertValidity { get; set; } = "";
        public string KeyVaultCertPrincipals { get; set; } = "";
        public string KeyVaultOsSecretPrefix { get; set; } = "";
        public string KeyVaultAppStackSecretPrefix { get; set; } = "";
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
