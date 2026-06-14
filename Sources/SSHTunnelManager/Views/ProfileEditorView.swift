import SwiftUI
import AppKit

struct ProfileEditorView: View {
    @State private var profile: SSHProfile
    var onSave: (SSHProfile) -> Void
    var onCancel: () -> Void

    @State private var newPassword: String = ""
    @State private var hasSavedPassword: Bool
    @State private var removePassword: Bool = false

    init(profile: SSHProfile,
         onSave: @escaping (SSHProfile) -> Void,
         onCancel: @escaping () -> Void) {
        _profile = State(initialValue: profile)
        _hasSavedPassword = State(initialValue: KeychainStore.shared.hasPassword(for: profile.id))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        !profile.host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !profile.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Name", text: $profile.name)
                    TextField("Host", text: $profile.host)
                        .autocorrectionDisabled()
                    HStack {
                        TextField("Username", text: $profile.username)
                            .autocorrectionDisabled()
                        TextField("Port", text: $profile.port)
                            .frame(width: 70)
                    }
                    HStack {
                        TextField("Identity file (optional)", text: $profile.identityFile)
                            .autocorrectionDisabled()
                        Button("Choose…", action: chooseIdentityFile)
                    }
                    TextField("Jump host / bastion (optional)", text: $profile.jumpHost)
                        .autocorrectionDisabled()
                }

                Section {
                    if hasSavedPassword && !removePassword {
                        HStack {
                            Label("Password saved in Keychain", systemImage: "key.fill")
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
                    Toggle("Require Touch ID / login password before use",
                           isOn: $profile.requireAuthForSavedPassword)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Stored securely in your macOS Keychain and typed automatically when the server asks for a password. Prefer SSH keys when you can; this is for servers that require password login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    if profile.forwards.isEmpty {
                        Text("No tunnels yet. Add a port forward below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach($profile.forwards) { $forward in
                        ForwardEditor(forward: $forward) {
                            profile.forwards.removeAll { $0.id == forward.id }
                        }
                        Divider()
                    }
                    Button {
                        profile.forwards.append(PortForward())
                    } label: {
                        Label("Add Port Forward", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Port Forwards / Tunnels")
                }

                Section("Appearance") {
                    Picker("Theme", selection: $profile.theme) {
                        ForEach(TerminalTheme.all) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    ThemePreview(theme: TerminalTheme.theme(id: profile.theme))
                }

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
                        Label("Add Command", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Saved Commands")
                }

                Section("Options") {
                    Toggle("Open interactive shell (off = tunnels only, -N)", isOn: $profile.openShell)
                    Toggle("Keep alive (ServerAliveInterval)", isOn: $profile.keepAlive)
                    Toggle("Compression (-C)", isOn: $profile.compression)
                    Toggle("Verbose logging (-v)", isOn: $profile.verbose)
                    TextField("Extra ssh options (optional)", text: $profile.extraOptions)
                        .autocorrectionDisabled()
                }
            }
            .formStyle(.grouped)

            Divider()

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
                    Text(SSHCommandBuilder.commandPreview(for: profile))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    applyPasswordChanges()
                    onSave(normalized())
                }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(16)
        }
    }

    private func normalized() -> SSHProfile {
        var p = profile
        p.name = p.name.trimmingCharacters(in: .whitespaces)
        p.host = p.host.trimmingCharacters(in: .whitespaces)
        p.username = p.username.trimmingCharacters(in: .whitespaces)
        if p.port.trimmingCharacters(in: .whitespaces).isEmpty { p.port = "22" }
        return p
    }

    private func applyPasswordChanges() {
        if removePassword {
            KeychainStore.shared.deletePassword(for: profile.id)
        }
        if !newPassword.isEmpty {
            KeychainStore.shared.setPassword(newPassword, for: profile.id)
        }
    }

    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(SSHCommandBuilder.commandPreview(for: profile), forType: .string)
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
