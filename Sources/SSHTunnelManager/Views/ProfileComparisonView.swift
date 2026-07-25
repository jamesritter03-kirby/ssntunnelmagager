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
            ProfileField("SFTP Paths", .text, get: { String($0.sftpBookmarks.count) }),
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

    /// The shared password typed into the "unify passwords" row.
    @State private var passwordValue: String = ""
    /// Whether the ticked profiles should require Touch ID before using the
    /// password that's applied to them.
    @State private var passwordRequireAuth: Bool = true

    /// Drives the "copy lists between profiles" dialog.
    @State private var showPropagate = false

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
        .frame(minWidth: 720, idealWidth: 980, maxWidth: .infinity,
               minHeight: 460, idealHeight: 640, maxHeight: .infinity)
        .background(SheetResizeEnabler(minSize: NSSize(width: 720, height: 460)))
        .onAppear {
            if fieldIsOptions { optionValue = currentOptions.first ?? "" }
        }
        .sheet(isPresented: $showPropagate) {
            PropagateCollectionView(
                targets: rows.filter { selected.contains($0.id) },
                initialSourceID: rows.first(where: { selected.contains($0.id) })?.id
            )
            .environmentObject(store)
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
        // One scroll area on both axes. The header row is pinned (frozen) to the
        // top, so it stays visible while the profile rows scroll under it; all
        // columns scroll together horizontally.
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { profile in
                        tableRow(profile)
                        Divider()
                    }
                } header: {
                    tableHeaderRow
                }
            }
            .font(.callout)
        }
    }

    /// The pinned header row: the checkbox spacer, then every resizable column.
    private var tableHeaderRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 28)
                resizableHeader("Profile", key: "Profile")
                resizableHeader("Host", key: "Host")
                ForEach(ProfileField.all) { field in
                    resizableHeader(field.name, key: field.name)
                }
            }
            Divider()
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// One profile row: checkbox, name, host and every setting column.
    private func tableRow(_ profile: SSHProfile) -> some View {
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
    }

    /// A column header with a draggable handle on its trailing edge that resizes
    /// and persists the column's width.
    private func resizableHeader(_ title: String, key: String) -> some View {
        columnHeader(title, width: columnWidths.width(for: key))
            .overlay(alignment: .trailing) { resizeHandle(for: key) }
    }

    /// A draggable handle that resizes and persists the width of column `key`.
    private func resizeHandle(for key: String) -> some View {
        ColumnResizeHandle(
            onChanged: { value in
                if dragStartWidth[key] == nil {
                    dragStartWidth[key] = columnWidths.width(for: key)
                }
                let start = dragStartWidth[key] ?? columnWidths.width(for: key)
                columnWidths.setWidth(start + value.translation.width, for: key)
            },
            onEnded: {
                dragStartWidth[key] = nil
                columnWidths.save()
            })
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

            Divider()

            // Unify passwords: store one password on every ticked profile at once,
            // so a set of boxes that share a login can be set up together. Each
            // profile keeps its own Keychain entry (Touch-ID gated by default), so
            // autofill works the same as a password typed in the profile editor.
            HStack(spacing: 8) {
                Text("Password")
                    .foregroundStyle(.secondary)
                SecureField("shared password", text: $passwordValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Toggle("Require Touch ID", isOn: $passwordRequireAuth)
                    .toggleStyle(.checkbox)
                    .help("Ask for Touch ID / your login password before the saved password is used")
                Button("Set on Selected") { applyPassword() }
                    .buttonStyle(.borderedProminent)
                    .disabled(passwordValue.isEmpty)
                Button("Clear on Selected") { clearPasswords() }
                    .help("Remove the saved password from every ticked profile")
            }

            Divider()

            // Copy list-valued settings (saved commands, links, SFTP paths, port
            // forwards, environment variables) from one profile onto the ticked ones.
            HStack(spacing: 8) {
                Text("Lists")
                    .foregroundStyle(.secondary)
                Button("Copy Lists Between Profiles…") { showPropagate = true }
                    .help("View a profile's saved commands, links, SFTP paths, port forwards or environment variables and copy them onto the ticked profiles")
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

    /// Store the typed password on every ticked remote profile (each keeps its own
    /// Keychain entry), setting its Touch-ID requirement to match the toggle. Local
    /// profiles are skipped — they have nothing to authenticate.
    private func applyPassword() {
        let password = passwordValue
        guard !password.isEmpty else {
            status = "Type a password to set."
            return
        }
        let targets = rows.filter { selected.contains($0.id) && !$0.isLocal }
        guard !targets.isEmpty else {
            status = "No remote profiles selected — tick one or more rows first."
            return
        }
        var applied = 0
        for var profile in targets {
            guard KeychainStore.shared.setPassword(password, for: profile.id) else { continue }
            profile.requireAuthForSavedPassword = passwordRequireAuth
            store.update(profile)
            applied += 1
        }
        passwordValue = ""
        status = "Set a shared password on \(applied) profile(s)."
    }

    /// Remove the saved password from every ticked remote profile.
    private func clearPasswords() {
        let targets = rows.filter { selected.contains($0.id) && !$0.isLocal }
        guard !targets.isEmpty else {
            status = "No remote profiles selected — tick one or more rows first."
            return
        }
        var cleared = 0
        for profile in targets where KeychainStore.shared.hasPassword(for: profile.id) {
            KeychainStore.shared.deletePassword(for: profile.id)
            cleared += 1
        }
        status = "Cleared the saved password from \(cleared) profile(s)."
    }
}

/// How a copied collection is applied to a destination profile.
enum PropagateMode: String, CaseIterable, Identifiable {
    case merge = "Add new items"
    case replace = "Replace all"
    var id: String { rawValue }
}

/// The list-valued profile settings the "copy lists between profiles" dialog can
/// preview and propagate. Each case knows how to describe its items and how to
/// copy them from one profile onto another.
enum ProfileCollectionKind: String, CaseIterable, Identifiable {
    case snippets = "Saved Commands"
    case links = "Links"
    case sftpPaths = "SFTP Paths"
    case forwards = "Port Forwards"
    case envVars = "Environment Variables"

    var id: String { rawValue }

    /// One-line, human-readable descriptions of each item in `profile`.
    func items(in profile: SSHProfile) -> [String] {
        switch self {
        case .snippets:
            return profile.snippets.map { s in
                let l = s.label.trimmingCharacters(in: .whitespaces)
                return l.isEmpty ? s.command : "\(l) — \(s.command)"
            }
        case .links:
            return profile.links.map { "\($0.displayLabel) — \($0.url)" }
        case .sftpPaths:
            return profile.sftpBookmarks.map { b in
                let l = b.label.trimmingCharacters(in: .whitespaces)
                return l.isEmpty ? b.trimmedPath : "\(l) — \(b.trimmedPath)"
            }
        case .forwards:
            return profile.forwards.map { f in
                let n = f.trimmedName
                return n.isEmpty ? f.summary : "\(n): \(f.summary)"
            }
        case .envVars:
            return profile.environment.map { "\($0.name)=\($0.value)" }
        }
    }

    func count(in profile: SSHProfile) -> Int { items(in: profile).count }

    /// Copy this collection from `source` into `dest`. `.replace` overwrites the
    /// destination's list; `.merge` appends only items not already present.
    /// Copied items get fresh ids so the two profiles keep independent entries.
    func copy(from source: SSHProfile, into dest: inout SSHProfile, mode: PropagateMode) {
        switch self {
        case .snippets:
            var incoming = source.snippets.map { s -> CommandSnippet in var c = s; c.id = UUID(); return c }
            if mode == .merge {
                let have = Set(dest.snippets.map { "\($0.label)\u{1}\($0.command)" })
                incoming = incoming.filter { !have.contains("\($0.label)\u{1}\($0.command)") }
                dest.snippets.append(contentsOf: incoming)
            } else {
                dest.snippets = incoming
            }
        case .links:
            var incoming = source.links.map { l -> ProfileLink in var c = l; c.id = UUID(); return c }
            if mode == .merge {
                let have = Set(dest.links.map { "\($0.label)\u{1}\($0.url)" })
                incoming = incoming.filter { !have.contains("\($0.label)\u{1}\($0.url)") }
                dest.links.append(contentsOf: incoming)
            } else {
                dest.links = incoming
            }
        case .sftpPaths:
            var incoming = source.sftpBookmarks.map { b -> SFTPBookmark in var c = b; c.id = UUID(); return c }
            if mode == .merge {
                let have = Set(dest.sftpBookmarks.map { $0.trimmedPath })
                incoming = incoming.filter { !have.contains($0.trimmedPath) }
                dest.sftpBookmarks.append(contentsOf: incoming)
            } else {
                dest.sftpBookmarks = incoming
            }
        case .forwards:
            var incoming = source.forwards.map { f -> PortForward in var c = f; c.id = UUID(); return c }
            if mode == .merge {
                let have = Set(dest.forwards.map { $0.summary })
                incoming = incoming.filter { !have.contains($0.summary) }
                dest.forwards.append(contentsOf: incoming)
            } else {
                dest.forwards = incoming
            }
        case .envVars:
            var incoming = source.environment.map { e -> EnvVar in var c = e; c.id = UUID(); return c }
            if mode == .merge {
                let have = Set(dest.environment.map { $0.name })
                incoming = incoming.filter { !have.contains($0.name) }
                dest.environment.append(contentsOf: incoming)
            } else {
                dest.environment = incoming
            }
        }
    }
}

/// A dialog that previews one list-valued setting (saved commands, links, SFTP
/// paths, port forwards or environment variables) from a chosen profile and
/// copies it onto the profiles ticked in the compare table.
struct PropagateCollectionView: View {
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    /// The profiles ticked in the compare table — the copy targets (a snapshot
    /// taken when the dialog opened).
    let targets: [SSHProfile]

    @State private var kind: ProfileCollectionKind = .snippets
    @State private var sourceID: UUID?
    @State private var mode: PropagateMode = .merge
    @State private var status = ""

    init(targets: [SSHProfile], initialSourceID: UUID?) {
        self.targets = targets
        _sourceID = State(initialValue: initialSourceID)
    }

    private var source: SSHProfile? { store.profiles.first { $0.id == sourceID } }

    /// Targets excluding the source profile itself.
    private var effectiveTargets: [SSHProfile] { targets.filter { $0.id != sourceID } }

    private var sourceIsTicked: Bool {
        guard let sid = sourceID else { return false }
        return targets.contains { $0.id == sid }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogHeader(
                icon: "doc.on.doc",
                title: "Copy Lists Between Profiles",
                subtitle: "Pick a list and a profile to copy it from, then push it onto the ticked profiles."
            )
            .padding(16)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                labelledRow("List") {
                    Picker("List", selection: $kind) {
                        ForEach(ProfileCollectionKind.allCases) { k in Text(k.rawValue).tag(k) }
                    }
                    .labelsHidden()
                    .frame(width: 240)
                    .onChange(of: kind) { _ in status = "" }
                }

                labelledRow("From") {
                    Picker("From", selection: $sourceID) {
                        Text("Choose a profile…").tag(UUID?.none)
                        ForEach(store.profiles.filter { !$0.isLocal }) { p in
                            Text(p.name).tag(UUID?.some(p.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }

                GroupBox {
                    preview
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 150, maxHeight: .infinity)

                labelledRow("Mode") {
                    Picker("Mode", selection: $mode) {
                        ForEach(PropagateMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }

                Text(copyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                Button("Copy to Ticked Profiles") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(source == nil || effectiveTargets.isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 480, idealHeight: 560)
    }

    @ViewBuilder
    private var preview: some View {
        if let source {
            let items = kind.items(in: source)
            if items.isEmpty {
                Text("“\(source.name)” has no \(kind.rawValue.lowercased()).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(4)
                }
            }
        } else {
            Text("Pick a profile to preview its \(kind.rawValue.lowercased()).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(4)
        }
    }

    private var copyDescription: String {
        let n = effectiveTargets.count
        if n == 0 {
            return sourceIsTicked
                ? "Tick another profile to copy to (the source profile is skipped)."
                : "Tick one or more profiles in the table to copy to."
        }
        let suffix = sourceIsTicked ? " (the source profile is skipped)" : ""
        return "Copies to \(n) ticked profile(s)\(suffix)."
    }

    private func labelledRow<Content: View>(_ title: String,
                                            @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 56, alignment: .leading)
                .foregroundStyle(.secondary)
            content()
            Spacer(minLength: 0)
        }
    }

    private func apply() {
        guard let src = source else { status = "Choose a profile to copy from."; return }
        let dests = effectiveTargets
        guard !dests.isEmpty else {
            status = "Tick at least one other profile to copy to."
            return
        }
        for var d in dests {
            kind.copy(from: src, into: &d, mode: mode)
            store.update(d)
        }
        status = "Copied \(kind.rawValue.lowercased()) to \(dests.count) profile(s)."
    }
}

/// A slim draggable handle sitting on a column's trailing edge. Dragging it
/// reports the drag (in **global** space, so a handle that moves as its column
/// resizes doesn't chase the cursor) so the caller can resize the column; a
/// native cursor rect shows the left-right resize cursor while hovering.
private struct ColumnResizeHandle: View {
    let onChanged: (DragGesture.Value) -> Void
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
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { onChanged($0) }
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

/// Makes the hosting sheet window user-resizable. SwiftUI sheets on macOS are
/// fixed-size by default (no resize control), so we reach the presenting window
/// and add `.resizable` to its style mask plus a sensible min/max size. This
/// lets the user drag the sheet's edges to grow the compare table.
struct SheetResizeEnabler: NSViewRepresentable {
    var minSize: NSSize
    var maxSize: NSSize = NSSize(width: 4000, height: 3000)

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.resizable)
        window.minSize = minSize
        window.maxSize = maxSize
    }
}

