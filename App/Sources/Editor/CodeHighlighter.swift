// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Coloration syntaxique des blocs de code.
///
/// # Pourquoi rien n'est embarqué
///
/// Le §4.3 tranche : **aucune dépendance**. Ni Highlightr, qui embarque
/// JavaScriptCore pour faire tourner highlight.js dans une app d'écriture, ni
/// tree-sitter, qui impose de compiler des grammaires C et d'en suivre les
/// versions. Dans un éditeur de prose un bloc de code fait dix lignes ; la
/// précision d'un vrai analyseur n'y apporte rien de perceptible, et son coût
/// est permanent.
///
/// # Quatre catégories, pas quarante
///
/// En monochrome — le défaut — la coloration ne dispose que de la graisse et de
/// l'opacité. Quatre catégories sont donc tout ce qu'on peut distinguer, et
/// c'est tout ce dont on a besoin pour rendre un extrait lisible : ce qui est
/// structurel (mot-clé), ce qui est une donnée (chaîne, nombre), et ce qui est
/// du commentaire.
///
/// Un langage inconnu se rend en chasse fixe sans coloration. Jamais d'erreur,
/// jamais de bloc vide (§4.3).
enum CodeHighlighter {

    enum Category {
        case keyword
        case string
        case comment
        case number
    }

    /// La palette **par défaut** : monochrome (§7). Le sens passe par la
    /// graisse et l'opacité, jamais par la teinte.
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

    /// La palette **en couleurs**, activable dans les réglages.
    ///
    /// C'est le seul endroit de l'app où la couleur est autorisée, et seulement
    /// sur demande explicite de l'utilisateur (§4.3). Les teintes sont
    /// délibérément sourdes : un bloc de code ne doit pas devenir le point le
    /// plus vif d'une page de prose.
    static func colorAttributes(for category: Category, font: NSFont) -> [NSAttributedString.Key: Any] {
        switch category {
        case .keyword:
            [.foregroundColor: adaptive(light: 0x8B2A6B, dark: 0xE08CC4)]
        case .string:
            [.foregroundColor: adaptive(light: 0x1E6B3A, dark: 0x8CD6A4)]
        case .comment:
            [.font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask),
             .foregroundColor: adaptive(light: 0x6B6B6B, dark: 0x8A8A8A)]
        case .number:
            [.foregroundColor: adaptive(light: 0x1E4F8B, dark: 0x8CB8E0)]
        }
    }

    // MARK: - Analyse

    /// Découpe un extrait en catégories, dans l'ordre où elles apparaissent.
    ///
    /// - Parameter offset: position du bloc dans le tampon, pour que les plages
    ///   renvoyées soient directement utilisables sur `NSTextStorage`.
    static func categorize(_ code: String, language: String?, offset: Int) -> [(NSRange, Category)] {
        guard let grammar = Grammar.named(language) else { return [] }
        var result: [(NSRange, Category)] = []
        let units = Array(code.utf16)

        var index = 0
        while index < units.count {
            // Les commentaires et les chaînes d'abord : ce qui est dedans n'est
            // plus du code, et un `//` dans une chaîne ne commente rien.
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

    // MARK: - Grammaires

    /// Une grammaire est une liste de mots-clés et une manière de reconnaître
    /// les commentaires et les chaînes. C'est tout ce que quatre catégories
    /// demandent.
    struct Grammar {
        var keywords: Set<String>
        var lineComment: String?
        var blockComment: (open: String, close: String)?
        var stringDelimiters: [Character]
        /// Le caractère d'échappement à l'intérieur d'une chaîne.
        var escape: Character? = "\\"

        static func named(_ language: String?) -> Grammar? {
            guard let language else { return nil }
            return all[language.lowercased()]
        }

        /// Reconnaît un commentaire ou une chaîne commençant à cet index.
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
                    // Une chaîne non fermée s'arrête en fin de ligne plutôt que
                    // d'avaler le reste du bloc : c'est le cas normal pendant
                    // la frappe.
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

        /// Le jeu fermé du §4.3. Assez pour la documentation technique qu'on
        /// écrit dans un éditeur de prose, et rien de plus.
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

    // MARK: - Caractères

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

    private static func adaptive(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }
}
