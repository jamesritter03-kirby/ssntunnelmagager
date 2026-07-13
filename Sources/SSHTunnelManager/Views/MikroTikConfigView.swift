import SwiftUI

/// A WinBox-style configuration explorer for one MikroTik router. The left list
/// groups the common RouterOS menus; selecting one shows its rows in a table
/// with add / edit / enable / delete, driven entirely by the RouterOS REST API.
struct MikroTikConfigView: View {
    let router: MikroTikRouter
    @ObservedObject var mikro: MikroTikStore

    @State private var selected: MikroTikMenu = MikroTikMenu.catalog.first!
    @State private var search = ""
    @State private var editing: EditTarget?

    // Config-file import state.
    @State private var showImporter = false
    @State private var pendingConfig: PendingConfig?
    @State private var applying = false
    @State private var applyResult: ApplyResult?

    // Export / backup state.
    @State private var exporting = false

    /// A loaded config file awaiting user confirmation before it's applied.
    private struct PendingConfig: Identifiable {
        let id = UUID()
        var fileName: String
        var source: String
        var lineCount: Int
    }

    /// The outcome of applying a config, shown in an alert.
    private struct ApplyResult: Identifiable {
        let id = UUID()
        var success: Bool
        var message: String
    }

    /// What the editor sheet is working on: a brand-new row or an existing one.
    private struct EditTarget: Identifiable {
        let id = UUID()
        var menu: MikroTikMenu
        var entry: MikroTikEntry?   // nil = adding
    }

    private var groups: [String] {
        var seen = Set<String>()
        return MikroTikMenu.catalog.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    var body: some View {
        HStack(spacing: 0) {
            menuList
                .frame(width: 210)
            Divider()
            entryPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $editing) { target in
            MikroTikEntryEditor(
                router: router, mikro: mikro, menu: target.menu, entry: target.entry)
        }
        .task(id: selected.path) { await mikro.loadMenu(router, selected) }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.plainText, .text, .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .alert(item: $pendingConfig) { cfg in
            Alert(
                title: Text("Apply “\(cfg.fileName)”?"),
                message: Text("This runs \(cfg.lineCount) line\(cfg.lineCount == 1 ? "" : "s") of RouterOS commands on \(router.displayName). Applying a configuration can change addresses, firewall rules, and interfaces — you may lose connectivity if the config is wrong. There is no automatic undo."),
                primaryButton: .destructive(Text("Apply Config")) { apply(cfg) },
                secondaryButton: .cancel())
        }
        .alert(item: $applyResult) { res in
            Alert(title: Text(res.success ? "Configuration Applied" : "Apply Failed"),
                  message: Text(res.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    // MARK: Config-file import

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let err):
            applyResult = ApplyResult(success: false, message: err.localizedDescription)
        case .success(let urls):
            guard let url = urls.first else { return }
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let lines = text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                guard !lines.isEmpty else {
                    applyResult = ApplyResult(success: false, message: "The file has no configuration commands.")
                    return
                }
                pendingConfig = PendingConfig(
                    fileName: url.lastPathComponent, source: text, lineCount: lines.count)
            } catch {
                applyResult = ApplyResult(
                    success: false,
                    message: "Couldn't read the file as text. RouterOS export (.rsc) files are expected.\n\n\(error.localizedDescription)")
            }
        }
    }

    private func apply(_ cfg: PendingConfig) {
        applying = true
        Task {
            do {
                try await mikro.applyConfig(router, source: cfg.source)
                applying = false
                applyResult = ApplyResult(
                    success: true,
                    message: "Applied “\(cfg.fileName)”. Reloading the current view.")
                await mikro.loadMenu(router, selected)
            } catch {
                applying = false
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                applyResult = ApplyResult(success: false, message: msg)
            }
        }
    }

    // MARK: Export / backup

    /// Pull the router's `/export` and save it to a `.rsc` file the user picks.
    private func exportConfig() {
        exporting = true
        Task {
            do {
                let text = try await mikro.exportConfig(router)
                exporting = false
                await saveExport(text)
            } catch {
                exporting = false
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                applyResult = ApplyResult(success: false, message: msg)
            }
        }
    }

    @MainActor
    private func saveExport(_ text: String) async {
        let panel = NSSavePanel()
        panel.title = "Save Configuration Export"
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(safeName(router.displayName))-\(dateStamp()).rsc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            applyResult = ApplyResult(
                success: true, message: "Saved configuration export to “\(url.lastPathComponent)”.")
        } catch {
            applyResult = ApplyResult(success: false, message: error.localizedDescription)
        }
    }

