using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>
/// Loads and persists SSH profiles as JSON under the platform's per-user app-data
/// directory. A cross-platform port of the original Swift <c>ProfileStore</c>.
/// </summary>
public sealed class ProfileStore
{
    private readonly string _fileURL;
    private readonly string _seededFlagPath;
    private readonly string _workspacesURL;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    public List<SshProfile> Profiles { get; private set; } = new();

    /// <summary>Absolute path of the profiles file (shown in the UI).</summary>
    public string StoragePath => _fileURL;

    public ProfileStore()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir))
            baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var dir = Path.Combine(baseDir, "RemoteStuff");
        Directory.CreateDirectory(dir);
        _fileURL = Path.Combine(dir, "profiles.json");
        _seededFlagPath = Path.Combine(dir, ".seeded");
        _workspacesURL = Path.Combine(dir, "workspaces.json");

        Load();
        LoadWorkspaces();
    }

    private void Load()
    {
        try
        {
            if (File.Exists(_fileURL))
            {
                var data = File.ReadAllText(_fileURL);
                var decoded = JsonSerializer.Deserialize<List<SshProfile>>(data, JsonOptions);
                if (decoded != null)
                    Profiles = decoded;
            }
        }
        catch
        {
            // Corrupt or unreadable file: start empty rather than crash.
            Profiles = new List<SshProfile>();
        }

        // On the very first launch (no saved profiles, never seeded) add examples.
        if (Profiles.Count == 0 && !File.Exists(_seededFlagPath))
        {
            Profiles = ExampleProfiles.All();
            try { File.WriteAllText(_seededFlagPath, DateTime.UtcNow.ToString("o")); } catch { /* ignore */ }
            Save();
        }
    }

    public void Save()
    {
        try
        {
            var data = JsonSerializer.Serialize(Profiles, JsonOptions);
            var tmp = _fileURL + ".tmp";
            File.WriteAllText(tmp, data);
            File.Move(tmp, _fileURL, overwrite: true);
        }
        catch
        {
            // Best-effort save; ignore transient IO errors.
        }
    }

    /// <summary>
    /// Re-read the profiles file from disk, replacing the in-memory list. Used after an
    /// external change to <c>profiles.json</c> (e.g. a Git pull). Keeps the current list
    /// on any read/parse error.
    /// </summary>
    public void Reload()
    {
        try
        {
            if (File.Exists(_fileURL))
            {
                var decoded = JsonSerializer.Deserialize<List<SshProfile>>(File.ReadAllText(_fileURL), JsonOptions);
                if (decoded != null) Profiles = decoded;
            }
        }
        catch
        {
            // Keep the current in-memory profiles on a bad read.
        }
    }

    // MARK: - Mutations

    public void Add(SshProfile profile)
    {
        Profiles.Add(profile);
        Save();
    }

    public void Update(SshProfile profile)
    {
        var idx = Profiles.FindIndex(p => p.Id == profile.Id);
        if (idx >= 0) Profiles[idx] = profile;
        else Profiles.Add(profile);
        Save();
    }

    public void Delete(SshProfile profile)
    {
        Profiles.RemoveAll(p => p.Id == profile.Id);
        Save();
    }

    /// <summary>
    /// Swap the positions of two profiles in the flat, persisted order. Used by the
    /// sidebar to reorder adjacent rows within a group. Returns true if both were found.
    /// </summary>
    public bool Swap(Guid a, Guid b)
    {
        var ia = Profiles.FindIndex(p => p.Id == a);
        var ib = Profiles.FindIndex(p => p.Id == b);
        if (ia < 0 || ib < 0 || ia == ib) return false;
        (Profiles[ia], Profiles[ib]) = (Profiles[ib], Profiles[ia]);
        Save();
        return true;
    }

    public SshProfile Duplicate(SshProfile profile)
    {
        var copy = profile.Clone();
        copy.Id = Guid.NewGuid();
        copy.Name += " copy";
        var idx = Profiles.FindIndex(p => p.Id == profile.Id);
        if (idx >= 0) Profiles.Insert(idx + 1, copy);
        else Profiles.Add(copy);
        Save();
        return copy;
    }

    /// <summary>Append imported profiles, giving each a unique display name.</summary>
    public int ImportProfiles(IEnumerable<SshProfile> incoming)
    {
        var added = 0;
        foreach (var profile in incoming)
        {
            profile.Id = Guid.NewGuid();
            profile.Name = UniqueName(profile.Name);
            Profiles.Add(profile);
            added++;
        }
        if (added > 0) Save();
        return added;
    }

    /// <summary>Serialize every profile to a JSON document (for Export).</summary>
    public string ExportJson() => JsonSerializer.Serialize(Profiles, JsonOptions);

    /// <summary>Serialize a single profile to JSON.</summary>
    public string ExportJson(SshProfile profile) =>
        JsonSerializer.Serialize(new[] { profile }, JsonOptions);

    /// <summary>Parse a JSON document (array or single object) and import its profiles.</summary>
    public int ImportJson(string json)
    {
        List<SshProfile>? incoming = null;
        var trimmed = json.TrimStart();
        if (trimmed.StartsWith("["))
        {
            incoming = JsonSerializer.Deserialize<List<SshProfile>>(json, JsonOptions);
        }
        else
        {
            var one = JsonSerializer.Deserialize<SshProfile>(json, JsonOptions);
            if (one != null) incoming = new List<SshProfile> { one };
        }
        return incoming == null ? 0 : ImportProfiles(incoming);
    }

    /// <summary>A display name that doesn't already exist, suffixing " (2)", " (3)"…</summary>
    public string UniqueName(string proposed)
    {
        var trimmed = proposed.Trim();
        var baseName = trimmed.Length == 0 ? "Imported Profile" : trimmed;
        var existing = Profiles.Select(p => p.Name).ToHashSet();
        if (!existing.Contains(baseName)) return baseName;
        var n = 2;
        while (existing.Contains($"{baseName} ({n})")) n++;
        return $"{baseName} ({n})";
    }

    // MARK: - Saved workspace templates

    /// <summary>Saved workspace templates (name + the profile ids to reopen).</summary>
    public List<WorkspaceTemplate> WorkspaceTemplates { get; private set; } = new();

    private void LoadWorkspaces()
    {
        try
        {
            if (File.Exists(_workspacesURL))
            {
                var decoded = JsonSerializer.Deserialize<List<WorkspaceTemplate>>(
                    File.ReadAllText(_workspacesURL), JsonOptions);
                if (decoded != null) WorkspaceTemplates = decoded;
            }
        }
        catch
        {
            WorkspaceTemplates = new List<WorkspaceTemplate>();
        }
    }

    private void SaveWorkspaces()
    {
        try
        {
            var data = JsonSerializer.Serialize(WorkspaceTemplates, JsonOptions);
            var tmp = _workspacesURL + ".tmp";
            File.WriteAllText(tmp, data);
            File.Move(tmp, _workspacesURL, overwrite: true);
        }
        catch { /* best-effort */ }
    }

    /// <summary>Snapshot a workspace's full tab set under a name, replacing any of
    /// the same name. Every tab kind (ssh, sftp, vnc, browser, finder…) is captured,
    /// not just profile-backed ones, along with each tab's dock edge and the drawer
    /// collapse/size state, so reopening rebuilds the workspace exactly.</summary>
    public void SaveWorkspaceTemplate(WorkspaceTemplate template)
    {
        template.Name = string.IsNullOrWhiteSpace(template.Name) ? "Workspace" : template.Name.Trim();
        WorkspaceTemplates.RemoveAll(w => w.Name.Equals(template.Name, StringComparison.OrdinalIgnoreCase));
        WorkspaceTemplates.Add(template);
        SaveWorkspaces();
    }

    public void DeleteWorkspaceTemplate(string name)
    {
        WorkspaceTemplates.RemoveAll(w => w.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
        SaveWorkspaces();
    }

    // MARK: - Last session (resume at launch)

    private string SessionPath => Path.ChangeExtension(_workspacesURL, null) + "-lastsession.json";

    public void SaveLastSession(SessionSnapshot snapshot)
    {
        try
        {
            var tmp = SessionPath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(snapshot, JsonOptions));
            File.Move(tmp, SessionPath, overwrite: true);
        }
        catch { /* best-effort */ }
    }

    public SessionSnapshot? LoadLastSession()
    {
        try
        {
            if (File.Exists(SessionPath))
                return JsonSerializer.Deserialize<SessionSnapshot>(File.ReadAllText(SessionPath), JsonOptions);
        }
        catch { /* ignore */ }
        return null;
    }
}

