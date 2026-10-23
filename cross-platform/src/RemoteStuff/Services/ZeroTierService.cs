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

    public ZeroTierAccount AddAccount(string label, string baseUrl, string token,
        ZtNetworkSource source = ZtNetworkSource.Auto)
    {
        var account = new ZeroTierAccount
        {
            Label = label,
            BaseUrl = string.IsNullOrWhiteSpace(baseUrl) ? ZeroTierAccount.CentralBaseUrl : baseUrl.Trim(),
            NetworkSource = source
        };
        _accounts.Add(account);
        SaveAccounts();
        _secrets.Set(account.Id, token);
        return account;
    }

    /// <summary>Update an existing account's label / base URL / network source (and token
    /// when a non-empty one is supplied). Returns false if the id isn't found.</summary>
    public bool UpdateAccount(Guid id, string label, string baseUrl, ZtNetworkSource source, string? token)
    {
        var account = _accounts.FirstOrDefault(a => a.Id == id);
        if (account is null) return false;
        account.Label = label;
        account.BaseUrl = string.IsNullOrWhiteSpace(baseUrl) ? ZeroTierAccount.CentralBaseUrl : baseUrl.Trim();
        account.NetworkSource = source;
        SaveAccounts();
        if (!string.IsNullOrWhiteSpace(token)) _secrets.Set(account.Id, token.Trim());
        return true;
    }

    public void RemoveAccount(Guid id)
    {
        _accounts.RemoveAll(a => a.Id == id);
        SaveAccounts();
        _secrets.Set(id, null);
        _networks.RemoveAll(n => n.AccountId == id);
        _members.RemoveAll(m => m.AccountId == id);
        _emptyStreak.Remove(id);
        _accountDiag.Remove(id);
        ResetMissingStreaks(id);
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
        // Serialize refreshes: the ZeroTier tab and the sidebar panel each run their own
        // timer against this shared service, and concurrent calls can race the _networks swap
        // (and hammer a slow controller into failing), blanking an account. Skip duplicates —
        // the single in-flight refresh updates both via the Updated event.
        if (_isRefreshing) return;
        _isRefreshing = true;
        try
        {
            await RefreshCoreAsync();
        }
        finally { _isRefreshing = false; }
    }

    private bool _isRefreshing;

    private async Task RefreshCoreAsync()
    {
        var networks = new List<ZeroTierNetwork>();
        var members = new List<ZeroTierMember>();

        foreach (var account in _accounts.ToList())
        {
            var token = _secrets.Get(account.Id);
            if (string.IsNullOrEmpty(token)) continue;

            int netStart = networks.Count;
            int memStart = members.Count;
            var prevNets = _networks.Where(n => n.AccountId == account.Id).ToList();
            var prevMems = _members.Where(m => m.AccountId == account.Id).ToList();

            // Which routes to read, per the account's declared source (Auto tries both).
            bool usePersonal = account.NetworkSource is ZtNetworkSource.Auto or ZtNetworkSource.Personal;
            bool useOrg = account.NetworkSource is ZtNetworkSource.Auto or ZtNetworkSource.Organization;

            bool personalOk = false;   // /network returned an array (even if empty)
            bool orgListOk = false;    // /org returned an array
            bool orgNetOk = false;     // at least one /org/{id}/network returned an array
            bool anyOrgNetFailed = false;
            int lastFailStatus = 0;    // last non-404 failure status, for the diagnostic

            void CarryOver()
            {
                if (networks.Count > netStart) networks.RemoveRange(netStart, networks.Count - netStart);
                if (members.Count > memStart) members.RemoveRange(memStart, members.Count - memStart);
                networks.AddRange(prevNets);
                members.AddRange(prevMems);
            }

            try
            {
                var accountNetworks = new List<ZeroTierNetwork>();

                // Personal / Central route.
                if (usePersonal)
                {
                    var personal = await GetArrayAsync(account.BaseUrl, token, "/network");
                    if (personal.Ok)
                    {
                        personalOk = true;
                        foreach (var e in personal.Array!.Value.EnumerateArray())
                        {
                            var n = ZeroTierNetwork.FromJson(e);
                            n.AccountId = account.Id;
                            accountNetworks.Add(n);
                        }
                    }
                    else if (personal.Status != 404) lastFailStatus = personal.Status;
                }

                // Self-hosted org-scoped tokens: enumerate orgs then their networks.
                if (useOrg)
                {
                    var orgs = await GetArrayAsync(account.BaseUrl, token, "/org");
                    if (orgs.Ok)
                    {
                        orgListOk = true;
                        foreach (var orgEl in orgs.Array!.Value.EnumerateArray())
                        {
                            var orgId = orgEl.GetStringOr("id");
                            if (string.IsNullOrEmpty(orgId)) continue;
                            var orgNet = await GetArrayAsync(account.BaseUrl, token, $"/org/{orgId}/network");
                            if (!orgNet.Ok) { anyOrgNetFailed = true; if (orgNet.Status != 404) lastFailStatus = orgNet.Status; continue; }
                            orgNetOk = true;
                            foreach (var e in orgNet.Array!.Value.EnumerateArray())
                            {
                                var n = ZeroTierNetwork.FromJson(e);
                                n.AccountId = account.Id;
                                n.OrgId = orgId;
                                if (accountNetworks.All(x => x.Id != n.Id))
                                    accountNetworks.Add(n);
                            }
                        }
                    }
                    else if (orgs.Status != 404) lastFailStatus = orgs.Status;
                }

                foreach (var n in accountNetworks)
                {
                    networks.Add(n);
                    var path = n.OrgId is null
                        ? $"/network/{n.Id}/member"
                        : $"/org/{n.OrgId}/network/{n.Id}/member";
                    var mem = await GetArrayAsync(account.BaseUrl, token, path);

                    var netMembers = new List<ZeroTierMember>();
                    if (mem.Ok)
                    {
                        foreach (var e in mem.Array!.Value.EnumerateArray())
                        {
                            var m = ZeroTierMember.FromJson(e);
                            if (string.IsNullOrEmpty(m.NetworkId)) m.NetworkId = n.Id;
                            m.AccountId = account.Id;
                            m.OrgId = n.OrgId;
                            netMembers.Add(m);
                        }
                    }

                    // Per-network member grace: a transient member-fetch failure, or a 200 []
                    // where the network had devices last time (seen with ZTNET), would blank the
                    // device list for one refresh and repopulate on the next. Keep last-known
                    // members for a few cycles so a network's devices don't vanish and reappear.
                    var prevNetMems = prevMems.Where(m =>
                        string.Equals(m.NetworkId, n.Id, StringComparison.OrdinalIgnoreCase)).ToList();
                    var memKey = (account.Id, n.Id);
                    if ((!mem.Ok || netMembers.Count == 0) && prevNetMems.Count > 0 &&
                        _memberMissingStreak.GetValueOrDefault(memKey) < MissingGrace)
                    {
                        _memberMissingStreak[memKey] = _memberMissingStreak.GetValueOrDefault(memKey) + 1;
                        members.AddRange(prevNetMems);
                    }
                    else
                    {
                        if (netMembers.Count > 0) _memberMissingStreak.Remove(memKey);
                        members.AddRange(netMembers);
                    }
                }

                int fetched = networks.Count - netStart;

                // Did the route that should carry THIS account's networks succeed this cycle?
                bool prevHadOrg = prevNets.Any(n => n.OrgId != null);
                bool prevHadPersonal = prevNets.Any(n => n.OrgId == null);
                bool routeOk = account.NetworkSource switch
                {
                    ZtNetworkSource.Personal => personalOk,
                    ZtNetworkSource.Organization => orgListOk && !anyOrgNetFailed,
                    _ => prevNets.Count == 0
                        ? (personalOk || orgNetOk)
                        : (!prevHadOrg || orgNetOk) && (!prevHadPersonal || personalOk),
                };

                if (!routeOk && prevNets.Count > fetched)
                {
                    // The authoritative route failed — keep last-known networks.
                    CarryOver();
                    ResetMissingStreaks(account.Id);
                    _accountDiag[account.Id] = lastFailStatus != 0
                        ? $"Showing {prevNets.Count} last-known network(s) — controller returned HTTP {lastFailStatus}"
                        : $"Showing {prevNets.Count} last-known network(s) — controller didn't return them (timeout)";
                }
                else if (routeOk && fetched == 0 && prevNets.Count > 0 && _emptyStreak.GetValueOrDefault(account.Id) < EmptyGrace)
                {
                    // The route succeeded but returned zero where it had networks. Controllers
                    // (seen with ZTNET) occasionally reply 200 [] mid-session; keep last-known
                    // for a few cycles so the account doesn't blink empty on a glitch.
                    _emptyStreak[account.Id] = _emptyStreak.GetValueOrDefault(account.Id) + 1;
                    CarryOver();
                    ResetMissingStreaks(account.Id);
                    _accountDiag[account.Id] = $"Showing {prevNets.Count} last-known network(s) — controller returned 0 this refresh";
                }
                else
                {
                    _emptyStreak[account.Id] = fetched == 0 ? _emptyStreak.GetValueOrDefault(account.Id) : 0;

                    // Partial-loss grace: the route succeeded but omitted SOME previously-known
                    // networks (ZTNET can return a 200 that drops a few networks for one cycle).
                    // Re-add each missing network (and its last-known members) for a few cycles so
                    // individual networks don't blink out of an otherwise-healthy account; a network
                    // absent past the grace window is accepted as genuinely removed.
                    int carried = 0;
                    if (routeOk && fetched > 0 && prevNets.Count > 0)
                    {
                        var present = new HashSet<string>(
                            networks.Skip(netStart).Select(n => n.Id), StringComparer.OrdinalIgnoreCase);
                        foreach (var pn in prevNets)
                        {
                            var key = (account.Id, pn.Id);
                            if (present.Contains(pn.Id)) { _missingStreak.Remove(key); continue; }

                            int streak = _missingStreak.GetValueOrDefault(key);
                            if (streak < MissingGrace)
                            {
                                _missingStreak[key] = streak + 1;
                                networks.Add(pn);
                                members.AddRange(prevMems.Where(m =>
                                    string.Equals(m.NetworkId, pn.Id, StringComparison.OrdinalIgnoreCase)));
                                carried++;
                            }
                            else _missingStreak.Remove(key);
                        }
                    }

                    _accountDiag[account.Id] = carried > 0
                        ? $"{fetched} network(s) loaded · {carried} kept last-known (absent this refresh)"
                        : $"{networks.Count - netStart} network(s) loaded";
                }
            }
            catch
            {
                if (prevNets.Count > networks.Count - netStart) CarryOver();
                _accountDiag[account.Id] = $"Showing {prevNets.Count} last-known network(s) — refresh error";
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

    // accountId -> one-line summary of the last refresh (shown on the account header).
    private readonly Dictionary<Guid, string> _accountDiag = new();

    // accountId -> consecutive refreshes the authoritative route returned 0 networks where it
    // had some. Up to EmptyGrace of these keep last-known data (controllers occasionally reply
    // 200 [] mid-session); after that a real emptying is accepted.
    private readonly Dictionary<Guid, int> _emptyStreak = new();
    private const int EmptyGrace = 3;

    // (accountId, networkId) -> consecutive refreshes a previously-known network was absent from
    // an otherwise-successful route result. Up to MissingGrace of these re-add the network from
    // last-known data (ZTNET occasionally returns a partial 200 that omits some networks for a
    // cycle); after that the network is accepted as genuinely removed.
    private readonly Dictionary<(Guid Account, string Network), int> _missingStreak = new();
    private const int MissingGrace = 3;

    // (accountId, networkId) -> consecutive refreshes a present network's member fetch failed or
    // returned 0 where it had devices. Up to MissingGrace of these keep last-known members.
    private readonly Dictionary<(Guid Account, string Network), int> _memberMissingStreak = new();

    private void ResetMissingStreaks(Guid accountId)
    {
        foreach (var key in _missingStreak.Keys.Where(k => k.Account == accountId).ToList())
            _missingStreak.Remove(key);
        foreach (var key in _memberMissingStreak.Keys.Where(k => k.Account == accountId).ToList())
            _memberMissingStreak.Remove(key);
    }

    /// <summary>A short human summary of the account's last refresh (networks read, or
    /// "kept last-known" with the failing status), for the account header tooltip.</summary>
    public string? DiagnosticFor(Guid accountId) => _accountDiag.TryGetValue(accountId, out var s) ? s : null;

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

    /// <summary>Whether the host is online in ZeroTier. Reflects the member entry that owns
    /// this exact IP (the same entry the ZeroTier panel shows for it), so the sidebar dot
    /// stays consistent with the panel — matching a different network's entry for the same
    /// node would over-report online.</summary>
    public bool IsHostOnline(string? host) => MemberForIp(host)?.IsOnline ?? false;

    /// <summary>Whether this host maps to a known ZeroTier device, so its online/offline
    /// state is meaningful. Hosts we don't track (ordinary internet hosts) have no online
    /// info and fall back to connection-based sidebar dots.</summary>
    public bool IsHostTracked(string? host) => MemberForIp(host) is not null;

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

    /// <summary>Result of a list fetch: the HTTP status (0 = timeout/network error) and the
    /// parsed array when the call succeeded with an array body.</summary>
    private readonly record struct ArrayResult(int Status, JsonElement? Array)
    {
        public bool Ok => Array is not null;
    }

    private static async Task<ArrayResult> GetArrayAsync(string baseUrl, string token, string path)
    {
        try
        {
            using var resp = await SendAsync(baseUrl, token, HttpMethod.Get, path, null);
            int status = (int)resp.StatusCode;
            if (!resp.IsSuccessStatusCode) return new ArrayResult(status, null);
            var json = await resp.Content.ReadAsStringAsync();
            try
            {
                using var doc = JsonDocument.Parse(json);
                if (doc.RootElement.ValueKind != JsonValueKind.Array) return new ArrayResult(status, null);
                // Clone so the element outlives the disposed document.
                return new ArrayResult(status, doc.RootElement.Clone());
            }
            catch { return new ArrayResult(status, null); }
        }
        catch { return new ArrayResult(0, null); }  // timeout / network error
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
