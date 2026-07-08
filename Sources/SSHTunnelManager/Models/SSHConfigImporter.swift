import Foundation
import AppKit

/// Imports hosts defined in the user's `~/.ssh/config` as SSH profiles, so the
/// dozens of hosts people already have there can be pulled in with one click.
/// Wildcard blocks (`Host *`, patterns with `*` / `?`) are skipped — they're
/// defaults, not connectable hosts.
enum SSHConfigImporter {
    static var configPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
    }

    static var configExists: Bool {
        FileManager.default.fileExists(atPath: configPath)
    }

    // MARK: - Parsing

    /// Parse ssh-config text into importable profiles, in file order.
    static func parse(_ text: String) -> [SSHProfile] {
        var profiles: [SSHProfile] = []
        var current: SSHProfile?

        func flush() {
            guard var profile = current else { return }
            // No explicit HostName → the alias itself is the host to dial.
            if profile.host.trimmingCharacters(in: .whitespaces).isEmpty {
                profile.host = profile.name
            }
            profiles.append(profile)
            current = nil
        }

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (keyword, value) = splitKeyword(line)
            guard !keyword.isEmpty else { continue }

            switch keyword.lowercased() {
            case "host":
                flush()
                let patterns = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                // Use the first concrete (non-wildcard, non-negated) alias.
                guard let alias = patterns.first(where: {
                    !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!")
                }) else {
                    current = nil        // a pure wildcard block — ignore it
                    continue
                }
                var profile = SSHProfile()
                profile.name = alias
                current = profile
            case "hostname":       current?.host = value
            case "user":           current?.username = value
            case "port":           if !value.isEmpty { current?.port = value }
            case "identityfile":   current?.identityFile = value
            case "proxyjump":      current?.jumpHost = value
            case "forwardagent":   current?.forwardAgent = value.lowercased() == "yes"
            case "compression":    current?.compression = value.lowercased() == "yes"
            case "connecttimeout": current?.connectTimeout = Int(value) ?? 0
            case "localforward":   if let f = parseForward(value, type: .local)  { current?.forwards.append(f) }
            case "remoteforward":  if let f = parseForward(value, type: .remote) { current?.forwards.append(f) }
            case "dynamicforward": if let f = parseDynamic(value) { current?.forwards.append(f) }
            default:               break
            }
        }
        flush()
        return profiles
    }

    /// Split a config line into its keyword and value. ssh-config allows either
    /// `Keyword value` or `Keyword=value`, with optional surrounding quotes.
    static func splitKeyword(_ line: String) -> (String, String) {
        guard let idx = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (line, "")
        }
        let key = String(line[line.startIndex..<idx])
        let rest = line[line.index(after: idx)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        return (key, stripQuotes(rest))
    }

    private static func stripQuotes(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// Parse a `LocalForward` / `RemoteForward` value: `[bind:]port host:hostport`.
    private static func parseForward(_ value: String, type: ForwardType) -> PortForward? {
        let tokens = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2 else { return nil }
        let (bind, listen) = splitHostPort(tokens[0])
        let (targetHost, targetPort) = splitHostPort(tokens[1])
        guard !listen.isEmpty, !targetPort.isEmpty else { return nil }
        var forward = PortForward()
        forward.type = type
        forward.bindAddress = bind
        forward.listenPort = listen
        forward.targetHost = targetHost.isEmpty ? "localhost" : targetHost
        forward.targetPort = targetPort
        return forward
    }

    /// Parse a `DynamicForward` value: `[bind:]port`.
    private static func parseDynamic(_ value: String) -> PortForward? {
        let token = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? value
        let (bind, listen) = splitHostPort(token)
        guard !listen.isEmpty else { return nil }
        var forward = PortForward()
        forward.type = .dynamic
        forward.bindAddress = bind
        forward.listenPort = listen
        return forward
    }

    /// Split `host:port` / `port` / `[v6::addr]:port` into (host, port). The port
    /// is always the part after the final colon; anything before it is the host.
    private static func splitHostPort(_ s: String) -> (host: String, port: String) {
        let value = s
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            // Bracketed IPv6: [::1]:port
            let host = String(value[value.index(after: value.startIndex)..<close])
            let after = value[value.index(after: close)...]
            let port = after.hasPrefix(":") ? String(after.dropFirst()) : ""
            return (host, port)
        }
        guard let colon = value.lastIndex(of: ":") else { return ("", value) }
        let host = String(value[value.startIndex..<colon])
        let port = String(value[value.index(after: colon)...])
        return (host, port)
    }

    // MARK: - Import flow

    /// Read `~/.ssh/config`, import its hosts, and report the result. Runs on the
    /// main thread (shows AppKit alerts).
    static func importFlow(into store: ProfileStore) {
        guard configExists, let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            presentAlert(title: "No SSH Config Found",
                         message: "There's no file at ~/.ssh/config to import.",
                         style: .informational)
            return
        }
        let parsed = parse(text)
        guard !parsed.isEmpty else {
            presentAlert(title: "Nothing to Import",
                         message: "No connectable hosts were found in ~/.ssh/config (wildcard blocks are skipped).",
                         style: .informational)
            return
        }
        let added = store.importProfiles(parsed)
        presentAlert(title: "Imported \(added) Host\(added == 1 ? "" : "s")",
                     message: "Added \(added) profile\(added == 1 ? "" : "s") from ~/.ssh/config. Review each one — passwords and any options this app doesn't model aren't imported.",
                     style: .informational)
    }

    private static func presentAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
