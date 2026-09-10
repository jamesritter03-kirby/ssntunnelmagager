import SwiftUI
import AppKit

// MARK: - Log-tools model types

/// Which klogg-style tool the side panel is showing.
enum LogToolsTab: String, CaseIterable, Identifiable {
    case filter, search, marks, highlighters
    var id: String { rawValue }
    var title: String {
        switch self {
        case .filter:       return "Filter"
        case .search:       return "Results"
        case .marks:        return "Marks"
        case .highlighters: return "Highlight"
        }
    }
    var systemImage: String {
        switch self {
        case .filter:       return "line.3.horizontal.decrease.circle"
        case .search:       return "list.bullet.rectangle"
        case .marks:        return "bookmark"
        case .highlighters: return "highlighter"
        }
    }
}

/// One line shown in a filter / search / marks result list, carrying its 1-based
/// source line number so a click can jump to it in the editor.
struct LogResultLine: Identifiable, Equatable {
    let lineNumber: Int
    let text: String
    var id: Int { lineNumber }
}

/// A user-defined highlighter (klogg): every match of `pattern` gets `colorHex`
/// as its background (or the whole matching line, when `wholeLine`).
struct LogHighlighter: Identifiable, Codable, Equatable {
    var id = UUID()
    var pattern: String
    var colorHex: String
    var caseSensitive: Bool = false
    var wholeLine: Bool = false
    var enabled: Bool = true

    /// A palette of pleasant, readable highlight backgrounds to cycle through.
    static let palette: [String] = [
        "#FFF3A3", "#B7E4C7", "#A9D6FF", "#FFC9C9", "#E4C1F9",
        "#FFD8A8", "#C3FAE8", "#D0BFFF", "#FFEC99", "#B2F2BB",
    ]
}

// MARK: - Colour helpers

extension NSColor {
    /// Parse "#RRGGBB" / "#RRGGBBAA" (case-insensitive). Falls back to yellow.
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Highlighter application

/// Applies the user's highlighters onto an `NSTextStorage`, layered on top of any
/// syntax colours. The classic editor's `highlight(_:range:)` calls this after it
/// paints tokens; it uses `.backgroundColor` so it never fights foreground syntax
/// colours.
enum LogHighlightApplier {
    static func apply(_ highlighters: [LogHighlighter], to storage: NSTextStorage, range: NSRange) {
        guard range.length > 0 else { return }
        // Clear any prior highlight background in this range first.
        storage.removeAttribute(.backgroundColor, range: range)
        let text = storage.string
        for h in highlighters where h.enabled && !h.pattern.isEmpty {
            var opts: NSRegularExpression.Options = []
            if !h.caseSensitive { opts.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: h.pattern, options: opts) else { continue }
            let color = NSColor(hex: h.colorHex)
            let ns = text as NSString
            re.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, match.range.length > 0 else { return }
                let target = h.wholeLine
                    ? ns.lineRange(for: match.range)
                    : match.range
                let safe = NSIntersectionRange(target, NSRange(location: 0, length: ns.length))
                if safe.length > 0 {
                    storage.addAttribute(.backgroundColor, value: color, range: safe)
                }
            }
        }
    }
}

// MARK: - TextEditorModel log-tools logic

extension TextEditorModel {
    /// The authoritative buffer text for computing result lists — the live text
    /// view when mounted, else the last mirrored snapshot.
    var logBufferText: String {
        engine.textView != nil ? engine.string : pendingContent
    }

