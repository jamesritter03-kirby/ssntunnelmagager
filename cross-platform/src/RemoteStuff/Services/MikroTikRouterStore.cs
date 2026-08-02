using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>
/// Persists the user's saved MikroTik routers as JSON in the app config
/// directory. Router metadata (name/host/port/user/https) lives in the JSON
/// file; passwords are stored in the shared <see cref="SecretStore"/> under the
/// key <c>mikrotik:{id}</c>, so no plaintext password ever touches the JSON.
/// </summary>
public sealed class MikroTikRouterStore
{
    private readonly string _path;
    private readonly SecretStore _secrets;
    private List<MikroTikRouter> _routers = new();

    public MikroTikRouterStore(SecretStore secrets)
    {
        _secrets = secrets;
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir))
            baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var dir = Path.Combine(baseDir, "RemoteStuff");
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, "mikrotik-routers.json");
        Load();
    }

    /// <summary>A stable snapshot of the saved routers.</summary>
    public IReadOnlyList<MikroTikRouter> Routers => _routers;

    public bool HasRouters => _routers.Count > 0;

    private static string SecretKey(Guid id) => "mikrotik:" + id.ToString("N");

    public string? Password(Guid id) => _secrets.Get(SecretKey(id));

    /// <summary>Add a router; its password (if any) goes to the secret store.</summary>
    public void Add(MikroTikRouter router, string? password)
    {
        if (string.IsNullOrWhiteSpace(router.Host)) return;
        if (router.Id == Guid.Empty) router.Id = Guid.NewGuid();
        _routers.Add(router);
        if (!string.IsNullOrEmpty(password)) _secrets.Set(SecretKey(router.Id), password);
        Save();
    }

    /// <summary>Update an existing router; pass a non-null password to change it.</summary>
    public void Update(MikroTikRouter router, string? password)
    {
        var idx = _routers.FindIndex(r => r.Id == router.Id);
        if (idx < 0) return;
        _routers[idx] = router;
        if (password is not null && password.Length > 0) _secrets.Set(SecretKey(router.Id), password);
        Save();
    }

    public void Remove(Guid id)
    {
        _routers.RemoveAll(r => r.Id == id);
        _secrets.Set(SecretKey(id), null);
        Save();
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_path)) return;
            var json = File.ReadAllText(_path);
            var list = JsonSerializer.Deserialize<List<MikroTikRouter>>(json);
            if (list is not null)
                _routers = list.Where(r => r.Id != Guid.Empty).ToList();
        }
        catch { /* ignore a corrupt file — start empty */ }
    }

    private void Save()
    {
        try
        {
            var json = JsonSerializer.Serialize(_routers, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(_path, json);
        }
        catch { /* best effort */ }
    }
}
