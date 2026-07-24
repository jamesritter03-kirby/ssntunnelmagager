using System;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace RemoteStuff.Models;

/// <summary>Shared limits for the terminal text size (points).</summary>
public static class TerminalFontMetrics
{
    public const double Default = 13;
    public const double Min = 8;
    public const double Max = 36;
    public const double Step = 1;

    public static double Clamp(double size) => Math.Min(Max, Math.Max(Min, Math.Round(size)));
}

/// <summary>A single port-forwarding rule.</summary>
public sealed class PortForward
{
    public Guid Id { get; set; } = Guid.NewGuid();

    /// <summary>Optional user-facing name so several forwards can be told apart.</summary>
    public string Name { get; set; } = "";

    public ForwardType Type { get; set; } = ForwardType.Local;

    /// <summary>What the forwarded local port exposes (drives the "Open …" launchers).</summary>
    public ForwardCategory Category { get; set; } = ForwardCategory.None;

    /// <summary>Username for a categorized MQTT / Redis service.</summary>
    public string ServiceUsername { get; set; } = "";

    /// <summary>
    /// Service password captured in the editor, pending persistence into the
    /// encrypted <c>SecretStore</c> (keyed by this forward's <see cref="Id"/>).
    /// Never serialized. Null means "unchanged".
    /// </summary>
    [JsonIgnore]
    public string? PendingServicePassword { get; set; }

    /// <summary>Optional bind address for the listening side (e.g. 127.0.0.1, 0.0.0.0, *).</summary>
    public string BindAddress { get; set; } = "";

    /// <summary>The port that is opened / listened on.</summary>
    public string ListenPort { get; set; } = "";

    /// <summary>The destination host (used by -L and -R, ignored by -D).</summary>
    public string TargetHost { get; set; } = "localhost";

    /// <summary>The destination port (used by -L and -R, ignored by -D).</summary>
    public string TargetPort { get; set; } = "";

    /// <summary>Short one-line description for list rows.</summary>
    [JsonIgnore]
    public string Summary
    {
        get
        {
            var lp = string.IsNullOrEmpty(ListenPort) ? "?" : ListenPort;
            var tp = string.IsNullOrEmpty(TargetPort) ? "?" : TargetPort;
            return Type switch
            {
                ForwardType.Dynamic => $"SOCKS :{lp}",
                ForwardType.Local => $":{lp} → {TargetHost}:{tp}",
                ForwardType.Remote => $"srv:{lp} → {TargetHost}:{tp}",
                _ => ""
            };
        }
    }

    public PortForward Clone() => new()
    {
        Id = Guid.NewGuid(),
        Name = Name,
        Type = Type,
        Category = Category,
        ServiceUsername = ServiceUsername,
        BindAddress = BindAddress,
        ListenPort = ListenPort,
        TargetHost = TargetHost,
        TargetPort = TargetPort
    };

    /// <summary>True when this forward exposes a launchable service (web / MQTT / Redis).</summary>
    [JsonIgnore]
    public bool IsLaunchable => Category.IsLaunchable();

    /// <summary>The label for the "Open …" launcher button.</summary>
    [JsonIgnore]
    public string LaunchLabel => Category switch
    {
        ForwardCategory.Webpage => "Open Web",
        ForwardCategory.Mqtt => "Open MQTT",
        ForwardCategory.Redis => "Open Redis",
        _ => "Open"
    };
}

/// <summary>A reusable, named command the user can insert into a session's terminal.</summary>
public sealed class CommandSnippet
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Label { get; set; } = "";
    public string Command { get; set; } = "";
}

/// <summary>One environment variable sent to the server for a session (ssh SetEnv).</summary>
public sealed class EnvVar
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Value { get; set; } = "";

    /// <summary>A trimmed <c>NAME=VALUE</c> token, or null when the name is blank.</summary>
    [JsonIgnore]
    public string? SetEnvToken
    {
        get
        {
            var n = Name.Trim();
            return string.IsNullOrEmpty(n) ? null : $"{n}={Value}";
        }
    }
}

