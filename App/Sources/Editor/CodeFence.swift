// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// La ligne d'ouverture d'un bloc de code, et le mot de langage qu'elle porte.
///
/// Fovea colore une dizaine de langages depuis toujours, et n'offrait **aucun
/// moyen d'en choisir un** : il fallait savoir qu'on écrit ` ```swift `, donc
/// connaître la syntaxe que l'app passe son temps à masquer. C'est la
/// contradiction que ce fichier lève.
///
/// Tout y est pur : une ligne, une position de curseur, et la réponse.
enum CodeFence {

    /// Ce qu'il y a à compléter sur la ligne d'ouverture.
    struct LanguageTrigger: Equatable {
        /// La plage du mot de langage dans le document — vide quand il n'y a
        /// encore rien après les accents graves.
        var range: NSRange
        /// Ce qui a déjà été tapé, pour filtrer la liste.
        var query: String
    }

    /// Le curseur est-il posé sur le mot de langage d'une ouverture de bloc ?
    ///
    /// - Parameters:
    ///   - line: la ligne courante, terminateur exclu.
    ///   - lineStart: son offset dans le document.
    ///   - caret: la position du curseur dans le document.
    /// - Returns: `nil` dès que la ligne n'est pas une ouverture, ou que le
    ///   curseur est ailleurs que dans le mot de langage.
    static func languageTrigger(inLine line: String, lineStart: Int, caret: Int) -> LanguageTrigger? {
        let units = Array(line.utf16)
        var index = 0
        // Jusqu'à trois espaces d'indentation sont permis avant la clôture.
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
        // Le curseur doit être **après** la clôture et sur cette ligne. Poser
        // le curseur dans les accents graves eux-mêmes, c'est vouloir les
        // modifier, pas nommer un langage.
        let caretInLine = caret - lineStart
        guard caretInLine >= infoStart, caretInLine <= units.count else { return nil }

        // Un langage ne contient pas d'espace : `csv sans en-tête` est une note
        // que l'auteur s'est écrite, pas un nom à compléter.
        let info = String(decoding: units[infoStart...], as: UTF16.self)
        guard !info.contains(" ") else { return nil }

        return LanguageTrigger(range: NSRange(location: lineStart + infoStart,
                                              length: units.count - infoStart),
                               query: String(decoding: units[infoStart..<caretInLine], as: UTF16.self))
    }

    /// Les langages proposés, dans l'ordre où on les propose.
    ///
    /// Le jeu est celui que la coloration connaît (§4.3) : proposer un langage
    /// qu'on ne saurait pas colorer serait une promesse en l'air. Les alias
    /// (`js`, `py`) sont écartés de la liste — ils restent acceptés à la
    /// frappe, mais un menu n'a pas à proposer deux fois la même chose.
    static let languages: [String] = [
        "swift", "javascript", "typescript", "python", "bash",
        "json", "yaml", "css", "html", "sql", "xml",
    ]

    /// Le markdown d'un tableau vide aux dimensions demandées.
    ///
    /// Placé ici plutôt que dans le damier : c'est du texte, pas de
    /// l'interface, et un test le vérifie sans ouvrir de fenêtre.
    ///
    /// - Returns: le texte, et l'offset où poser le curseur — la première
    ///   cellule, celle qu'on va remplir.
    static func table(columns: Int, rows: Int) -> (markdown: String, caret: Int) {
        let columns = max(1, columns)
        let rows = max(1, rows)
        let header = "|" + String(repeating: "  |", count: columns)
        let rule = "|" + String(repeating: "---|", count: columns)
        let body = "|" + String(repeating: "  |", count: columns)
        let lines = [header, rule] + Array(repeating: body, count: rows)
        return (lines.joined(separator: "\n"), 2)
    }

    /// Les langages qui correspondent à ce qui a été tapé.
    ///
    /// Le préfixe d'abord, puis le reste : taper `s` doit proposer `swift`
    /// avant `css`, parce qu'on tape le début d'un mot, pas son milieu.
    static func matching(_ query: String) -> [String] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return languages }
        let prefixed = languages.filter { $0.hasPrefix(needle) }
        let contained = languages.filter { !$0.hasPrefix(needle) && $0.contains(needle) }
        return prefixed + contained
    }
}
