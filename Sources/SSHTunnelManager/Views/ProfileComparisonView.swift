import SwiftUI
import AppKit

/// Presentation state for the **Compare & Bulk Edit Profiles** sheet.
@MainActor
final class ProfileComparisonModel: ObservableObject {
    static let shared = ProfileComparisonModel()
    @Published var isPresented = false
    func present() { isPresented = true }
    private init() {}
}

/// Remembers the user's per-column widths for the compare table across launches.
/// Keyed by column name ("Profile", "Host", and each `ProfileField.name`).
@MainActor
final class ComparisonColumnWidths: ObservableObject {
    static let shared = ComparisonColumnWidths()
    @Published private(set) var widths: [String: CGFloat]

    private let storeKey = "profileCompare.columnWidths.v1"
    private let minWidth: CGFloat = 70
    private let maxWidth: CGFloat = 640

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let dict = try? JSONDecoder().decode([String: CGFloat].self, from: data) {
            widths = dict
        } else {
            widths = [:]
        }
    }

    static func defaultWidth(for key: String) -> CGFloat {
        switch key {
        case "Profile": return 190
        case "Host":    return 160
        default:        return 120
        }
    }

    func width(for key: String) -> CGFloat {
        widths[key] ?? Self.defaultWidth(for: key)
    }

    func setWidth(_ w: CGFloat, for key: String) {
        widths[key] = min(max(w, minWidth), maxWidth)
    }

    func save() {
        if let data = try? JSONEncoder().encode(widths) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    var hasCustomWidths: Bool { !widths.isEmpty }

    func reset() {
        widths.removeAll()
        save()
    }
}

/// The kind of editor a `ProfileField` needs.
enum ProfileFieldKind { case text, number, bool, options }

/// One comparable / bulk-editable setting on an `SSHProfile`. The same list drives
/// both the comparison table columns and the "apply to selected" picker, so the two
/// can never drift out of sync. A `nil` setter marks a compare-only column (e.g. a
/// collection count) that can't be bulk-applied.
struct ProfileField: Identifiable {
    let name: String
    let kind: ProfileFieldKind
    let get: (SSHProfile) -> String
    let set: ((inout SSHProfile, String) -> Void)?
    let options: [String]?

    var id: String { name }
    var isEditable: Bool { self.set != nil }

    init(_ name: String,
         _ kind: ProfileFieldKind,
         get: @escaping (SSHProfile) -> String,
         set: ((inout SSHProfile, String) -> Void)? = nil,
         options: [String]? = nil) {
        self.name = name
        self.kind = kind
        self.get = get
        self.set = set
        self.options = options
    }

    static let boolOptions = ["Off", "On"]

