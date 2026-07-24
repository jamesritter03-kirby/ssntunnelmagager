using System;
using System.Collections.Generic;
using System.Linq;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>
/// Minimal parser for <c>~/.ssh/config</c> that turns each <c>Host</c> stanza into
/// an <see cref="SshProfile"/>. Wildcard hosts (containing * or ?) are skipped.
/// </summary>
public static class SshConfigImporter
{
    public static List<SshProfile> Parse(string text)
    {
        var results = new List<SshProfile>();
        SshProfile? current = null;

        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;

            var (key, value) = SplitKeyValue(line);
            if (key.Length == 0) continue;

            switch (key.ToLowerInvariant())
            {
                case "host":
                    // A stanza may list several patterns; take the first concrete one.
                    var alias = value.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries)
                                     .FirstOrDefault(v => !v.Contains('*') && !v.Contains('?'));
                    if (current != null) results.Add(current);
                    current = alias == null ? null : new SshProfile { Name = alias, Host = alias };
                    break;

                case "hostname":
                    if (current != null) current.Host = value;
                    break;
                case "user":
                    if (current != null) current.Username = value;
                    break;
                case "port":
                    if (current != null) current.Port = value;
                    break;
                case "identityfile":
                    if (current != null) current.IdentityFile = value;
                    break;
                case "proxyjump":
                    if (current != null) current.JumpHost = value;
                    break;
                case "compression":
                    if (current != null) current.Compression = value.Equals("yes", StringComparison.OrdinalIgnoreCase);
                    break;
                case "forwardagent":
                    if (current != null) current.ForwardAgent = value.Equals("yes", StringComparison.OrdinalIgnoreCase);
                    break;
                case "connecttimeout":
                    if (current != null && int.TryParse(value, out var t)) current.ConnectTimeout = t;
                    break;
                case "localforward":
                    AddForward(current, value, ForwardType.Local);
                    break;
                case "remoteforward":
                    AddForward(current, value, ForwardType.Remote);
                    break;
                case "dynamicforward":
                    AddDynamicForward(current, value);
                    break;
            }
        }

        if (current != null) results.Add(current);
        return results;
    }

    private static (string key, string value) SplitKeyValue(string line)
    {
        // Config allows "Key Value" or "Key=Value".
        var eq = line.IndexOf('=');
        var sp = line.IndexOfAny(new[] { ' ', '\t' });
        int idx;
        if (eq >= 0 && (sp < 0 || eq < sp)) idx = eq;
        else idx = sp;
        if (idx < 0) return (line, "");
        return (line[..idx].Trim(), line[(idx + 1)..].Trim());
    }

    private static void AddForward(SshProfile? p, string value, ForwardType type)
    {
        if (p == null) return;
        // Format: "[bind:]port host:hostport"
        var parts = value.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) return;

        var (bind, listen) = SplitHostPort(parts[0]);
        var (targetHost, targetPort) = SplitHostPort(parts[1]);
        p.Forwards.Add(new PortForward
        {
            Type = type,
            BindAddress = bind,
            ListenPort = listen,
            TargetHost = string.IsNullOrEmpty(targetHost) ? "localhost" : targetHost,
            TargetPort = targetPort
        });
    }

    private static void AddDynamicForward(SshProfile? p, string value)
    {
        if (p == null) return;
        var (bind, listen) = SplitHostPort(value.Trim());
        p.Forwards.Add(new PortForward
        {
            Type = ForwardType.Dynamic,
            BindAddress = bind,
            ListenPort = listen
        });
    }

    private static (string host, string port) SplitHostPort(string s)
    {
        var idx = s.LastIndexOf(':');
        if (idx < 0) return ("", s);
        return (s[..idx], s[(idx + 1)..]);
    }
}