/// <summary>A saved workspace: a name plus the ordered tabs to reopen. Older files
/// stored only <see cref="ProfileIds"/>; newer ones capture a full
/// <see cref="Tabs"/> snapshot (every tab kind, profile-backed or ad-hoc).</summary>
public sealed class WorkspaceTemplate
{
    public string Name { get; set; } = "";
    public string Color { get; set; } = "";
    /// <summary>Legacy: profile ids only. Read for backward compatibility when
    /// <see cref="Tabs"/> is empty.</summary>
    public List<Guid> ProfileIds { get; set; } = new();
    /// <summary>The full ordered tab snapshot to recreate.</summary>
    public List<TabSnapshot> Tabs { get; set; } = new();

    // Drawer (edge dock) state, so a reopened workspace restores which drawers were
    // collapsed and how wide/tall they were. Widths of 0 mean "use the default".
    public bool LeftCollapsed { get; set; }
    public bool RightCollapsed { get; set; }
    public bool TopCollapsed { get; set; }
    public bool BottomCollapsed { get; set; }
    public double LeftWidth { get; set; }
    public double RightWidth { get; set; }
    public double TopHeight { get; set; }
    public double BottomHeight { get; set; }
}

/// <summary>A codable description of one open tab, enough to recreate it: its kind
/// plus whatever address / profile / path that kind needs. Passwords are never
/// stored — ad-hoc tabs prompt again on reconnect, matching the macOS app.</summary>
public sealed class TabSnapshot
{
    /// <summary>A stable per-tab id. Ad-hoc tab credentials (MQTT / Redis) are stored
    /// in the encrypted <c>SecretStore</c> keyed by this id, so a saved workspace can
    /// remember them without writing plaintext into the workspace JSON.</summary>
    public Guid Id { get; set; } = Guid.NewGuid();
    /// <summary>ssh · local · sftp · vnc · vnc-tunnel · browser · finder · mqtt · redis · network · mikrotik</summary>
    public string Kind { get; set; } = "";
    /// <summary>The originating profile's id, when profile-backed. Recreation prefers
    /// a matching saved profile; otherwise it rebuilds an ad-hoc tab from
    /// host/port/username.</summary>
    public Guid? ProfileId { get; set; }
    public string? Title { get; set; }
    public string? Host { get; set; }
    public int Port { get; set; }
    public string? Username { get; set; }
    /// <summary>Browser tabs: the URL to load.</summary>
    public string? Url { get; set; }
    /// <summary>SFTP / Finder tabs: the directory to open at.</summary>
    public string? Path { get; set; }
    /// <summary>ssh / local terminal tabs: a per-tab command auto-run on connect,
    /// independent of the backing profile's runOnConnect. Lets several tabs on the
    /// same server each fire a different command.</summary>
    public string? RunOnConnect { get; set; }
    /// <summary>Which edge this tab was docked to (Center = the main tab area).</summary>
    public DockSide Dock { get; set; } = DockSide.Center;
    /// <summary>Per-tab terminal colour theme id, overriding the profile default.</summary>
    public string? ThemeId { get; set; }
    /// <summary>Per-tab terminal font size (0 = fall back to the profile/default).</summary>
    public double FontSize { get; set; }
    /// <summary>Optional per-tab accent colour (hex, empty/null = none).</summary>
    public string? TabColor { get; set; }
    /// <summary>Optional user-supplied custom tab name (empty/null = auto title).</summary>
    public string? CustomTitle { get; set; }
}

/// <summary>The last open session (restored at launch when enabled).</summary>
public sealed class SessionSnapshot
{
    public List<WorkspaceTemplate> Workspaces { get; set; } = new();
}
