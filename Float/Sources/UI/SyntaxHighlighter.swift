import AppKit
import SwiftUI

/// Small regex highlighter for code blocks: comments, strings, numbers, keywords and type names,
/// in Xcode's default colours for light and dark. Unknown languages stay plain.
enum SyntaxHighlighter {
    private struct Language {
        var keywords: Set<String>
        var lineComment: [String] = ["//"]
        var blockComment: (String, String)? = ("/*", "*/")
        var strings: [Character] = ["\"", "'"]
        var capitalizedAreTypes = true
        var variables = false     // $name in shell
        var markup = false        // <tags> in HTML/XML
    }

    private static let cKeywords: Set<String> = ["if", "else", "for", "while", "do", "switch", "case", "default", "break",
                                                 "continue", "return", "struct", "enum", "union", "typedef", "static", "const",
                                                 "void", "int", "char", "float", "double", "long", "short", "unsigned", "signed",
                                                 "bool", "true", "false", "sizeof", "goto", "extern", "inline", "auto", "volatile",
                                                 "include", "define", "ifdef", "ifndef", "endif", "pragma", "NULL", "nullptr",
                                                 "class", "public", "private", "protected", "virtual", "override", "template",
                                                 "typename", "namespace", "using", "new", "delete", "this", "try", "catch", "throw",
                                                 "operator", "friend", "constexpr", "noexcept", "self", "super", "nil", "id",
                                                 "interface", "implementation", "property", "end"]

