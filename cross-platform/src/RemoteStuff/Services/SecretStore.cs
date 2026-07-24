using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RemoteStuff.Services;

/// <summary>
/// A cross-platform, AES-encrypted store for per-profile secrets (passwords /
/// key passphrases). There is no OS keychain dependency: secrets are encrypted
/// with a random 256-bit key kept in a 0600 key file beside the data file.
/// This is a convenience store, not a hardened vault.
/// </summary>
public sealed class SecretStore
{
    private readonly string _dataPath;
    private readonly string _keyPath;
    private readonly byte[] _key;
    private Dictionary<string, string> _secrets = new();

    public SecretStore()
    {
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir))
            baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var dir = Path.Combine(baseDir, "RemoteStuff");
        Directory.CreateDirectory(dir);
        _dataPath = Path.Combine(dir, "secrets.dat");
        _keyPath = Path.Combine(dir, "secret.key");
        _key = LoadOrCreateKey();
        Load();
    }

    private byte[] LoadOrCreateKey()
    {
        try
        {
            if (File.Exists(_keyPath))
            {
                var existing = File.ReadAllBytes(_keyPath);
                if (existing.Length == 32) return existing;
            }
        }
        catch { /* fall through and regenerate */ }

        var key = RandomNumberGenerator.GetBytes(32);
        try
        {
            File.WriteAllBytes(_keyPath, key);
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(_keyPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        catch { /* best effort */ }
        return key;
    }

    private void Load()
    {
        try
        {
            if (!File.Exists(_dataPath)) return;
            var blob = File.ReadAllBytes(_dataPath);
            if (blob.Length < 12 + 16) return;
            var nonce = blob.AsSpan(0, 12).ToArray();
            var tag = blob.AsSpan(12, 16).ToArray();
            var cipher = blob.AsSpan(28).ToArray();
            var plain = new byte[cipher.Length];
            using var aes = new AesGcm(_key, 16);
            aes.Decrypt(nonce, cipher, tag, plain);
            var json = Encoding.UTF8.GetString(plain);
            _secrets = JsonSerializer.Deserialize<Dictionary<string, string>>(json) ?? new();
        }
        catch
        {
            _secrets = new();
        }
    }

    private void Save()
    {
        try
        {
            var json = JsonSerializer.Serialize(_secrets);
            var plain = Encoding.UTF8.GetBytes(json);
            var nonce = RandomNumberGenerator.GetBytes(12);
            var tag = new byte[16];
            var cipher = new byte[plain.Length];
            using var aes = new AesGcm(_key, 16);
            aes.Encrypt(nonce, plain, cipher, tag);

            using var ms = new MemoryStream();
            ms.Write(nonce);
            ms.Write(tag);
            ms.Write(cipher);
            var tmp = _dataPath + ".tmp";
            File.WriteAllBytes(tmp, ms.ToArray());
            File.Move(tmp, _dataPath, overwrite: true);
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(_dataPath, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        catch { /* best effort */ }
    }

    public string? Get(Guid profileId) =>
        _secrets.TryGetValue(profileId.ToString(), out var v) ? v : null;

    public bool Has(Guid profileId) => _secrets.ContainsKey(profileId.ToString());

    public void Set(Guid profileId, string? password)
    {
        var key = profileId.ToString();
        if (string.IsNullOrEmpty(password)) _secrets.Remove(key);
        else _secrets[key] = password;
        Save();
    }

    /// <summary>Get a secret by an arbitrary string key (for app-level saved values).</summary>
    public string? Get(string key) =>
        _secrets.TryGetValue(key, out var v) ? v : null;

    /// <summary>Store (or clear, when null/empty) a secret under an arbitrary string key.</summary>
    public void Set(string key, string? value)
    {
        if (string.IsNullOrEmpty(value)) _secrets.Remove(key);
        else _secrets[key] = value;
        Save();
    }
}