    /// The full ordered list of comparable fields.
    static let all: [ProfileField] = {
        let themeNames = TerminalTheme.all.map(\.name)
        let strictTitles = StrictHostKeyChecking.allCases.map(\.title)

        func boolField(_ name: String,
                       _ get: @escaping (SSHProfile) -> Bool,
                       _ set: @escaping (inout SSHProfile, Bool) -> Void) -> ProfileField {
            ProfileField(name, .bool,
                         get: { get($0) ? "On" : "Off" },
                         set: { p, v in set(&p, v == "On") },
                         options: boolOptions)
        }

        return [
            ProfileField("Group", .text, get: { $0.group },
                         set: { p, v in p.group = v.trimmingCharacters(in: .whitespaces) }),
            ProfileField("Username", .text, get: { $0.username },
                         set: { p, v in p.username = v.trimmingCharacters(in: .whitespaces) }),
            ProfileField("Port", .text, get: { $0.port },
                         set: { p, v in
                             let t = v.trimmingCharacters(in: .whitespaces)
                             p.port = t.isEmpty ? "22" : t
                         }),
            ProfileField("Identity File", .text, get: { $0.identityFile },
                         set: { p, v in p.identityFile = v.trimmingCharacters(in: .whitespaces) }),
            ProfileField("Jump Host", .text, get: { $0.jumpHost },
                         set: { p, v in p.jumpHost = v.trimmingCharacters(in: .whitespaces) }),
            ProfileField("Run On Connect", .text, get: { $0.runOnConnect },
                         set: { p, v in p.runOnConnect = v }),
            ProfileField("Remote Command", .text, get: { $0.remoteCommand },
                         set: { p, v in p.remoteCommand = v }),
            ProfileField("Extra Options", .text, get: { $0.extraOptions },
                         set: { p, v in p.extraOptions = v }),
            ProfileField("Icon", .text, get: { $0.icon },
                         set: { p, v in p.icon = v.trimmingCharacters(in: .whitespaces) }),
            ProfileField("Theme", .options,
                         get: { TerminalTheme.theme(id: $0.theme).name },
                         set: { p, v in
                             if let match = TerminalTheme.all.first(where: { $0.name == v }) {
                                 p.theme = match.id
                             }
                         },
                         options: themeNames),
            ProfileField("Font Size", .number, get: { String(Int($0.fontSize)) },
                         set: { p, v in
                             if let d = Double(v) { p.fontSize = TerminalFontMetrics.clamp(d) }
                         }),
            ProfileField("Connect Timeout", .number, get: { String($0.connectTimeout) },
                         set: { p, v in
                             if let n = Int(v), n >= 0 { p.connectTimeout = n }
                         }),
            ProfileField("Strict Host Key", .options,
                         get: { $0.strictHostKeyChecking.title },
                         set: { p, v in
                             if let match = StrictHostKeyChecking.allCases.first(where: { $0.title == v }) {
                                 p.strictHostKeyChecking = match
                             }
                         },
                         options: strictTitles),
            boolField("Favorite", { $0.isFavorite }, { $0.isFavorite = $1 }),
            boolField("Keep Alive", { $0.keepAlive }, { $0.keepAlive = $1 }),
            boolField("Compression", { $0.compression }, { $0.compression = $1 }),
            boolField("Forward Agent", { $0.forwardAgent }, { $0.forwardAgent = $1 }),
            boolField("Add Keys To Agent", { $0.addKeysToAgent }, { $0.addKeysToAgent = $1 }),
            boolField("Request TTY", { $0.requestTTY }, { $0.requestTTY = $1 }),
            boolField("Open Shell", { $0.openShell }, { $0.openShell = $1 }),
            boolField("Use Mosh", { $0.useMosh }, { $0.useMosh = $1 }),
            boolField("Auto Reconnect", { $0.autoReconnect }, { $0.autoReconnect = $1 }),
            boolField("Auto Connect", { $0.autoConnectOnLaunch }, { $0.autoConnectOnLaunch = $1 }),
            boolField("Log Session", { $0.logSession }, { $0.logSession = $1 }),
            boolField("Verbose", { $0.verbose }, { $0.verbose = $1 }),
            boolField("Own Workspace", { $0.opensInOwnWorkspace }, { $0.opensInOwnWorkspace = $1 }),
            ProfileField("Workspace Name", .text, get: { $0.workspace },
                         set: { p, v in p.workspace = v.trimmingCharacters(in: .whitespaces) }),
            ProfileField("Start Path", .text, get: { $0.startPath },
                         set: { p, v in p.startPath = v.trimmingCharacters(in: .whitespaces) }),

            // Compare-only columns (collections) — shown but not bulk-editable.
            ProfileField("Snippets", .text, get: { String($0.snippets.count) }),
            ProfileField("Links", .text, get: { String($0.links.count) }),
            ProfileField("Forwards", .text, get: { String($0.forwards.count) }),
            ProfileField("Env Vars", .text, get: { String($0.environment.count) })
        ]
    }()

    static let editable: [ProfileField] = all.filter(\.isEditable)
}

