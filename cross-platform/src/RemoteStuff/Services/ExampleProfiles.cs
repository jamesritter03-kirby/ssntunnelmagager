using System.Collections.Generic;
using RemoteStuff.Models;

namespace RemoteStuff.Services;

/// <summary>
/// Example profiles seeded on first launch so a new user can see how different
/// options come together. They use <c>example.com</c> placeholder hosts.
/// </summary>
public static class ExampleProfiles
{
    public static List<SshProfile> All() => new()
    {
        DatabaseTunnel(),
        SocksProxy(),
        BastionShell(),
        RemoteShare()
    };

    /// <summary>-L local forward, tunnels-only (-N): reach a remote database on localhost.</summary>
    private static SshProfile DatabaseTunnel() => new()
    {
        Name = "Example: Database tunnel (-L)",
        Host = "db.internal.example.com",
        Username = "deploy",
        OpenShell = false,
        KeepAlive = true,
        Theme = "ocean",
        Forwards = new List<PortForward>
        {
            new() { Type = ForwardType.Local, ListenPort = "5433", TargetHost = "127.0.0.1", TargetPort = "5432" }
        },
        Snippets = new List<CommandSnippet>
        {
            new() { Label = "Connect with psql", Command = "psql \"host=127.0.0.1 port=5433 dbname=app user=app\"" }
        }
    };

    /// <summary>-D dynamic SOCKS proxy with compression, tunnels-only.</summary>
    private static SshProfile SocksProxy() => new()
    {
        Name = "Example: SOCKS proxy (-D)",
        Host = "gateway.example.com",
        Username = "tunnel",
        OpenShell = false,
        Compression = true,
        KeepAlive = true,
        Theme = "dracula",
        Forwards = new List<PortForward>
        {
            new() { Type = ForwardType.Dynamic, ListenPort = "1080" }
        }
    };

    /// <summary>-J jump host + private key + interactive shell + local forwards + snippets.</summary>
    private static SshProfile BastionShell() => new()
    {
        Name = "Example: Bastion + shell (-J)",
        Host = "10.0.5.20",
        Username = "admin",
        JumpHost = "jump@bastion.example.com",
        IdentityFile = "~/.ssh/id_ed25519",
        OpenShell = true,
        KeepAlive = true,
        Compression = true,
        Theme = "homebrew",
        ExtraOptions = "-o StrictHostKeyChecking=accept-new",
        Forwards = new List<PortForward>
        {
            new() { Type = ForwardType.Local, Category = ForwardCategory.Webpage, ListenPort = "8080", TargetHost = "127.0.0.1", TargetPort = "80" },
            new() { Type = ForwardType.Local, Category = ForwardCategory.Redis, ServiceUsername = "default", ListenPort = "6379", TargetHost = "127.0.0.1", TargetPort = "6379" },
            new() { Type = ForwardType.Local, Category = ForwardCategory.Mqtt, ServiceUsername = "admin", ListenPort = "1883", TargetHost = "127.0.0.1", TargetPort = "1883" }
        },
        Snippets = new List<CommandSnippet>
        {
            new() { Label = "Tail app log", Command = "sudo journalctl -u myapp -f" },
            new() { Label = "Disk usage", Command = "df -h" }
        }
    };

    /// <summary>-R remote forward: expose this machine's local dev server on the remote host.</summary>
    private static SshProfile RemoteShare() => new()
    {
        Name = "Example: Share local port (-R)",
        Host = "public.example.com",
        Username = "web",
        OpenShell = false,
        KeepAlive = true,
        Theme = "novel",
        Forwards = new List<PortForward>
        {
            new() { Type = ForwardType.Remote, ListenPort = "9000", TargetHost = "127.0.0.1", TargetPort = "3000" }
        }
    };
}
