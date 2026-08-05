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

    /// <summary>
    /// Probe an account's base URL + token with a single request. Returns null when
    /// the controller is reachable and the token is accepted; otherwise a
    /// human-readable reason (bad host, timeout, unauthorized, wrong path) so a
    /// typo'd URL surfaces a clear error instead of silently showing no networks.
    /// </summary>
    public async Task<string?> TestConnectionAsync(string baseUrl, string token)
    {
        baseUrl = string.IsNullOrWhiteSpace(baseUrl) ? ZeroTierAccount.CentralBaseUrl : baseUrl.Trim();
        if (string.IsNullOrWhiteSpace(token)) return "No API token was provided.";
        try
        {
            using var resp = await SendAsync(baseUrl, token, HttpMethod.Get, "/network", null);
            if (resp.IsSuccessStatusCode) return null;
            if ((int)resp.StatusCode is 401 or 403)
            {
                // An org-scoped token may be denied on /network but allowed on /org.
                using var orgResp = await SendAsync(baseUrl, token, HttpMethod.Get, "/org", null);
                if (orgResp.IsSuccessStatusCode) return null;
                return "The server rejected the API token (unauthorized). Check the token.";
            }
            if ((int)resp.StatusCode == 404)
                return "The server didn't recognize the ZeroTier API." + SuggestApiPath(baseUrl);
            return $"The server returned {(int)resp.StatusCode} {resp.ReasonPhrase}. Check the base URL and token." + SuggestApiPath(baseUrl);
        }
        catch (TaskCanceledException)
        {
            return "The server didn't respond in time. Check the base URL and that the controller is running.";
        }
        catch (HttpRequestException ex)
        {
            return "Couldn't reach the server — " + FriendlyNetworkError(ex) + " Check the base URL for typos." + SuggestApiPath(baseUrl);
        }
        catch (UriFormatException)
        {
            return "The base URL isn't valid. It should look like https://host/api/v1.";
        }
    }

    /// <summary>Suggest the conventional <c>/api/v1</c> suffix when a non-Central base
    /// URL is missing it — a common cause of "wrong API path" failures.</summary>
    private static string SuggestApiPath(string baseUrl)
    {
        var trimmed = baseUrl.TrimEnd('/');
        if (trimmed.EndsWith("/api/v1", StringComparison.OrdinalIgnoreCase)) return string.Empty;
        return $" The URL usually ends in /api/v1 — try {trimmed}/api/v1.";
    }

    /// <summary>Unwrap a network exception to a short, plain reason (DNS/refused/timeout).</summary>
    private static string FriendlyNetworkError(Exception ex)
    {
        var inner = ex;
        while (inner.InnerException is not null) inner = inner.InnerException;
        if (inner is System.Net.Sockets.SocketException se)
        {
            return se.SocketErrorCode switch
            {
                System.Net.Sockets.SocketError.HostNotFound => "the host name couldn't be found (DNS lookup failed).",
                System.Net.Sockets.SocketError.TryAgain => "the host name couldn't be resolved (DNS lookup failed).",
                System.Net.Sockets.SocketError.ConnectionRefused => "the connection was refused.",
                System.Net.Sockets.SocketError.TimedOut => "the connection timed out.",
                System.Net.Sockets.SocketError.NetworkUnreachable => "the network is unreachable.",
                System.Net.Sockets.SocketError.HostUnreachable => "the host is unreachable.",
                _ => inner.Message
            };
        }
        return inner.Message;
    }

    // ---- Local node (this device's own joined networks, via loopback service) ----

    // networkId (lowercased) -> live join status on this device (e.g. "OK").
    private Dictionary<string, string> _localStatus = new();

    /// <summary>True when the local ZeroTier service responded during the last refresh.
    /// When false, member-of filtering cannot work and should be skipped gracefully.</summary>
    public bool LocalDaemonAvailable { get; private set; }

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
        if (string.IsNullOrEmpty(token)) { _localStatus = new(); LocalDaemonAvailable = false; return; }
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, "http://127.0.0.1:9993/network");
            req.Headers.TryAddWithoutValidation("X-ZT1-Auth", token);
            req.Headers.TryAddWithoutValidation("Accept", "application/json");
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(4));
            using var resp = await Http.SendAsync(req, cts.Token);
            if (!resp.IsSuccessStatusCode) { _localStatus = new(); LocalDaemonAvailable = false; return; }
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
            LocalDaemonAvailable = true;
        }
        catch { _localStatus = new(); LocalDaemonAvailable = false; }
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
        var localData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var candidates = new[]
        {
            // macOS / Linux service copies.
            Path.Combine(home, "Library", "Application Support", "ZeroTier", "One", "authtoken.secret"),
            "/Library/Application Support/ZeroTier/One/authtoken.secret",
            "/var/lib/zerotier-one/authtoken.secret",
            // Windows: the tray UI writes a user-readable copy under LocalAppData; prefer
            // it because the ProgramData copy below is admin-only (Access denied for a
            // normally-run app).
            Path.Combine(localData, "ZeroTier", "authtoken.secret"),
            Path.Combine(localData, "ZeroTier", "One", "authtoken.secret"),
            Path.Combine(appData, "ZeroTier", "One", "authtoken.secret"),
            // Windows service-owned copy (admin-only; last resort, e.g. if elevated).
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

    /// <summary>Authorize or deauthorize a member, then re-read it from the controller
    /// to confirm the change actually took effect. Returns the controller's resulting
    /// authorized state — which may differ from <paramref name="authorized"/> if the API
    /// token can read members but lacks authorize permission (a common cause of a
    /// silently-ignored request).</summary>
    public async Task<bool> SetAuthorizedAsync(ZeroTierMember member, bool authorized)
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
            path = $"/network/{member.NetworkId}/member/{member.NodeId}";
        else
            path = $"/org/{member.OrgId}/network/{member.NetworkId}/member/{member.NodeId}";

        // The two controllers validate the body differently, so the authorize flag
        // must be placed where each one expects it — using the wrong shape is silently
        // rejected (ZeroTier Central 400s a stray top-level key; ZTNET's strict schema
        // 400s an unknown `config` key), which is the usual cause of "authorize does
        // nothing". Central keeps it under `config`; ZTNET wants it at the top level.
        if (account.IsCentral)
            body = new { config = new { authorized } };
        else
            body = new { authorized };

        await PostAsync(account.BaseUrl, token, path, body);
        // Confirm against the controller rather than assuming success: a read-only
        // token / insufficient network permission can return 200 yet leave the member
        // unchanged, so the UI must reflect what the controller actually stored.
        var confirmed = await GetMemberAuthorizedAsync(account.BaseUrl, token, path) ?? authorized;
        member.Authorized = confirmed;
        Updated?.Invoke();
        return confirmed;
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

    // ZeroTier Central's Authorization schemes: newer API tokens require `bearer`
    // (what ZeroTier's own client sends), while older tokens — and the published API
    // spec — use `token`. Try `bearer` first, then fall back to `token` on an auth
    // rejection, so both old and new keys work. ZTNET ignores Authorization and reads
    // the `x-ztnet-auth` header instead. Sending the wrong Central scheme is why a
    // freshly-created token can list nothing (401) even though it's valid.
    private static readonly string[] AuthSchemes = { "bearer", "token" };

    /// <summary>Send a request, retrying with the alternate Central auth scheme on a
    /// 401/403. Non-auth failures return immediately. The caller owns (and disposes)
    /// the returned response.</summary>
    private static async Task<HttpResponseMessage> SendAsync(
        string baseUrl, string token, HttpMethod method, string path, string? jsonBody)
    {
        var url = baseUrl.TrimEnd('/') + path;
        HttpResponseMessage? authFail = null;
        foreach (var scheme in AuthSchemes)
        {
            var req = new HttpRequestMessage(method, url);
            req.Headers.TryAddWithoutValidation("Authorization", scheme + " " + token); // Central
            req.Headers.TryAddWithoutValidation("x-ztnet-auth", token);                 // self-hosted (ZTNET)
            req.Headers.TryAddWithoutValidation("Accept", "application/json");
            if (jsonBody != null)
                req.Content = new StringContent(jsonBody, Encoding.UTF8, "application/json");

            var resp = await Http.SendAsync(req);
            if (resp.IsSuccessStatusCode) { authFail?.Dispose(); return resp; }
            // Only an auth rejection is worth retrying with the other scheme.
            if ((int)resp.StatusCode is 401 or 403)
            {
                authFail?.Dispose();
                authFail = resp;
                continue;
            }
            authFail?.Dispose();
            return resp;
        }
        return authFail!;
    }

    private static async Task<JsonElement?> GetArrayAsync(string baseUrl, string token, string path)
    {
        using var resp = await SendAsync(baseUrl, token, HttpMethod.Get, path, null);
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

    /// <summary>Read a single member and return its authorized flag, or null if the
    /// request failed or couldn't be parsed. Used to confirm an authorize/deauthorize
    /// actually took effect on the controller.</summary>
    private static async Task<bool?> GetMemberAuthorizedAsync(string baseUrl, string token, string path)
    {
        using var resp = await SendAsync(baseUrl, token, HttpMethod.Get, path, null);
        if (!resp.IsSuccessStatusCode) return null;
        var json = await resp.Content.ReadAsStringAsync();
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            return ZeroTierMember.FromJson(doc.RootElement).Authorized;
        }
        catch { return null; }
    }

    private static async Task PostAsync(string baseUrl, string token, string path, object body)
    {
        using var resp = await SendAsync(
            baseUrl, token, HttpMethod.Post, path, JsonSerializer.Serialize(body));
        if (!resp.IsSuccessStatusCode)
        {
            // Surface the controller's own explanation (bad token, wrong endpoint,
            // read-only key, member not found…) instead of a bare status code, so the
            // status bar tells the user *why* an authorize/update was rejected.
            var detail = string.Empty;
            try { detail = (await resp.Content.ReadAsStringAsync())?.Trim() ?? string.Empty; } catch { /* ignore */ }
            var msg = $"server returned {(int)resp.StatusCode} {resp.ReasonPhrase}".TrimEnd();
            if (detail.Length > 0)
                msg += ": " + (detail.Length > 300 ? detail[..300] + "…" : detail);
            throw new HttpRequestException(msg);
        }
    }
}