    private static let languages: [String: Language] = {
        let swift = Language(keywords: ["func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "repeat",
                                        "switch", "case", "default", "break", "continue", "struct", "class", "enum", "protocol",
                                        "extension", "import", "init", "deinit", "self", "Self", "super", "nil", "true", "false",
                                        "static", "private", "fileprivate", "public", "internal", "open", "final", "override",
                                        "mutating", "throws", "throw", "rethrows", "try", "catch", "do", "async", "await",
                                        "some", "any", "where", "as", "is", "typealias", "associatedtype", "inout", "defer",
                                        "lazy", "weak", "unowned", "get", "set", "willSet", "didSet", "actor", "nonisolated",
                                        "fallthrough", "subscript", "operator", "convenience", "required", "optional"],
                             strings: ["\""])
        let js = Language(keywords: ["function", "const", "let", "var", "if", "else", "return", "for", "while", "do", "of", "in",
                                     "switch", "case", "default", "break", "continue", "class", "extends", "new", "this",
                                     "super", "import", "export", "from", "as", "async", "await", "try", "catch", "finally",
                                     "throw", "typeof", "instanceof", "null", "undefined", "true", "false", "yield", "static",
                                     "get", "set", "delete", "void", "interface", "type", "enum", "implements", "private",
                                     "public", "protected", "readonly", "namespace", "declare", "keyof", "satisfies"],
                          strings: ["\"", "'", "`"])
        let python = Language(keywords: ["def", "class", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is",
                                         "return", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass",
                                         "break", "continue", "lambda", "yield", "global", "nonlocal", "True", "False", "None",
                                         "async", "await", "del", "assert", "match", "case", "self", "cls"],
                              lineComment: ["#"], blockComment: nil)
        let go = Language(keywords: ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan",
                                     "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "return",
                                     "go", "defer", "select", "fallthrough", "goto", "nil", "true", "false", "iota", "make",
                                     "new", "len", "cap", "append", "error", "string", "int", "int64", "bool", "byte", "rune",
                                     "float64", "any"],
                          strings: ["\"", "'", "`"])
        let rust = Language(keywords: ["fn", "let", "mut", "const", "static", "if", "else", "match", "for", "in", "while", "loop",
                                       "break", "continue", "return", "struct", "enum", "trait", "impl", "pub", "use", "mod",
                                       "crate", "self", "Self", "super", "where", "as", "ref", "move", "async", "await", "dyn",
                                       "unsafe", "true", "false", "type", "extern", "Some", "None", "Ok", "Err"],
                            strings: ["\""])
        let java = Language(keywords: ["class", "interface", "enum", "extends", "implements", "public", "private", "protected",
                                       "static", "final", "abstract", "void", "int", "long", "double", "float", "boolean",
                                       "char", "byte", "short", "if", "else", "for", "while", "do", "switch", "case", "default",
                                       "break", "continue", "return", "new", "this", "super", "null", "true", "false", "try",
                                       "catch", "finally", "throw", "throws", "import", "package", "synchronized", "var",
                                       "fun", "val", "object", "data", "when", "is", "in", "override", "open", "companion",
                                       "suspend", "record"])
        let ruby = Language(keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for",
                                       "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "self", "nil",
                                       "true", "false", "and", "or", "not", "require", "attr_accessor", "attr_reader",
                                       "include", "extend", "lambda", "proc", "then", "case", "when"],
                            lineComment: ["#"], blockComment: nil)
        let shell = Language(keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case",
                                        "esac", "function", "return", "local", "export", "echo", "cd", "exit", "set", "unset",
                                        "source", "alias", "sudo", "readonly", "shift", "true", "false"],
                             lineComment: ["#"], blockComment: nil, capitalizedAreTypes: false, variables: true)
        let sql = Language(keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                                      "delete", "create", "table", "drop", "alter", "add", "index", "join", "left", "right",
                                      "inner", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as",
                                      "distinct", "union", "all", "null", "is", "in", "like", "between", "case", "when",
                                      "then", "else", "end", "primary", "key", "foreign", "references", "default", "with",
                                      "returning", "exists", "count", "sum", "avg", "min", "max", "asc", "desc", "integer",
                                      "text", "varchar", "boolean", "true", "false"],
                           lineComment: ["--"], capitalizedAreTypes: false)
        let css = Language(keywords: ["important", "media", "import", "keyframes", "from", "to", "root", "hover", "before",
                                      "after", "none", "auto", "inherit", "initial", "solid", "flex", "grid", "block", "inline"],
                           lineComment: [], capitalizedAreTypes: false)
        let yaml = Language(keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                            lineComment: ["#"], blockComment: nil, capitalizedAreTypes: false)
        let json = Language(keywords: ["true", "false", "null"], lineComment: [], blockComment: nil,
                            strings: ["\""], capitalizedAreTypes: false)
        let toml = Language(keywords: ["true", "false"], lineComment: ["#"], blockComment: nil, capitalizedAreTypes: false)
        let html = Language(keywords: [], lineComment: [], blockComment: ("<!--", "-->"), capitalizedAreTypes: false, markup: true)
        let c = Language(keywords: cKeywords)

        var map: [String: Language] = [:]
        for k in ["swift"] { map[k] = swift }
        for k in ["js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs"] { map[k] = js }
        for k in ["py", "python", "python3"] { map[k] = python }
        for k in ["go", "golang"] { map[k] = go }
        for k in ["rs", "rust"] { map[k] = rust }
        for k in ["java", "kotlin", "kt", "scala", "cs", "csharp", "dart"] { map[k] = java }
        for k in ["rb", "ruby"] { map[k] = ruby }
        for k in ["sh", "bash", "zsh", "shell", "console", "fish"] { map[k] = shell }
        for k in ["sql", "postgres", "postgresql", "sqlite", "mysql"] { map[k] = sql }
        for k in ["css", "scss", "less"] { map[k] = css }
        for k in ["yaml", "yml"] { map[k] = yaml }
        for k in ["json", "jsonc", "json5"] { map[k] = json }
        for k in ["toml", "ini"] { map[k] = toml }
        for k in ["html", "xml", "svg", "plist", "vue"] { map[k] = html }
        for k in ["c", "h", "cpp", "c++", "cc", "hpp", "objc", "objective-c", "m", "mm"] { map[k] = c }
        return map
    }()

    // Xcode's default theme colours, light / dark.
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func rgb(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) })
    }
    private static let keywordColor = dynamic(0x9B2393, 0xFF7AB2)
    private static let stringColor = dynamic(0xC41A16, 0xFF8170)
    private static let commentColor = dynamic(0x5D6C79, 0x7F8C98)
    private static let numberColor = dynamic(0x1C00CF, 0xD9C97C)
    private static let typeColor = dynamic(0x3900A0, 0xDABAFF)
    private static let attributeColor = dynamic(0x815F03, 0xFFA14F)
    private static let keyColor = dynamic(0x0B4F79, 0x6BDFFF)

    private static var cache: [String: AttributedString] = [:]

    static func highlight(_ code: String, language: String) -> AttributedString {
        let lang = language.lowercased().split(separator: " ").first.map(String.init) ?? ""
        guard let spec = languages[lang], code.utf16.count < 60_000 else { return AttributedString(code) }
        let key = lang + "\u{0}" + code
        if let hit = cache[key] { return hit }

        var out = AttributedString(code)
        let ns = code as NSString
        func paint(_ r: NSRange, _ color: Color) {
            guard let sr = Range(r, in: code), let ar = Range<AttributedString.Index>(sr, in: out) else { return }
            out[ar].foregroundColor = color
        }

        // One pass, earliest match wins, so a quote inside a comment (or // inside a string) is left alone.
        var parts: [String] = []
        if let (open, close) = spec.blockComment {
            parts.append("(?<block>" + NSRegularExpression.escapedPattern(for: open) + "[\\s\\S]*?(?:" +
                         NSRegularExpression.escapedPattern(for: close) + "|$))")
        }
        if !spec.lineComment.isEmpty {
            parts.append("(?<line>(?:" + spec.lineComment.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")[^\\n]*)")
        }
        if spec.strings.contains("\"") { parts.append("(?<triple>\"\"\"[\\s\\S]*?(?:\"\"\"|$))") }
        for q in spec.strings {
            let e = NSRegularExpression.escapedPattern(for: String(q))
            parts.append("(?<s\(q.asciiValue ?? 0)>\(e)(?:\\\\.|[^\(e)\\\\\(q == "`" ? "" : "\\n")])*\(e)?)")
        }
        if spec.markup { parts.append("(?<tag></?[A-Za-z][\\w:-]*)") }
        if spec.variables { parts.append("(?<var>\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?)") }
        parts.append("(?<attr>@[A-Za-z_][A-Za-z0-9_]*)")
        parts.append("(?<num>\\b(?:0x[0-9A-Fa-f_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b)")
        parts.append("(?<word>[A-Za-z_][A-Za-z0-9_]*)")
        guard let re = try? NSRegularExpression(pattern: parts.joined(separator: "|"),
                                                options: lang == "sql" ? [.caseInsensitive] : []) else { return out }

        // Only ask a match about groups the pattern has: an unknown group name raises.
        let included = Set(parts.compactMap { p in p.range(of: "(?<=\\(\\?<)\\w+", options: .regularExpression).map { String(p[$0]) } })
        let stringGroups = (["triple"] + spec.strings.map { "s\($0.asciiValue ?? 0)" }).filter(included.contains)
        for m in re.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
            func has(_ name: String) -> Bool { included.contains(name) && m.range(withName: name).location != NSNotFound }
            if has("block") || has("line") {
                paint(m.range, commentColor)
            } else if stringGroups.contains(where: has) {
                // A JSON/YAML-style key ("name": …) reads better in the key colour.
                let after = m.range.location + m.range.length
                let isKey = (lang.hasPrefix("json") || lang == "yaml" || lang == "yml") && after < ns.length
                    && ns.substring(from: after).drop(while: { $0 == " " }).first == ":"
                paint(m.range, isKey ? keyColor : stringColor)
            } else if has("tag") {
                paint(m.range, keywordColor)
            } else if has("var") {
                paint(m.range, keyColor)
            } else if has("attr") {
                paint(m.range, attributeColor)
            } else if has("num") {
                paint(m.range, numberColor)
            } else if has("word") {
                let w = ns.substring(with: m.range)
                if spec.keywords.contains(lang == "sql" ? w.lowercased() : w) {
                    paint(m.range, keywordColor)
                } else if spec.capitalizedAreTypes, w.first?.isUppercase == true, w.count > 1 {
                    paint(m.range, typeColor)
                } else if (lang == "yaml" || lang == "yml" || lang == "toml"),
                          m.range.location + m.range.length < ns.length,
                          ns.substring(from: m.range.location + m.range.length).first == ":" || ns.substring(from: m.range.location + m.range.length).first == "=" {
                    paint(m.range, keyColor)
                }
            }
        }
        if cache.count > 80 { cache.removeAll() }
        cache[key] = out
        return out
    }
}
