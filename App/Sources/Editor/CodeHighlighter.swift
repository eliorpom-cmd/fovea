// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import AppKit

/// Syntax highlighting for code blocks.
///
/// # Why nothing is bundled
///
/// §4.3 settles it: **no dependency**. Not Highlightr, which bundles
/// JavaScriptCore to run highlight.js inside a writing app; not tree-sitter,
/// which requires compiling C grammars and tracking their versions. In a
/// prose editor a code block runs ten lines; the precision of a real parser
/// adds nothing perceptible to that, and its cost is permanent.
///
/// # Four categories, not forty
///
/// In monochrome — the default — highlighting has only weight and opacity to
/// work with. Four categories are therefore all that can be distinguished,
/// and that's all it takes to make a snippet readable: what is structural
/// (keyword), what is data (string, number), and what is a comment.
///
/// An unknown language renders in monospaced type with no highlighting.
/// Never an error, never an empty block (§4.3).
enum CodeHighlighter {

    enum Category {
        case keyword
        case string
        case comment
        case number
    }

    /// The palette: monochrome (§7). Meaning is carried by weight and
    /// opacity, never by hue.
    ///
    /// There used to be a colour palette too, behind a setting. It was the
    /// only place in the app where colour was allowed, and the only setting
    /// whose change forced a full re-render.
    static func monochromeAttributes(for category: Category, font: NSFont) -> [NSAttributedString.Key: Any] {
        switch category {
        case .keyword:
            [.font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
             .foregroundColor: Theme.NS.label]
        case .string:
            [.foregroundColor: Theme.NS.labelSecondary]
        case .comment:
            [.font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask),
             .foregroundColor: Theme.NS.labelTertiary]
        case .number:
            [.foregroundColor: Theme.NS.labelSecondary]
        }
    }

    // MARK: - Parsing

    /// Splits a snippet into categories, in the order they appear.
    ///
    /// - Parameter offset: the block's position in the buffer, so the
    ///   returned ranges are directly usable on `NSTextStorage`.
    static func categorize(_ code: String, language: String?, offset: Int) -> [(NSRange, Category)] {
        guard let grammar = Grammar.named(language) else { return [] }
        var result: [(NSRange, Category)] = []
        let units = Array(code.utf16)

        var index = 0
        while index < units.count {
            // Comments and strings first: what's inside them is no longer
            // code, and a `//` inside a string comments out nothing.
            if let (length, category) = grammar.matchVerbatim(units, at: index) {
                result.append((NSRange(location: offset + index, length: length), category))
                index += length
                continue
            }
            if isIdentifierStart(units[index]) {
                var end = index
                while end < units.count, isIdentifierPart(units[end]) { end += 1 }
                let word = String(decoding: units[index..<end], as: UTF16.self)
                if grammar.keywords.contains(word) {
                    result.append((NSRange(location: offset + index, length: end - index), .keyword))
                }
                index = end
                continue
            }
            if isDigit(units[index]), index == 0 || !isIdentifierPart(units[index - 1]) {
                var end = index
                while end < units.count, isDigit(units[end]) || units[end] == dot || isHexLetter(units[end]) {
                    end += 1
                }
                result.append((NSRange(location: offset + index, length: end - index), .number))
                index = end
                continue
            }
            index += 1
        }
        return result
    }

    // MARK: - Grammars

    /// A grammar is a list of keywords and a way to recognize comments and
    /// strings. That's all four categories require.
    struct Grammar {
        var keywords: Set<String>
        var lineComment: String?
        var blockComment: (open: String, close: String)?
        var stringDelimiters: [Character]
        /// The escape character inside a string.
        var escape: Character? = "\\"

        static func named(_ language: String?) -> Grammar? {
            guard let language else { return nil }
            return all[language.lowercased()]
        }

        /// Recognizes a comment or a string starting at this index.
        func matchVerbatim(_ units: [UInt16], at index: Int) -> (length: Int, category: Category)? {
            if let lineComment, matches(units, at: index, text: lineComment) {
                var end = index
                while end < units.count, units[end] != newline { end += 1 }
                return (end - index, .comment)
            }
            if let blockComment, matches(units, at: index, text: blockComment.open) {
                var end = index + blockComment.open.utf16.count
                while end < units.count, !matches(units, at: end, text: blockComment.close) { end += 1 }
                let close = min(end + blockComment.close.utf16.count, units.count)
                return (close - index, .comment)
            }
            for delimiter in stringDelimiters {
                let unit = Array(String(delimiter).utf16)[0]
                guard units[index] == unit else { continue }
                var end = index + 1
                while end < units.count {
                    // An unclosed string stops at the end of the line rather
                    // than swallowing the rest of the block: that's the
                    // normal case while typing.
                    if units[end] == newline { break }
                    if let escape, units[end] == Array(String(escape).utf16)[0] {
                        end += 2
                        continue
                    }
                    if units[end] == unit { end += 1; break }
                    end += 1
                }
                return (end - index, .string)
            }
            return nil
        }

        private func matches(_ units: [UInt16], at index: Int, text: String) -> Bool {
            let pattern = Array(text.utf16)
            guard index + pattern.count <= units.count else { return false }
            for offset in 0..<pattern.count where units[index + offset] != pattern[offset] {
                return false
            }
            return true
        }

        /// The closed set from §4.3. Enough for the technical documentation
        /// written in a prose editor, and nothing more.
        static let all: [String: Grammar] = {
            let cLike = Grammar(keywords: [], lineComment: "//",
                                blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'"])

            var swift = cLike
            swift.keywords = ["import", "let", "var", "func", "class", "struct", "enum", "protocol",
                              "extension", "if", "else", "guard", "return", "for", "in", "while",
                              "switch", "case", "default", "break", "continue", "static", "private",
                              "public", "internal", "fileprivate", "open", "final", "init", "deinit",
                              "self", "super", "nil", "true", "false", "throw", "throws", "try",
                              "catch", "do", "defer", "where", "as", "is", "async", "await", "actor",
                              "some", "any", "typealias", "inout", "lazy", "weak", "unowned", "override"]

            var javascript = cLike
            javascript.keywords = ["const", "let", "var", "function", "class", "extends", "return",
                                   "if", "else", "for", "while", "switch", "case", "default", "break",
                                   "continue", "new", "this", "null", "undefined", "true", "false",
                                   "import", "export", "from", "async", "await", "try", "catch",
                                   "throw", "typeof", "instanceof", "of", "in", "delete", "yield"]
            javascript.stringDelimiters = ["\"", "'", "`"]

            var typescript = javascript
            typescript.keywords.formUnion(["interface", "type", "enum", "implements", "readonly",
                                           "public", "private", "protected", "abstract", "namespace",
                                           "declare", "as", "satisfies", "keyof", "infer"])

            var python = Grammar(keywords: ["def", "class", "return", "if", "elif", "else", "for",
                                            "while", "break", "continue", "import", "from", "as",
                                            "try", "except", "finally", "raise", "with", "lambda",
                                            "None", "True", "False", "and", "or", "not", "in", "is",
                                            "pass", "yield", "global", "nonlocal", "assert", "async",
                                            "await", "del"],
                                 lineComment: "#", blockComment: nil,
                                 stringDelimiters: ["\"", "'"])
            python.escape = "\\"

            let bash = Grammar(keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do",
                                          "done", "case", "esac", "function", "return", "export",
                                          "local", "readonly", "set", "echo", "cd", "source", "exit"],
                               lineComment: "#", blockComment: nil,
                               stringDelimiters: ["\"", "'"])

            let json = Grammar(keywords: ["true", "false", "null"],
                               lineComment: nil, blockComment: nil,
                               stringDelimiters: ["\""])

            let yaml = Grammar(keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                               lineComment: "#", blockComment: nil,
                               stringDelimiters: ["\"", "'"])

            let css = Grammar(keywords: ["important", "media", "import", "keyframes", "supports",
                                         "font-face", "root"],
                              lineComment: nil, blockComment: ("/*", "*/"),
                              stringDelimiters: ["\"", "'"])

            let html = Grammar(keywords: [],
                               lineComment: nil, blockComment: ("<!--", "-->"),
                               stringDelimiters: ["\"", "'"])

            let sql = Grammar(keywords: ["select", "from", "where", "insert", "into", "values",
                                         "update", "set", "delete", "create", "table", "drop",
                                         "alter", "join", "left", "right", "inner", "outer", "on",
                                         "group", "order", "by", "having", "limit", "offset",
                                         "and", "or", "not", "null", "as", "distinct", "union"],
                              lineComment: "--", blockComment: ("/*", "*/"),
                              stringDelimiters: ["'", "\""])

            return [
                "swift": swift,
                "js": javascript, "javascript": javascript, "jsx": javascript,
                "ts": typescript, "typescript": typescript, "tsx": typescript,
                "python": python, "py": python,
                "bash": bash, "sh": bash, "shell": bash, "zsh": bash,
                "json": json,
                "yaml": yaml, "yml": yaml,
                "css": css,
                "html": html, "xml": html,
                "sql": sql,
            ]
        }()
    }

    // MARK: - Characters

    private static let newline = UInt16(UnicodeScalar("\n").value)
    private static let dot = UInt16(UnicodeScalar(".").value)

    private static func isIdentifierStart(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.letters.contains(scalar) || scalar == "_"
    }

    private static func isIdentifierPart(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= 48 && unit <= 57
    }

    private static func isHexLetter(_ unit: UInt16) -> Bool {
        (unit >= 97 && unit <= 102) || (unit >= 65 && unit <= 70) || unit == 120 // a-f A-F x
    }
}
