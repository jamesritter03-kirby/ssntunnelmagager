import AppKit

/// A colour scheme for the text‑editor tab: an explicit background / foreground
/// pair plus syntax‑token colours. Themes carry concrete colours (rather than
/// relying on the system's dynamic `textColor` / `textBackgroundColor`, which can
/// resolve against the wrong appearance inside a SwiftUI‑hosted `NSTextView` and
/// render text invisibly against its own background). The "System" theme is the
/// one exception and follows the current light / dark appearance.
struct EditorTheme: Identifiable, Equatable {
    enum Mode { case system, light, dark }

    let id: String
    let name: String
    let mode: Mode
    let background: NSColor
    let foreground: NSColor
    let insertionPoint: NSColor
    let selection: NSColor
    let gutterBackground: NSColor
    let gutterForeground: NSColor
    let separator: NSColor
    let keyword: NSColor
    let type: NSColor
    let string: NSColor
    let comment: NSColor
    let number: NSColor
    let constant: NSColor
    let attribute: NSColor
    let tag: NSColor

    func color(for token: SyntaxToken) -> NSColor {
        switch token {
        case .keyword:   return keyword
        case .type:      return type
        case .string:    return string
        case .comment:   return comment
        case .number:    return number
        case .constant:  return constant
        case .attribute: return attribute
        case .tag:       return tag
        }
    }

    /// The appearance the editor's `NSTextView` should adopt, so its scrollers,
    /// caret blink and default field‑editor colours match the theme regardless
    /// of the app's own appearance. `nil` for the System theme (inherit).
    var nsAppearance: NSAppearance? {
        switch mode {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    var isDark: Bool { mode == .dark }

    static func == (lhs: EditorTheme, rhs: EditorTheme) -> Bool { lhs.id == rhs.id }

    // MARK: - Registry

    static let defaultID = "system"

    static let all: [EditorTheme] = [
        .system, .xcodeLight, .xcodeDark, .githubLight, .oneDark, .dracula,
        .monokai, .solarizedLight, .solarizedDark, .nord, .midnight
    ]

    static func theme(id: String) -> EditorTheme {
        all.first { $0.id == id } ?? .system
    }

    // MARK: - Colour helpers

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// A colour that resolves to `light` in Aqua and `dark` in Dark Aqua.
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? rgb(dark) : rgb(light)
        }
    }

    // MARK: - Built‑in themes

    static let system = EditorTheme(
        id: "system", name: "System (Auto)", mode: .system,
        background: .textBackgroundColor,
        foreground: .textColor,
        insertionPoint: .controlAccentColor,
        selection: .selectedTextBackgroundColor,
        gutterBackground: .textBackgroundColor,
        gutterForeground: .secondaryLabelColor,
        separator: .separatorColor,
        keyword:   dynamic(0x9B2393, 0xFF7AB2),
        type:      dynamic(0x0B4F79, 0x6BDFFF),
        string:    dynamic(0xC41A16, 0xFF8170),
        comment:   dynamic(0x707F8C, 0x7E8A97),
        number:    dynamic(0x1C00CF, 0xD9C97C),
        constant:  dynamic(0xAD3DA4, 0xDABAFF),
        attribute: dynamic(0x6C36A9, 0xB398E8),
        tag:       dynamic(0x2F6F9F, 0x79C0FF))

    static let xcodeLight = EditorTheme(
        id: "xcode-light", name: "Xcode Light", mode: .light,
        background: rgb(0xFFFFFF), foreground: rgb(0x1A1A1A),
        insertionPoint: rgb(0x1A1A1A), selection: rgb(0xB3D7FF),
        gutterBackground: rgb(0xFFFFFF), gutterForeground: rgb(0xA3A3A3),
        separator: rgb(0xE0E0E0),
        keyword: rgb(0x9B2393), type: rgb(0x0F68A0), string: rgb(0xC41A16),
        comment: rgb(0x008400), number: rgb(0x1C00CF), constant: rgb(0xAD3DA4),
        attribute: rgb(0x6C36A9), tag: rgb(0x2F6F9F))

    static let xcodeDark = EditorTheme(
        id: "xcode-dark", name: "Xcode Dark", mode: .dark,
        background: rgb(0x1F1F24), foreground: rgb(0xDFDFE0),
        insertionPoint: rgb(0xFFFFFF), selection: rgb(0x3F638B),
        gutterBackground: rgb(0x1F1F24), gutterForeground: rgb(0x6E6F75),
        separator: rgb(0x38383C),
        keyword: rgb(0xFC5FA3), type: rgb(0x5DD8FF), string: rgb(0xFC6A5D),
        comment: rgb(0x7E8A97), number: rgb(0xD0BF69), constant: rgb(0xFC5FA3),
        attribute: rgb(0xBF8355), tag: rgb(0x92C7FF))

    static let githubLight = EditorTheme(
        id: "github-light", name: "GitHub Light", mode: .light,
        background: rgb(0xFFFFFF), foreground: rgb(0x24292E),
        insertionPoint: rgb(0x24292E), selection: rgb(0xC8E1FF),
        gutterBackground: rgb(0xFFFFFF), gutterForeground: rgb(0x8C959F),
        separator: rgb(0xE1E4E8),
        keyword: rgb(0xD73A49), type: rgb(0x6F42C1), string: rgb(0x032F62),
        comment: rgb(0x6A737D), number: rgb(0x005CC5), constant: rgb(0x005CC5),
        attribute: rgb(0x22863A), tag: rgb(0x22863A))

