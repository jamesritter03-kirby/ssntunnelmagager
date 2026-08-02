using System.Collections.Generic;

namespace RemoteStuff.Models;

/// <summary>One editable field in a config menu's add/edit form.</summary>
public sealed class MtField
{
    public enum FieldKind { Text, Number, Bool }

    public string Key { get; }
    public string Label { get; }
    public FieldKind Kind { get; }
    public string Placeholder { get; }
    /// <summary>Fixed set of choices, when the field is really an enum.</summary>
    public IReadOnlyList<string> Choices { get; }

    public MtField(string key, string label, FieldKind kind = FieldKind.Text,
                   string placeholder = "", IReadOnlyList<string>? choices = null)
    {
        Key = key;
        Label = label;
        Kind = kind;
        Placeholder = placeholder;
        Choices = choices ?? System.Array.Empty<string>();
    }
}

/// <summary>A WinBox-style configuration menu, mapped onto a RouterOS REST path.</summary>
public sealed class MtMenu
{
    public string Group { get; }         // e.g. "IP", "System"
    public string Title { get; }         // e.g. "Addresses"
    public string Path { get; }          // REST path, e.g. "ip/address"
    /// <summary>Field keys shown as columns in the list.</summary>
    public IReadOnlyList<string> Columns { get; }
    /// <summary>Fields offered when adding a new entry.</summary>
    public IReadOnlyList<MtField> AddFields { get; }
    /// <summary>A settings menu (single object) rather than a list of rows.</summary>
    public bool IsSingleton { get; }
    /// <summary>Whether the user can add / delete rows (false for read-only menus).</summary>
    public bool Editable { get; }

    public string DisplayName => $"{Group} · {Title}";

    public MtMenu(string group, string title, string path,
                  IReadOnlyList<string> columns, IReadOnlyList<MtField> addFields,
                  bool isSingleton = false, bool editable = true)
    {
        Group = group;
        Title = title;
        Path = path;
        Columns = columns;
        AddFields = addFields;
        IsSingleton = isSingleton;
        Editable = editable;
    }

    private static MtField F(string key, string label, MtField.FieldKind kind = MtField.FieldKind.Text,
                            string placeholder = "", string[]? choices = null) =>
        new(key, label, kind, placeholder, choices);

