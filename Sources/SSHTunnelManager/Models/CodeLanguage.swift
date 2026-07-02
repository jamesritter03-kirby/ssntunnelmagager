import Foundation

/// A category of token the highlighter can emit. The concrete colours live in
/// the view layer (`EditorTheme`) so the model stays UI‑agnostic.
enum SyntaxToken: String {
    case keyword     // language keywords (if, func, return…)
    case type        // types / classes (Int, String, capitalised idents…)
    case string      // string & character literals
    case comment     // line & block comments
    case number      // numeric literals
    case constant    // true / false / null / preprocessor / symbols
    case attribute   // markup attributes, CSS properties, YAML/INI keys
    case tag         // markup tags, markdown headings
}

/// One compiled highlighting rule: a regex plus the token it paints. `group`
/// selects which capture group is coloured (0 = the whole match).
struct HighlightPattern {
    let regex: NSRegularExpression
    let token: SyntaxToken
    let group: Int
}

/// A programming / markup language the text‑editor tab can recognise, driving
/// syntax highlighting and the status‑bar language menu. `.plainText` disables
/// highlighting entirely.
enum CodeLanguage: String, CaseIterable, Identifiable, Codable {
    case plainText
    case swift
    case python
    case javascript
    case typescript
    case json
    case html
    case xml
    case css
    case markdown
    case shell
    case c
    case cpp
    case java
    case csharp
    case go
    case rust
    case ruby
    case php
    case sql
    case yaml
    case toml
    case ini

    var id: String { rawValue }

    /// The name shown in the language menu and status bar.
    var displayName: String {
        switch self {
        case .plainText:  return "Plain Text"
        case .swift:      return "Swift"
        case .python:     return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .json:       return "JSON"
        case .html:       return "HTML"
        case .xml:        return "XML"
        case .css:        return "CSS"
        case .markdown:   return "Markdown"
        case .shell:      return "Shell"
        case .c:          return "C"
        case .cpp:        return "C++"
        case .java:       return "Java"
        case .csharp:     return "C#"
        case .go:         return "Go"
        case .rust:       return "Rust"
        case .ruby:       return "Ruby"
        case .php:        return "PHP"
        case .sql:        return "SQL"
        case .yaml:       return "YAML"
        case .toml:       return "TOML"
        case .ini:        return "INI"
        }
    }

    /// The extension suggested when saving a brand‑new document in this language.
    var preferredExtension: String? {
        switch self {
        case .plainText:  return "txt"
        case .swift:      return "swift"
        case .python:     return "py"
        case .javascript: return "js"
        case .typescript: return "ts"
        case .json:       return "json"
        case .html:       return "html"
        case .xml:        return "xml"
        case .css:        return "css"
        case .markdown:   return "md"
        case .shell:      return "sh"
        case .c:          return "c"
        case .cpp:        return "cpp"
        case .java:       return "java"
        case .csharp:     return "cs"
        case .go:         return "go"
        case .rust:       return "rs"
        case .ruby:       return "rb"
        case .php:        return "php"
        case .sql:        return "sql"
        case .yaml:       return "yaml"
        case .toml:       return "toml"
        case .ini:        return "ini"
        }
    }

