import SwiftUI
import AppKit

/// A Notepad++‑style text‑editor tab: an action toolbar, an optional find /
/// replace bar, the code editor itself, and a status bar. All editing state
/// lives in the session's `TextEditorModel`.
struct TextEditorTabView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: TextEditorModel
    @EnvironmentObject var sessions: TerminalSessionManager

    init(session: TerminalSession) {
        self.session = session
        self.model = session.textEditorModel ?? TextEditorModel()
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.findVisible {
                findBar
                Divider()
            }
            if model.externalChange != nil {
                externalChangeBanner
                Divider()
            }
            // Pin the AppKit editor to a concrete size from the surrounding
            // geometry and clip it. An `NSScrollView` over a large `NSTextView`
            // reports a huge ideal size; without this the tabbed layout (which
            // sizes its `VStack`/`ZStack` from child ideals) balloons past the
            // window, covering the tab bar and scrolling typed text out of view.
            GeometryReader { geo in
                Group {
                    if model.useScintillaEngine {
                        ScintillaEditorView(model: model)
                    } else {
                        CodeEditorView(model: model)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            Divider()
            statusBar
        }
        .background(Color(nsColor: EditorTheme.theme(id: model.themeID).background))
        // Surface the "file changed on disk" popup for the visible tab: when it's
        // first shown, when a change is detected while it's open, and when the app
        // is brought back to the front.
        .onAppear { presentExternalPromptSoon() }
        .onChange(of: model.externalChange) { _ in presentExternalPromptSoon() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            presentExternalPromptSoon()
        }
    }

    /// Present the model's change popup on the next runloop tick, so we never run
    /// a modal in the middle of a SwiftUI view update.
    private func presentExternalPromptSoon() {
        DispatchQueue.main.async { model.presentExternalChangePromptIfNeeded() }
    }

    // MARK: - External-change banner

    private var externalChangeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: model.externalChange == .deleted
                  ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                .foregroundStyle(model.externalChange == .deleted ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.externalChange == .deleted
                     ? "This file was moved or deleted."
                     : "This file changed on disk.")
                    .font(.callout.weight(.medium))
                Text(model.externalChange == .deleted
                     ? "Your text is kept here — save it again to write a new copy."
                     : (model.isDirty
                        ? "Reloading discards the unsaved changes you have here."
                        : "Another program modified it."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.externalChange == .modified {
                Button("Reload") { model.reloadFromDiskExternal() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Keep Mine") { model.dismissExternalChange() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("Keep in Editor") { model.dismissExternalChange() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolButton("doc.badge.plus", "New", help: "New empty document") {
                if model.confirmCloseIfNeeded() { model.newDocument() }
            }
            toolButton("folder", "Open", help: "Open a file…") {
                model.openWithPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            toolButton("square.and.arrow.down", "Save", help: "Save") {
                model.save()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.fileURL != nil && !model.isDirty)
            toolButton("square.and.arrow.down.on.square", "Save As", help: "Save As…") {
                model.saveAs()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider().frame(height: 18)

            toolButton("magnifyingglass", "Find", help: "Find & Replace") {
                model.openFindBar(replace: false)
            }
            .keyboardShortcut("f", modifiers: .command)

            Divider().frame(height: 18)

            toggleButton("text.alignleft", "Wrap", isOn: model.wordWrap,
                         help: "Wrap long lines") {
                model.wordWrap.toggle()
            }
            toggleButton("list.number", "Line Numbers", isOn: model.showLineNumbers,
                         help: "Show line numbers") {
                model.showLineNumbers.toggle()
            }

            Divider().frame(height: 18)

            toggleButton("chevron.left.forwardslash.chevron.right", "Folding Engine",
                         isOn: model.useScintillaEngine,
                         help: "Scintilla engine (beta): code folding for JSON, XML, and more") {
                model.useScintillaEngine.toggle()
            }

            if model.useScintillaEngine {
                toggleButton("map", "Document Map",
                             isOn: model.showDocumentMap,
                             help: "Show a document map (minimap) of the whole file") {
                    model.showDocumentMap.toggle()
                }

                viewOptionsMenu
                if !model.compareActive { actionsMenu }

                if model.compareActive {
                    toolButton("chevron.up", "Previous Change", help: "Previous change") {
                        model.compareGoToChange(-1)
                    }
                    toolButton("chevron.down", "Next Change", help: "Next change") {
                        model.compareGoToChange(1)
                    }
                    Button(action: { model.endCompare() }) {
                        Image(systemName: "xmark.circle.fill")
                            .frame(width: 22, height: 20)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .help("Exit compare (\(model.compareOtherName))")
                    .accessibilityLabel("Exit Compare")
                } else {
                    Menu {
                        if otherEditorSessions.isEmpty {
                            Text("No other open files")
                        } else {
                            ForEach(otherEditorSessions, id: \.id) { other in
                                Button(other.textEditorModel?.displayName ?? "Untitled") {
                                    startCompare(with: other)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Compare with another open file")
                    .accessibilityLabel("Compare")
                }
            }

            Divider().frame(height: 18)

            toolButton("minus.magnifyingglass", "Smaller", help: "Decrease font size") {
                model.decreaseFont()
            }
            toolButton("plus.magnifyingglass", "Larger", help: "Increase font size") {
                model.increaseFont()
            }

            Spacer()

            // Replace shortcut lives here so it works whenever the tab is focused.
            Button("") { model.openFindBar(replace: true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .opacity(0).frame(width: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    /// Scintilla-only editor view toggles (highlights, guides, whitespace,
    /// ruler, change-history bar). Persisted app-wide via the model.
    private var viewOptionsMenu: some View {
        Menu {
            Toggle("Current Line Highlight", isOn: $model.showCurrentLine)
            Toggle("Indentation Guides", isOn: $model.showIndentGuides)
            Toggle("Show Whitespace", isOn: $model.showWhitespace)
            Toggle("Column Ruler (80)", isOn: $model.showRuler)
            Toggle("Change History Bar", isOn: $model.showChangeHistory)
        } label: {
            Image(systemName: "eye")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Editor view options")
        .accessibilityLabel("View Options")
    }

    /// Scintilla-only smart-editing commands (line ops, comment toggle,
    /// multi-cursor, word completion, bookmarks) with keyboard shortcuts.
    private var actionsMenu: some View {
        Menu {
            Button("Move Line Up") { model.moveLinesUp() }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Move Line Down") { model.moveLinesDown() }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Button("Duplicate Line") { model.duplicateSelection() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Delete Line") { model.deleteCurrentLine() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Toggle Comment") { model.toggleComment() }
                .keyboardShortcut("/", modifiers: .command)
            Button("Select Next Occurrence") { model.selectNextOccurrence() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Complete Word") { model.completeWord() }
                .keyboardShortcut(.escape, modifiers: .option)
            Divider()
            Button("Toggle Bookmark") { model.toggleBookmark() }
            Button("Next Bookmark") { model.nextBookmark() }
            Button("Previous Bookmark") { model.previousBookmark() }
        } label: {
            Image(systemName: "wand.and.stars")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Editing actions")
        .accessibilityLabel("Actions")
    }

    private func toolButton(_ symbol: String, _ title: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(title)
    }

    private func toggleButton(_ symbol: String, _ title: String, isOn: Bool, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 20)
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(title)
    }

    /// Other open text-editor tabs, eligible as the right-hand side of a compare.
    private var otherEditorSessions: [TerminalSession] {
        sessions.sessions.filter {
            $0.kind == .editor && $0.id != session.id && $0.textEditorModel != nil
        }
    }

    /// Begin comparing this document against another open file's current text.
    private func startCompare(with other: TerminalSession) {
        guard let target = other.textEditorModel else { return }
        model.beginCompare(withText: target.pendingContent, name: target.displayName)
    }

    // MARK: - Find / replace bar

    private var findBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find", text: $model.findText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 160)
                    .onChange(of: model.findText) { _ in model.refreshFindCount() }
                    .onSubmit { model.findNext() }

                Button { model.findPrevious() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .help("Previous match")
                Button { model.findNext() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .help("Next match")

                optionToggle("Aa", isOn: $model.findCaseSensitive, help: "Match case")
                optionToggle(".*", isOn: $model.findUsesRegex, help: "Regular expression")
                optionToggle("W", isOn: $model.findWholeWord, help: "Whole word")

                Text(model.findStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60, alignment: .leading)

                Spacer()

                Button {
                    model.replaceVisible.toggle()
                } label: {
                    Image(systemName: model.replaceVisible ? "chevron.down.square" : "chevron.right.square")
                }
                .buttonStyle(.borderless)
                .help("Toggle Replace")

                Button { model.closeFindBar() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close")
                    .keyboardShortcut(.escape, modifiers: [])
            }

            if model.replaceVisible {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.2.squarepath")
                        .foregroundStyle(.secondary)
                    TextField("Replace", text: $model.replaceText)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160)
                        .onSubmit { model.replaceCurrent() }
                    Button("Replace") { model.replaceCurrent() }
                        .help("Replace this match")
                    Button("Replace All") { model.replaceAll() }
                        .help("Replace every match")
                    Spacer()
                }
            }
        }
        .onChange(of: model.findCaseSensitive) { _ in model.refreshFindCount() }
        .onChange(of: model.findUsesRegex) { _ in model.refreshFindCount() }
        .onChange(of: model.findWholeWord) { _ in model.refreshFindCount() }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func optionToggle(_ label: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 18)
                .background(isOn.wrappedValue ? Color.accentColor.opacity(0.25) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(isOn.wrappedValue ? Color.accentColor : Color.secondary.opacity(0.4)))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("Ln \(model.caretLine), Col \(model.caretColumn)")
            if model.selectionLength > 0 {
                Text("Sel \(model.selectionLength)")
            }
            Text("\(model.lineCount) line\(model.lineCount == 1 ? "" : "s")")
            Text("\(model.characterCount) char\(model.characterCount == 1 ? "" : "s")")

            Spacer()

            if model.isDirty {
                HStack(spacing: 3) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    Text("Unsaved")
                }
            }

            remoteSyncIndicator

            lineEndingMenu
            Text(model.encoding.displayName)
            themeMenu
            languageMenu
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// Shows the SFTP save‑back state when this tab is editing a remote file:
    /// a cloud badge that reads Synced / Uploading… / the failure reason. The
    /// tooltip names the server and the remote path the file writes back to.
    @ViewBuilder
    private var remoteSyncIndicator: some View {
        if let link = model.remoteEdit {
            HStack(spacing: 3) {
                Image(systemName: remoteSyncSymbol)
                    .foregroundStyle(remoteSyncColor)
                Text(remoteSyncText)
            }
            .help("Editing a file on \(link.serverLabel). Saving uploads it back to \(link.remotePath).")
        }
    }

    private var remoteSyncSymbol: String {
        switch model.remoteSyncState {
        case .idle, .synced: return "checkmark.icloud"
        case .syncing:       return "arrow.clockwise.icloud"
        case .failed:        return "exclamationmark.icloud"
        }
    }

    private var remoteSyncColor: Color {
        switch model.remoteSyncState {
        case .idle, .synced: return .green
        case .syncing:       return .accentColor
        case .failed:        return .orange
        }
    }

    private var remoteSyncText: String {
        switch model.remoteSyncState {
        case .idle, .synced:  return "Synced to server"
        case .syncing:        return "Uploading…"
        case .failed(let m):  return m.isEmpty ? "Upload failed" : m
        }
    }

    private var themeMenu: some View {
        Menu {
            ForEach(EditorTheme.all) { theme in
                Button {
                    model.themeID = theme.id
                } label: {
                    if theme.id == model.themeID {
                        Label(theme.name, systemImage: "checkmark")
                    } else {
                        Text(theme.name)
                    }
                }
            }
        } label: {
            Label(EditorTheme.theme(id: model.themeID).name, systemImage: "paintpalette")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Editor colour theme")
    }

    private var languageMenu: some View {
        Menu {
            ForEach(CodeLanguage.allCases) { lang in
                Button {
                    model.language = lang
                } label: {
                    if lang == model.language {
                        Label(lang.displayName, systemImage: "checkmark")
                    } else {
                        Text(lang.displayName)
                    }
                }
            }
        } label: {
            Text(model.language.displayName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Syntax highlighting language")
    }

    private var lineEndingMenu: some View {
        Menu {
            ForEach(LineEnding.allCases) { ending in
                Button {
                    if model.lineEnding != ending {
                        model.lineEnding = ending
                        model.markDirty()
                    }
                } label: {
                    if ending == model.lineEnding {
                        Label(ending.displayName, systemImage: "checkmark")
                    } else {
                        Text(ending.displayName)
                    }
                }
            }
        } label: {
            Text(model.lineEnding.displayName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Line endings")
    }
}
