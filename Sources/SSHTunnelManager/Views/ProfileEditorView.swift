import SwiftUI
import AppKit

struct ProfileEditorView: View {
    @State private var profile: SSHProfile
    var onSave: (SSHProfile) -> Void
    var onCancel: () -> Void

    @State private var newPassword: String = ""
    @State private var hasSavedPassword: Bool
    @State private var removePassword: Bool = false
    @State private var showIconPicker = false
    /// Pending service-password edits per forward id (typed but not yet saved).
    @State private var serviceNewPasswords: [UUID: String] = [:]
    /// Forward ids whose saved service password should be removed on save.
    @State private var serviceRemovePasswords: Set<UUID> = []
    private let isNew: Bool

    /// The profile as it was loaded, to detect unsaved edits (for the save-on-quit
    /// prompt).
    @State private var originalProfile: SSHProfile
    @ObservedObject private var editCoordinator = ProfileEditCoordinator.shared

    init(profile: SSHProfile,
         onSave: @escaping (SSHProfile) -> Void,
         onCancel: @escaping () -> Void) {
        _profile = State(initialValue: profile)
        _originalProfile = State(initialValue: profile)
        _hasSavedPassword = State(initialValue: KeychainStore.shared.hasPassword(for: profile.id))
        isNew = !ProfileStore.shared.profiles.contains { $0.id == profile.id }
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        let hasName = !profile.name.trimmingCharacters(in: .whitespaces).isEmpty
        if profile.isLocal { return hasName }
        return hasName && !profile.host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var headerSubtitle: String {
        if profile.isLocal {
            let p = profile.startPath.trimmingCharacters(in: .whitespaces)
            return p.isEmpty ? "Local shell" : "Local shell · \(displayPath(p))"
        }
        return profile.host.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Configure a new SSH connection"
            : profile.subtitle
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            typePicker
            Divider()

            Form {
                if profile.isLocal {
                    localSection
                    terminalSection
                    workspaceSection
                    snippetsSection
                    linksSection
                } else {
                    connectionSection
                    authenticationSection
                    forwardsSection
                    optionsSection
                    terminalSection
                    workspaceSection
                    snippetsSection
                    linksSection
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)

            Divider()
            commandPreview
            Divider()
            actionBar
        }
        .onAppear { syncCoordinator() }
        .onDisappear {
            // The sheet closed; nothing is "open and unsaved" any more.
            editCoordinator.isOpen = false
            editCoordinator.isDirty = false
        }
        .onChange(of: editFingerprint) { _ in syncCoordinator() }
        .onChange(of: editCoordinator.commitRequested) { requested in
            guard requested else { return }
            editCoordinator.commitRequested = false
            // Run the editor's normal save (or, if the profile is incomplete and
            // can't be saved, just dismiss) so a "Save" from the quit prompt does
            // exactly what the Save button would.
            if canSave {
                applyPasswordChanges()
                onSave(normalized())
            } else {
                onCancel()
            }
            editCoordinator.editorDidFinishCommit()
        }
    }

    // MARK: - Unsaved-edit tracking (for the save-on-quit prompt)

    /// Whether the editor currently holds edits that differ from what was loaded.
    private var isDirtyNow: Bool {
        if profile != originalProfile { return true }
        if !newPassword.isEmpty { return true }
        if removePassword { return true }
        if serviceNewPasswords.values.contains(where: { !$0.isEmpty }) { return true }
        if !serviceRemovePasswords.isEmpty { return true }
        return false
    }

    /// A value that changes whenever any editable state changes, so a single
    /// `onChange` can keep the coordinator in sync.
    private var editFingerprint: Int {
        var h = Hasher()
        h.combine(profile)
        h.combine(newPassword)
        h.combine(removePassword)
        for (key, value) in serviceNewPasswords { h.combine(key); h.combine(value) }
        h.combine(serviceRemovePasswords)
        return h.finalize()
    }

    private func syncCoordinator() {
        editCoordinator.isOpen = true
        editCoordinator.isDirty = isDirtyNow
        editCoordinator.canSave = canSave
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: profile.displayIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(isNew ? "New Profile" : "Edit Profile")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// Segmented SSH / Local switch.
    private var typePicker: some View {
        Picker("Type", selection: $profile.isLocal) {
            Text("SSH Tunnel").tag(false)
            Text("Local Shell").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Sections

    /// Name + start folder for a local-shell profile.
    private var localSection: some View {
        Section {
            iconRow
            labeledField("Name", systemImage: "tag",
                         placeholder: "My Folder", text: $profile.name,
                         required: true)
            startPathRow
        } header: {
            Label("Local Shell", systemImage: "terminal")
        } footer: {
            Text("Opens your login shell in a new tab, starting in the folder below. Leave the folder empty to start in your home directory.")
        }
    }

    /// A row that shows the current icon and opens the icon picker popover.
    private var iconRow: some View {
        LabeledContent {
            Button {
                showIconPicker = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: profile.displayIcon)
                        .frame(width: 18)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .popover(isPresented: $showIconPicker, arrowEdge: .bottom) {
                iconPicker
            }
        } label: {
            Label("Icon", systemImage: "square.grid.2x2")
        }
    }

    private var iconPicker: some View {
        let columns = Array(repeating: GridItem(.fixed(40), spacing: 8), count: 6)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Choose an Icon").font(.headline)
                Spacer()
                Button("Default") {
                    profile.icon = ""
                    showIconPicker = false
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ProfileIcon.groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(group.symbols, id: \.self) { sym in
                                    iconCell(sym)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 320, height: 380)
    }

    private func iconCell(_ symbol: String) -> some View {
        let selected = profile.displayIcon == symbol
        return Button {
            profile.icon = symbol
            showIconPicker = false
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 40, height: 36)
                .background(selected ? Color.accentColor.opacity(0.25)
                                     : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .help(symbol)
    }

    @ViewBuilder
    private var startPathRow: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField("~/projects (optional)", text: $profile.startPath)
                    .autocorrectionDisabled()
                Button("Choose…", action: chooseStartPath)
            }
        } label: {
            Label("Start folder", systemImage: "folder")
        }
    }

    private var connectionSection: some View {
        Section {
            iconRow
            labeledField("Name", systemImage: "tag",
                         placeholder: "My Server", text: $profile.name,
                         required: true)
            LabeledContent {
                HStack(spacing: 8) {
                    TextField("example.com or 10.0.0.5", text: $profile.host)
                        .autocorrectionDisabled()
                    Text("Port").font(.caption).foregroundStyle(.secondary)
                    TextField("22", text: $profile.port)
                        .frame(width: 56)
                        .multilineTextAlignment(.center)
                        .autocorrectionDisabled()
                }
            } label: {
                HStack(spacing: 6) {
                    Label("Host", systemImage: "server.rack")
                    requiredBadge(profile.host)
                }
            }
            labeledField("Username", systemImage: "person",
                         placeholder: "deploy (optional)",
                         text: $profile.username, disableAutocorrect: true)
            labeledField("Jump host", systemImage: "arrow.triangle.branch",
                         placeholder: "user@bastion (optional)",
                         text: $profile.jumpHost, disableAutocorrect: true)
        } header: {
            Label("Connection", systemImage: "network")
        } footer: {
            Text("The server you’re connecting to. A jump host first hops through a bastion (ssh -J).")
        }
    }

    private var authenticationSection: some View {
        Section {
            identityFileRow
            passwordRows
            Toggle("Require Touch ID / login password before use",
                   isOn: $profile.requireAuthForSavedPassword)
            Button {
                setUpPasswordlessLogin()
            } label: {
                Label("Set Up Passwordless Login…", systemImage: "key")
            }
            .disabled(!canSave)
            .help(canSave
                  ? "Save this profile, then copy your SSH key to the server with ssh-copy-id so you can sign in without a password."
                  : "Enter a name and host first.")
        } header: {
            Label("Authentication", systemImage: "lock")
        } footer: {
            Text("Prefer an SSH key when you can. A saved password lives in your macOS Keychain and is typed automatically when the server asks. Passwords are never included when you export profiles.\n\n“Set Up Passwordless Login” saves the profile and uses ssh-copy-id to install your key on the server — generating a new key first if you don’t have one.")
        }
    }

    /// Save the profile, then kick off the one-click `ssh-copy-id` key setup for
    /// it. Deferred a runloop turn so the editor sheet finishes dismissing before
    /// the key-setup alert / terminal tab appears in the main window behind it.
    private func setUpPasswordlessLogin() {
        applyPasswordChanges()
        let saved = normalized()
        onSave(saved)
        DispatchQueue.main.async {
            TerminalSessionManager.shared.setUpKeyLogin(profile: saved)
        }
    }

    @ViewBuilder
    private var identityFileRow: some View {
        if profile.identityFile.isEmpty {
            LabeledContent {
                Button("Choose…", action: chooseIdentityFile)
            } label: {
                Label("SSH private key", systemImage: "key")
            }
        } else {
            LabeledContent {
                HStack(spacing: 8) {
                    Button("Change…", action: chooseIdentityFile)
                    Button("Clear") { profile.identityFile = "" }
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SSH private key")
                        Text(displayPath(profile.identityFile))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } icon: {
                    Image(systemName: "key.fill")
                }
            }
        }
    }

    @ViewBuilder
    private var passwordRows: some View {
        if hasSavedPassword && !removePassword {
            HStack {
                Label("Password saved in Keychain", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remove", role: .destructive) {
                    removePassword = true
                    newPassword = ""
                }
                .buttonStyle(.borderless)
            }
            SecureField("Replace password (optional)", text: $newPassword)
        } else {
            SecureField("Password (optional)", text: $newPassword)
            if removePassword {
                Text("The saved password will be removed when you save.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var forwardsSection: some View {
        Section {
            if profile.forwards.isEmpty {
                Text("No tunnels yet. Add a port forward below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach($profile.forwards) { $forward in
                ForwardEditor(
                    forward: $forward,
                    serviceNewPassword: serviceNewPasswordBinding(forward.id),
                    serviceRemovePassword: serviceRemoveBinding(forward.id),
                    hasSavedServicePassword: KeychainStore.shared.hasPassword(for: forward.id)
                ) {
                    profile.forwards.removeAll { $0.id == forward.id }
                }
                Divider()
            }
            Button {
                profile.forwards.append(PortForward())
            } label: {
                Label("Add Port Forward", systemImage: "plus.circle.fill")
            }
        } header: {
            Label("Port Forwards", systemImage: "arrow.left.arrow.right")
        } footer: {
            Text("Each rule maps a port through the SSH connection. Pick a type to see what it does.")
        }
    }

    private var optionsSection: some View {
        Section {
            Toggle("Open an interactive shell", isOn: $profile.openShell)
                .help("When off, only the tunnels run (ssh -N).")
            Toggle("Keep the connection alive", isOn: $profile.keepAlive)
                .help("Periodic keepalives so idle tunnels don’t drop.")
            Toggle("Enable compression", isOn: $profile.compression)
                .help("Helpful over slow links (ssh -C).")
            Toggle("Verbose logging", isOn: $profile.verbose)
                .help("Show ssh’s connection diagnostics (ssh -v).")
            LabeledContent {
                TextField("-o StrictHostKeyChecking=accept-new",
                          text: $profile.extraOptions)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
            } label: {
                Label("Extra ssh options", systemImage: "ellipsis.curlybraces")
            }
        } header: {
            Label("SSH Options", systemImage: "slider.horizontal.3")
        }
    }

    private var terminalSection: some View {
        Section {
            Picker("Theme", selection: $profile.theme) {
                Section("Dark") {
                    ForEach(TerminalTheme.dark) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                Section("Light") {
                    ForEach(TerminalTheme.light) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
            }
            ThemePreview(theme: TerminalTheme.theme(id: profile.theme))
            Stepper(value: $profile.fontSize,
                    in: TerminalFontMetrics.min...TerminalFontMetrics.max,
                    step: TerminalFontMetrics.step) {
                Text("Text size: \(Int(profile.fontSize)) pt")
            }
            .help("The terminal text size for this profile. You can also adjust it live with ⌘+ / ⌘− in the terminal.")
        } header: {
            Label("Terminal", systemImage: "terminal")
        }
    }

    /// Existing open + saved workspace names, offered as quick-pick suggestions.
    private var workspaceSuggestions: [String] {
        let mgr = TerminalSessionManager.shared
        let names = mgr.workspaces.map(\.name) + mgr.savedWorkspaces.map(\.name)
        return Array(Set(names))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var workspaceSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("Current workspace", text: $profile.workspace)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    if !workspaceSuggestions.isEmpty {
                        Menu {
                            ForEach(workspaceSuggestions, id: \.self) { name in
                                Button(name) { profile.workspace = name }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Pick an existing workspace")
                    }
                    if !profile.workspace.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button {
                            profile.workspace = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Use the current workspace")
                    }
                }
            } label: {
                Label("Open in workspace", systemImage: "rectangle.split.3x1")
            }
            Text("Connecting this profile (including its SFTP and VNC tabs) switches to this workspace, creating it if it doesn’t exist, and keeps the connection there. Leave blank to use whatever workspace is current.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Label("Workspace", systemImage: "square.grid.2x2")
        }
    }

    private var snippetsSection: some View {
        Section {
            if profile.snippets.isEmpty {
                Text("No saved commands yet. Add commands you run often to insert them into the terminal with one click.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach($profile.snippets) { $snippet in
                SnippetEditor(snippet: $snippet) {
                    profile.snippets.removeAll { $0.id == snippet.id }
                }
                Divider()
            }
            Button {
                profile.snippets.append(CommandSnippet())
            } label: {
                Label("Add Command", systemImage: "plus.circle.fill")
            }
        } header: {
            HStack {
                Label("Saved Commands", systemImage: "text.append")
                Spacer()
                Menu {
                    Button {
                        let imported = ProfileTransfer.importSnippets()
                        if !imported.isEmpty { profile.snippets.append(contentsOf: imported) }
                    } label: {
                        Label("Import Commands…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        ProfileTransfer.exportSnippets(profile.snippets,
                                                       suggestedName: ProfileTransfer.snippetsFileName(for: profile))
                    } label: {
                        Label("Export Commands…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(profile.snippets.isEmpty)
                } label: {
                    Label("Import / Export", systemImage: "square.and.arrow.up.on.square")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .textCase(nil)
                .help("Import or export this profile’s saved commands")
            }
        }
    }

    // MARK: - Command preview + actions

    private var linksSection: some View {
        Section {
            if profile.links.isEmpty {
                Text("No links yet. Add web pages — like a tunnel's web UI — to open them in an in-app browser tab.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach($profile.links) { $link in
                LinkEditor(link: $link,
                           onOpen: { TerminalSessionManager.shared.openLink(link, profile: profile) },
                           onDelete: { profile.links.removeAll { $0.id == link.id } })
                Divider()
            }
            Button {
                profile.links.append(ProfileLink())
            } label: {
                Label("Add Link", systemImage: "plus.circle.fill")
            }
        } header: {
            Label("Links", systemImage: "globe")
        } footer: {
            Text("Open a link from the globe menu in the tab bar, a tab's right-click menu, or the sidebar. Opening a link starts this profile's tunnel if it isn't already running. If the profile has a dynamic (SOCKS) forward, the browser routes through it (macOS 14+). A URL without a scheme defaults to http for localhost / IPs and https otherwise.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("COMMAND PREVIEW")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyCommand()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(previewText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The command shown in the preview (ssh for remote profiles, the shell for local).
    private var previewText: String {
        if profile.isLocal {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let p = profile.startPath.trimmingCharacters(in: .whitespaces)
            return p.isEmpty ? "\(shell) -l"
                : "cd \(SSHCommandBuilder.shellQuote(p)) && \(shell) -l"
        }
        return SSHCommandBuilder.commandPreview(for: profile)
    }

    private var actionBar: some View {
        HStack {
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(isNew ? "Add Profile" : "Save") {
                applyPasswordChanges()
                onSave(normalized())
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Field helpers

    @ViewBuilder
    private func labeledField(_ title: String, systemImage: String,
                              placeholder: String, text: Binding<String>,
                              disableAutocorrect: Bool = false,
                              required: Bool = false) -> some View {
        LabeledContent {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.leading)
                .autocorrectionDisabled(disableAutocorrect)
        } label: {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage)
                if required {
                    requiredBadge(text.wrappedValue)
                }
            }
        }
    }

    /// A small amber "Required" pill shown only while `value` is still empty, so
    /// it disappears the moment the user fills the field in.
    @ViewBuilder
    private func requiredBadge(_ value: String) -> some View {
        if value.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Required")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.15), in: Capsule())
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func normalized() -> SSHProfile {
        var p = profile
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        p.startPath = p.startPath.trimmingCharacters(in: .whitespaces)
        p.host = p.host.trimmingCharacters(in: .whitespaces)
        p.username = p.username.trimmingCharacters(in: .whitespaces)
        if !p.isLocal, p.port.trimmingCharacters(in: .whitespaces).isEmpty { p.port = "22" }
        p.links.removeAll {
            $0.label.trimmingCharacters(in: .whitespaces).isEmpty
                && $0.url.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return p
    }

    private func applyPasswordChanges() {
        if removePassword {
            KeychainStore.shared.deletePassword(for: profile.id)
        }
        if !newPassword.isEmpty {
            KeychainStore.shared.setPassword(newPassword, for: profile.id)
        }
        applyServicePasswordChanges()
    }

    /// Persist per-forward MQTT / Redis service passwords (Keychain, keyed by the
    /// forward id), and clean up entries for forwards removed during this edit.
    private func applyServicePasswordChanges() {
        for forward in profile.forwards {
            if serviceRemovePasswords.contains(forward.id) {
                KeychainStore.shared.deletePassword(for: forward.id)
            }
            if let pw = serviceNewPasswords[forward.id], !pw.isEmpty,
               forward.category == .mqtt || forward.category == .redis {
                KeychainStore.shared.setPassword(pw, for: forward.id)
            }
        }
        // Drop Keychain passwords for forwards that existed before but were
        // deleted in this session, so they don't linger orphaned.
        if let original = ProfileStore.shared.profiles.first(where: { $0.id == profile.id }) {
            let current = Set(profile.forwards.map(\.id))
            for removed in original.forwards where !current.contains(removed.id) {
                KeychainStore.shared.deletePassword(for: removed.id)
            }
        }
    }

    private func serviceNewPasswordBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { serviceNewPasswords[id] ?? "" },
                set: { serviceNewPasswords[id] = $0 })
    }

    private func serviceRemoveBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { serviceRemovePasswords.contains(id) },
                set: { remove in
                    if remove { serviceRemovePasswords.insert(id) }
                    else { serviceRemovePasswords.remove(id) }
                })
    }

    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(previewText, forType: .string)
    }

    private func chooseStartPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Start Folder"
        if !profile.startPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath:
                (profile.startPath as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            profile.startPath = url.path
        }
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.title = "Choose SSH Private Key"
        let sshDir = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh")
        panel.directoryURL = URL(fileURLWithPath: sshDir)
        if panel.runModal() == .OK, let url = panel.url {
            profile.identityFile = url.path
        }
    }
}

/// A small live preview of a terminal theme's colors.
struct ThemePreview: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("user@host")
                    .foregroundStyle(Color(nsColor: theme.ansi[2].nsColor))
                Text(" ~ % ")
                    .foregroundStyle(Color(nsColor: theme.foreground.nsColor))
                Text("ssh -L 8080:localhost:80")
                    .foregroundStyle(Color(nsColor: theme.foreground.nsColor))
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)

            HStack(spacing: 3) {
                ForEach(Array(theme.ansi.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: color.nsColor))
                        .frame(width: 13, height: 13)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: theme.background.nsColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
}

/// One row in the Links editor: a label, a URL, an Open button and delete.
struct LinkEditor: View {
    @Binding var link: ProfileLink
    var onOpen: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Label (e.g. Web UI)", text: $link.label)
                    .textFieldStyle(.roundedBorder)
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .disabled(link.normalizedURL == nil)
                .help("Open this link in a browser tab")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this link")
            }
            TextField("URL (e.g. localhost:8080 or https://example.com)", text: $link.url)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
        }
        .padding(.vertical, 4)
    }
}

/// One row in the Saved Commands editor: a label and the command text.
struct SnippetEditor: View {
    @Binding var snippet: CommandSnippet
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Label (e.g. Tail logs)", text: $snippet.label)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this command")
            }
            TextField("Command (e.g. tail -f /var/log/app.log)", text: $snippet.command)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
        }
        .padding(.vertical, 4)
    }
}

struct ForwardEditor: View {
    @Binding var forward: PortForward
    /// Pending (typed-but-unsaved) service password for this forward.
    @Binding var serviceNewPassword: String
    /// Whether the saved service password should be removed on save.
    @Binding var serviceRemovePassword: Bool
    /// Whether a service password is already stored for this forward.
    let hasSavedServicePassword: Bool
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Type", selection: $forward.type) {
                    ForEach(ForwardType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this forward")
            }

            Text(forward.type.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Only local (-L) forwards listen on this Mac, so only they can be
            // categorized into a launchable Web / MQTT / Redis tab.
            if forward.type == .local {
                HStack(spacing: 8) {
                    Label("Opens as", systemImage: "square.grid.2x2")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Service category", selection: $forward.category) {
                        ForEach(ForwardCategory.allCases) { category in
                            Label(category.title, systemImage: category.symbol).tag(category)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    Spacer()
                }
                if forward.category != .none {
                    Text(categoryHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if forward.category == .mqtt || forward.category == .redis {
                    serviceCredentials
                }
            }

            switch forward.type {
            case .dynamic:
                HStack(alignment: .bottom, spacing: 12) {
                    field("SOCKS port", "1080", $forward.listenPort, width: 110)
                    field("Bind address (optional)", "127.0.0.1", $forward.bindAddress, width: 160)
                }
            case .local:
                HStack(alignment: .bottom, spacing: 8) {
                    field("Local port", "8080", $forward.listenPort, width: 90)
                    arrow
                    field("Target host", "localhost", $forward.targetHost)
                    field("Target port", "80", $forward.targetPort, width: 80)
                }
            case .remote:
                HStack(alignment: .bottom, spacing: 8) {
                    field("Remote port", "8080", $forward.listenPort, width: 100)
                    arrow
                    field("Target host", "localhost", $forward.targetHost)
                    field("Target port", "80", $forward.targetPort, width: 80)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }

    /// Username + Keychain password for an MQTT / Redis service forward.
    @ViewBuilder
    private var serviceCredentials: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                field("Username (optional)", "username", $forward.serviceUsername, width: 200)
                Spacer()
            }
            servicePasswordField
            Text("Used to authenticate to the \(forward.category.title) service. The password is stored in your macOS Keychain — never in the profile file or exports.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var servicePasswordField: some View {
        if hasSavedServicePassword && !serviceRemovePassword {
            HStack {
                Label("Password saved in Keychain", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Remove", role: .destructive) {
                    serviceRemovePassword = true
                    serviceNewPassword = ""
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            secureField("Replace password (optional)", $serviceNewPassword)
        } else {
            secureField("Password (optional)", $serviceNewPassword)
            if serviceRemovePassword {
                Text("The saved password will be removed when you save.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func secureField(_ placeholder: String, _ text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 320, alignment: .leading)
    }

    /// One-line description of what choosing a service category adds.
    private var categoryHint: String {
        switch forward.category {
        case .none:
            return ""
        case .webpage:
            return "Adds an “Open Web Page” action that loads this port in a browser tab."
        case .mqtt:
            return "Adds an “Open MQTT” action: a mosquitto_sub monitor tab on every topic."
        case .redis:
            return "Adds an “Open Redis” action: an interactive redis-cli tab."
        }
    }

    @ViewBuilder
    private func field(_ title: String, _ placeholder: String, _ text: Binding<String>, width: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Group {
                if let width {
                    TextField(placeholder, text: text).frame(width: width)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
        }
    }
}