    static let oneDark = EditorTheme(
        id: "one-dark", name: "One Dark", mode: .dark,
        background: rgb(0x282C34), foreground: rgb(0xABB2BF),
        insertionPoint: rgb(0x528BFF), selection: rgb(0x3E4451),
        gutterBackground: rgb(0x282C34), gutterForeground: rgb(0x636D83),
        separator: rgb(0x3A3F4B),
        keyword: rgb(0xC678DD), type: rgb(0xE5C07B), string: rgb(0x98C379),
        comment: rgb(0x5C6370), number: rgb(0xD19A66), constant: rgb(0x56B6C2),
        attribute: rgb(0xD19A66), tag: rgb(0xE06C75))

    static let dracula = EditorTheme(
        id: "dracula", name: "Dracula", mode: .dark,
        background: rgb(0x282A36), foreground: rgb(0xF8F8F2),
        insertionPoint: rgb(0xF8F8F0), selection: rgb(0x44475A),
        gutterBackground: rgb(0x282A36), gutterForeground: rgb(0x6272A4),
        separator: rgb(0x3B3D4C),
        keyword: rgb(0xFF79C6), type: rgb(0x8BE9FD), string: rgb(0xF1FA8C),
        comment: rgb(0x6272A4), number: rgb(0xBD93F9), constant: rgb(0xBD93F9),
        attribute: rgb(0x50FA7B), tag: rgb(0xFF79C6))

    static let monokai = EditorTheme(
        id: "monokai", name: "Monokai", mode: .dark,
        background: rgb(0x272822), foreground: rgb(0xF8F8F2),
        insertionPoint: rgb(0xF8F8F0), selection: rgb(0x49483E),
        gutterBackground: rgb(0x272822), gutterForeground: rgb(0x90908A),
        separator: rgb(0x3B3C35),
        keyword: rgb(0xF92672), type: rgb(0x66D9EF), string: rgb(0xE6DB74),
        comment: rgb(0x75715E), number: rgb(0xAE81FF), constant: rgb(0xAE81FF),
        attribute: rgb(0xA6E22E), tag: rgb(0xF92672))

    static let solarizedLight = EditorTheme(
        id: "solarized-light", name: "Solarized Light", mode: .light,
        background: rgb(0xFDF6E3), foreground: rgb(0x657B83),
        insertionPoint: rgb(0x586E75), selection: rgb(0xEEE8D5),
        gutterBackground: rgb(0xFDF6E3), gutterForeground: rgb(0x93A1A1),
        separator: rgb(0xEEE8D5),
        keyword: rgb(0x859900), type: rgb(0xB58900), string: rgb(0x2AA198),
        comment: rgb(0x93A1A1), number: rgb(0xD33682), constant: rgb(0x6C71C4),
        attribute: rgb(0x268BD2), tag: rgb(0x268BD2))

    static let solarizedDark = EditorTheme(
        id: "solarized-dark", name: "Solarized Dark", mode: .dark,
        background: rgb(0x002B36), foreground: rgb(0x93A1A1),
        insertionPoint: rgb(0xEEE8D5), selection: rgb(0x073642),
        gutterBackground: rgb(0x002B36), gutterForeground: rgb(0x586E75),
        separator: rgb(0x0B3A46),
        keyword: rgb(0x859900), type: rgb(0xB58900), string: rgb(0x2AA198),
        comment: rgb(0x586E75), number: rgb(0xD33682), constant: rgb(0x6C71C4),
        attribute: rgb(0x268BD2), tag: rgb(0x268BD2))

    static let nord = EditorTheme(
        id: "nord", name: "Nord", mode: .dark,
        background: rgb(0x2E3440), foreground: rgb(0xD8DEE9),
        insertionPoint: rgb(0xD8DEE9), selection: rgb(0x434C5E),
        gutterBackground: rgb(0x2E3440), gutterForeground: rgb(0x4C566A),
        separator: rgb(0x3B4252),
        keyword: rgb(0x81A1C1), type: rgb(0x8FBCBB), string: rgb(0xA3BE8C),
        comment: rgb(0x616E88), number: rgb(0xB48EAD), constant: rgb(0x5E81AC),
        attribute: rgb(0xEBCB8B), tag: rgb(0x88C0D0))

    static let midnight = EditorTheme(
        id: "midnight", name: "Midnight", mode: .dark,
        background: rgb(0x000000), foreground: rgb(0xE6E6E6),
        insertionPoint: rgb(0xFFFFFF), selection: rgb(0x2A2A2A),
        gutterBackground: rgb(0x000000), gutterForeground: rgb(0x555555),
        separator: rgb(0x1E1E1E),
        keyword: rgb(0xFF6AC1), type: rgb(0x63C5EA), string: rgb(0xADE25D),
        comment: rgb(0x6B6B6B), number: rgb(0xE0A060), constant: rgb(0xC792EA),
        attribute: rgb(0x82AAFF), tag: rgb(0xFF9E64))
}
