// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import Foundation

/// Approximate matching: a few letters typed in order, not an exact title.
///
/// Typing `tab` finds "Table", `hr` finds "Horizontal Rule". What matters is
/// that the menu finds what is being aimed at without requiring it to be
/// spelled out.
///
/// It lived on `CommandPalette` while the palette existed, and the slash menu
/// borrowed it so that both lists would answer the same gesture the same way.
/// The slash menu is now the only list in the app, and this is a pure
/// function of two strings — testable without an interface.
enum SubsequenceMatch {

    /// Score of a subsequence match, or `nil` if the text does not contain
    /// the letters of the query in order.
    ///
    /// Matches **at the start of a word** are worth more: searching for "mf"
    /// must rank "Mode focus" above "Search for a format". `nonisolated`
    /// Case- **and accent-**insensitive.
    ///
    /// The comparison used to be a plain `lowercased()`: "cafe" would not
    /// find "café", "resume" would not find "résumé". In an app whose titles
    /// are accented as often as not, searching by title would require typing
    /// the exact accent — that is, already knowing what is being searched
    /// for.
    ///
    /// The fallback runs without a locale, so it is identical everywhere:
    /// the result should not depend on the system's language.
    static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    static func score(_ text: String, query: String) -> Int? {
        let haystack = Array(folded(text))
        let needle = Array(folded(query).filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }

        var score = 0
        var index = 0
        var previousWasSeparator = true
        for character in needle {
            var found = false
            while index < haystack.count {
                let candidate = haystack[index]
                let isSeparator = candidate == " " || candidate == "-" || candidate == "'"
                index += 1
                if candidate == character {
                    score += previousWasSeparator ? 10 : 1
                    previousWasSeparator = false
                    found = true
                    break
                }
                previousWasSeparator = isSeparator
            }
            guard found else { return nil }
        }
        return score
    }
}