/// <summary>A saved web link the user can open in a browser.</summary>
public sealed class ProfileLink
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Label { get; set; } = "";
    public string Url { get; set; } = "";
}

/// <summary>A saved SSH connection + tunnel configuration.</summary>
public sealed class SshProfile
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "New Profile";

    /// <summary>When true this is a local shell profile (no SSH).</summary>
    public bool IsLocal { get; set; }

    /// <summary>For local profiles: the folder the shell starts in (supports ~).</summary>
    public string StartPath { get; set; } = "";

    public string Host { get; set; } = "";
    public string Port { get; set; } = "22";
    public string Username { get; set; } = "";

    /// <summary>Path to a private key file (optional). Supports ~ expansion.</summary>
    public string IdentityFile { get; set; } = "";

    public List<PortForward> Forwards { get; set; } = new();

    /// <summary>When true, open an interactive shell in addition to the tunnels.</summary>
    public bool OpenShell { get; set; } = true;

    public bool Compression { get; set; }
    public bool KeepAlive { get; set; } = true;
    public bool Verbose { get; set; }

    /// <summary>Optional ProxyJump host (-J), e.g. <c>user@bastion</c>.</summary>
    public string JumpHost { get; set; } = "";

    /// <summary>Extra raw ssh options appended verbatim.</summary>
    public string ExtraOptions { get; set; } = "";

    public bool ForwardAgent { get; set; }
    public bool AddKeysToAgent { get; set; }
    public bool RequestTty { get; set; }

    /// <summary>Seconds before giving up on establishing the connection. 0 = ssh default.</summary>
    public int ConnectTimeout { get; set; }

    public StrictHostKeyChecking StrictHostKeyChecking { get; set; } = StrictHostKeyChecking.Ask;

    /// <summary>A command to run on the server instead of an interactive shell.</summary>
    public string RemoteCommand { get; set; } = "";

    public List<EnvVar> Environment { get; set; } = new();

    /// <summary>A command automatically run in the terminal once the shell is ready.</summary>
    public string RunOnConnect { get; set; } = "";

    public bool AutoConnectOnLaunch { get; set; }
    public bool IsFavorite { get; set; }

    /// <summary>Optional group/folder name for organising the sidebar.</summary>
    public string Group { get; set; } = "";

    public string Theme { get; set; } = "pro";
    public double FontSize { get; set; } = TerminalFontMetrics.Default;

    public List<CommandSnippet> Snippets { get; set; } = new();
    public List<ProfileLink> Links { get; set; } = new();

    // --- Extended options (parity with the macOS app) ---

    /// <summary>An emoji/glyph shown as the profile icon in the sidebar and tabs.</summary>
    public string Icon { get; set; } = "";

    /// <summary>True only when <see cref="Icon"/> is a renderable emoji rather than an
    /// SF Symbol identifier (e.g. <c>macpro.gen3</c>) imported from the macOS app.
    /// SF Symbol names are plain ASCII; emoji contain non-ASCII code points.</summary>
    [JsonIgnore]
    public bool IconIsEmoji
    {
        get
        {
            if (string.IsNullOrWhiteSpace(Icon)) return false;
            foreach (var ch in Icon)
                if (ch > 0x7F) return true;
            return false;
        }
    }

    /// <summary>The icon to show in the UI — empty when <see cref="Icon"/> is a non-renderable
    /// SF Symbol name, so those don't appear as stray text next to the profile name.</summary>
    [JsonIgnore]
    public string DisplayIcon => IconIsEmoji ? Icon : "";

    /// <summary>Optional tab accent colour (hex like <c>#4C8BF5</c>, empty = default).</summary>
    public string TabColor { get; set; } = "";

    /// <summary>Use mosh (mobile shell) instead of plain ssh for the interactive shell.</summary>
    public bool UseMosh { get; set; }

    /// <summary>Automatically reconnect the session if it drops.</summary>
    public bool AutoReconnect { get; set; }

    /// <summary>Log the session's terminal output to a file under the app's Logs folder.</summary>
    public bool LogSession { get; set; }

    /// <summary>How the profile launches: into the current tab area or its own workspace.</summary>
    public WorkspaceLaunch WorkspaceLaunch { get; set; } = WorkspaceLaunch.Current;

    /// <summary>Optional display name for the workspace this profile launches into.
    /// When blank, the profile's own name is used, so several profiles that recreate
    /// the same template each get a distinct, recognisable workspace name.</summary>
    public string WorkspaceName { get; set; } = "";

    /// <summary>The saved-workspace template this profile recreates on launch (by name).
    /// Kept separate from <see cref="WorkspaceName"/> so the workspace can be named after
    /// the profile while still recreating a shared template.</summary>
    public string WorkspaceTemplateName { get; set; } = "";

    /// <summary>True when this profile was created via "Save Workspace as Profile".
    /// Such a launcher re-points its saved workspace template's ad-hoc tabs at this
    /// profile's own host, so relaunching moves the whole workspace to that server.</summary>
    public bool IsWorkspaceLauncher { get; set; }
    // --- Derived / display helpers (not serialized) ---

    /// <summary>
    /// Password captured in the editor, pending persistence into the encrypted
    /// <c>SecretStore</c>. Never serialized to the profiles JSON. Null means "unchanged".
    /// </summary>
    [JsonIgnore]
    public string? PendingPassword { get; set; }

    /// <summary><c>user@host</c> style subtitle for list rows.</summary>
    [JsonIgnore]
    public string Subtitle
    {
        get
        {
            var user = string.IsNullOrEmpty(Username) ? "" : $"{Username}@";
            var h = string.IsNullOrEmpty(Host) ? "—" : Host;
            var p = (string.IsNullOrEmpty(Port) || Port == "22") ? "" : $":{Port}";
            return $"{user}{h}{p}";
        }
    }

    /// <summary>Subtitle shown in the sidebar — local profiles show their start folder.</summary>
    [JsonIgnore]
    public string RowSubtitle
    {
        get
        {
            if (!IsLocal) return Subtitle;
            var p = StartPath.Trim();
            if (string.IsNullOrEmpty(p)) return "Local shell";
            var home = System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile);
            var shown = p.StartsWith(home, StringComparison.Ordinal) ? "~" + p[home.Length..] : p;
            return $"Local · {shown}";
        }
    }

    /// <summary>
    /// The local endpoints (host, port) opened by this profile's <c>-L</c>/<c>-D</c>
    /// forwards, used by the tunnel-health probe to check the ports are listening.
    /// </summary>
    [JsonIgnore]
    public System.Collections.Generic.IEnumerable<(string Host, int Port)> LocalForwardEndpoints
    {
        get
        {
            foreach (var f in Forwards)
            {
                if (f.Type != ForwardType.Local && f.Type != ForwardType.Dynamic) continue;
                if (!int.TryParse(f.ListenPort.Trim(), out var port) || port <= 0) continue;
                var host = f.BindAddress.Trim();
                if (host.Length == 0 || host == "*" || host == "0.0.0.0") host = "127.0.0.1";
                yield return (host, port);
            }
        }
    }

    public SshProfile Clone()
    {
        var copy = (SshProfile)MemberwiseClone();
        copy.Forwards = Forwards.ConvertAll(f => new PortForward
        {
            Id = f.Id,
            Name = f.Name,
            Type = f.Type,
            Category = f.Category,
            ServiceUsername = f.ServiceUsername,
            BindAddress = f.BindAddress,
            ListenPort = f.ListenPort,
            TargetHost = f.TargetHost,
            TargetPort = f.TargetPort
        });
        copy.Environment = Environment.ConvertAll(e => new EnvVar { Id = e.Id, Name = e.Name, Value = e.Value });
        copy.Snippets = Snippets.ConvertAll(s => new CommandSnippet { Id = s.Id, Label = s.Label, Command = s.Command });
        copy.Links = Links.ConvertAll(l => new ProfileLink { Id = l.Id, Label = l.Label, Url = l.Url });
        return copy;
    }
}
