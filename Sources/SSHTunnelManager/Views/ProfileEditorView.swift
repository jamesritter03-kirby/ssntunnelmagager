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

    /// When this editor was opened by **Duplicate**, the name of the profile the
    /// copy was made from — drives the "finish setting up this copy" wizard. `nil`
    /// for a normal new/edit.
    private let duplicatedFromName: String?
    /// Set once the user hides the duplication wizard.
    @State private var wizardDismissed = false
    /// Steps the user has manually acknowledged in the duplication wizard.
    @State private var wizardAcks: Set<WizardStep> = []

    /// The profile as it was loaded, to detect unsaved edits (for the save-on-quit
    /// prompt).
    @State private var originalProfile: SSHProfile
    @ObservedObject private var editCoordinator = ProfileEditCoordinator.shared
    /// A save awaiting the “also update the workspace's tab addresses?” answer, and
    /// the flag that presents that prompt.
    @State private var pendingSaveProfile: SSHProfile?
    @State private var isConfirmingTabHostSync = false

    init(profile: SSHProfile,
         duplicatedFromName: String? = nil,
         onSave: @escaping (SSHProfile) -> Void,
         onCancel: @escaping () -> Void) {
        _profile = State(initialValue: profile)
        _originalProfile = State(initialValue: profile)
        _hasSavedPassword = State(initialValue: KeychainStore.shared.hasPassword(for: profile.id))
        isNew = !ProfileStore.shared.profiles.contains { $0.id == profile.id }
        self.duplicatedFromName = duplicatedFromName
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
                if showWizard {
                    duplicationWizardSection
                }
                if profile.isLocal {
                    localSection
                    organizationSection
                    automationSection
                    terminalSection
                    workspaceSection
                    snippetsSection
                    linksSection
                } else {
                    connectionSection
                    authenticationSection
                    forwardsSection
                    optionsSection
                    advancedSection
                    automationSection
                    organizationSection
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
        .alert("Point Workspace Tabs at This Host?", isPresented: $isConfirmingTabHostSync,
               presenting: pendingSaveProfile) { saved in
            Button("Update Tabs") { commitSave(saved, syncTabHosts: true) }
            Button("Keep Their Addresses") { commitSave(saved, syncTabHosts: false) }
            Button("Cancel", role: .cancel) { pendingSaveProfile = nil }
        } message: { saved in
            Text("This profile opens a workspace whose tabs point at a different address. Update those tabs to use “\(saved.host)” so they all connect to this server?")
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
        DialogHeader(icon: profile.displayIcon,
                     title: isNew ? "New Profile" : "Edit Profile",
                     subtitle: headerSubtitle,
                     helpArticleID: "profiles")
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
                    ZeroTierPickerButton { profile.host = $0 }
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

    /// SSH power-user options: agent, host-key policy, timeout, environment and a
    /// remote command. Only shown for SSH profiles.
    private var advancedSection: some View {
        Section {
            Toggle("Forward SSH agent (-A)", isOn: $profile.forwardAgent)
                .help("Lets a jump chain reuse your local keys without copying them onto intermediate hosts.")
            Toggle("Add keys to the agent on first use", isOn: $profile.addKeysToAgent)
                .help("Caches the key's passphrase in ssh-agent so it's only asked once (AddKeysToAgent=yes).")
            Toggle("Use mosh (mobile shell)", isOn: $profile.useMosh)
                .help(MoshCommandBuilder.isAvailable
                      ? "A resilient session that survives sleep and network changes. Port forwards don't apply to mosh."
                      : "Install mosh (e.g. brew install mosh) to use this. Port forwards don't apply to mosh.")
            Picker(selection: $profile.strictHostKeyChecking) {
                ForEach(StrictHostKeyChecking.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Host key checking", systemImage: "checkmark.shield")
            }
            LabeledContent {
                HStack(spacing: 6) {
                    TextField("0", value: $profile.connectTimeout, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.center)
                    Text("seconds (0 = default)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } label: {
                Label("Connect timeout", systemImage: "timer")
            }
            Toggle("Force a TTY for the remote command", isOn: $profile.requestTTY)
                .help("Adds ssh -tt so an interactive remote command (sudo, tmux…) gets a terminal.")
            LabeledContent {
                TextField("tail -f /var/log/syslog (optional)", text: $profile.remoteCommand)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
            } label: {
                Label("Remote command", systemImage: "terminal")
            }
            environmentEditor
        } header: {
            Label("Advanced", systemImage: "gearshape.2")
        } footer: {
            Text("Agent forwarding, host-key policy, environment variables sent to the server (SetEnv), and a command to run instead of a plain login shell.")
        }
    }

    /// A small key/value editor for the profile's SetEnv environment variables.
    private var environmentEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Environment (SetEnv)", systemImage: "character.textbox")
            ForEach($profile.environment) { $env in
                HStack(spacing: 6) {
                    TextField("NAME", text: $env.name)
                        .autocorrectionDisabled()
                        .frame(maxWidth: 150)
                    Text("=").foregroundStyle(.secondary)
                    TextField("value", text: $env.value)
                        .autocorrectionDisabled()
                    Button(role: .destructive) {
                        profile.environment.removeAll { $0.id == env.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                profile.environment.append(EnvVar())
            } label: {
                Label("Add Variable", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }

    /// Automation options shared by local and SSH profiles.
    private var automationSection: some View {
        Section {
            Toggle("Connect automatically at launch", isOn: $profile.autoConnectOnLaunch)
                .help("Bring this connection up when the app starts.")
            if !profile.isLocal {
                Toggle("Reconnect automatically if the connection drops",
                       isOn: $profile.autoReconnect)
                    .help("Retries with a short backoff after an unexpected drop — not when you disconnect it yourself.")
            }
            LabeledContent {
                TextField("tmux attach || tmux new (optional)", text: $profile.runOnConnect)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
            } label: {
                Label("Run on connect", systemImage: "play.circle")
            }
            Toggle("Log this session to a file", isOn: $profile.logSession)
                .help("Records a transcript under Application Support/SSHTunnelManager/Logs; reveal it from the tab's menu.")
        } header: {
            Label("Automation", systemImage: "wand.and.stars")
        } footer: {
            Text("“Run on connect” is typed into the terminal once the shell is ready.")
        }
    }

    /// Sidebar organisation: favourite + group/folder. Shared by local and SSH.
    private var organizationSection: some View {
        Section {
            Toggle("Favourite", isOn: $profile.isFavorite)
                .help("Favourites appear in their own section at the top of the sidebar.")
            labeledField("Group", systemImage: "folder",
                         placeholder: "e.g. Production (optional)",
                         text: $profile.group)
        } header: {
            Label("Organization", systemImage: "square.stack.3d.up")
        } footer: {
            Text("Star the profiles you use most, and group the rest into collapsible sidebar folders.")
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

    /// How connecting this profile places its tabs, for the workspace picker.
    private enum WorkspaceLaunchChoice: Hashable {
        case current
        case own
        case template(UUID)
    }

    /// Saved workspaces offered as launch templates, sorted by name.
    private var savedWorkspaceTemplates: [SavedWorkspace] {
        TerminalSessionManager.shared.savedWorkspaces
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The name the dedicated workspace will take: the custom name if the user
    /// typed one, otherwise the profile's own name.
    private var effectiveWorkspaceName: String {
        let custom = profile.workspace.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { return custom }
        let n = profile.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "this profile" : n
    }

    /// Placeholder for the workspace-name field: the profile's own name, used as
    /// the default when the field is left blank.
    private var workspaceNamePlaceholder: String {
        let n = profile.name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Workspace name" : n
    }

    /// The current launch choice, derived from — and written back to — the profile.
    /// The custom workspace name (`profile.workspace`) is preserved across mode
    /// changes so switching Own ⇄ Template doesn't lose what the user typed.
    private var workspaceChoice: Binding<WorkspaceLaunchChoice> {
        Binding(
            get: {
                if let tid = profile.workspaceTemplateID,
                   savedWorkspaceTemplates.contains(where: { $0.id == tid }) {
                    return .template(tid)
                }
                if profile.opensInOwnWorkspace { return .own }
                return .current
            },
            set: { choice in
                switch choice {
                case .current:
                    profile.opensInOwnWorkspace = false
                    profile.workspaceTemplateID = nil
                case .own:
                    profile.opensInOwnWorkspace = true
                    profile.workspaceTemplateID = nil
                case .template(let id):
                    profile.opensInOwnWorkspace = false
                    profile.workspaceTemplateID = id
                }
            }
        )
    }

    /// One-line explanation of what the selected launch choice does.
    private var workspaceHint: String {
        switch workspaceChoice.wrappedValue {
        case .current:
            return "Connecting opens this profile's tabs in whatever workspace is active."
        case .own:
            return "Connecting opens a workspace named “\(effectiveWorkspaceName)” and keeps this profile's tabs (connection, SFTP, VNC…) together. Reconnecting reuses it."
        case .template(let id):
            let name = savedWorkspaceTemplates.first { $0.id == id }?.name ?? "the saved workspace"
            return "Connecting builds a workspace named “\(effectiveWorkspaceName)” from “\(name)” — recreating its tabs and layout — then connects. Reconnecting reuses that workspace."
        }
    }

    private var workspaceSection: some View {
        Section {
            Picker(selection: workspaceChoice) {
                Text("Current workspace").tag(WorkspaceLaunchChoice.current)
                Text("New workspace for this profile").tag(WorkspaceLaunchChoice.own)
                if !savedWorkspaceTemplates.isEmpty {
                    Section("Recreate a saved workspace") {
                        ForEach(savedWorkspaceTemplates) { ws in
                            Text(ws.name).tag(WorkspaceLaunchChoice.template(ws.id))
                        }
                    }
                }
            } label: {
                Label("Launch in", systemImage: "rectangle.split.3x1")
            }
            if workspaceChoice.wrappedValue != .current {
                LabeledContent {
                    TextField(workspaceNamePlaceholder, text: $profile.workspace)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                } label: {
                    Label("Workspace name", systemImage: "character.cursor.ibeam")
                }
                LabeledContent {
                    WorkspaceTabColorPicker(selection: $profile.workspaceTabColor)
                } label: {
                    Label("Tab color", systemImage: "paintpalette")
                }
            }
            Text(workspaceHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if savedWorkspaceTemplates.isEmpty {
                Text("Tip: arrange some tabs, then choose **Save Workspace…** from the workspace menu to reuse that layout here as a template.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Label("Workspace", systemImage: "square.grid.2x2")
        }
    }

    // MARK: - Duplication wizard

    /// The guided steps shown after a profile is duplicated. Kept intentionally
    /// small — this is guidance, not validation (the copy already exists in the
    /// store the moment it is created).
    private enum WizardStep: Hashable {
        case rename
        case connection
        case authentication
        case review
    }

    /// Show the "finish setting up this copy" wizard only when the editor was
    /// opened via Duplicate and the user hasn't dismissed it yet.
    private var showWizard: Bool {
        duplicatedFromName != nil && !wizardDismissed
    }

    /// A single row in the duplication wizard.
    private struct WizardItem: Identifiable {
        let step: WizardStep
        let title: String
        let detail: String
        let isDone: Bool
        /// `true` when completion is detected from the profile itself (no button
        /// to tap); `false` when the user ticks it off manually.
        let auto: Bool
        var id: WizardStep { step }
    }

    /// The steps to show, tailored to local vs SSH profiles and driven by live
    /// profile state wherever completion can be detected automatically.
    private var wizardItems: [WizardItem] {
        var items: [WizardItem] = []
        let trimmedName = profile.name.trimmingCharacters(in: .whitespaces)

        // 1. Rename — auto-completes once the name no longer matches the "… copy"
        //    default that `duplicate(_:)` generated.
        let autoCopyName = ((duplicatedFromName ?? "") + " copy")
            .trimmingCharacters(in: .whitespaces)
        let renamed = !trimmedName.isEmpty
            && trimmedName.caseInsensitiveCompare(autoCopyName) != .orderedSame
        items.append(WizardItem(
            step: .rename,
            title: "Give the copy its own name",
            detail: renamed
                ? "Named “\(trimmedName)”."
                : "Still called “\(trimmedName)”. Rename it up top so you can tell it apart.",
            isDone: renamed,
            auto: true))

        if !profile.isLocal {
            // 2. Connection — manual: host/port/user were copied from the original,
            //    so ask the user to confirm they point at the right server.
            items.append(WizardItem(
                step: .connection,
                title: "Point it at the right server",
                detail: "Check the host, port and username under Connection.",
                isDone: wizardAcks.contains(.connection),
                auto: false))

            // 3. Authentication — auto: the saved password is intentionally NOT
            //    copied, so this is done only once a key or password is in place.
            let hasAuth = hasSavedPassword
                || !newPassword.isEmpty
                || !profile.identityFile.trimmingCharacters(in: .whitespaces).isEmpty
            items.append(WizardItem(
                step: .authentication,
                title: "Set up sign-in",
                detail: hasAuth
                    ? "A key or password is set."
                    : "Passwords aren’t copied. Add an SSH key or password under Authentication.",
                isDone: hasAuth,
                auto: true))
        }

        // Final review — manual.
        items.append(WizardItem(
            step: .review,
            title: "Review the details",
            detail: profile.isLocal
                ? "Confirm the start path, terminal options and the “Launch in” workspace."
                : "Review your port forwards, links and the “Launch in” workspace.",
            isDone: wizardAcks.contains(.review),
            auto: false))

        return items
    }

    private var wizardDoneCount: Int { wizardItems.filter(\.isDone).count }

    /// The banner-style checklist shown at the very top of a duplicated profile.
    private var duplicationWizardSection: some View {
        Section {
            ForEach(wizardItems) { item in
                HStack(alignment: .top, spacing: 10) {
                    if item.auto {
                        wizardMark(done: item.isDone)
                            .frame(width: 22)
                    } else {
                        Button {
                            if item.isDone { wizardAcks.remove(item.step) }
                            else { wizardAcks.insert(item.step) }
                        } label: {
                            wizardMark(done: item.isDone)
                                .frame(width: 22)
                        }
                        .buttonStyle(.plain)
                        .help(item.isDone ? "Mark as not done" : "Mark as done")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(item.isDone ? .secondary : .primary)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack {
                Label("Finish setting up this copy", systemImage: "wand.and.stars")
                Spacer()
                Text("\(wizardDoneCount) of \(wizardItems.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                if let from = duplicatedFromName {
                    Text("Copied from “\(from)”. Steps you tick off are just reminders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(wizardDoneCount == wizardItems.count ? "Done" : "Dismiss") {
                    withAnimation { wizardDismissed = true }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func wizardMark(done: Bool) -> some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(done ? Color.green : Color.orange)
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
        if profile.useMosh {
            return MoshCommandBuilder.commandPreview(for: profile)
        }
        return SSHCommandBuilder.commandPreview(for: profile)
    }

    private var actionBar: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Add Profile" : "Save") { attemptSave() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Save, but first offer to bring the profile's workspace tabs along when its
    /// host differs from the addresses baked into its assigned template — the
    /// moment the final host is known (a profile made from a workspace, or a
    /// duplicated workspace profile, whose tabs still point at the source address).
    private func attemptSave() {
        let final = normalized()
        if !final.isLocal,
           let tid = final.workspaceTemplateID,
           !final.host.isEmpty,
           TerminalSessionManager.shared.templateHasTabsWithDifferentHost(tid, than: final.host) {
            pendingSaveProfile = final
            isConfirmingTabHostSync = true
            return
        }
        commitSave(final, syncTabHosts: false)
    }

    /// Persist the profile (optionally re-pointing its template's tabs at the
    /// profile host), then hand back to the caller.
    private func commitSave(_ final: SSHProfile, syncTabHosts: Bool) {
        pendingSaveProfile = nil
        if syncTabHosts, let tid = final.workspaceTemplateID {
            TerminalSessionManager.shared.normalizeTemplateTabHosts(tid, to: final.host)
        }
        applyPasswordChanges()
        onSave(final)
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
        p.group = p.group.trimmingCharacters(in: .whitespaces)
        p.runOnConnect = p.runOnConnect.trimmingCharacters(in: .whitespacesAndNewlines)
        p.remoteCommand = p.remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isLocal, p.port.trimmingCharacters(in: .whitespaces).isEmpty { p.port = "22" }
        // Drop environment rows with a blank name (nothing to send).
        p.environment.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
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
            HStack(spacing: 8) {
                Picker("Type", selection: $forward.type) {
                    ForEach(ForwardType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                TextField("Name (optional)", text: $forward.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .help("A label for this forward, shown in the “Open …” menus and on the tab it launches — handy for telling several web pages apart.")

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

/// A compact horizontal swatch picker for a workspace's launch tint. Renders one
/// filled circle per `TabColor` (in its actual color) plus a “Default” chip that
/// clears the tint; the active choice is ringed and checked.
private struct WorkspaceTabColorPicker: View {
    @Binding var selection: TabColor?

    var body: some View {
        HStack(spacing: 8) {
            Button { selection = nil } label: {
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.12))
                    Circle().strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5)
                    if selection == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Default")

            ForEach(TabColor.allCases) { c in
                Button { selection = c } label: {
                    ZStack {
                        Circle().fill(c.color)
                        Circle().strokeBorder(Color.primary.opacity(selection == c ? 0.55 : 0.15),
                                              lineWidth: selection == c ? 2 : 1)
                        if selection == c {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(c.label)
            }
        }
    }
}
