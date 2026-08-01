using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text.Json;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>
/// App-wide reusable commands surfaced in the command palette. A cross-platform port
/// of the macOS <c>CustomCommandStore</c> — persists as JSON alongside the profiles.
/// </summary>
public sealed class CustomCommandStore
{
    /// <summary>The single shared instance used by the command palette.</summary>
    public static CustomCommandStore Shared { get; } = new();

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };

    private readonly string _path;

    /// <summary>The saved commands, in the order they were added.</summary>
    public ObservableCollection<CustomCommand> Commands { get; } = new();

    private CustomCommandStore()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir))
            baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var dir = Path.Combine(baseDir, "RemoteStuff");
        Directory.CreateDirectory(dir);
        _path = Path.Combine(dir, "custom-commands.json");
        Load();
    }

    public void Add(CustomCommand command)
    {
        Commands.Add(command);
        Save();
    }

    public void Remove(CustomCommand command)
    {
        if (Commands.Remove(command)) Save();
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_path)) return;
            var loaded = JsonSerializer.Deserialize<List<CustomCommand>>(File.ReadAllText(_path), JsonOptions);
            if (loaded == null) return;
            foreach (var c in loaded) Commands.Add(c);
        }
        catch { /* keep empty on any read/parse error */ }
    }

    public void Save()
    {
        try
        {
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(Commands.ToList(), JsonOptions));
            File.Move(tmp, _path, overwrite: true);
        }
        catch { /* best-effort persistence */ }
    }
}