    /// Split the buffer into 1-based numbered lines once, for the result lists.
    private func numberedLines() -> [(Int, String)] {
        logBufferText.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, $0.element) }
    }

    // MARK: Persisted highlighters

    private static let highlightersKey = "editor.logHighlighters"

    static func loadHighlighters() -> [LogHighlighter] {
        guard let data = UserDefaults.standard.data(forKey: highlightersKey),
              let list = try? JSONDecoder().decode([LogHighlighter].self, from: data) else { return [] }
        return list
    }

    static func saveHighlighters(_ list: [LogHighlighter]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: highlightersKey)
        }
    }

    // MARK: Panel toggling

    func toggleLogTools() { logToolsVisible.toggle(); if logToolsVisible { refreshLogTools() } }

    /// Recompute whichever result list the active tab shows.
    func refreshLogTools() {
        switch logToolsTab {
        case .filter: runFilter()
        case .search: refreshSearchResults()
        default: objectWillChange.send()
        }
    }

    /// Called after the buffer is replaced (open / reload / follow-mode append).
    func refreshLogToolsAfterBufferChange() {
        guard logToolsVisible else { return }
        if logToolsTab == .filter { runFilter() }
        if logToolsTab == .search { refreshSearchResults() }
    }

    // MARK: Filter (grep) pane

    func scheduleFilterRefresh() {
        filterWorkItemCancel()
        let item = DispatchWorkItem { [weak self] in self?.runFilter() }
        setFilterWorkItem(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    func runFilter() {
        let query = filterText
        guard !query.isEmpty else { setFilterResults([]); return }
        let matcher = LineMatcher(query: query, regex: filterUsesRegex,
                                  caseSensitive: filterCaseSensitive)
        var out: [LogResultLine] = []
        for (n, line) in numberedLines() {
            let hit = matcher.matches(line)
            if hit != filterInverted { out.append(LogResultLine(lineNumber: n, text: line)) }
        }
        setFilterResults(out)
    }

    // MARK: Search-results pane

    /// List every line that contains a match of the current Find query.
    func refreshSearchResults() {
        let query = findText
        guard !query.isEmpty else { setSearchResults([]); return }
        let matcher = LineMatcher(query: query, regex: findUsesRegex,
                                  caseSensitive: findCaseSensitive)
        var out: [LogResultLine] = []
        for (n, line) in numberedLines() where matcher.matches(line) {
            out.append(LogResultLine(lineNumber: n, text: line))
        }
        setSearchResults(out)
    }

    // MARK: Marks

    /// A sorted list of marked lines with their text, for the Marks pane.
    var marksList: [LogResultLine] {
        let lines = numberedLines()
        return marks.sorted().compactMap { n in
            guard n >= 1, n <= lines.count else { return nil }
            return LogResultLine(lineNumber: n, text: lines[n - 1].1)
        }
    }

    /// Toggle a mark on the line the caret is on.
    func toggleMarkAtCaret() {
        let line = caretLine
        if marks.contains(line) { marks.remove(line) } else { marks.insert(line) }
    }

    func nextMark() {
        guard let next = marks.sorted().first(where: { $0 > caretLine }) ?? marks.min() else { return }
        jumpToLine(next)
    }

    func previousMark() {
        guard let prev = marks.sorted().last(where: { $0 < caretLine }) ?? marks.max() else { return }
        jumpToLine(prev)
    }

    func clearMarks() { marks.removeAll() }

    // MARK: Highlighter CRUD

    func addHighlighterFromFind() {
        let seed = findText.isEmpty ? filterText : findText
        let color = LogHighlighter.palette[highlighters.count % LogHighlighter.palette.count]
        highlighters.append(LogHighlighter(pattern: seed, colorHex: color,
                                           caseSensitive: findCaseSensitive))
    }

    func removeHighlighter(_ h: LogHighlighter) {
        highlighters.removeAll { $0.id == h.id }
    }

    // MARK: Jump

    /// Select a 1-based line in the editor and bring it into view.
    func jumpToLine(_ line: Int) {
        engine.goToLine(line)
    }

    func requestScrollToEnd() { setScrollToEndToken(UUID()) }
}

/// Compiles a filter/search query once and tests lines against it.
private struct LineMatcher {
    let regex: NSRegularExpression?
    let literal: String
    let caseSensitive: Bool

    init(query: String, regex useRegex: Bool, caseSensitive: Bool) {
        self.caseSensitive = caseSensitive
        if useRegex {
            var opts: NSRegularExpression.Options = []
            if !caseSensitive { opts.insert(.caseInsensitive) }
            self.regex = try? NSRegularExpression(pattern: query, options: opts)
            self.literal = ""
        } else {
            self.regex = nil
            self.literal = query
        }
    }

    func matches(_ line: String) -> Bool {
        if let re = regex {
            let ns = line as NSString
            return re.firstMatch(in: line, options: [],
                                 range: NSRange(location: 0, length: ns.length)) != nil
        }
        guard !literal.isEmpty else { return false }
        return line.range(of: literal,
                          options: caseSensitive ? [] : [.caseInsensitive]) != nil
    }
}

// MARK: - Cross-file private setters
//
// `filterResults`, `searchResults`, `scrollToEndToken` and the filter debounce
// work item are `private(set)` / `private` on the model so only the model mutates
// them. These thin helpers let this same-type extension (in a separate file)
// assign them without widening their access for everyone else.
extension TextEditorModel {
    func setFilterResults(_ r: [LogResultLine]) { _setFilterResults(r) }
    func setSearchResults(_ r: [LogResultLine]) { _setSearchResults(r) }
    func setScrollToEndToken(_ t: UUID) { _setScrollToEndToken(t) }
    func setFilterWorkItem(_ w: DispatchWorkItem) { _setFilterWorkItem(w) }
    func filterWorkItemCancel() { _filterWorkItemCancel() }
}

// MARK: - Panel view

/// The klogg-style side panel: a segmented header to pick a tool, then the
/// matching result list or editor. Lives to the right of the editor in
/// `TextEditorTabView` when `model.logToolsVisible` is on.
struct LogToolsPanel: View {
    @ObservedObject var model: TextEditorModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 240)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 2) {
            ForEach(LogToolsTab.allCases) { tab in
                Button {
                    model.logToolsTab = tab
                    model.refreshLogTools()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.systemImage)
                        Text(tab.title).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(model.logToolsTab == tab
                                ? Color.accentColor.opacity(0.18) : Color.clear)
                    .foregroundStyle(model.logToolsTab == tab ? Color.accentColor : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            Button { model.logToolsVisible = false } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close log tools")
            .padding(.leading, 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch model.logToolsTab {
        case .filter:       filterPane
        case .search:       searchPane
        case .marks:        marksPane
        case .highlighters: highlightersPane
        }
    }

    // MARK: Filter pane

    private var filterPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter lines (regex)", text: $model.filterText)
                        .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    Toggle(".*", isOn: $model.filterUsesRegex).toggleStyle(.button)
                        .help("Treat the filter as a regular expression")
                    Toggle("Aa", isOn: $model.filterCaseSensitive).toggleStyle(.button)
                        .help("Match case")
                    Toggle("≠", isOn: $model.filterInverted).toggleStyle(.button)
                        .help("Invert: show lines that do NOT match")
                    Spacer()
                    Text("\(model.filterResults.count)")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Matching lines")
                }
            }
            .padding(8)
            Divider()
            resultList(model.filterResults,
                       empty: model.filterText.isEmpty ? "Type a filter to grep the log."
                                                       : "No lines match.")
        }
    }

    // MARK: Search-results pane

    private var searchPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass").foregroundStyle(.secondary)
                Text(model.findText.isEmpty ? "Use Find to search"
                                            : "“\(model.findText)”")
                    .lineLimit(1).font(.callout)
                Spacer()
                Text("\(model.searchResults.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Button { model.refreshSearchResults() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh results")
            }
            .padding(8)
            Divider()
            resultList(model.searchResults,
                       empty: model.findText.isEmpty ? "Search from the Find bar (⌘F)."
                                                     : "No matches.")
        }
    }

    // MARK: Marks pane

    private var marksPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.toggleMarkAtCaret() } label: {
                    Label("Mark Line", systemImage: "bookmark")
                }
                .buttonStyle(.borderless)
                .help("Toggle a mark on the current line")
                Spacer()
                Button { model.clearMarks() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(model.marks.isEmpty)
                    .help("Clear all marks")
            }
            .padding(8)
            Divider()
            resultList(model.marksList, empty: "No marks. Mark lines to jump between them.")
        }
    }

    // MARK: Highlighters pane

    private var highlightersPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.addHighlighterFromFind() } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a highlighter (seeded from the Find text)")
                Spacer()
                Text("\(model.highlighters.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()
            if model.highlighters.isEmpty {
                emptyLabel("Add colour rules to highlight matching text in the log.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach($model.highlighters) { $h in
                            highlighterRow($h)
                        }
                    }
                    .padding(8)
                }
            }
        }
    }

    private func highlighterRow(_ h: Binding<LogHighlighter>) -> some View {
        HStack(spacing: 6) {
            Toggle("", isOn: h.enabled).labelsHidden()
                .help("Enable this highlighter")
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: h.wrappedValue.colorHex)) },
                set: { h.wrappedValue.colorHex = $0.toHex() }
            )).labelsHidden().frame(width: 34)
            TextField("regex", text: h.pattern)
                .textFieldStyle(.roundedBorder)
            Toggle("Aa", isOn: h.caseSensitive).toggleStyle(.button)
                .help("Match case")
            Toggle("▬", isOn: h.wholeLine).toggleStyle(.button)
                .help("Colour the whole line, not just the match")
            Button { model.removeHighlighter(h.wrappedValue) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Shared result list

    @ViewBuilder
    private func resultList(_ lines: [LogResultLine], empty: String) -> some View {
        if lines.isEmpty {
            emptyLabel(empty)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Button {
                            model.jumpToLine(line.lineNumber)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(line.lineNumber)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 44, alignment: .trailing)
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private func emptyLabel(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Color → hex

extension Color {
    /// A "#RRGGBB" string for persisting a picked colour.
    func toHex() -> String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .yellow
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