    /// Create a binary `.backup` on the router itself.
    private func createBackup() {
        exporting = true
        Task {
            do {
                let file = try await mikro.createBackup(router, name: "\(safeName(router.displayName))-\(dateStamp())")
                exporting = false
                applyResult = ApplyResult(
                    success: true,
                    message: "Created backup “\(file)” on the router’s storage. Binary backups can’t be downloaded over the API — retrieve it via WinBox (Files) or FTP if you need a local copy.")
            } catch {
                exporting = false
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                applyResult = ApplyResult(success: false, message: msg)
            }
        }
    }

    private func safeName(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).isEmpty ? "router" : String(cleaned)
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    // MARK: Menu list

    private var menuList: some View {
        List(selection: Binding(
            get: { selected },
            set: { if let v = $0 { selected = v } })) {
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(MikroTikMenu.catalog.filter { $0.group == group }) { menu in
                        Label(menu.title, systemImage: menu.icon)
                            .tag(menu)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Entry pane

    private var entries: [MikroTikEntry] {
        let all = mikro.entries(router, selected.path)
        guard !search.isEmpty else { return all }
        return all.filter { entry in
            entry.fields.values.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var entryPane: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let err = mikro.menuError(router, selected.path) {
                errorBanner(err)
            }
            if mikro.isMenuLoading(router, selected.path) && entries.isEmpty {
                Spacer()
                ProgressView("Loading \(selected.title)…")
                Spacer()
            } else if entries.isEmpty {
                Spacer()
                Text("No entries")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                entryTable
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(selected.title).font(.headline)
            if mikro.isMenuLoading(router, selected.path) {
                ProgressView().controlSize(.small)
            }
            Spacer()
            TextField("Filter", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            Button { Task { await mikro.loadMenu(router, selected) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")
            if applying {
                ProgressView().controlSize(.small)
            }
            Menu {
                Button {
                    exportConfig()
                } label: {
                    Label("Export Config to File (.rsc)…", systemImage: "square.and.arrow.up")
                }
                Button {
                    createBackup()
                } label: {
                    Label("Create Backup on Router (.backup)", systemImage: "externaldrive.badge.timemachine")
                }
                Divider()
                Button {
                    showImporter = true
                } label: {
                    Label("Load & Apply Config File…", systemImage: "square.and.arrow.down")
                }
            } label: {
                if exporting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.arrow.down.square")
                }
            }
            .menuIndicator(.hidden)
            .help("Backup, export, or apply a configuration")
            .disabled(applying || exporting)
            if selected.editable && !selected.isSingleton {
                Button { editing = EditTarget(menu: selected, entry: nil) } label: {
                    Image(systemName: "plus")
                }
                .help("Add \(selected.title)")
            }
            if selected.isSingleton, let only = entries.first {
                Button { editing = EditTarget(menu: selected, entry: only) } label: {
                    Image(systemName: "pencil")
                }
                .help("Edit settings")
            }
        }
        .padding(10)
    }

    private func errorBanner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
    }

    private var entryTable: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                columnHeader
                ForEach(entries) { entry in
                    entryRow(entry)
                    Divider()
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            if canToggle { Color.clear.frame(width: 34) }
            ForEach(selected.columns, id: \.self) { col in
                Text(col)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Color.clear.frame(width: 60)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var canToggle: Bool {
        selected.editable && !selected.isSingleton
    }

    private func entryRow(_ entry: MikroTikEntry) -> some View {
        HStack(spacing: 8) {
            if canToggle {
                Toggle("", isOn: Binding(
                    get: { !entry.disabled },
                    set: { on in Task { await mikro.setEntryDisabled(router, selected, id: entry.id, disabled: !on) } }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .frame(width: 34)
            }
            ForEach(selected.columns, id: \.self) { col in
                Text(entry.value(col))
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(entry.disabled ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack(spacing: 4) {
                if selected.editable {
                    Button { editing = EditTarget(menu: selected, entry: entry) } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    if !selected.isSingleton {
                        Button { Task { await mikro.removeEntry(router, selected, id: entry.id) } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }
            }
            .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .contextMenu {
            Button("Edit…") { editing = EditTarget(menu: selected, entry: entry) }
            if selected.editable && !selected.isSingleton {
                Button(entry.disabled ? "Enable" : "Disable") {
                    Task { await mikro.setEntryDisabled(router, selected, id: entry.id, disabled: !entry.disabled) }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    Task { await mikro.removeEntry(router, selected, id: entry.id) }
                }
            }
        }
    }
}

// MARK: - Entry editor

/// Add or edit one config row. When editing, shows every field the router
/// returned (so anything is tweakable); when adding, shows the menu's curated
/// add-fields. Booleans render as toggles, enum-ish fields as pickers.
private struct MikroTikEntryEditor: View {
    let router: MikroTikRouter
    @ObservedObject var mikro: MikroTikStore
    let menu: MikroTikMenu
    let entry: MikroTikEntry?

    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    /// Field order to render (keys).
    @State private var keys: [String] = []
    @State private var saving = false

    private var isAdding: Bool { entry == nil && !menu.isSingleton }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())

            ScrollView {
                Form {
                    ForEach(keys, id: \.self) { key in
                        field(for: key)
                    }
                }
                .formStyle(.grouped)
            }
            .frame(maxHeight: 420)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isAdding ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: prepare)
    }

    private var title: String {
        if menu.isSingleton { return "Edit \(menu.title)" }
        return isAdding ? "New \(menu.title)" : "Edit \(menu.title)"
    }

    /// The catalog field descriptor for a key, if any (drives labels/kinds).
    private func descriptor(_ key: String) -> MikroTikField? {
        menu.addFields.first { $0.key == key }
    }

    @ViewBuilder
    private func field(for key: String) -> some View {
        let desc = descriptor(key)
        let label = desc?.label ?? key
        let binding = Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 })

        if desc?.kind == .bool || isBoolValue(values[key]) {
            Toggle(label, isOn: Binding(
                get: { boolFrom(values[key]) },
                set: { values[key] = $0 ? "yes" : "no" }))
        } else if let choices = desc?.choices, !choices.isEmpty {
            Picker(label, selection: binding) {
                Text("(unset)").tag("")
                ForEach(choices, id: \.self) { Text($0).tag($0) }
                // Include the current value if it isn't in the preset list.
                if let cur = values[key], !cur.isEmpty, !choices.contains(cur) {
                    Text(cur).tag(cur)
                }
            }
        } else {
            TextField(label, text: binding,
                      prompt: Text(desc?.placeholder ?? ""))
        }
    }

    private func isBoolValue(_ v: String?) -> Bool {
        guard let v else { return false }
        return v == "true" || v == "false" || v == "yes" || v == "no"
    }

    private func boolFrom(_ v: String?) -> Bool {
        v == "true" || v == "yes"
    }

    private func prepare() {
        if let entry {
            // Edit: show every returned field, common ones first.
            values = entry.fields
            let priority = menu.columns + menu.addFields.map(\.key)
            var ordered: [String] = []
            for k in priority where entry.fields[k] != nil && !ordered.contains(k) { ordered.append(k) }
            for k in entry.fields.keys.sorted() where !ordered.contains(k) && !k.hasPrefix(".") { ordered.append(k) }
            // Drop read-only-ish RouterOS bookkeeping fields.
            let hidden: Set<String> = ["dynamic", "default", "invalid", "builtin"]
            keys = ordered.filter { !hidden.contains($0) }
        } else {
            // Add: the curated fields.
            keys = menu.addFields.map(\.key)
            for field in menu.addFields {
                values[field.key] = field.kind == .bool ? "no" : field.placeholder
            }
            // Don't pre-fill placeholders as real values for text fields.
            for field in menu.addFields where field.kind != .bool {
                values[field.key] = ""
            }
        }
    }

    private func save() {
        saving = true
        // Only send fields the user actually set (non-empty), so we don't clobber
        // router defaults with blanks on add.
        var payload: [String: String] = [:]
        for (k, v) in values {
            if isAdding && v.isEmpty { continue }
            payload[k] = v
        }
        Task {
            if menu.isSingleton {
                await mikro.updateEntry(router, menu, id: entry?.id ?? "", fields: payload)
            } else if let entry {
                await mikro.updateEntry(router, menu, id: entry.id, fields: payload)
            } else {
                await mikro.addEntry(router, menu, fields: payload)
            }
            dismiss()
        }
    }
}
