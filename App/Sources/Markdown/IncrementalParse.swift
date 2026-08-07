// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// Décide **ce qu'il faut ré-analyser** après une frappe.
///
/// # Pourquoi cette classe existe
///
/// Le §3.3 l'annonçait : « reparser 100 000 mots à chaque touche ne tiendra
/// pas ». La mesure lui a donné raison. Sur un document de 10 000 mots, en
/// Debug, un cycle complet coûtait :
///
/// | Étape | Coût |
/// |---|---|
/// | Table des lignes | 1,7 ms |
/// | Analyse (cmark + parcours + conversion) | 36,4 ms |
/// | Pose des attributs | 48,0 ms |
/// | **Total** | **88,5 ms** pour un budget de 8 ms |
///
/// Les deux postes lourds sont proportionnels au document entier alors qu'une
/// frappe n'en change qu'une ligne. Toute l'optimisation tient dans une idée :
/// **ne ré-analyser et ne re-styler que le bloc touché**.
///
/// # Quand ça ne suffit pas
///
/// Un bloc ne peut être traité isolément que si son sens ne dépend pas de ce
/// qui l'entoure. Deux cas cassent cette hypothèse, et déclenchent une analyse
/// complète :
///
/// - **Une clôture de bloc de code.** Taper ` ``` ` change l'interprétation de
///   *tout ce qui suit* : le reste du document devient du code, ou cesse de
///   l'être. C'est le cas le plus fréquent du §6, et le plus visible.
/// - **Une édition à l'intérieur d'un bloc de code existant.** Sa portée
///   dépasse déjà les lignes vides, qui n'y délimitent plus rien.
enum IncrementalParse {

    /// La portée à ré-analyser, ou `nil` s'il faut tout reprendre.
    ///
    /// - Parameters:
    ///   - text: le texte **après** l'édition.
    ///   - editedRange: la plage modifiée, dans le texte après édition.
    ///   - inserted: le texte inséré, pour repérer une clôture de code.
    ///   - existingCodeBlocks: les blocs de code connus **avant** l'édition.
    static func scope(in text: NSString,
                      editedRange: NSRange,
                      inserted: String,
                      existingCodeBlocks: [NSRange]) -> NSRange? {

        // Une clôture de bloc de code rebat les cartes pour tout ce qui suit.
        if inserted.contains("`") || inserted.contains("~") { return nil }

        // Éditer **dans** un bloc de code : les lignes vides n'y délimitent
        // plus rien, la portée par bloc n'a pas de sens.
        if existingCodeBlocks.contains(where: { NSIntersectionRange($0, editedRange).length > 0
                                                || NSLocationInRange(editedRange.location, $0) }) {
            return nil
        }

        var block = blockRange(in: text, around: editedRange)

        // Un bloc de code **voisin** ne justifie pas de tout reprendre, mais il
        // ne peut pas être coupé en deux : un fragment qui commencerait au
        // milieu d'un bloc de code verrait sa clôture de fin sans son ouverture,
        // et lirait le reste comme du code.
        //
        // La première version refusait ces cas et retombait sur l'analyse
        // complète — ce qui, sur un document contenant des blocs de code tous
        // les six paragraphes, revenait à n'avoir aucun incrémental du tout.
        for codeBlock in existingCodeBlocks where NSIntersectionRange(codeBlock, block).length > 0 {
            block = NSUnionRange(block, codeBlock)
        }
        // Élargir a pu faire toucher un nouveau bloc de code : au-delà de la
        // moitié du document, l'analyse complète est de toute façon moins chère
        // que ce jeu de dominos.
        if block.length * 2 >= text.length { return nil }
        return block
    }

