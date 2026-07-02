import Foundation

/// One entry in the welcome screen's **Recently Closed** list: a single tab or a
/// whole workspace the user closed without explicitly saving it. Reopened on
/// demand from the welcome screen so an accidental close can be undone.
///
/// We reuse the same codable shapes the resume / saved-workspace features use
/// (`SessionSnapshot` / `SavedWorkspace`) so a recorded entry recreates through
/// the exact same path — no live process state (or password) is ever stored.
struct ClosedItem: Identifiable, Codable {
    enum Kind: String, Codable { case tab, workspace }

    var id: UUID = UUID()
    var kind: Kind
    /// What to show as the entry's primary line (the tab title or workspace name).
    var title: String
    /// An SF Symbol name representing the entry.
    var symbol: String
    /// When it was closed (drives the "2 minutes ago" detail line).
    var closedAt: Date

    /// Populated for a closed **tab**.
    var tab: SessionSnapshot?
    /// Populated for a closed **workspace**.
    var workspace: SavedWorkspace?

    // MARK: Display helpers

    /// How many tabs this entry would reopen.
    var tabCount: Int {
        switch kind {
        case .tab:       return tab != nil ? 1 : 0
        case .workspace: return workspace?.tabs.count ?? 0
        }
    }

    /// A short, human label for the kind of thing this is.
    var typeLabel: String {
        switch kind {
        case .workspace:
            let n = tabCount
            return "Workspace · \(n) tab\(n == 1 ? "" : "s")"
        case .tab:
            return ClosedItem.label(for: tab?.kind)
        }
    }

    /// The secondary line: the type plus a relative "… ago" timestamp.
    var detail: String {
        "\(typeLabel) · \(ClosedItem.relativeFormatter.localizedString(for: closedAt, relativeTo: Date()))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// A friendly name for a tab kind, used in the secondary line.
    static func label(for kind: TerminalSession.Kind?) -> String {
        switch kind {
        case .localShell: return "Local Terminal"
        case .ssh:        return "SSH"
        case .sftp:       return "SFTP"
        case .vnc:        return "VNC"
        case .web:        return "Web Page"
        case .mqtt:       return "MQTT"
        case .redis:      return "Redis"
        case .finder:     return "Finder"
        case .editor:     return "Text Editor"
        case .none:       return "Tab"
        }
    }
}