    /// <summary>A curated set of common WinBox menus mapped to RouterOS REST paths.
    /// The edit form additionally shows every field the router returns, so anything
    /// not listed here is still editable — this catalog drives discovery, column
    /// layout and sensible "add" defaults.</summary>
    public static readonly IReadOnlyList<MtMenu> Catalog = new List<MtMenu>
    {
        // Interfaces
        new("Interfaces", "Interface List", "interface",
            new[] { "name", "type", "running", "actual-mtu" },
            new[] { F("name", "Name"), F("comment", "Comment") }, editable: false),
        new("Interfaces", "Bridge", "interface/bridge",
            new[] { "name", "protocol-mode", "vlan-filtering" },
            new[] { F("name", "Name", MtField.FieldKind.Text, "bridge1"),
                    F("vlan-filtering", "VLAN Filtering", MtField.FieldKind.Bool),
                    F("comment", "Comment") }),
        new("Interfaces", "Bridge Ports", "interface/bridge/port",
            new[] { "interface", "bridge", "pvid" },
            new[] { F("interface", "Interface"), F("bridge", "Bridge", MtField.FieldKind.Text, "bridge1"),
                    F("pvid", "PVID", MtField.FieldKind.Number, "1") }),
        new("Interfaces", "VLAN", "interface/vlan",
            new[] { "name", "vlan-id", "interface" },
            new[] { F("name", "Name", MtField.FieldKind.Text, "vlan10"),
                    F("vlan-id", "VLAN ID", MtField.FieldKind.Number, "10"),
                    F("interface", "Interface", MtField.FieldKind.Text, "bridge") }),
        new("Interfaces", "List Members", "interface/list/member",
            new[] { "list", "interface" },
            new[] { F("list", "List", MtField.FieldKind.Text, "LAN"), F("interface", "Interface") }),

        // Wireless
        new("Wireless", "WiFi", "interface/wifi",
            new[] { "name", "configuration.ssid", "disabled" },
            new[] { F("name", "Name"), F("comment", "Comment") }, editable: false),

        // IP
        new("IP", "Addresses", "ip/address",
            new[] { "address", "network", "interface" },
            new[] { F("address", "Address", MtField.FieldKind.Text, "192.168.88.1/24"),
                    F("interface", "Interface", MtField.FieldKind.Text, "bridge"),
                    F("comment", "Comment") }),
        new("IP", "ARP", "ip/arp",
            new[] { "address", "mac-address", "interface" },
            new[] { F("address", "Address"), F("mac-address", "MAC Address"),
                    F("interface", "Interface") }),
        new("IP", "DHCP Server", "ip/dhcp-server",
            new[] { "name", "interface", "address-pool", "lease-time" },
            new[] { F("name", "Name", MtField.FieldKind.Text, "dhcp1"),
                    F("interface", "Interface", MtField.FieldKind.Text, "bridge"),
                    F("address-pool", "Address Pool", MtField.FieldKind.Text, "dhcp"),
                    F("lease-time", "Lease Time", MtField.FieldKind.Text, "10m") }),
        new("IP", "DHCP Networks", "ip/dhcp-server/network",
            new[] { "address", "gateway", "dns-server" },
            new[] { F("address", "Address", MtField.FieldKind.Text, "192.168.88.0/24"),
                    F("gateway", "Gateway", MtField.FieldKind.Text, "192.168.88.1"),
                    F("dns-server", "DNS Server", MtField.FieldKind.Text, "192.168.88.1") }),
        new("IP", "DHCP Leases", "ip/dhcp-server/lease",
            new[] { "address", "mac-address", "host-name", "status" },
            new[] { F("address", "Address"), F("mac-address", "MAC Address"),
                    F("server", "Server", MtField.FieldKind.Text, "dhcp1"), F("comment", "Comment") }),
        new("IP", "DHCP Client", "ip/dhcp-client",
            new[] { "interface", "status", "address" },
            new[] { F("interface", "Interface"),
                    F("add-default-route", "Add Default Route", MtField.FieldKind.Bool),
                    F("use-peer-dns", "Use Peer DNS", MtField.FieldKind.Bool) }),
        new("IP", "DNS", "ip/dns",
            new[] { "servers", "allow-remote-requests" },
            new[] { F("servers", "Servers", MtField.FieldKind.Text, "1.1.1.1,8.8.8.8"),
                    F("allow-remote-requests", "Allow Remote Requests", MtField.FieldKind.Bool) },
            isSingleton: true),
        new("IP", "DNS Static", "ip/dns/static",
            new[] { "name", "address", "type", "ttl" },
            new[] { F("name", "Name"), F("address", "Address"),
                    F("ttl", "TTL", MtField.FieldKind.Text, "1d") }),
        new("IP", "Routes", "ip/route",
            new[] { "dst-address", "gateway", "distance", "active" },
            new[] { F("dst-address", "Dst. Address", MtField.FieldKind.Text, "0.0.0.0/0"),
                    F("gateway", "Gateway"),
                    F("distance", "Distance", MtField.FieldKind.Number, "1") }),
        new("IP", "Pool", "ip/pool",
            new[] { "name", "ranges" },
            new[] { F("name", "Name", MtField.FieldKind.Text, "dhcp"),
                    F("ranges", "Ranges", MtField.FieldKind.Text, "192.168.88.10-192.168.88.254") }),
        new("IP", "Cloud (DDNS)", "ip/cloud",
            new[] { "ddns-enabled", "dns-name", "public-address" },
            new[] { F("ddns-enabled", "DDNS Enabled", MtField.FieldKind.Bool) }, isSingleton: true),
        new("IP", "Services", "ip/service",
            new[] { "name", "port", "disabled" },
            System.Array.Empty<MtField>(), editable: false),
        new("IP", "Neighbors", "ip/neighbor",
            new[] { "address", "identity", "interface", "mac-address" },
            System.Array.Empty<MtField>(), editable: false),

        // Firewall
        new("Firewall", "Filter Rules", "ip/firewall/filter",
            new[] { "chain", "action", "src-address", "dst-address" },
            new[] { F("chain", "Chain", MtField.FieldKind.Text, "forward",
                        new[] { "input", "forward", "output" }),
                    F("action", "Action", MtField.FieldKind.Text, "accept",
                        new[] { "accept", "drop", "reject", "log", "fasttrack-connection" }),
                    F("src-address", "Src. Address"),
                    F("dst-address", "Dst. Address"),
                    F("protocol", "Protocol", MtField.FieldKind.Text, "", new[] { "tcp", "udp", "icmp" }),
                    F("comment", "Comment") }),
        new("Firewall", "NAT", "ip/firewall/nat",
            new[] { "chain", "action", "src-address", "to-addresses" },
            new[] { F("chain", "Chain", MtField.FieldKind.Text, "srcnat", new[] { "srcnat", "dstnat" }),
                    F("action", "Action", MtField.FieldKind.Text, "masquerade",
                        new[] { "masquerade", "src-nat", "dst-nat", "redirect", "accept" }),
                    F("out-interface", "Out Interface"),
                    F("to-addresses", "To Addresses"),
                    F("comment", "Comment") }),
        new("Firewall", "Mangle", "ip/firewall/mangle",
            new[] { "chain", "action", "new-packet-mark" },
            new[] { F("chain", "Chain", MtField.FieldKind.Text, "prerouting"),
                    F("action", "Action", MtField.FieldKind.Text, "mark-packet"),
                    F("comment", "Comment") }),
        new("Firewall", "Address Lists", "ip/firewall/address-list",
            new[] { "list", "address", "timeout" },
            new[] { F("list", "List"), F("address", "Address"),
                    F("comment", "Comment") }),

        // Queues
        new("Queues", "Simple Queues", "queue/simple",
            new[] { "name", "target", "max-limit" },
            new[] { F("name", "Name"), F("target", "Target", MtField.FieldKind.Text, "192.168.88.0/24"),
                    F("max-limit", "Max Limit", MtField.FieldKind.Text, "10M/10M") }),

        // System
        new("System", "Identity", "system/identity",
            new[] { "name" },
            new[] { F("name", "Name") }, isSingleton: true),
        new("System", "Clock", "system/clock",
            new[] { "time", "date", "time-zone-name" },
            new[] { F("time-zone-name", "Time Zone", MtField.FieldKind.Text, "America/New_York") },
            isSingleton: true),
        new("System", "NTP Client", "system/ntp/client",
            new[] { "enabled", "servers", "status" },
            new[] { F("enabled", "Enabled", MtField.FieldKind.Bool),
                    F("servers", "Servers", MtField.FieldKind.Text, "pool.ntp.org") }, isSingleton: true),
        new("System", "Users", "user",
            new[] { "name", "group", "disabled" },
            new[] { F("name", "Name"), F("group", "Group", MtField.FieldKind.Text, "full",
                        new[] { "full", "read", "write" }),
                    F("password", "Password") }),
        new("System", "Packages", "system/package",
            new[] { "name", "version", "disabled" },
            System.Array.Empty<MtField>(), editable: false),
        new("System", "Scheduler", "system/scheduler",
            new[] { "name", "interval", "next-run" },
            new[] { F("name", "Name"), F("interval", "Interval", MtField.FieldKind.Text, "1d"),
                    F("on-event", "On Event") }),
        new("System", "Scripts", "system/script",
            new[] { "name", "run-count" },
            new[] { F("name", "Name"), F("source", "Source") }),
        new("System", "Logs", "log",
            new[] { "time", "topics", "message" },
            System.Array.Empty<MtField>(), editable: false),
    };
}

/// <summary>One row returned from a config menu: its RouterOS `.id` plus every
/// field as a string.</summary>
public sealed class MtEntry
{
    public string Id { get; }
    public IReadOnlyDictionary<string, string> Fields { get; }

    public MtEntry(string id, IReadOnlyDictionary<string, string> fields)
    {
        Id = id;
        Fields = fields;
    }

    public bool Disabled => Value("disabled") is "true" or "yes";
    public string Comment => Value("comment");

    public string Value(string key) => Fields.TryGetValue(key, out var v) ? v : "";

    /// <summary>A short label for the row, best-effort across menu types.</summary>
    public string TitleFor(IReadOnlyList<string> columns)
    {
        foreach (var k in new[] { "name", "address", "target", "dst-address", "chain", "list", "server", "interface" })
            if (Fields.TryGetValue(k, out var v) && v.Length > 0) return v;
        if (columns.Count > 0 && Fields.TryGetValue(columns[0], out var f) && f.Length > 0) return f;
        return Id;
    }
}
