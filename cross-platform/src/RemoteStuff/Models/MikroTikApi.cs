using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace RemoteStuff.Models;

/// <summary>A saved MikroTik router reachable over the RouterOS v7+ REST API.</summary>
public sealed class MikroTikRouter
{
    public string Name { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = 443;
    public string Username { get; set; } = "admin";
    public bool UseHttps { get; set; } = true;

    public string BaseUrl => $"{(UseHttps ? "https" : "http")}://{Host}:{Port}/rest";

    public string DisplayName
    {
        get
        {
            var n = Name.Trim();
            return n.Length > 0 ? n : (Host.Length > 0 ? Host : "New Router");
        }
    }
}

public sealed class MtInterface
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "?";
    public string Type { get; init; } = "";
    public bool Running { get; init; }
    public bool Disabled { get; init; }
    public string? Mac { get; init; }
    public string? Comment { get; init; }
    public string StatusGlyph => Disabled ? "⚪" : (Running ? "🟢" : "🔴");
}

public sealed class MtAddress
{
    public string Id { get; init; } = "";
    public string Address { get; init; } = "?";
    public string? Network { get; init; }
    public string Interface { get; init; } = "";
    public bool Disabled { get; init; }
}

public sealed class MtLease
{
    public string Id { get; init; } = "";
    public string Address { get; init; } = "?";
    public string Mac { get; init; } = "";
    public string? HostName { get; init; }
    public string? Status { get; init; }
    public bool Dynamic { get; init; }
}

public sealed class MtResource
{
    public string? Identity { get; set; }
    public string? BoardName { get; set; }
    public string? Version { get; set; }
    public string? Uptime { get; set; }
    public int? CpuLoad { get; set; }
    public long? FreeMemory { get; set; }
    public long? TotalMemory { get; set; }
    public string? Architecture { get; set; }

    public int? MemoryUsedPercent =>
        (TotalMemory is > 0 && FreeMemory.HasValue)
            ? (int)((double)(TotalMemory.Value - FreeMemory.Value) / TotalMemory.Value * 100.0)
            : null;
}

/// <summary>Talks to one router's RouterOS REST API. Accepts self-signed TLS.</summary>
public sealed class MikroTikApi : IDisposable
{
    private readonly MikroTikRouter _router;
    private readonly string _password;
    private readonly HttpClient _http;

