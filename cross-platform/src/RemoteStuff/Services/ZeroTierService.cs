using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>
/// A cross-platform ZeroTier client. Works with ZeroTier Central
/// (api.zerotier.com) and self-hosted ZTNET controllers: the token is sent in
/// both the Central (<c>Authorization: token …</c>) and ZTNET
/// (<c>x-ztnet-auth</c>) headers so either server accepts it. Accounts are
/// persisted as JSON; their tokens live in the encrypted <see cref="SecretStore"/>.
/// </summary>
public sealed class ZeroTierService
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };

    private readonly SecretStore _secrets;
    private readonly string _accountsPath;

    private List<ZeroTierAccount> _accounts = new();
    private List<ZeroTierNetwork> _networks = new();
    private List<ZeroTierMember> _members = new();

    public IReadOnlyList<ZeroTierAccount> Accounts => _accounts;
    public IReadOnlyList<ZeroTierNetwork> Networks => _networks;
    public IReadOnlyList<ZeroTierMember> Members => _members;

    /// <summary>Raised (on a background thread) whenever cached data changes.</summary>
    public event Action? Updated;

    public bool HasAccounts => _accounts.Count > 0;

    /// <summary>
    /// The single live instance, set on construction. Lets lightweight UI
    /// controls (e.g. the globe IP picker) reach ZeroTier data without threading
    /// the service through every view-model constructor.
    /// </summary>
    public static ZeroTierService? Shared { get; private set; }

    public ZeroTierService(SecretStore secrets)
    {
        _secrets = secrets;
        Shared = this;
        var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(baseDir))
            baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        var dir = Path.Combine(baseDir, "RemoteStuff");
        Directory.CreateDirectory(dir);
        _accountsPath = Path.Combine(dir, "zerotier-accounts.json");
        LoadAccounts();
    }

    // ---- Accounts ----

    private void LoadAccounts()
    {
        try
        {
            if (File.Exists(_accountsPath))
                _accounts = JsonSerializer.Deserialize<List<ZeroTierAccount>>(File.ReadAllText(_accountsPath))
                            ?? new();
        }
        catch { _accounts = new(); }
    }

    private void SaveAccounts()
    {
        try
        {
            File.WriteAllText(_accountsPath,
                JsonSerializer.Serialize(_accounts, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { /* best effort */ }
    }

    public ZeroTierAccount AddAccount(string label, string baseUrl, string token)
    {
        var account = new ZeroTierAccount
        {
            Label = label,
            BaseUrl = string.IsNullOrWhiteSpace(baseUrl) ? ZeroTierAccount.CentralBaseUrl : baseUrl.Trim()
        };
        _accounts.Add(account);
        SaveAccounts();
        _secrets.Set(account.Id, token);
        return account;
    }

    public void RemoveAccount(Guid id)
    {
        _accounts.RemoveAll(a => a.Id == id);
        SaveAccounts();
        _secrets.Set(id, null);
        _networks.RemoveAll(n => n.AccountId == id);
        _members.RemoveAll(m => m.AccountId == id);
        Updated?.Invoke();
    }

    public string? TokenFor(Guid accountId) => _secrets.Get(accountId);

    // ---- Saved "Connect as" credentials (shared across accounts) ----

    private const string ConnectPasswordKey = "zt-connect-password";

    /// <summary>The remembered "Connect as" password, or null if none saved.</summary>
    public string? GetConnectPassword() => _secrets.Get(ConnectPasswordKey);

    /// <summary>Persist (or clear, when null/empty) the "Connect as" password.</summary>
    public void SetConnectPassword(string? password) => _secrets.Set(ConnectPasswordKey, password);

    // ---- Refresh ----

    public async Task RefreshAsync()
    {
        var networks = new List<ZeroTierNetwork>();
        var members = new List<ZeroTierMember>();

        foreach (var account in _accounts.ToList())
        {
            var token = _secrets.Get(account.Id);
            if (string.IsNullOrEmpty(token)) continue;

            try
            {
                var accountNetworks = new List<ZeroTierNetwork>();

                // Personal / Central route first.
                var personal = await GetArrayAsync(account.BaseUrl, token, "/network");
                if (personal is not null)
                    foreach (var e in personal.Value.EnumerateArray())
                    {
                        var n = ZeroTierNetwork.FromJson(e);
                        n.AccountId = account.Id;
                        accountNetworks.Add(n);
                    }

                // Self-hosted org-scoped tokens: enumerate orgs then their networks.
                var orgs = await GetArrayAsync(account.BaseUrl, token, "/org");
                if (orgs is not null)
                {
                    foreach (var orgEl in orgs.Value.EnumerateArray())
                    {
                        var orgId = orgEl.GetStringOr("id");
                        if (string.IsNullOrEmpty(orgId)) continue;
                        var orgNetworks = await GetArrayAsync(account.BaseUrl, token, $"/org/{orgId}/network");
                        if (orgNetworks is null) continue;
                        foreach (var e in orgNetworks.Value.EnumerateArray())
                        {
                            var n = ZeroTierNetwork.FromJson(e);
                            n.AccountId = account.Id;
                            n.OrgId = orgId;
                            if (accountNetworks.All(x => x.Id != n.Id))
                                accountNetworks.Add(n);
                        }
                    }
                }

                foreach (var n in accountNetworks)
                {
                    networks.Add(n);
                    var path = n.OrgId is null
                        ? $"/network/{n.Id}/member"
                        : $"/org/{n.OrgId}/network/{n.Id}/member";
                    var mem = await GetArrayAsync(account.BaseUrl, token, path);
                    if (mem is null) continue;
                    foreach (var e in mem.Value.EnumerateArray())
                    {
                        var m = ZeroTierMember.FromJson(e);
                        if (string.IsNullOrEmpty(m.NetworkId)) m.NetworkId = n.Id;
                        m.AccountId = account.Id;
                        m.OrgId = n.OrgId;
                        members.Add(m);
                    }
                }
            }
            catch
            {
                // Skip an unreachable / mis-configured account; others still load.
            }
        }

        await RefreshLocalAsync();

        _networks = networks;
        _members = members;
        Updated?.Invoke();
    }

    // ---- Local node (this device's own joined networks, via loopback service) ----

    // networkId (lowercased) -> live join status on this device (e.g. "OK").
    private Dictionary<string, string> _localStatus = new();

    /// <summary>
    /// This device's join status for a network id (e.g. <c>"OK"</c> when the tunnel
    /// is up), or <c>null</c> if it hasn't joined that network / the local service
    /// is unavailable.
    /// </summary>
    public string? LocalStatusFor(string? networkId)
    {
        if (string.IsNullOrWhiteSpace(networkId)) return null;
        return _localStatus.TryGetValue(networkId.Trim().ToLowerInvariant(), out var s) ? s : null;
    }

    private async Task RefreshLocalAsync()
    {
        var token = ReadLocalAuthToken();
        if (string.IsNullOrEmpty(token)) { _localStatus = new(); return; }
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, "http://127.0.0.1:9993/network");
            req.Headers.TryAddWithoutValidation("X-ZT1-Auth", token);
            req.Headers.TryAddWithoutValidation("Accept", "application/json");
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            using var resp = await Http.SendAsync(req, cts.Token);
            if (!resp.IsSuccessStatusCode) { _localStatus = new(); return; }
            var json = await resp.Content.ReadAsStringAsync(cts.Token);
            using var doc = JsonDocument.Parse(json);
            var map = new Dictionary<string, string>();
            if (doc.RootElement.ValueKind == JsonValueKind.Array)
            {
                foreach (var e in doc.RootElement.EnumerateArray())
                {
                    var id = (e.GetStringOr("id") ?? e.GetStringOr("nwid") ?? "").ToLowerInvariant();
                    if (string.IsNullOrEmpty(id)) continue;
                    map[id] = e.GetStringOr("status") ?? "";
                }
            }
            _localStatus = map;
        }
        catch { _localStatus = new(); }
    }

    /// <summary>
    /// Read the local ZeroTier service's API token. The desktop installers leave a
    /// user-readable copy under the platform's app-data folder; fall back to the
    /// system-owned copies where readable.
    /// </summary>
    private static string? ReadLocalAuthToken()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var commonData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        var candidates = new[]
        {
            Path.Combine(home, "Library", "Application Support", "ZeroTier", "One", "authtoken.secret"),
            "/Library/Application Support/ZeroTier/One/authtoken.secret",
            "/var/lib/zerotier-one/authtoken.secret",
            Path.Combine(commonData, "ZeroTier", "One", "authtoken.secret"),
        };
        foreach (var path in candidates)
        {
            try
            {
                if (File.Exists(path))
                {
                    var t = File.ReadAllText(path).Trim();
                    if (!string.IsNullOrEmpty(t)) return t;
                }
            }
            catch { /* not readable — try the next candidate */ }
        }
        return null;
    }

    /// <summary>Find a member whose assigned IP matches <paramref name="ip"/> (for sidebar dots).</summary>
    public ZeroTierMember? MemberForIp(string? ip)
    {
        if (string.IsNullOrWhiteSpace(ip)) return null;
        var needle = ip.Trim();
        return _members.FirstOrDefault(m =>
            m.IpAssignments.Any(a => string.Equals(a, needle, StringComparison.OrdinalIgnoreCase)));
    }

    public bool IsHostOnline(string? host) => MemberForIp(host)?.IsOnline ?? false;

    public IEnumerable<ZeroTierMember> MembersOf(ZeroTierNetwork network) =>
        _members.Where(m => m.NetworkId == network.Id && m.AccountId == network.AccountId);

    // ---- Member authorization (write) ----

    public async Task SetAuthorizedAsync(ZeroTierMember member, bool authorized)
    {
        var account = _accounts.FirstOrDefault(a => a.Id == member.AccountId);
        if (account is null)
            throw new InvalidOperationException("No ZeroTier account is linked to this device.");
        var token = _secrets.Get(account.Id);
        if (string.IsNullOrEmpty(token))
            throw new InvalidOperationException("No API token saved for this account.");

        string path;
        object body;
        if (member.OrgId is null)
        {
            path = $"/network/{member.NetworkId}/member/{member.NodeId}";
            body = new { config = new { authorized } };
        }
        else
        {
            path = $"/org/{member.OrgId}/network/{member.NetworkId}/member/{member.NodeId}";
            body = new { authorized, config = new { authorized } };
        }

        await PostAsync(account.BaseUrl, token, path, body);
        member.Authorized = authorized;
        Updated?.Invoke();
    }

    public async Task SetDescriptionAsync(ZeroTierMember member, string description)
    {
        var account = _accounts.FirstOrDefault(a => a.Id == member.AccountId);
        if (account is null)
            throw new InvalidOperationException("No ZeroTier account is linked to this device.");
        var token = _secrets.Get(account.Id);
        if (string.IsNullOrEmpty(token))
            throw new InvalidOperationException("No API token saved for this account.");

        var path = member.OrgId is null
            ? $"/network/{member.NetworkId}/member/{member.NodeId}"
            : $"/org/{member.OrgId}/network/{member.NetworkId}/member/{member.NodeId}";

        await PostAsync(account.BaseUrl, token, path, new { description });
        member.Description = description;
        Updated?.Invoke();
    }

    // ---- HTTP ----

    private static async Task<JsonElement?> GetArrayAsync(string baseUrl, string token, string path)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, baseUrl.TrimEnd('/') + path);
        AddAuth(req, token);
        using var resp = await Http.SendAsync(req);
        if (!resp.IsSuccessStatusCode) return null;
        var json = await resp.Content.ReadAsStringAsync();
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return null;
            // Clone so the element outlives the disposed document.
            return doc.RootElement.Clone();
        }
        catch { return null; }
    }

    private static async Task PostAsync(string baseUrl, string token, string path, object body)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, baseUrl.TrimEnd('/') + path);
        AddAuth(req, token);
        req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        using var resp = await Http.SendAsync(req);
        resp.EnsureSuccessStatusCode();
    }

    private static void AddAuth(HttpRequestMessage req, string token)
    {
        req.Headers.TryAddWithoutValidation("Authorization", "token " + token); // Central
        req.Headers.TryAddWithoutValidation("x-ztnet-auth", token);             // self-hosted (ZTNET)
        req.Headers.TryAddWithoutValidation("Accept", "application/json");
    }
}
