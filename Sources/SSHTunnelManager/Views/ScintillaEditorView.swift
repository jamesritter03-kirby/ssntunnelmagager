import SwiftUI
import AppKit
import ScintillaEngine

/// SwiftUI host for the embedded Scintilla + Lexilla editing engine (beta).
///
/// This coexists with `CodeEditorView` and is selected per‑tab via
/// `TextEditorModel.useScintillaEngine`. It is the first step of migrating the
/// text editor onto Scintilla: it brings real code folding (collapse / expand
/// of structured regions) for JSON, XML, and every other Lexilla language,
/// driven from the same `TextEditorModel` state as the classic editor.
struct ScintillaEditorView: NSViewRepresentable {
    @ObservedObject var model: TextEditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> SciEditorView {
        let view = SciEditorView(frame: .zero)
        let coord = context.coordinator
        coord.view = view

        view.onTextChanged = { [weak coord] in
            guard let coord, let view = coord.view else { return }
            let text = view.text
            coord.model.captureLiveText(text)
            coord.model.markDirty()
            coord.updateCounts(text)
        }

        view.onSelectionChanged = { [weak coord] line, column, selLength in
            guard let coord else { return }
            DispatchQueue.main.async {
                coord.model.caretLine = line
                coord.model.caretColumn = column
                coord.model.selectionLength = selLength
            }
        }

        // Route the tab's Find / Replace bar to Scintilla's own search engine
        // while this view is the one on screen.
        model.scintillaFindProvider = coord
        model.scintillaCompareControl = coord

        // Language first (setting a lexer resets styles), then appearance,
        // then the document contents.
        coord.applyLanguage(force: true)
        coord.applyAppearance(force: true)
        view.text = model.pendingContent
        coord.lastReloadToken = model.reloadToken
        coord.updateCounts(model.pendingContent)
        coord.applyCompare()
        return view
    }

    func updateNSView(_ view: SciEditorView, context: Context) {
        let coord = context.coordinator
        coord.view = view

        if coord.lastReloadToken != model.reloadToken {
            coord.lastReloadToken = model.reloadToken
            view.text = model.pendingContent
            coord.updateCounts(model.pendingContent)
        }
        coord.applyLanguage(force: false)
        coord.applyAppearance(force: false)
        coord.applyCompare()
    }

    static func dismantleNSView(_ nsView: SciEditorView, coordinator: Coordinator) {
        if coordinator.model.scintillaFindProvider === coordinator {
            coordinator.model.scintillaFindProvider = nil
        }
        if coordinator.model.scintillaCompareControl === coordinator {
            coordinator.model.scintillaCompareControl = nil
        }
        nsView.endCompare()
        nsView.onTextChanged = nil
        nsView.onSelectionChanged = nil
    }

    // MARK: - Coordinator

    final class Coordinator {
        let model: TextEditorModel
        weak var view: SciEditorView?

        var lastReloadToken: UUID?
        private var lastLanguage: CodeLanguage?
        private var lastThemeID: String?
        private var lastFontSize: Double?
        private var lastWrap: Bool?
        private var lastLineNumbers: Bool?
        private var lastDocumentMap: Bool?
        private var lastCompareToken: UUID?

        init(model: TextEditorModel) { self.model = model }

        /// Push line/character counts back to the model for the status bar.
        /// Deferred to the next runloop tick so we never mutate published state
        /// in the middle of a SwiftUI view update.
        func updateCounts(_ text: String) {
            let chars = (text as NSString).length
            let lines = max(1, text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                            - (text.hasSuffix("\n") ? 1 : 0))
            DispatchQueue.main.async { [model] in
                model.characterCount = chars
                model.lineCount = lines
            }
        }

        func applyLanguage(force: Bool) {
            guard let view else { return }
            if force || lastLanguage != model.language {
                view.setLexerLanguage(ScintillaEditorView.lexerName(for: model.language))
                lastLanguage = model.language
                // Assigning a lexer clears styles, so re‑apply appearance.
                applyAppearance(force: true)
            }
        }

        func applyAppearance(force: Bool) {
            guard let view else { return }
            let theme = EditorTheme.theme(id: model.themeID)

            if force || lastThemeID != model.themeID || lastFontSize != model.fontSize {
                let fontName = NSFont.userFixedPitchFont(ofSize: CGFloat(model.fontSize))?.fontName ?? "Menlo"
                view.setFontName(fontName, size: CGFloat(model.fontSize))
                view.setEditorForeground(theme.foreground, background: theme.background)
                view.setSelectionBackground(theme.selection)
                view.setGutterForeground(theme.gutterForeground, background: theme.gutterBackground)
                view.setFoldColorsWithBackground(theme.background, marker: theme.gutterForeground)
                view.setDocumentMapViewportColor(theme.selection)
                Coordinator.pushTokenColors(theme: theme, to: view)
                lastThemeID = model.themeID
                lastFontSize = model.fontSize
            }
            if force || lastWrap != model.wordWrap {
                view.setWordWrap(model.wordWrap)
                lastWrap = model.wordWrap
            }
            if force || lastLineNumbers != model.showLineNumbers {
                view.setShowLineNumbers(model.showLineNumbers)
                lastLineNumbers = model.showLineNumbers
            }
            if force || lastDocumentMap != model.showDocumentMap {
                view.setDocumentMapVisible(model.showDocumentMap)
                lastDocumentMap = model.showDocumentMap
            }
        }