    public MikroTikApi(MikroTikRouter router, string password)
    {
        _router = router;
        _password = password;
        var handler = new HttpClientHandler
        {
            // RouterOS ships self-signed certs by default; this handler is scoped
            // to router calls only, so it never affects the app's other HTTPS.
            ServerCertificateCustomValidationCallback = (_, _, _, _) => true
        };
        _http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };
        var raw = Encoding.UTF8.GetBytes($"{router.Username}:{password}");
        _http.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Basic", Convert.ToBase64String(raw));
        _http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    }

    // MARK: reads
    public async Task<MtResource> GetResourceAsync()
    {
        var r = new MtResource();
        if (await GetObjectAsync("/system/resource") is { } res)
        {
            r.BoardName = Str(res, "board-name");
            r.Version = Str(res, "version");
            r.Uptime = Str(res, "uptime");
            r.CpuLoad = IntVal(res, "cpu-load");
            r.FreeMemory = LongVal(res, "free-memory");
            r.TotalMemory = LongVal(res, "total-memory");
            r.Architecture = Str(res, "architecture-name");
        }
        if (await GetObjectAsync("/system/identity") is { } ident)
            r.Identity = Str(ident, "name");
        return r;
    }

    public async Task<List<MtInterface>> GetInterfacesAsync() =>
        (await GetArrayAsync("/interface")).Select(row => new MtInterface
        {
            Id = Str(row, ".id") ?? Guid.NewGuid().ToString(),
            Name = Str(row, "name") ?? "?",
            Type = Str(row, "type") ?? "",
            Running = BoolVal(row, "running"),
            Disabled = BoolVal(row, "disabled"),
            Mac = Str(row, "mac-address"),
            Comment = Str(row, "comment")
        }).ToList();

    public async Task<List<MtAddress>> GetAddressesAsync() =>
        (await GetArrayAsync("/ip/address")).Select(row => new MtAddress
        {
            Id = Str(row, ".id") ?? Guid.NewGuid().ToString(),
            Address = Str(row, "address") ?? "?",
            Network = Str(row, "network"),
            Interface = Str(row, "interface") ?? "",
            Disabled = BoolVal(row, "disabled")
        }).ToList();

    public async Task<List<MtLease>> GetLeasesAsync() =>
        (await GetArrayAsync("/ip/dhcp-server/lease")).Select(row => new MtLease
        {
            Id = Str(row, ".id") ?? Guid.NewGuid().ToString(),
            Address = Str(row, "address") ?? "?",
            Mac = Str(row, "mac-address") ?? "",
            HostName = Str(row, "host-name"),
            Status = Str(row, "status"),
            Dynamic = BoolVal(row, "dynamic")
        }).ToList();

    // MARK: actions
    public Task SetInterfaceDisabledAsync(string id, bool disabled) =>
        PostAsync("/interface/set", new Dictionary<string, object>
        {
            [".id"] = id,
            ["disabled"] = disabled ? "yes" : "no"
        });

    public Task RebootAsync() => PostAsync("/system/reboot", new Dictionary<string, object>());

    public async Task<string> ExportConfigAsync()
    {
        var data = await RequestStringAsync("/export", HttpMethod.Post, new Dictionary<string, object>());
        using var doc = JsonDocument.Parse(data);
        var root = doc.RootElement;
        if (root.ValueKind == JsonValueKind.Object)
        {
            if (root.TryGetProperty("output", out var o) && o.ValueKind == JsonValueKind.String)
                return o.GetString() ?? "";
            if (root.TryGetProperty("ret", out var rr) && rr.ValueKind == JsonValueKind.String)
                return rr.GetString() ?? "";
        }
        if (root.ValueKind == JsonValueKind.Array)
        {
            var joined = string.Join("\n", root.EnumerateArray()
                .Select(e => e.TryGetProperty("output", out var op) ? op.GetString()
                          : (e.TryGetProperty("ret", out var rp) ? rp.GetString() : null))
                .Where(s => !string.IsNullOrEmpty(s)));
            if (joined.Length > 0) return joined;
        }
        if (root.ValueKind == JsonValueKind.String) return root.GetString() ?? "";
        return data;
    }

    public async Task ApplyConfigAsync(string source)
    {
        var name = "rs-apply-" + DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var created = await RequestStringAsync("/system/script", HttpMethod.Put, new Dictionary<string, object>
        {
            ["name"] = name,
            ["source"] = source,
            ["dont-require-permissions"] = "no"
        });
        string? scriptId = null;
        try
        {
            using var doc = JsonDocument.Parse(created);
            if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                doc.RootElement.TryGetProperty(".id", out var idEl))
                scriptId = idEl.GetString();
        }
        catch { /* ignore */ }

        try
        {
            await PostAsync("/system/script/run", new Dictionary<string, object> { ["number"] = name });
        }
        finally
        {
            if (scriptId != null)
                try { await RequestStringAsync($"/system/script/{scriptId}", HttpMethod.Delete, null); }
                catch { /* best-effort cleanup */ }
        }
    }

    /// <summary>List an arbitrary RouterOS menu (e.g. "ip/firewall/filter").</summary>
    public async Task<List<Dictionary<string, JsonElement>>> ListRawAsync(string menuPath)
    {
        var data = await RequestStringAsync("/" + menuPath.TrimStart('/'), HttpMethod.Get, null);
        using var doc = JsonDocument.Parse(data);
        var root = doc.RootElement;
        if (root.ValueKind == JsonValueKind.Array)
            return root.EnumerateArray().Select(ToDict).ToList();
        if (root.ValueKind == JsonValueKind.Object)
            return new List<Dictionary<string, JsonElement>> { ToDict(root) };
        return new List<Dictionary<string, JsonElement>>();
    }

    // MARK: HTTP plumbing
    private async Task<string> RequestStringAsync(string path, HttpMethod method, Dictionary<string, object>? body)
    {
        if (string.IsNullOrEmpty(_password))
            throw new InvalidOperationException("This router has no saved password.");
        using var req = new HttpRequestMessage(method, _router.BaseUrl + path);
        if (body != null)
            req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        HttpResponseMessage resp;
        try { resp = await _http.SendAsync(req); }
        catch (Exception ex) { throw new InvalidOperationException("Couldn’t reach the router: " + ex.Message); }
        using (resp)
        {
            if ((int)resp.StatusCode == 401)
                throw new InvalidOperationException("Login failed — check the username and password.");
            if (!resp.IsSuccessStatusCode)
                throw new InvalidOperationException($"Router API error (HTTP {(int)resp.StatusCode}).");
            return await resp.Content.ReadAsStringAsync();
        }
    }

    private async Task<List<Dictionary<string, JsonElement>>> GetArrayAsync(string path)
    {
        var data = await RequestStringAsync(path, HttpMethod.Get, null);
        using var doc = JsonDocument.Parse(data);
        return doc.RootElement.ValueKind == JsonValueKind.Array
            ? doc.RootElement.EnumerateArray().Select(ToDict).ToList()
            : new List<Dictionary<string, JsonElement>>();
    }

    private async Task<Dictionary<string, JsonElement>?> GetObjectAsync(string path)
    {
        try
        {
            var data = await RequestStringAsync(path, HttpMethod.Get, null);
            using var doc = JsonDocument.Parse(data);
            if (doc.RootElement.ValueKind == JsonValueKind.Object) return ToDict(doc.RootElement);
            if (doc.RootElement.ValueKind == JsonValueKind.Array)
            {
                var first = doc.RootElement.EnumerateArray().FirstOrDefault();
                if (first.ValueKind == JsonValueKind.Object) return ToDict(first);
            }
        }
        catch { /* tolerate */ }
        return null;
    }

    private Task PostAsync(string path, Dictionary<string, object> body) =>
        RequestStringAsync(path, HttpMethod.Post, body);

    private static Dictionary<string, JsonElement> ToDict(JsonElement obj)
    {
        var d = new Dictionary<string, JsonElement>();
        foreach (var p in obj.EnumerateObject()) d[p.Name] = p.Value.Clone();
        return d;
    }

    private static string? Str(Dictionary<string, JsonElement> row, string key)
    {
        if (!row.TryGetValue(key, out var v)) return null;
        return v.ValueKind switch
        {
            JsonValueKind.String => v.GetString(),
            JsonValueKind.Number => v.ToString(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => null
        };
    }

    private static int? IntVal(Dictionary<string, JsonElement> row, string key)
    {
        var s = Str(row, key);
        return int.TryParse(s, out var v) ? v : null;
    }

    private static long? LongVal(Dictionary<string, JsonElement> row, string key)
    {
        var s = Str(row, key);
        return long.TryParse(s, out var v) ? v : null;
    }

    private static bool BoolVal(Dictionary<string, JsonElement> row, string key)
    {
        var s = Str(row, key);
        return s is "true" or "yes" or "1";
    }

    public void Dispose() => _http.Dispose();
}
