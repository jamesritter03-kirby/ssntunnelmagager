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

    private static let nordANSI: [ThemeColor] = [
        ThemeColor(0x3b4252), ThemeColor(0xbf616a), ThemeColor(0xa3be8c), ThemeColor(0xebcb8b),
        ThemeColor(0x81a1c1), ThemeColor(0xb48ead), ThemeColor(0x88c0d0), ThemeColor(0xe5e9f0),
        ThemeColor(0x4c566a), ThemeColor(0xbf616a), ThemeColor(0xa3be8c), ThemeColor(0xebcb8b),
        ThemeColor(0x81a1c1), ThemeColor(0xb48ead), ThemeColor(0x8fbcbb), ThemeColor(0xeceff4),
    ]

    private static let gruvboxDarkANSI: [ThemeColor] = [
        ThemeColor(0x282828), ThemeColor(0xcc241d), ThemeColor(0x98971a), ThemeColor(0xd79921),
        ThemeColor(0x458588), ThemeColor(0xb16286), ThemeColor(0x689d6a), ThemeColor(0xa89984),
        ThemeColor(0x928374), ThemeColor(0xfb4934), ThemeColor(0xb8bb26), ThemeColor(0xfabd2f),
        ThemeColor(0x83a598), ThemeColor(0xd3869b), ThemeColor(0x8ec07c), ThemeColor(0xebdbb2),
    ]

    private static let gruvboxLightANSI: [ThemeColor] = [
        ThemeColor(0xfbf1c7), ThemeColor(0xcc241d), ThemeColor(0x98971a), ThemeColor(0xd79921),
        ThemeColor(0x458588), ThemeColor(0xb16286), ThemeColor(0x689d6a), ThemeColor(0x7c6f64),
        ThemeColor(0x928374), ThemeColor(0x9d0006), ThemeColor(0x79740e), ThemeColor(0xb57614),
        ThemeColor(0x076678), ThemeColor(0x8f3f71), ThemeColor(0x427b58), ThemeColor(0x3c3836),
    ]

    private static let oneDarkANSI: [ThemeColor] = [
        ThemeColor(0x282c34), ThemeColor(0xe06c75), ThemeColor(0x98c379), ThemeColor(0xe5c07b),
        ThemeColor(0x61afef), ThemeColor(0xc678dd), ThemeColor(0x56b6c2), ThemeColor(0xabb2bf),
        ThemeColor(0x5c6370), ThemeColor(0xe06c75), ThemeColor(0x98c379), ThemeColor(0xe5c07b),
        ThemeColor(0x61afef), ThemeColor(0xc678dd), ThemeColor(0x56b6c2), ThemeColor(0xffffff),
    ]

    private static let oneLightANSI: [ThemeColor] = [
        ThemeColor(0x383a42), ThemeColor(0xe45649), ThemeColor(0x50a14f), ThemeColor(0xc18401),
        ThemeColor(0x4078f2), ThemeColor(0xa626a4), ThemeColor(0x0184bc), ThemeColor(0xfafafa),
        ThemeColor(0x4f525e), ThemeColor(0xe45649), ThemeColor(0x50a14f), ThemeColor(0xc18401),
        ThemeColor(0x4078f2), ThemeColor(0xa626a4), ThemeColor(0x0184bc), ThemeColor(0xffffff),
    ]

    private static let monokaiANSI: [ThemeColor] = [
        ThemeColor(0x272822), ThemeColor(0xf92672), ThemeColor(0xa6e22e), ThemeColor(0xf4bf75),
        ThemeColor(0x66d9ef), ThemeColor(0xae81ff), ThemeColor(0xa1efe4), ThemeColor(0xf8f8f2),
        ThemeColor(0x75715e), ThemeColor(0xf92672), ThemeColor(0xa6e22e), ThemeColor(0xf4bf75),
        ThemeColor(0x66d9ef), ThemeColor(0xae81ff), ThemeColor(0xa1efe4), ThemeColor(0xf9f8f5),
    ]

    private static let tokyoNightANSI: [ThemeColor] = [
        ThemeColor(0x15161e), ThemeColor(0xf7768e), ThemeColor(0x9ece6a), ThemeColor(0xe0af68),
        ThemeColor(0x7aa2f7), ThemeColor(0xbb9af7), ThemeColor(0x7dcfff), ThemeColor(0xa9b1d6),
        ThemeColor(0x414868), ThemeColor(0xf7768e), ThemeColor(0x9ece6a), ThemeColor(0xe0af68),
        ThemeColor(0x7aa2f7), ThemeColor(0xbb9af7), ThemeColor(0x7dcfff), ThemeColor(0xc0caf5),
    ]

    private static let catppuccinMochaANSI: [ThemeColor] = [
        ThemeColor(0x45475a), ThemeColor(0xf38ba8), ThemeColor(0xa6e3a1), ThemeColor(0xf9e2af),
        ThemeColor(0x89b4fa), ThemeColor(0xf5c2e7), ThemeColor(0x94e2d5), ThemeColor(0xbac2de),
        ThemeColor(0x585b70), ThemeColor(0xf38ba8), ThemeColor(0xa6e3a1), ThemeColor(0xf9e2af),
        ThemeColor(0x89b4fa), ThemeColor(0xf5c2e7), ThemeColor(0x94e2d5), ThemeColor(0xa6adc8),
    ]

    private static let catppuccinLatteANSI: [ThemeColor] = [
        ThemeColor(0x5c5f77), ThemeColor(0xd20f39), ThemeColor(0x40a02b), ThemeColor(0xdf8e1d),
        ThemeColor(0x1e66f5), ThemeColor(0xea76cb), ThemeColor(0x179299), ThemeColor(0xacb0be),
        ThemeColor(0x6c6f85), ThemeColor(0xd20f39), ThemeColor(0x40a02b), ThemeColor(0xdf8e1d),
        ThemeColor(0x1e66f5), ThemeColor(0xea76cb), ThemeColor(0x179299), ThemeColor(0xbcc0cc),
    ]

    private static let githubDarkANSI: [ThemeColor] = [
        ThemeColor(0x484f58), ThemeColor(0xff7b72), ThemeColor(0x3fb950), ThemeColor(0xd29922),
        ThemeColor(0x58a6ff), ThemeColor(0xbc8cff), ThemeColor(0x39c5cf), ThemeColor(0xb1bac4),
        ThemeColor(0x6e7681), ThemeColor(0xffa198), ThemeColor(0x56d364), ThemeColor(0xe3b341),
        ThemeColor(0x79c0ff), ThemeColor(0xd2a8ff), ThemeColor(0x56d4dd), ThemeColor(0xf0f6fc),
    ]

    private static let githubLightANSI: [ThemeColor] = [
        ThemeColor(0x24292f), ThemeColor(0xcf222e), ThemeColor(0x116329), ThemeColor(0x4d2d00),
        ThemeColor(0x0969da), ThemeColor(0x8250df), ThemeColor(0x1b7c83), ThemeColor(0x6e7781),
        ThemeColor(0x57606a), ThemeColor(0xa40e26), ThemeColor(0x1a7f37), ThemeColor(0x633c01),
        ThemeColor(0x218bff), ThemeColor(0xa475f9), ThemeColor(0x3192aa), ThemeColor(0x8c959f),
    ]

    private static let nightOwlANSI: [ThemeColor] = [
        ThemeColor(0x011627), ThemeColor(0xef5350), ThemeColor(0x22da6e), ThemeColor(0xc5e478),
        ThemeColor(0x82aaff), ThemeColor(0xc792ea), ThemeColor(0x21c7a8), ThemeColor(0xffffff),
        ThemeColor(0x637777), ThemeColor(0xef5350), ThemeColor(0x22da6e), ThemeColor(0xffeb95),
        ThemeColor(0x82aaff), ThemeColor(0xc792ea), ThemeColor(0x7fdbca), ThemeColor(0xffffff),
    ]

    private static let snazzyANSI: [ThemeColor] = [
        ThemeColor(0x282a36), ThemeColor(0xff5c57), ThemeColor(0x5af78e), ThemeColor(0xf3f99d),
        ThemeColor(0x57c7ff), ThemeColor(0xff6ac1), ThemeColor(0x9aedfe), ThemeColor(0xf1f1f0),
        ThemeColor(0x686868), ThemeColor(0xff5c57), ThemeColor(0x5af78e), ThemeColor(0xf3f99d),
        ThemeColor(0x57c7ff), ThemeColor(0xff6ac1), ThemeColor(0x9aedfe), ThemeColor(0xf1f1f0),
    ]

    private static let materialANSI: [ThemeColor] = [
        ThemeColor(0x000000), ThemeColor(0xff5370), ThemeColor(0xc3e88d), ThemeColor(0xffcb6b),
        ThemeColor(0x82aaff), ThemeColor(0xc792ea), ThemeColor(0x89ddff), ThemeColor(0xffffff),
        ThemeColor(0x546e7a), ThemeColor(0xff5370), ThemeColor(0xc3e88d), ThemeColor(0xffcb6b),
        ThemeColor(0x82aaff), ThemeColor(0xc792ea), ThemeColor(0x89ddff), ThemeColor(0xffffff),
    ]

    private static let ayuDarkANSI: [ThemeColor] = [
        ThemeColor(0x01060e), ThemeColor(0xea6c73), ThemeColor(0x91b362), ThemeColor(0xf9af4f),
        ThemeColor(0x53bdfa), ThemeColor(0xfae994), ThemeColor(0x90e1c6), ThemeColor(0xc7c7c7),
        ThemeColor(0x686868), ThemeColor(0xf07178), ThemeColor(0xc2d94c), ThemeColor(0xffb454),
        ThemeColor(0x59c2ff), ThemeColor(0xffee99), ThemeColor(0x95e6cb), ThemeColor(0xffffff),
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

        // More macOS Terminal.app classics
        TerminalTheme(id: "grass", name: "Grass", isDark: true,
                      background: ThemeColor(0x13773d), foreground: ThemeColor(0xfff0a5),
                      cursor: ThemeColor(0x8c1700), ansi: standardANSI),
        TerminalTheme(id: "man", name: "Man Page", isDark: false,
                      background: ThemeColor(0xfef49c), foreground: ThemeColor(0x000000),
                      cursor: ThemeColor(0x7f7f7f), ansi: standardANSI),
        TerminalTheme(id: "red-sands", name: "Red Sands", isDark: true,
                      background: ThemeColor(0x7a251e), foreground: ThemeColor(0xd7c9a7),
                      cursor: ThemeColor(0xffffff), ansi: standardANSI),
        TerminalTheme(id: "silver-aerogel", name: "Silver Aerogel", isDark: false,
                      background: ThemeColor(0x929292), foreground: ThemeColor(0x000000),
                      cursor: ThemeColor(0x000000), ansi: standardANSI),

        // Developer favorites
        TerminalTheme(id: "nord", name: "Nord", isDark: true,
                      background: ThemeColor(0x2e3440), foreground: ThemeColor(0xd8dee9),
                      cursor: ThemeColor(0xd8dee9), ansi: nordANSI),
        TerminalTheme(id: "gruvbox-dark", name: "Gruvbox Dark", isDark: true,
                      background: ThemeColor(0x282828), foreground: ThemeColor(0xebdbb2),
                      cursor: ThemeColor(0xebdbb2), ansi: gruvboxDarkANSI),
        TerminalTheme(id: "gruvbox-light", name: "Gruvbox Light", isDark: false,
                      background: ThemeColor(0xfbf1c7), foreground: ThemeColor(0x3c3836),
                      cursor: ThemeColor(0x3c3836), ansi: gruvboxLightANSI),
        TerminalTheme(id: "one-dark", name: "One Dark", isDark: true,
                      background: ThemeColor(0x282c34), foreground: ThemeColor(0xabb2bf),
                      cursor: ThemeColor(0x528bff), ansi: oneDarkANSI),
        TerminalTheme(id: "one-light", name: "One Light", isDark: false,
                      background: ThemeColor(0xfafafa), foreground: ThemeColor(0x383a42),
                      cursor: ThemeColor(0x526fff), ansi: oneLightANSI),
        TerminalTheme(id: "monokai", name: "Monokai", isDark: true,
                      background: ThemeColor(0x272822), foreground: ThemeColor(0xf8f8f2),
                      cursor: ThemeColor(0xf8f8f2), ansi: monokaiANSI),
        TerminalTheme(id: "tokyo-night", name: "Tokyo Night", isDark: true,
                      background: ThemeColor(0x1a1b26), foreground: ThemeColor(0xc0caf5),
                      cursor: ThemeColor(0xc0caf5), ansi: tokyoNightANSI),
        TerminalTheme(id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
                      background: ThemeColor(0x1e1e2e), foreground: ThemeColor(0xcdd6f4),
                      cursor: ThemeColor(0xf5e0dc), ansi: catppuccinMochaANSI),
        TerminalTheme(id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false,
                      background: ThemeColor(0xeff1f5), foreground: ThemeColor(0x4c4f69),
                      cursor: ThemeColor(0xdc8a78), ansi: catppuccinLatteANSI),
        TerminalTheme(id: "github-dark", name: "GitHub Dark", isDark: true,
                      background: ThemeColor(0x0d1117), foreground: ThemeColor(0xc9d1d9),
                      cursor: ThemeColor(0xc9d1d9), ansi: githubDarkANSI),
        TerminalTheme(id: "github-light", name: "GitHub Light", isDark: false,
                      background: ThemeColor(0xffffff), foreground: ThemeColor(0x24292f),
                      cursor: ThemeColor(0x24292f), ansi: githubLightANSI),
        TerminalTheme(id: "night-owl", name: "Night Owl", isDark: true,
                      background: ThemeColor(0x011627), foreground: ThemeColor(0xd6deeb),
                      cursor: ThemeColor(0x80a4c2), ansi: nightOwlANSI),
        TerminalTheme(id: "snazzy", name: "Snazzy", isDark: true,
                      background: ThemeColor(0x282a36), foreground: ThemeColor(0xeff0eb),
                      cursor: ThemeColor(0x97979b), ansi: snazzyANSI),
        TerminalTheme(id: "material", name: "Material", isDark: true,
                      background: ThemeColor(0x263238), foreground: ThemeColor(0xeeffff),
                      cursor: ThemeColor(0xffcc00), ansi: materialANSI),
        TerminalTheme(id: "ayu-dark", name: "Ayu Dark", isDark: true,
                      background: ThemeColor(0x0a0e14), foreground: ThemeColor(0xbfbdb6),
                      cursor: ThemeColor(0xe6b450), ansi: ayuDarkANSI),
    ]

    /// Dark themes, in display order (used to group the theme picker).
    static let dark = all.filter { $0.isDark }

    /// Light themes, in display order (used to group the theme picker).
    static let light = all.filter { !$0.isDark }

    static let `default` = all.first { $0.id == defaultID }!

    static func theme(id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? .default
    }
}
