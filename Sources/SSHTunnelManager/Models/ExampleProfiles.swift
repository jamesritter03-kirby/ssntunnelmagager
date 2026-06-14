import Foundation

/// Example profiles seeded on first launch so a new user can see how different
/// options come together. They use `example.com` placeholder hosts (which won't
/// resolve) and are safe to edit or delete — see `ProfileStore` for the one-time
/// seeding logic.
extension SSHProfile {
    static var examples: [SSHProfile] {
        [
            databaseTunnelExample,
            socksProxyExample,
            bastionShellExample,
            remoteShareExample,
        ]
    }

    /// `-L` local forward, tunnels-only (`-N`): reach a remote database on localhost.
    private static var databaseTunnelExample: SSHProfile {
        var p = SSHProfile()
        p.name = "Example: Database tunnel (-L)"
        p.host = "db.internal.example.com"
        p.username = "deploy"
        p.openShell = false          // tunnels only → ssh runs with -N
        p.keepAlive = true
        p.theme = "ocean"
        p.forwards = [
            PortForward(type: .local,
                        listenPort: "5433",
                        targetHost: "127.0.0.1",
                        targetPort: "5432"),
        ]
        p.snippets = [
            CommandSnippet(label: "Connect with psql",
                           command: #"psql "host=127.0.0.1 port=5433 dbname=app user=app""#),
        ]
        return p
    }

    /// `-D` dynamic SOCKS proxy with compression, tunnels-only.
    private static var socksProxyExample: SSHProfile {
        var p = SSHProfile()
        p.name = "Example: SOCKS proxy (-D)"
        p.host = "gateway.example.com"
        p.username = "tunnel"
        p.openShell = false
        p.compression = true         // -C, handy over slow links
        p.keepAlive = true
        p.theme = "dracula"
        p.forwards = [
            PortForward(type: .dynamic, listenPort: "1080"),
        ]
        return p
    }

    /// `-J` jump host + private key + interactive shell + two local forwards + snippets.
    private static var bastionShellExample: SSHProfile {
        var p = SSHProfile()
        p.name = "Example: Bastion + shell (-J)"
        p.host = "10.0.5.20"                       // private host, only reachable via the bastion
        p.username = "admin"
        p.jumpHost = "jump@bastion.example.com"     // -J
        p.identityFile = "~/.ssh/id_ed25519"        // -i (a specific key)
        p.openShell = true                          // interactive shell alongside the tunnels
        p.keepAlive = true
        p.compression = true
        p.theme = "homebrew"
        p.extraOptions = "-o StrictHostKeyChecking=accept-new"
        p.forwards = [
            PortForward(type: .local,
                        listenPort: "8080",
                        targetHost: "127.0.0.1",
                        targetPort: "80"),          // web UI on the private box
            PortForward(type: .local,
                        listenPort: "6379",
                        targetHost: "127.0.0.1",
                        targetPort: "6379"),        // Redis
        ]
        p.snippets = [
            CommandSnippet(label: "Tail app log", command: "sudo journalctl -u myapp -f"),
            CommandSnippet(label: "Disk usage", command: "df -h"),
        ]
        return p
    }

    /// `-R` remote forward: expose this Mac's local dev server on the remote host.
    private static var remoteShareExample: SSHProfile {
        var p = SSHProfile()
        p.name = "Example: Share local port (-R)"
        p.host = "public.example.com"
        p.username = "web"
        p.openShell = false
        p.keepAlive = true
        p.theme = "novel"
        p.forwards = [
            PortForward(type: .remote,
                        listenPort: "9000",
                        targetHost: "127.0.0.1",
                        targetPort: "3000"),        // remote :9000 → your Mac's :3000
        ]
        return p
    }
}