        /// Enters, refreshes, or leaves Scintilla compare mode in response to
        /// `model.compareRequest`. Computes the line diff against the current
        /// editor text and hands the aligned sides to the bridge.
        func applyCompare() {
            guard let view else { return }
            let token = model.compareRequest?.token
            guard token != lastCompareToken else { return }
            lastCompareToken = token

            guard let req = model.compareRequest else {
                view.endCompare()
                return
            }

            let theme = EditorTheme.theme(id: model.themeID)
            view.setCompareColorsAdded(Coordinator.diffColor(.added, theme),
                                       deleted: Coordinator.diffColor(.deleted, theme),
                                       changed: Coordinator.diffColor(.changed, theme),
                                       filler: Coordinator.diffColor(.filler, theme))

            let diff = TextDiff.compare(view.text, req.otherText)
            let lexer = ScintillaEditorView.lexerName(for: model.language)
            func nums(_ a: [Int]) -> [NSNumber] { a.map { NSNumber(value: $0) } }
            view.showCompareLeftText(diff.left.text,
                                     rightText: diff.right.text,
                                     leftStatus: nums(diff.left.status),
                                     rightStatus: nums(diff.right.status),
                                     leftNumbers: nums(diff.left.numbers),
                                     rightNumbers: nums(diff.right.numbers),
                                     leftSpanStart: nums(diff.left.spanStart),
                                     leftSpanLength: nums(diff.left.spanLength),
                                     rightSpanStart: nums(diff.right.spanStart),
                                     rightSpanLength: nums(diff.right.spanLength),
                                     lexer: lexer)
        }

        /// The translucent line tints used by compare mode. Fixed, readable
        /// diff colors; the bridge applies alpha so syntax colors show through.
        static func diffColor(_ status: DiffRowStatus, _ theme: EditorTheme) -> NSColor {
            switch status {
            case .added:   return NSColor.systemGreen
            case .deleted: return NSColor.systemRed
            case .changed: return NSColor.systemYellow
            case .filler:  return NSColor.gray
            case .equal:   return theme.background
            }
        }

        /// Maps the theme's `SyntaxToken` colors onto the engine's token kinds,
        /// then asks it to apply them to the active lexer's styles.
        static func pushTokenColors(theme: EditorTheme, to view: SciEditorView) {
            let map: [(SyntaxToken, Int)] = [
                (.keyword, 0), (.type, 1), (.string, 2), (.comment, 3),
                (.number, 4), (.constant, 5), (.attribute, 6), (.tag, 7)
            ]
            for (token, raw) in map {
                if let kind = SciTokenKind(rawValue: raw) {
                    view.setTokenColor(kind, color: theme.color(for: token))
                }
            }
            view.applyTokenColors()
        }
    }

    // MARK: - Language mapping

    /// Maps the app's `CodeLanguage` to a Lexilla lexer name. Languages without
    /// a dedicated Lexilla lexer fall back to the C‑family lexer ("cpp"), which
    /// still provides brace‑based folding. `nil` selects the null lexer.
    static func lexerName(for language: CodeLanguage) -> String? {
        switch language {
        case .plainText:  return nil
        case .json:       return "json"
        case .xml:        return "xml"
        case .html:       return "hypertext"
        case .css:        return "css"
        case .python:     return "python"
        case .yaml:       return "yaml"
        case .toml:       return "toml"
        case .ini:        return "props"
        case .markdown:   return "markdown"
        case .shell:      return "bash"
        case .sql:        return "sql"
        case .ruby:       return "ruby"
        case .rust:       return "rust"
        case .php:        return "phpscript"
        case .swift, .javascript, .typescript, .c, .cpp, .java, .csharp, .go:
            return "cpp"
        }
    }
}

// MARK: - Find / Replace bridging

/// Routes the tab's Find / Replace bar to Scintilla's native, byte-accurate
/// search so it behaves identically to the classic editor's provider.
extension ScintillaEditorView.Coordinator: EditorFindProvider {
    func find(_ query: String, caseSensitive: Bool, regex: Bool, wholeWord: Bool,
              forward: Bool) -> (found: Bool, index: Int, total: Int) {
        guard let view else { return (false, 0, 0) }
        let index = view.findText(query, caseSensitive: caseSensitive, regex: regex,
                                  wholeWord: wholeWord, forward: forward)
        if index == 0 { return (false, 0, 0) }
        let total = view.matchCount(for: query, caseSensitive: caseSensitive,
                                    regex: regex, wholeWord: wholeWord)
        return (true, index, max(total, index))
    }

    func count(_ query: String, caseSensitive: Bool, regex: Bool, wholeWord: Bool) -> Int {
        view?.matchCount(for: query, caseSensitive: caseSensitive,
                         regex: regex, wholeWord: wholeWord) ?? 0
    }

    func replaceCurrent(_ query: String, with replacement: String, caseSensitive: Bool,
                        regex: Bool, wholeWord: Bool) -> Bool {
        view?.replaceCurrent(query, with: replacement, caseSensitive: caseSensitive,
                             regex: regex, wholeWord: wholeWord) ?? false
    }

    func replaceAll(_ query: String, with replacement: String, caseSensitive: Bool,
                    regex: Bool, wholeWord: Bool) -> Int {
        view?.replaceAll(of: query, with: replacement, caseSensitive: caseSensitive,
                         regex: regex, wholeWord: wholeWord) ?? 0
    }
}
// MARK: - Compare bridging

/// Lets the tab toolbar step through change blocks while compare mode is up.
extension ScintillaEditorView.Coordinator: EditorCompareControl {
    func compareGoToChange(_ direction: Int) {
        view?.compareStep(direction)
    }
}