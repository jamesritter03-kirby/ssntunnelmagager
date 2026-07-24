using System.Collections.Generic;
using System.Linq;

namespace RemoteStuff.Models;

/// <summary>
/// A named terminal colour theme (background, text, cursor + 16 ANSI colours),
/// modelled after the built-in macOS Terminal.app profiles. Ported from the
/// original app's <c>TerminalTheme</c>.
/// </summary>
public sealed class TerminalTheme
{
    public string Id { get; }
    public string Name { get; }
    public bool IsDark { get; }
    public int Background { get; }
    public int Foreground { get; }
    public int Cursor { get; }
    /// <summary>Exactly 16 entries: ANSI 0–7 (normal) then 8–15 (bright).</summary>
    public int[] Ansi { get; }

    private TerminalTheme(string id, string name, bool isDark, int bg, int fg, int cursor, int[] ansi)
    {
        Id = id; Name = name; IsDark = isDark;
        Background = bg; Foreground = fg; Cursor = cursor; Ansi = ansi;
    }

    public const string DefaultId = "pro";

    private static readonly int[] StandardAnsi =
    {
        0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5,
        0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff
    };
    private static readonly int[] SolarizedAnsi =
    {
        0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
        0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3
    };
    private static readonly int[] DraculaAnsi =
    {
        0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
        0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff
    };
    private static readonly int[] NordAnsi =
    {
        0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
        0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4
    };
    private static readonly int[] GruvboxDarkAnsi =
    {
        0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
        0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2
    };
    private static readonly int[] GruvboxLightAnsi =
    {
        0xfbf1c7, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0x7c6f64,
        0x928374, 0x9d0006, 0x79740e, 0xb57614, 0x076678, 0x8f3f71, 0x427b58, 0x3c3836
    };
    private static readonly int[] OneDarkAnsi =
    {
        0x282c34, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xabb2bf,
        0x5c6370, 0xe06c75, 0x98c379, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xffffff
    };
    private static readonly int[] OneLightAnsi =
    {
        0x383a42, 0xe45649, 0x50a14f, 0xc18401, 0x4078f2, 0xa626a4, 0x0184bc, 0xfafafa,
        0x4f525e, 0xe45649, 0x50a14f, 0xc18401, 0x4078f2, 0xa626a4, 0x0184bc, 0xffffff
    };
    private static readonly int[] MonokaiAnsi =
    {
        0x272822, 0xf92672, 0xa6e22e, 0xf4bf75, 0x66d9ef, 0xae81ff, 0xa1efe4, 0xf8f8f2,
        0x75715e, 0xf92672, 0xa6e22e, 0xf4bf75, 0x66d9ef, 0xae81ff, 0xa1efe4, 0xf9f8f5
    };
    private static readonly int[] TokyoNightAnsi =
    {
        0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
        0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5
    };
    private static readonly int[] CatppuccinMochaAnsi =
    {
        0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
        0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8
    };
    private static readonly int[] CatppuccinLatteAnsi =
    {
        0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xacb0be,
        0x6c6f85, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xbcc0cc
    };
    private static readonly int[] GithubDarkAnsi =
    {
        0x484f58, 0xff7b72, 0x3fb950, 0xd29922, 0x58a6ff, 0xbc8cff, 0x39c5cf, 0xb1bac4,
        0x6e7681, 0xffa198, 0x56d364, 0xe3b341, 0x79c0ff, 0xd2a8ff, 0x56d4dd, 0xf0f6fc
    };
    private static readonly int[] GithubLightAnsi =
    {
        0x24292f, 0xcf222e, 0x116329, 0x4d2d00, 0x0969da, 0x8250df, 0x1b7c83, 0x6e7781,
        0x57606a, 0xa40e26, 0x1a7f37, 0x633c01, 0x218bff, 0xa475f9, 0x3192aa, 0x8c959f
    };
    private static readonly int[] NightOwlAnsi =
    {
        0x011627, 0xef5350, 0x22da6e, 0xc5e478, 0x82aaff, 0xc792ea, 0x21c7a8, 0xffffff,
        0x637777, 0xef5350, 0x22da6e, 0xffeb95, 0x82aaff, 0xc792ea, 0x7fdbca, 0xffffff
    };
    private static readonly int[] SnazzyAnsi =
    {
        0x282a36, 0xff5c57, 0x5af78e, 0xf3f99d, 0x57c7ff, 0xff6ac1, 0x9aedfe, 0xf1f1f0,
        0x686868, 0xff5c57, 0x5af78e, 0xf3f99d, 0x57c7ff, 0xff6ac1, 0x9aedfe, 0xf1f1f0
    };
    private static readonly int[] MaterialAnsi =
    {
        0x000000, 0xff5370, 0xc3e88d, 0xffcb6b, 0x82aaff, 0xc792ea, 0x89ddff, 0xffffff,
        0x546e7a, 0xff5370, 0xc3e88d, 0xffcb6b, 0x82aaff, 0xc792ea, 0x89ddff, 0xffffff
    };
    private static readonly int[] AyuDarkAnsi =
    {
        0x01060e, 0xea6c73, 0x91b362, 0xf9af4f, 0x53bdfa, 0xfae994, 0x90e1c6, 0xc7c7c7,
        0x686868, 0xf07178, 0xc2d94c, 0xffb454, 0x59c2ff, 0xffee99, 0x95e6cb, 0xffffff
    };