    /// Best‑guess language for a file, from its name / extension.
    static func detect(forFileName name: String) -> CodeLanguage {
        let base = (name as NSString).lastPathComponent.lowercased()
        switch base {
        case "makefile", "gnumakefile", "dockerfile", "cmakelists.txt":
            return .shell
        case ".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile",
             ".bash_aliases", ".zshenv":
            return .shell
        case ".gitconfig", ".editorconfig", ".npmrc":
            return .ini
        default:
            break
        }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift":                              return .swift
        case "py", "pyw", "pyi":                   return .python
        case "js", "mjs", "cjs", "jsx":            return .javascript
        case "ts", "tsx":                          return .typescript
        case "json", "jsonc", "geojson":           return .json
        case "html", "htm", "xhtml", "vue":        return .html
        case "xml", "plist", "storyboard", "xib",
             "svg", "xsd", "xsl":                  return .xml
        case "css", "scss", "sass", "less":        return .css
        case "md", "markdown", "mdown", "mkd":     return .markdown
        case "sh", "bash", "zsh", "command",
             "ksh", "fish", "env":                 return .shell
        case "c", "h":                             return .c
        case "cpp", "cc", "cxx", "c++", "hpp",
             "hh", "hxx", "ipp", "mm":             return .cpp
        case "java":                               return .java
        case "cs":                                 return .csharp
        case "go":                                 return .go
        case "rs":                                 return .rust
        case "rb", "erb", "rake", "gemspec":       return .ruby
        case "php", "phtml", "php3", "php4",
             "php5":                               return .php
        case "sql", "psql", "mysql":               return .sql
        case "yml", "yaml":                        return .yaml
        case "toml":                               return .toml
        case "ini", "cfg", "conf", "properties":   return .ini
        default:                                   return .plainText
        }
    }

    // MARK: - Highlighting rules

    private static var patternCache: [CodeLanguage: [HighlightPattern]] = [:]

    /// The ordered highlighting rules for this language. Later rules win over
    /// earlier ones for overlapping ranges, so keywords/numbers come first and
    /// strings then comments come last (a keyword inside a comment reads as a
    /// comment). Cached after first use.
    func highlightPatterns() -> [HighlightPattern] {
        if let cached = CodeLanguage.patternCache[self] { return cached }
        let built = CodeLanguage.buildPatterns(for: self)
        CodeLanguage.patternCache[self] = built
        return built
    }

    /// Whether this language has any highlighting at all.
    var hasHighlighting: Bool { self != .plainText }

    // MARK: Rule construction

    private static func re(_ pattern: String,
                           _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static func pat(_ pattern: String,
                            _ token: SyntaxToken,
                            group: Int = 0,
                            options: NSRegularExpression.Options = []) -> HighlightPattern? {
        guard let r = re(pattern, options) else { return nil }
        return HighlightPattern(regex: r, token: token, group: group)
    }

    /// `\b(?:word1|word2|…)\b` for a set of keywords.
    private static func keywordPattern(_ words: [String],
                                       _ token: SyntaxToken,
                                       caseInsensitive: Bool = false) -> HighlightPattern? {
        guard !words.isEmpty else { return nil }
        let escaped = words.map { NSRegularExpression.escapedPattern(for: $0) }
        let body = "\\b(?:" + escaped.joined(separator: "|") + ")\\b"
        return pat(body, token, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    // Reusable literal fragments (raw strings keep the backslashes literal).
    private static let strDouble      = #""(?:\\.|[^"\\\n])*""#
    private static let strSingle      = #"'(?:\\.|[^'\\\n])*'"#
    private static let strBacktick    = #"`(?:\\.|[^`\\])*`"#
    private static let strTripleDbl   = #""""[\s\S]*?""""#
    private static let strTripleSng   = #"'''[\s\S]*?'''"#
    private static let numberLiteral  =
        #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?)\b"#

    private static func lineComment(_ token: String) -> HighlightPattern? {
        let esc = NSRegularExpression.escapedPattern(for: token)
        return pat(esc + ".*", .comment)
    }

    private static func blockComment(_ open: String, _ close: String) -> HighlightPattern? {
        let o = NSRegularExpression.escapedPattern(for: open)
        let c = NSRegularExpression.escapedPattern(for: close)
        return pat(o + "[\\s\\S]*?" + c, .comment)
    }

    private static func buildPatterns(for lang: CodeLanguage) -> [HighlightPattern] {
        var out: [HighlightPattern] = []
        func add(_ p: HighlightPattern?) { if let p { out.append(p) } }

        switch lang {
        case .plainText:
            return []

        case .swift:
            add(pat(numberLiteral, .number))
            add(keywordPattern(cKeywords + [
                "func", "let", "var", "guard", "defer", "in", "where", "protocol",
                "extension", "struct", "enum", "class", "actor", "init", "deinit",
                "self", "Self", "super", "throws", "rethrows", "try", "throw",
                "async", "await", "some", "any", "nil", "associatedtype", "typealias",
                "import", "public", "private", "fileprivate", "internal", "open",
                "static", "final", "lazy", "weak", "unowned", "mutating", "nonmutating",
                "override", "convenience", "required", "subscript", "willSet", "didSet",
                "get", "set", "operator", "precedencegroup", "inout", "indirect",
                "repeat", "fallthrough", "case", "switch", "default", "as", "is"
            ], .keyword))
            add(keywordPattern(["true", "false", "nil"], .constant))
            add(pat(#"@\w+"#, .attribute))
            add(pat(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type))
            add(pat(strDouble, .string))
            add(lineComment("//"))
            add(blockComment("/*", "*/"))

        case .c, .cpp, .java, .csharp:
            add(pat(numberLiteral, .number))
            add(keywordPattern(cKeywords + cppExtraKeywords, .keyword))
            add(keywordPattern(["true", "false", "null", "nullptr", "NULL"], .constant))
            if lang == .c || lang == .cpp {
                add(pat(#"^\s*#\s*\w+"#, .constant, options: [.anchorsMatchLines]))
            }
            if lang == .csharp {
                add(pat(#"\[\w[\w.]*\]"#, .attribute))
            }
            add(pat(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type))
            add(pat(strDouble, .string))
            add(pat(strSingle, .string))
            add(lineComment("//"))
            add(blockComment("/*", "*/"))

        case .javascript, .typescript:
            add(pat(numberLiteral, .number))
            add(keywordPattern([
                "break", "case", "catch", "class", "const", "continue", "debugger",
                "default", "delete", "do", "else", "export", "extends", "finally",
                "for", "function", "if", "import", "in", "instanceof", "new", "return",
                "super", "switch", "this", "throw", "try", "typeof", "var", "void",
                "while", "with", "yield", "let", "static", "async", "await", "of",
                "get", "set", "from", "as"
            ] + (lang == .typescript ? [
                "interface", "type", "enum", "namespace", "declare", "public",
                "private", "protected", "readonly", "abstract", "implements",
                "keyof", "infer", "is", "satisfies"
            ] : []), .keyword))
            add(keywordPattern(["true", "false", "null", "undefined", "NaN", "Infinity"], .constant))
            add(pat(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type))
            add(pat(strDouble, .string))
            add(pat(strSingle, .string))
            add(pat(strBacktick, .string))
            add(lineComment("//"))
            add(blockComment("/*", "*/"))

        case .python:
            add(pat(numberLiteral, .number))
            add(keywordPattern([
                "and", "as", "assert", "async", "await", "break", "class", "continue",
                "def", "del", "elif", "else", "except", "finally", "for", "from",
                "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
                "or", "pass", "raise", "return", "try", "while", "with", "yield",
                "match", "case"
            ], .keyword))
            add(keywordPattern(["True", "False", "None", "self", "cls",
                                "__init__", "__name__"], .constant))
            add(pat(#"@\w[\w.]*"#, .attribute))
            add(pat(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type))
            add(pat(strTripleDbl, .string))
            add(pat(strTripleSng, .string))
            add(pat(strDouble, .string))
            add(pat(strSingle, .string))
            add(lineComment("#"))

        case .go:
            add(pat(numberLiteral, .number))
            add(keywordPattern([
                "break", "case", "chan", "const", "continue", "default", "defer",
                "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
                "interface", "map", "package", "range", "return", "select", "struct",
                "switch", "type", "var"
            ], .keyword))
            add(keywordPattern(["true", "false", "nil", "iota"], .constant))
            add(keywordPattern(["int", "int8", "int16", "int32", "int64", "uint",
                                "uint8", "uint16", "uint32", "uint64", "float32",
                                "float64", "string", "bool", "byte", "rune", "error",
                                "any"], .type))
            add(pat(strDouble, .string))
            add(pat(strBacktick, .string))
            add(lineComment("//"))
            add(blockComment("/*", "*/"))

        case .rust:
            add(pat(numberLiteral, .number))
            add(keywordPattern([
                "as", "async", "await", "break", "const", "continue", "crate", "dyn",
                "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let",
                "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
                "Self", "static", "struct", "super", "trait", "type", "unsafe", "use",
                "where", "while", "union"
            ], .keyword))
            add(keywordPattern(["true", "false", "None", "Some", "Ok", "Err"], .constant))
            add(pat(#"'\w+"#, .attribute))
            add(pat(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type))
            add(pat(strDouble, .string))
            add(lineComment("//"))
            add(blockComment("/*", "*/"))

        case .ruby:
            add(pat(numberLiteral, .number))
            add(keywordPattern([
                "begin", "break", "case", "class", "def", "defined?", "do", "else",
                "elsif", "end", "ensure", "for", "if", "in", "module", "next", "redo",
                "rescue", "retry", "return", "then", "unless", "until", "when",
                "while", "yield", "and", "or", "not", "require", "require_relative",
                "attr_accessor", "attr_reader", "attr_writer", "puts", "lambda", "proc"
            ], .keyword))
            add(keywordPattern(["true", "false", "nil", "self", "super", "__FILE__"], .constant))
            add(pat(#":\w+"#, .constant))
            add(pat(#"@@?\w+"#, .attribute))
            add(pat(#"\b[A-Z][A-Za-z0-9_]*\b"#, .type))
            add(pat(strDouble, .string))
            add(pat(strSingle, .string))
            add(lineComment("#"))

        case .php:
            add(pat(numberLiteral, .number))
            add(keywordPattern([
                "abstract", "and", "array", "as", "break", "callable", "case", "catch",
                "class", "clone", "const", "continue", "declare", "default", "do",
                "echo", "else", "elseif", "empty", "enddeclare", "endfor", "endforeach",
                "endif", "endswitch", "endwhile", "extends", "final", "finally", "fn",
                "for", "foreach", "function", "global", "goto", "if", "implements",
                "include", "include_once", "instanceof", "insteadof", "interface",
                "isset", "list", "namespace", "new", "or", "print", "private",
                "protected", "public", "require", "require_once", "return", "static",
                "switch", "throw", "trait", "try", "unset", "use", "var", "while", "xor",
                "yield"
            ], .keyword))
            add(keywordPattern(["true", "false", "null", "TRUE", "FALSE", "NULL"], .constant))
            add(pat(#"\$\w+"#, .attribute))
            add(pat(strDouble, .string))
            add(pat(strSingle, .string))
            add(lineComment("//"))
            add(lineComment("#"))
            add(blockComment("/*", "*/"))

        case .shell:
            add(keywordPattern([
                "if", "then", "else", "elif", "fi", "for", "while", "until", "do",
                "done", "case", "esac", "function", "in", "select", "return", "break",
                "continue", "local", "export", "readonly", "declare", "unset", "shift",
                "source", "alias", "set", "trap", "eval", "exec", "echo", "cd", "exit"
            ], .keyword))
            add(pat(#"\$\{?\w+\}?"#, .attribute))
            add(pat(#"\$\([^)]*\)"#, .attribute))
            add(pat(strDouble, .string))
            add(pat(strSingle, .string))
            add(lineComment("#"))

        case .sql:
            add(pat(numberLiteral, .number))
            add(keywordPattern([
                "select", "from", "where", "insert", "into", "values", "update", "set",
                "delete", "create", "drop", "alter", "table", "view", "index", "join",
                "inner", "left", "right", "outer", "full", "on", "as", "and", "or",
                "not", "in", "is", "null", "like", "between", "group", "by", "order",
                "having", "limit", "offset", "distinct", "union", "all", "primary",
                "key", "foreign", "references", "default", "constraint", "unique",
                "add", "column", "database", "schema", "grant", "revoke", "begin",
                "commit", "rollback", "transaction", "with", "case", "when", "then",
                "else", "end", "exists", "count", "sum", "avg", "min", "max", "asc",
                "desc", "if", "cascade", "auto_increment", "returning"
            ], .keyword, caseInsensitive: true))
            add(keywordPattern(["true", "false", "null"], .constant, caseInsensitive: true))
            add(pat(strSingle, .string))
            add(pat(strDouble, .string))
            add(lineComment("--"))
            add(blockComment("/*", "*/"))

        case .json:
            add(pat(numberLiteral, .number))
            add(keywordPattern(["true", "false", "null"], .constant))
            // A quoted string immediately followed by a colon is a key.
            add(pat(#""(?:\\.|[^"\\\n])*"(?=\s*:)"#, .attribute))
            add(pat(strDouble, .string))
            add(lineComment("//"))
            add(blockComment("/*", "*/"))

        case .html, .xml:
            add(blockComment("<!--", "-->"))
            // Tag names.
            add(pat(#"</?\s*([A-Za-z][\w:-]*)"#, .tag, group: 1))
            add(pat(#"<[!?][A-Za-z][\w:-]*"#, .tag))
            // Attribute names.
            add(pat(#"([A-Za-z_:][\w:.-]*)\s*="#, .attribute, group: 1))
            add(pat(strDouble, .string))
            add(pat(strSingle, .string))
            if lang == .html {
                add(pat(#"&[a-zA-Z]+;|&#\d+;"#, .constant))
            }

        case .css:
            add(pat(numberLiteral, .number))
            add(pat(#"@[\w-]+"#, .keyword))
            add(pat(#"[.#]?[\w-]+(?=\s*\{)"#, .tag))
            add(pat(#"[\w-]+(?=\s*:)"#, .attribute))
            add(pat(#"#[0-9a-fA-F]{3,8}\b"#, .constant))
            add(pat(strDouble, .string))
            add(pat(strSingle, .string))
            add(blockComment("/*", "*/"))

        case .markdown:
            add(pat(#"^#{1,6}\s.*$"#, .tag, options: [.anchorsMatchLines]))
            add(pat(#"^\s{0,3}(?:[-*+]|\d+\.)\s"#, .keyword, options: [.anchorsMatchLines]))
            add(pat(#"^\s{0,3}>.*$"#, .comment, options: [.anchorsMatchLines]))
            add(pat(#"`[^`\n]+`"#, .string))
            add(pat(#"```[\s\S]*?```"#, .string))
            add(pat(#"\*\*[^*\n]+\*\*"#, .constant))
            add(pat(#"(?<!\*)\*[^*\n]+\*(?!\*)"#, .attribute))
            add(pat(#"\[[^\]\n]*\]\([^)\n]*\)"#, .type))

        case .yaml:
            add(pat(numberLiteral, .number))
            add(pat(#"^\s*(?:-\s+)?([\w.\-/ ]+?)\s*:(?=\s|$)"#, .attribute, group: 1,
                    options: [.anchorsMatchLines]))
            add(keywordPattern(["true", "false", "null", "yes", "no", "on", "off",
                                "True", "False", "Null", "~"], .constant))
            add(pat(#"&\w+|\*\w+"#, .keyword))
            add(pat(strDouble, .string))
            add(pat(strSingle, .string))
            add(lineComment("#"))

        case .toml, .ini:
            add(pat(numberLiteral, .number))
            add(pat(#"^\s*\[.*\]\s*$"#, .tag, options: [.anchorsMatchLines]))
            add(pat(#"^\s*([\w.\-]+)\s*="#, .attribute, group: 1, options: [.anchorsMatchLines]))
            if lang == .toml {
                add(keywordPattern(["true", "false"], .constant))
            }
            add(pat(strDouble, .string))
            add(pat(strSingle, .string))
            add(lineComment("#"))
            add(lineComment(";"))
        }
        return out
    }

    /// Keywords shared by the C family (C / C++ / Java / C# reuse most of these).
    private static let cKeywords = [
        "auto", "break", "case", "char", "const", "continue", "default", "do",
        "double", "else", "enum", "extern", "float", "for", "goto", "if", "int",
        "long", "register", "return", "short", "signed", "sizeof", "static",
        "struct", "switch", "typedef", "union", "unsigned", "void", "volatile",
        "while"
    ]

    /// Extra keywords for C++/Java/C# layered on top of `cKeywords`.
    private static let cppExtraKeywords = [
        "class", "public", "private", "protected", "virtual", "override", "final",
        "namespace", "using", "template", "typename", "new", "delete", "try",
        "catch", "throw", "throws", "this", "operator", "friend", "inline",
        "explicit", "mutable", "constexpr", "noexcept", "nullptr", "bool", "true",
        "false", "import", "package", "interface", "extends", "implements",
        "abstract", "synchronized", "instanceof", "super", "boolean", "byte",
        "string", "var", "let", "async", "await", "foreach", "in", "is", "as",
        "readonly", "get", "set", "yield", "lock", "out", "ref", "params", "base",
        "sealed", "internal", "partial", "event", "decimal", "object", "dynamic"
    ]
}