/// The "Compare & Bulk Edit Profiles" sheet: shows every profile side by side and
/// lets the user apply one setting's value to a group of selected profiles at once.
struct ProfileComparisonView: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<UUID> = []
    @State private var fieldName: String = ProfileField.editable.first?.name ?? ""
    @State private var textValue: String = ""
    @State private var optionValue: String = ""
    @State private var status: String = ""

    @ObservedObject private var columnWidths = ComparisonColumnWidths.shared
    /// Width of each column at the moment a resize drag began, keyed by column.
    @State private var dragStartWidth: [String: CGFloat] = [:]

    /// Profiles in a stable, grouped order.
    private var rows: [SSHProfile] {
        store.profiles.sorted {
            if $0.group.lowercased() != $1.group.lowercased() {
                return $0.group.lowercased() < $1.group.lowercased()
            }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    private var selectedField: ProfileField? {
        ProfileField.all.first { $0.name == fieldName }
    }

    private var fieldIsOptions: Bool {
        guard let k = selectedField?.kind else { return false }
        return k == .options || k == .bool
    }

    private var currentOptions: [String] { selectedField?.options ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            comparisonTable
            Divider()
            bulkEditBar
        }
        .frame(minWidth: 820, idealWidth: 980, minHeight: 520, idealHeight: 640)
        .onAppear {
            if fieldIsOptions { optionValue = currentOptions.first ?? "" }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            DialogHeader(
                icon: "tablecells",
                title: "Compare & Bulk Edit Profiles",
                subtitle: "Tick profiles, choose a setting and a value, then apply it to the whole selection."
            )
            Spacer()
            if columnWidths.hasCustomWidths {
                Button("Reset Widths") { columnWidths.reset() }
                    .help("Restore every column to its default width")
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Table

    private var comparisonTable: some View {
        // The first column (checkbox + profile name) stays pinned while the Host
        // and setting columns scroll horizontally. Both halves live in the same
        // vertical ScrollView, so they scroll up/down together and stay row-aligned.
        ScrollView(.vertical) {
            HStack(spacing: 0) {
                // Frozen first column.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 28)
                        resizableHeader("Profile", key: "Profile")
                    }
                    .background(Color(nsColor: .underPageBackgroundColor))

                    Divider()

                    ForEach(rows) { profile in
                        HStack(spacing: 0) {
                            Toggle("", isOn: binding(for: profile.id))
                                .labelsHidden()
                                .frame(width: 28)
                            HStack(spacing: 5) {
                                Image(systemName: profile.displayIcon)
                                    .foregroundStyle(.secondary)
                                Text(profile.name)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(width: columnWidths.width(for: "Profile"), alignment: .leading)
                            .padding(.horizontal, 8)
                        }
                        .frame(height: 30)
                        .background(selected.contains(profile.id)
                                    ? Color.accentColor.opacity(0.12) : Color.clear)
                        Divider()
                    }
                }

                Divider()

                // Horizontally-scrolling columns.
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 0) {
                            resizableHeader("Host", key: "Host")
                            ForEach(ProfileField.all) { field in
                                resizableHeader(field.name, key: field.name)
                            }
                        }
                        .background(Color(nsColor: .underPageBackgroundColor))

                        Divider()

                        ForEach(rows) { profile in
                            HStack(spacing: 0) {
                                Text(profile.isLocal ? "local shell" : profile.subtitle)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: columnWidths.width(for: "Host"), alignment: .leading)
                                    .padding(.horizontal, 8)
                                ForEach(ProfileField.all) { field in
                                    Text(field.get(profile))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(width: columnWidths.width(for: field.name), alignment: .leading)
                                        .padding(.horizontal, 8)
                                }
                            }
                            .frame(height: 30)
                            .background(selected.contains(profile.id)
                                        ? Color.accentColor.opacity(0.12) : Color.clear)
                            Divider()
                        }
                    }
                }
            }
            .font(.callout)
        }
    }

    /// A column header with a draggable handle on its trailing edge that resizes
    /// and persists the column's width.
    private func resizableHeader(_ title: String, key: String) -> some View {
        columnHeader(title, width: columnWidths.width(for: key))
            .overlay(alignment: .trailing) {
                ColumnResizeHandle(
                    onChanged: { delta in
                        if dragStartWidth[key] == nil {
                            dragStartWidth[key] = columnWidths.width(for: key)
                        }
                        let start = dragStartWidth[key] ?? columnWidths.width(for: key)
                        columnWidths.setWidth(start + delta, for: key)
                    },
                    onEnded: {
                        dragStartWidth[key] = nil
                        columnWidths.save()
                    })
            }
    }

    private func columnHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }

    // MARK: - Bulk edit

    private var bulkEditBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("Select All") { selected = Set(rows.map(\.id)) }
                Button("Select None") { selected.removeAll() }
                Text("\(selected.count) of \(rows.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("Setting")
                    .foregroundStyle(.secondary)
                Picker("Setting", selection: $fieldName) {
                    ForEach(ProfileField.editable) { field in
                        Text(field.name).tag(field.name)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                .onChange(of: fieldName) { _ in
                    status = ""
                    if fieldIsOptions {
                        optionValue = currentOptions.first ?? ""
                    } else {
                        textValue = ""
                    }
                }

                Text("Value")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                if fieldIsOptions {
                    Picker("Value", selection: $optionValue) {
                        ForEach(currentOptions, id: \.self) { opt in
                            Text(opt).tag(opt)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                } else {
                    TextField("new value", text: $textValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                Button("Copy from Selected") { copyFromFirstSelected() }
                    .help("Fill the value box from the first ticked profile")
                Button("Apply to Selected") { apply() }
                    .buttonStyle(.borderedProminent)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    // MARK: - Actions

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { on in
                if on { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    private func copyFromFirstSelected() {
        guard let field = selectedField else { return }
        guard let first = rows.first(where: { selected.contains($0.id) }) else {
            status = "Select a profile first."
            return
        }
        let value = field.get(first)
        if fieldIsOptions { optionValue = value } else { textValue = value }
    }

    private func apply() {
        guard let field = selectedField, let setter = field.set else {
            status = "Pick a setting to apply."
            return
        }
        let targets = rows.filter { selected.contains($0.id) }
        guard !targets.isEmpty else {
            status = "No profiles selected — tick one or more rows first."
            return
        }
        let value = fieldIsOptions ? optionValue : textValue
        for var profile in targets {
            setter(&profile, value)
            store.update(profile)
        }
        status = "Applied \(field.name) = \"\(value)\" to \(targets.count) profile(s)."
    }
}

/// A slim draggable handle sitting on a column's trailing edge. Dragging it
/// reports the horizontal delta so the caller can resize the column; a native
/// cursor rect shows the left-right resize cursor while hovering.
private struct ColumnResizeHandle: View {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear.frame(width: 11)
            Rectangle()
                .fill(hovering ? Color.accentColor : Color.secondary.opacity(0.25))
                .frame(width: hovering ? 2 : 1)
                .padding(.vertical, 3)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay(ColumnResizeCursorRect())
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { onChanged($0.translation.width) }
                .onEnded { _ in onEnded() }
        )
    }
}

/// Shows the left-right resize cursor over its bounds via an AppKit cursor rect,
/// which balances enter/exit reliably even if the view is rebuilt mid-hover.
private struct ColumnResizeCursorRect: NSViewRepresentable {
    func makeNSView(context: Context) -> CursorRectView { CursorRectView() }
    func updateNSView(_ nsView: CursorRectView, context: Context) {}

    final class CursorRectView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
    }
}