    public static readonly IReadOnlyList<TerminalTheme> All = new List<TerminalTheme>
    {
        new("pro", "Pro", true, 0x000000, 0xf2f2f2, 0x4d4d4d, StandardAnsi),
        new("basic", "Basic", false, 0xffffff, 0x000000, 0x7f7f7f, StandardAnsi),
        new("homebrew", "Homebrew", true, 0x000000, 0x28fe14, 0x28fe14, StandardAnsi),
        new("ocean", "Ocean", true, 0x224fbc, 0xffffff, 0xffffff, StandardAnsi),
        new("novel", "Novel", false, 0xdfdbc3, 0x3b2322, 0x73635a, StandardAnsi),
        new("solarized-dark", "Solarized Dark", true, 0x002b36, 0x839496, 0x93a1a1, SolarizedAnsi),
        new("solarized-light", "Solarized Light", false, 0xfdf6e3, 0x657b83, 0x586e75, SolarizedAnsi),
        new("dracula", "Dracula", true, 0x282a36, 0xf8f8f2, 0xf8f8f0, DraculaAnsi),
        new("grass", "Grass", true, 0x13773d, 0xfff0a5, 0x8c1700, StandardAnsi),
        new("man", "Man Page", false, 0xfef49c, 0x000000, 0x7f7f7f, StandardAnsi),
        new("red-sands", "Red Sands", true, 0x7a251e, 0xd7c9a7, 0xffffff, StandardAnsi),
        new("silver-aerogel", "Silver Aerogel", false, 0x929292, 0x000000, 0x000000, StandardAnsi),
        new("nord", "Nord", true, 0x2e3440, 0xd8dee9, 0xd8dee9, NordAnsi),
        new("gruvbox-dark", "Gruvbox Dark", true, 0x282828, 0xebdbb2, 0xebdbb2, GruvboxDarkAnsi),
        new("gruvbox-light", "Gruvbox Light", false, 0xfbf1c7, 0x3c3836, 0x3c3836, GruvboxLightAnsi),
        new("one-dark", "One Dark", true, 0x282c34, 0xabb2bf, 0x528bff, OneDarkAnsi),
        new("one-light", "One Light", false, 0xfafafa, 0x383a42, 0x526fff, OneLightAnsi),
        new("monokai", "Monokai", true, 0x272822, 0xf8f8f2, 0xf8f8f2, MonokaiAnsi),
        new("tokyo-night", "Tokyo Night", true, 0x1a1b26, 0xc0caf5, 0xc0caf5, TokyoNightAnsi),
        new("catppuccin-mocha", "Catppuccin Mocha", true, 0x1e1e2e, 0xcdd6f4, 0xf5e0dc, CatppuccinMochaAnsi),
        new("catppuccin-latte", "Catppuccin Latte", false, 0xeff1f5, 0x4c4f69, 0xdc8a78, CatppuccinLatteAnsi),
        new("github-dark", "GitHub Dark", true, 0x0d1117, 0xc9d1d9, 0xc9d1d9, GithubDarkAnsi),
        new("github-light", "GitHub Light", false, 0xffffff, 0x24292f, 0x24292f, GithubLightAnsi),
        new("night-owl", "Night Owl", true, 0x011627, 0xd6deeb, 0x80a4c2, NightOwlAnsi),
        new("snazzy", "Snazzy", true, 0x282a36, 0xeff0eb, 0x97979b, SnazzyAnsi),
        new("material", "Material", true, 0x263238, 0xeeffff, 0xffcc00, MaterialAnsi),
        new("ayu-dark", "Ayu Dark", true, 0x0a0e14, 0xbfbdb6, 0xe6b450, AyuDarkAnsi),
    };

    public static TerminalTheme Default => All.First(t => t.Id == DefaultId);

    public static TerminalTheme ById(string id) => All.FirstOrDefault(t => t.Id == id) ?? Default;
}
