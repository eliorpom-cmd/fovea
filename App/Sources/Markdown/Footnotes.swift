// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// Repérage des notes de bas de page, que `swift-markdown` ne parse pas.
///
/// Le cahier des charges (§4.1) posait la question ; la réponse est non :
/// `cmark-gfm` possède bien l'extension, mais `swift-markdown` ne l'expose pas
/// et `[^1]` ressort en `Text` brut. Le motif étant sans la moindre ambiguïté,
/// une passe maison suffit — c'est le repli qui était prévu.
///
/// Ne sont reconnus que les renvois `[^identifiant]` dans le corps du texte.
/// La ligne de définition `[^1]: …` reste du texte ordinaire : elle se lit très
/// bien telle quelle, et lui inventer un rendu ferait disparaître le seul
/// endroit où l'utilisateur peut modifier la note.
enum Footnotes {

    static func scan(utf16: [UInt16], skippingCodeIn verbatim: [NSRange]) -> [SyntaxSpan] {
        let openBracket = UInt16(UnicodeScalar("[").value)
        let caret = UInt16(UnicodeScalar("^").value)
        let closeBracket = UInt16(UnicodeScalar("]").value)
        let backslash = UInt16(UnicodeScalar("\\").value)

        var spans: [SyntaxSpan] = []
        var index = 0
        while index + 3 < utf16.count {
            guard utf16[index] == openBracket, utf16[index + 1] == caret else {
                index += 1
                continue
            }
            // Un `[` échappé n'ouvre rien.
            if index > 0, utf16[index - 1] == backslash {
                index += 1
                continue
            }

            var end = index + 2
            var identifier = ""
            while end < utf16.count, utf16[end] != closeBracket {
                // Un identifiant ne franchit pas une fin de ligne : sans cette
                // borne, un `[` isolé avalerait la moitié du document.
                guard let scalar = UnicodeScalar(utf16[end]), scalar != "\n" else { break }
                identifier.unicodeScalars.append(scalar)
                end += 1
            }
            guard end < utf16.count, utf16[end] == closeBracket, !identifier.isEmpty else {
                index += 1
                continue
            }

            let range = NSRange(location: index, length: end - index + 1)
            if verbatim.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                index = end + 1
                continue
            }
            // La **définition** `[^1]: …` en début de ligne reste du texte
            // ordinaire (§4.1). Elle se lit très bien telle quelle, et lui
            // inventer un rendu ferait disparaître le seul endroit où
            // l'utilisateur peut modifier la note.
            if isDefinition(utf16: utf16, referenceStart: index, referenceEnd: end) {
                index = end + 1
                continue
            }

            // Les crochets sont la syntaxe, l'identifiant est le contenu : il
            // se rend en exposant. Tout masquer ferait disparaître le renvoi de
            // l'écran, et l'auteur n'aurait plus aucun repère vers sa note.
            spans.append(SyntaxSpan(
                kind: .footnoteReference(identifier: identifier),
                range: range,
                markers: [NSRange(location: index, length: 2),
                          NSRange(location: end, length: 1)],
                content: NSRange(location: index + 2, length: end - index - 2)))
            index = end + 1
        }
        return spans
    }

    /// Vrai si le motif est une **définition** et non un renvoi : seul du blanc
    /// le précède sur sa ligne, et un `:` le suit immédiatement.
    private static func isDefinition(utf16: [UInt16], referenceStart: Int, referenceEnd: Int) -> Bool {
        let colon = UInt16(UnicodeScalar(":").value)
        guard referenceEnd + 1 < utf16.count, utf16[referenceEnd + 1] == colon else { return false }

        let newline = UInt16(UnicodeScalar("\n").value)
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        var cursor = referenceStart - 1
        while cursor >= 0 {
            let unit = utf16[cursor]
            if unit == newline { return true }
            guard unit == space || unit == tab else { return false }
            cursor -= 1
        }
        return true
    }
}
