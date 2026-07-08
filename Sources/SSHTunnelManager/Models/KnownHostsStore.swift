import Foundation
import Combine

/// One entry (line) in `~/.ssh/known_hosts`.
struct KnownHostEntry: Identifiable, Hashable {
    let id = UUID()
    /// The exact original line, used to rewrite the file when removing.
    let rawLine: String
    /// A friendly host label (or "Hashed host" for a `|1|…` hashed entry).
    let hostLabel: String
    /// The key type (e.g. `ssh-ed25519`, `ecdsa-sha2-nistp256`), when parseable.
    let keyType: String
    /// Whether the host field is hashed (so it can't be shown in the clear).
    let isHashed: Bool
}

/// Reads and edits `~/.ssh/known_hosts` so a changed/stale host key can be
/// removed from inside the app instead of dropping to a shell.
final class KnownHostsStore: ObservableObject {
    @Published private(set) var entries: [KnownHostEntry] = []
    @Published var errorMessage: String?

    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/known_hosts")
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: KnownHostsStore.path) }

    func reload() {
        errorMessage = nil
        guard fileExists else { entries = []; return }
        guard let text = try? String(contentsOfFile: KnownHostsStore.path, encoding: .utf8) else {
            entries = []
            errorMessage = "Couldn't read ~/.ssh/known_hosts."
            return
        }
        entries = KnownHostsStore.parse(text)
    }

    /// Parse known_hosts text into per-line entries (blank/comment lines skipped).
    static func parse(_ text: String) -> [KnownHostEntry] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { rawSlice in
            let raw = String(rawSlice)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2 else { return nil }
            // A leading @marker (e.g. @cert-authority, @revoked) shifts the fields.
            var hostField = fields[0]
            var keyType = fields[1]
            if hostField.hasPrefix("@"), fields.count >= 3 {
                hostField = fields[1]
                keyType = fields[2]
            }
            let isHashed = hostField.hasPrefix("|")
            let hostLabel = isHashed
                ? "Hashed host"
                : hostField.split(separator: ",").map(prettyHost).joined(separator: ", ")
            return KnownHostEntry(rawLine: raw, hostLabel: hostLabel,
                                  keyType: keyType, isHashed: isHashed)
        }
    }

    /// Strip the `[host]:port` brackets ssh uses for non-standard ports.
    private static func prettyHost(_ token: Substring) -> String {
        let s = String(token)
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = s[s.index(after: s.startIndex)..<close]
            let after = s[s.index(after: close)...]
            let port = after.hasPrefix(":") ? after.dropFirst() : ""
            return port.isEmpty ? String(host) : "\(host):\(port)"
        }
        return s
    }

    /// Remove one entry by rewriting the file without its exact line (works for
    /// hashed entries too, which `ssh-keygen -R` can't target by name).
    func remove(_ entry: KnownHostEntry) {
        rewrite(removing: [entry])
    }

    func remove(_ toRemove: [KnownHostEntry]) {
        rewrite(removing: toRemove)
    }

    private func rewrite(removing toRemove: [KnownHostEntry]) {
        guard fileExists,
              let text = try? String(contentsOfFile: KnownHostsStore.path, encoding: .utf8) else { return }
        let doomed = Set(toRemove.map(\.rawLine))
        // Preserve every other line (including blanks / comments) verbatim.
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !doomed.contains(String($0)) }
        let rebuilt = kept.joined(separator: "\n")
        do {
            try rebuilt.write(toFile: KnownHostsStore.path, atomically: true, encoding: .utf8)
            reload()
        } catch {
            errorMessage = "Couldn't update known_hosts: \(error.localizedDescription)"
        }
    }
}
