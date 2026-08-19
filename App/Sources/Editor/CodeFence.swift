// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import Foundation

/// A code block's opening line, and the language word it carries.
///
/// Fovea has always highlighted about a dozen languages, and offered **no
/// way to pick one**: you had to already know that you write ` ```swift `,
/// i.e. know the syntax the app spends its time hiding. This file resolves
/// that contradiction.
///
/// Everything here is pure: a line, a caret position, and the answer.
enum CodeFence {

    /// What's left to complete on the opening line.
    struct LanguageTrigger: Equatable {
        /// The language word's range in the document — empty when there is
        /// nothing yet after the backticks.
        var range: NSRange
        /// What has already been typed, to filter the list.
        var query: String
    }

    /// Is the caret sitting on the language word of a block's opening fence?
    ///
    /// - Parameters:
    ///   - line: the current line, terminator excluded.
    ///   - lineStart: its offset in the document.
    ///   - caret: the caret's position in the document.
    /// - Returns: `nil` as soon as the line is not an opening fence, or the
    ///   caret is anywhere but in the language word.
    static func languageTrigger(inLine line: String, lineStart: Int, caret: Int) -> LanguageTrigger? {
        let units = Array(line.utf16)
        var index = 0
        // Up to three spaces of indentation are allowed before the fence.
        while index < units.count, index < 3, units[index] == UInt16(UnicodeScalar(" ").value) {
            index += 1
        }
        guard index < units.count else { return nil }
        let fence = units[index]
        guard fence == UInt16(UnicodeScalar("`").value)
                || fence == UInt16(UnicodeScalar("~").value) else { return nil }

        var run = 0
        while index + run < units.count, units[index + run] == fence { run += 1 }
        guard run >= 3 else { return nil }

        let infoStart = index + run
        // The caret must be **after** the fence and on this line. Placing
        // the caret inside the backticks themselves means editing them, not
        // naming a language.
        let caretInLine = caret - lineStart
        guard caretInLine >= infoStart, caretInLine <= units.count else { return nil }

        // A language name contains no space: `csv no header` is a note the
        // author wrote to themselves, not a name to complete.
        let info = String(decoding: units[infoStart...], as: UTF16.self)
        guard !info.contains(" ") else { return nil }

        return LanguageTrigger(range: NSRange(location: lineStart + infoStart,
                                              length: units.count - infoStart),
                               query: String(decoding: units[infoStart..<caretInLine], as: UTF16.self))
    }

    /// The languages offered, in the order they're offered.
    ///
    /// The set is exactly what highlighting knows (§4.3): offering a
    /// language it couldn't highlight would be an empty promise. Aliases
    /// (`js`, `py`) are left out of the list — they're still accepted while
    /// typing, but a menu doesn't need to offer the same thing twice.
    static let languages: [String] = [
        "swift", "javascript", "typescript", "python", "bash",
        "json", "yaml", "css", "html", "sql", "xml",
    ]

    /// The markdown for an empty table of the requested dimensions.
    ///
    /// Placed here rather than in the grid editor: it's text, not interface,
    /// and a test can verify it without opening a window.
    ///
    /// - Returns: the text, and the offset where the caret should land — the
    ///   first cell, the one about to be filled in.
    static func table(columns: Int, rows: Int) -> (markdown: String, caret: Int) {
        let columns = max(1, columns)
        let rows = max(1, rows)
        let header = "|" + String(repeating: "  |", count: columns)
        let rule = "|" + String(repeating: "---|", count: columns)
        let body = "|" + String(repeating: "  |", count: columns)
        let lines = [header, rule] + Array(repeating: body, count: rows)
        return (lines.joined(separator: "\n"), 2)
    }

    /// The languages that match what was typed.
    ///
    /// Prefix first, then the rest: typing `s` should offer `swift` before
    /// `css`, because you're typing the start of a word, not its middle.
    static func matching(_ query: String) -> [String] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return languages }
        let prefixed = languages.filter { $0.hasPrefix(needle) }
        let contained = languages.filter { !$0.hasPrefix(needle) && $0.contains(needle) }
        return prefixed + contained
    }
}