    /// Le bloc contenant la plage, délimité par des lignes vides — **et le bloc
    /// voisin de chaque côté**.
    ///
    /// Le voisinage n'est pas de la prudence gratuite. Un titre `setext` est
    /// souligné par la ligne d'après ; une liste dont on supprime la ligne vide
    /// qui la séparait de la suivante fusionne avec elle. Un bloc de marge de
    /// chaque côté couvre ces cas pour un coût négligeable.
    static func blockRange(in text: NSString, around range: NSRange) -> NSRange {
        let start = blockBoundaryBackward(in: text, from: range.location, blocks: 2)
        let end = blockBoundaryForward(in: text, from: min(range.upperBound, text.length), blocks: 2)
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Détails

    /// Remonte jusqu'au début du n-ième bloc précédent.
    private static func blockBoundaryBackward(in text: NSString, from location: Int, blocks: Int) -> Int {
        var index = min(location, text.length)
        var found = 0
        while index > 0 {
            let lineStart = text.lineRange(for: NSRange(location: index - 1, length: 0)).location
            if isBlank(text, lineAt: lineStart) {
                found += 1
                if found >= blocks { return lineStart }
            }
            if lineStart == 0 { return 0 }
            index = lineStart
        }
        return 0
    }

    private static func blockBoundaryForward(in text: NSString, from location: Int, blocks: Int) -> Int {
        var index = min(location, text.length)
        var found = 0
        while index < text.length {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            if isBlank(text, lineAt: line.location) {
                found += 1
                if found >= blocks { return line.upperBound }
            }
            if line.upperBound <= index { return text.length }
            index = line.upperBound
        }
        return text.length
    }

    /// Une ligne blanche : vide, ou uniquement des blancs.
    private static func isBlank(_ text: NSString, lineAt location: Int) -> Bool {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        for offset in line.location..<line.upperBound {
            let unit = text.character(at: offset)
            guard unit == 10 || unit == 13 || unit == 32 || unit == 9 else { return false }
        }
        return true
    }
}

extension MarkdownParser {

    /// Analyse un extrait et **décale ses positions** pour qu'elles désignent
    /// le document entier.
    ///
    /// L'extrait est analysé comme un document à part, ce qui est exactement
    /// l'hypothèse que `IncrementalParse.scope` a vérifiée avant de le
    /// découper : un bloc délimité par des lignes vides se lit sans son
    /// contexte.
    static func parse(_ text: String, offsetBy offset: Int) -> [SyntaxSpan] {
        let spans = offset == 0 ? parse(text).spans : parse(text).spans.map { span in
            var moved = span
            moved.range.location += offset
            moved.content.location += offset
            moved.markers = span.markers.map { NSRange(location: $0.location + offset, length: $0.length) }
            return moved
        }
        // Trié par position, pour que `splice` rende une liste triée et que
        // `SpanIndex` n'ait plus rien à trier. Le fragment est petit : ce tri
        // remplace celui du document entier, à chaque frappe.
        return spans.sorted { $0.range.location < $1.range.location }
    }

    /// Remplace, dans une liste de constructions, celles qui tombaient dans la
    /// portée ré-analysée — et décale celles qui suivent.
    ///
    /// - Parameters:
    ///   - previous: les constructions d'avant l'édition.
    ///   - scope: la portée ré-analysée, en coordonnées **après** l'édition.
    ///   - delta: la variation de longueur du document.
    static func splice(_ previous: [SyntaxSpan],
                       replacing scope: NSRange,
                       with fresh: [SyntaxSpan],
                       delta: Int) -> [SyntaxSpan] {
        // La portée exprimée en coordonnées d'avant l'édition, pour trier les
        // anciennes constructions.
        let oldScopeEnd = scope.upperBound - delta

        // `previous` est trié par position, `fresh` aussi : la concaténation
        // l'est donc également, ce dont `SpanIndex` tire parti.
        var result = previous.filter { $0.range.upperBound <= scope.location }
        result += fresh
        result += previous
            .filter { $0.range.location >= oldScopeEnd }
            .map { span in
                var moved = span
                moved.range.location += delta
                moved.content.location += delta
                moved.markers = span.markers.map { NSRange(location: $0.location + delta, length: $0.length) }
                return moved
            }
        return result
    }
}
