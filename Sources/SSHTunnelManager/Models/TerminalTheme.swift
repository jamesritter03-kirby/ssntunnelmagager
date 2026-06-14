import AppKit
import SwiftTerm

/// A single RGB color used by a terminal theme, defined from a 0xRRGGBB literal.
struct ThemeColor: Hashable {
    let r: UInt8, g: UInt8, b: UInt8

    init(_ hex: UInt32) {
        r = UInt8((hex >> 16) & 0xff)
        g = UInt8((hex >> 8) & 0xff)
        b = UInt8(hex & 0xff)
    }

    /// AppKit color (also used to build SwiftUI swatches via `Color(nsColor:)`).
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// SwiftTerm color (16-bit channels).
    var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r) &* 257, green: UInt16(g) &* 257, blue: UInt16(b) &* 257)
    }
}

/// A named terminal color theme (background, text, cursor + 16 ANSI colors),
/// modelled after the built-in macOS Terminal.app profiles.
struct TerminalTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let isDark: Bool
    let background: ThemeColor
    let foreground: ThemeColor
    let cursor: ThemeColor
    /// Exactly 16 entries: ANSI 0–7 (normal) then 8–15 (bright).
    let ansi: [ThemeColor]

    /// Apply this theme to a live terminal view.
    func apply(to view: TerminalView) {
        if ansi.count == 16 {
            view.installColors(ansi.map { $0.terminalColor })
        }
        view.nativeBackgroundColor = background.nsColor
        view.nativeForegroundColor = foreground.nsColor
        view.caretColor = cursor.nsColor
    }

    // MARK: - Presets

    static let defaultID = "pro"

    /// Standard xterm 16-color palette, used by the simpler themes.
    private static let standardANSI: [ThemeColor] = [
        ThemeColor(0x000000), ThemeColor(0xcd0000), ThemeColor(0x00cd00), ThemeColor(0xcdcd00),
        ThemeColor(0x0000ee), ThemeColor(0xcd00cd), ThemeColor(0x00cdcd), ThemeColor(0xe5e5e5),
        ThemeColor(0x7f7f7f), ThemeColor(0xff0000), ThemeColor(0x00ff00), ThemeColor(0xffff00),
        ThemeColor(0x5c5cff), ThemeColor(0xff00ff), ThemeColor(0x00ffff), ThemeColor(0xffffff),
    ]

    private static let solarizedANSI: [ThemeColor] = [
        ThemeColor(0x073642), ThemeColor(0xdc322f), ThemeColor(0x859900), ThemeColor(0xb58900),
        ThemeColor(0x268bd2), ThemeColor(0xd33682), ThemeColor(0x2aa198), ThemeColor(0xeee8d5),
        ThemeColor(0x002b36), ThemeColor(0xcb4b16), ThemeColor(0x586e75), ThemeColor(0x657b83),
        ThemeColor(0x839496), ThemeColor(0x6c71c4), ThemeColor(0x93a1a1), ThemeColor(0xfdf6e3),
    ]

    private static let draculaANSI: [ThemeColor] = [
        ThemeColor(0x21222c), ThemeColor(0xff5555), ThemeColor(0x50fa7b), ThemeColor(0xf1fa8c),
        ThemeColor(0xbd93f9), ThemeColor(0xff79c6), ThemeColor(0x8be9fd), ThemeColor(0xf8f8f2),
        ThemeColor(0x6272a4), ThemeColor(0xff6e6e), ThemeColor(0x69ff94), ThemeColor(0xffffa5),
        ThemeColor(0xd6acff), ThemeColor(0xff92df), ThemeColor(0xa4ffff), ThemeColor(0xffffff),
    ]

    static let all: [TerminalTheme] = [
        TerminalTheme(id: "pro", name: "Pro", isDark: true,
                      background: ThemeColor(0x000000), foreground: ThemeColor(0xf2f2f2),
                      cursor: ThemeColor(0x4d4d4d), ansi: standardANSI),
        TerminalTheme(id: "basic", name: "Basic", isDark: false,
                      background: ThemeColor(0xffffff), foreground: ThemeColor(0x000000),
                      cursor: ThemeColor(0x7f7f7f), ansi: standardANSI),
        TerminalTheme(id: "homebrew", name: "Homebrew", isDark: true,
                      background: ThemeColor(0x000000), foreground: ThemeColor(0x28fe14),
                      cursor: ThemeColor(0x28fe14), ansi: standardANSI),
        TerminalTheme(id: "ocean", name: "Ocean", isDark: true,
                      background: ThemeColor(0x224fbc), foreground: ThemeColor(0xffffff),
                      cursor: ThemeColor(0xffffff), ansi: standardANSI),
        TerminalTheme(id: "novel", name: "Novel", isDark: false,
                      background: ThemeColor(0xdfdbc3), foreground: ThemeColor(0x3b2322),
                      cursor: ThemeColor(0x73635a), ansi: standardANSI),
        TerminalTheme(id: "solarized-dark", name: "Solarized Dark", isDark: true,
                      background: ThemeColor(0x002b36), foreground: ThemeColor(0x839496),
                      cursor: ThemeColor(0x93a1a1), ansi: solarizedANSI),
        TerminalTheme(id: "solarized-light", name: "Solarized Light", isDark: false,
                      background: ThemeColor(0xfdf6e3), foreground: ThemeColor(0x657b83),
                      cursor: ThemeColor(0x586e75), ansi: solarizedANSI),
        TerminalTheme(id: "dracula", name: "Dracula", isDark: true,
                      background: ThemeColor(0x282a36), foreground: ThemeColor(0xf8f8f2),
                      cursor: ThemeColor(0xf8f8f0), ansi: draculaANSI),
    ]

    static let `default` = all.first { $0.id == defaultID }!

    static func theme(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? .default
    }
}
