using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RemoteStuff.Models;

/// <summary>One ZeroTier account (Central or a self-hosted ZTNET controller).</summary>
public sealed class ZeroTierAccount
{
    public const string CentralBaseUrl = "https://api.zerotier.com/api/v1";

    public Guid Id { get; set; } = Guid.NewGuid();
    public string Label { get; set; } = "";
    public string BaseUrl { get; set; } = CentralBaseUrl;

    [JsonIgnore] public bool IsCentral => BaseUrl == CentralBaseUrl;

    [JsonIgnore]
    public string DisplayLabel =>
        string.IsNullOrWhiteSpace(Label) ? "ZeroTier Account" : Label.Trim();

    [JsonIgnore]
    public string ServerDisplay
    {
        get
        {
            if (IsCentral) return "ZeroTier Central";
            if (Uri.TryCreate(BaseUrl, UriKind.Absolute, out var u))
                return u.Host + (u.IsDefaultPort ? "" : ":" + u.Port);
            return BaseUrl;
        }
    }
}

/// <summary>A ZeroTier network visible to an account.</summary>
public sealed class ZeroTierNetwork
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public int? TotalMemberCount { get; set; }
    public List<string> Routes { get; set; } = new();

    public Guid AccountId { get; set; }
    public string? OrgId { get; set; }

    public string DisplayName =>
        string.IsNullOrWhiteSpace(Name) ? Id : Name.Trim();

    /// <summary>Parse a network from either the Central (nested <c>config</c>) or ZTNET (flat) shape.</summary>
    public static ZeroTierNetwork FromJson(JsonElement e)
    {
        var n = new ZeroTierNetwork
        {
            Id = e.GetStringOr("id") ?? e.GetStringOr("nwid") ?? "",
            Description = e.GetStringOr("description") ?? "",
            TotalMemberCount = e.GetIntOrNull("totalMemberCount") ?? e.GetIntOrNull("memberCount")
        };

        var name = e.GetStringOr("name") ?? "";
        var routes = ReadRoutes(e);
        if (e.TryGetProperty("config", out var cfg) && cfg.ValueKind == JsonValueKind.Object)
        {
            if (string.IsNullOrEmpty(name)) name = cfg.GetStringOr("name") ?? "";
            if (routes.Count == 0) routes = ReadRoutes(cfg);
        }
        n.Name = name;
        n.Routes = routes;
        return n;
    }

    private static List<string> ReadRoutes(JsonElement e)
    {
        var list = new List<string>();
        if (e.TryGetProperty("routes", out var r) && r.ValueKind == JsonValueKind.Array)
            foreach (var item in r.EnumerateArray())
                if (item.TryGetProperty("target", out var t) && t.ValueKind == JsonValueKind.String)
                    list.Add(t.GetString()!);
        return list;
    }
}

/// <summary>A member (device) on a ZeroTier network.</summary>
public sealed class ZeroTierMember
{
    public string NetworkId { get; set; } = "";
    public string NodeId { get; set; } = "";
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public bool Authorized { get; set; }
    public List<string> IpAssignments { get; set; } = new();
    public string? PhysicalAddress { get; set; }
    public double? LastOnlineMs { get; set; }
    public bool? OnlineFlag { get; set; }

    public Guid AccountId { get; set; }
    public string? OrgId { get; set; }

    private const double OnlineWindowMs = 5 * 60 * 1000;

    public bool IsOnline =>
        OnlineFlag
        ?? (LastOnlineMs is > 0 &&
            (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - LastOnlineMs.Value) < OnlineWindowMs);

    public string DisplayName =>
        string.IsNullOrWhiteSpace(Name) ? NodeId : Name.Trim();

    public string PrimaryIp => IpAssignments.FirstOrDefault() ?? "";

    public static ZeroTierMember FromJson(JsonElement e)
    {
        var m = new ZeroTierMember
        {
            NetworkId = e.GetStringOr("networkId") ?? e.GetStringOr("nwid") ?? "",
            Name = e.GetStringOr("name") ?? "",
            Description = e.GetStringOr("description") ?? "",
            PhysicalAddress = e.GetStringOr("physicalAddress"),
            OnlineFlag = e.GetBoolOrNull("online")
        };

        m.LastOnlineMs = e.GetDoubleOrNull("lastOnline")
                         ?? e.GetDoubleOrNull("lastSeen")
                         ?? ParseTimestampMs(e.GetStringOr("lastSeen") ?? e.GetStringOr("lastOnline"));

        bool? authorized = e.GetBoolOrNull("authorized");
        var ips = ReadStrings(e, "ipAssignments");
        var node = e.GetStringOr("nodeId") ?? "";
        if (e.TryGetProperty("config", out var cfg) && cfg.ValueKind == JsonValueKind.Object)
        {
            authorized ??= cfg.GetBoolOrNull("authorized");
            if (ips.Count == 0) ips = ReadStrings(cfg, "ipAssignments");
            if (string.IsNullOrEmpty(node)) node = cfg.GetStringOr("address") ?? "";
        }
        if (string.IsNullOrEmpty(node))
            node = e.GetStringOr("id") ?? e.GetStringOr("address") ?? "";

        m.Authorized = authorized ?? false;
        m.IpAssignments = ips;
        m.NodeId = node;
        return m;
    }

    private static List<string> ReadStrings(JsonElement e, string prop)
    {
        var list = new List<string>();
        if (e.TryGetProperty(prop, out var arr) && arr.ValueKind == JsonValueKind.Array)
            foreach (var item in arr.EnumerateArray())
                if (item.ValueKind == JsonValueKind.String)
                    list.Add(item.GetString()!);
        return list;
    }

    private static double? ParseTimestampMs(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        if (DateTimeOffset.TryParse(s, out var dto))
            return dto.ToUnixTimeMilliseconds();
        return null;
    }
}

/// <summary>A self-hosted (ZTNET) organization the token can access.</summary>
public sealed class ZTOrg
{
    public string Id { get; set; } = "";
    public string? OrgName { get; set; }
}

/// <summary>Small helpers for tolerant JSON reads (fields vary by controller).</summary>
internal static class JsonElementExtensions
{
    public static string? GetStringOr(this JsonElement e, string prop) =>
        e.TryGetProperty(prop, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    public static int? GetIntOrNull(this JsonElement e, string prop) =>
        e.TryGetProperty(prop, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i : null;

    public static double? GetDoubleOrNull(this JsonElement e, string prop) =>
        e.TryGetProperty(prop, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d) ? d : null;

    public static bool? GetBoolOrNull(this JsonElement e, string prop) =>
        e.TryGetProperty(prop, out var v) && (v.ValueKind == JsonValueKind.True || v.ValueKind == JsonValueKind.False)
            ? v.GetBoolean() : null;
}
