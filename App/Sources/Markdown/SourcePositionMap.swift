// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// Convertit les positions de `swift-markdown` en offsets de `NSTextStorage`.
///
/// # Pourquoi cette classe existe
///
/// Les deux côtés ne comptent pas dans la même unité :
///
/// | | Unité | « é » | « 🙂 » |
/// |---|---|---|---|
/// | `swift-markdown` (cmark) | **octets UTF-8** | 2 | 4 |
/// | `NSTextStorage` | **unités UTF-16** | 1 | 2 |
///
/// Une conversion naïve — traiter la colonne comme un index de caractère —
/// désaligne tous les attributs dès la première lettre accentuée. Sur un texte
/// français, c'est-à-dire tout de suite. Le §3.3 du cahier des charges l'avait
/// identifié comme non négociable ; c'est ici que la promesse est tenue, et
/// `SourcePositionMapTests` la vérifie sur de l'accentué, des emoji et du CJK.
///
/// # Ce que ça coûte
///
/// Le tableau des lignes est construit en une passe à chaque reparse complet.
/// Une ligne purement ASCII — la majorité, même en français, dès qu'on compte
/// la ponctuation et les blancs — se convertit par une addition, sans parcours.
/// Les autres sont parcourues scalaire par scalaire, sur une longueur de ligne,
/// pas de document.
struct SourcePositionMap {

    private struct Line {
        /// Offset UTF-16 du premier caractère de la ligne, depuis le début du texte.
        let utf16Start: Int
        /// Index du premier scalaire de la ligne, pour le parcours.
        let scalarStart: String.UnicodeScalarView.Index
        /// Longueur de la ligne en unités UTF-16, terminateur exclu.
        let utf16Length: Int
        /// Vrai si la ligne ne contient que de l'ASCII : octets et unités
        /// coïncident, la conversion est une addition.
        let isASCII: Bool
    }

    private let scalars: String.UnicodeScalarView
    private let lines: [Line]

    /// Longueur totale du texte en unités UTF-16.
    let utf16Length: Int

    init(text: String) {
        self.scalars = text.unicodeScalars

        var built: [Line] = []
        built.reserveCapacity(256)

        var utf16Offset = 0
        var lineStartUTF16 = 0
        var lineStartIndex = scalars.startIndex
        var lineIsASCII = true

        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\n" {
                built.append(Line(utf16Start: lineStartUTF16,
                                  scalarStart: lineStartIndex,
                                  utf16Length: utf16Offset - lineStartUTF16,
                                  isASCII: lineIsASCII))
                utf16Offset += 1 // le saut de ligne lui-même
                index = scalars.index(after: index)
                lineStartUTF16 = utf16Offset
                lineStartIndex = index
                lineIsASCII = true
                continue
            }
            if !scalar.isASCII { lineIsASCII = false }
            utf16Offset += UTF16.width(scalar)
            index = scalars.index(after: index)
        }

        // La dernière ligne, qui n'est pas terminée par un saut de ligne. Elle
        // existe même quand le texte est vide : cmark numérote à partir de 1 et
        // référencerait une ligne 1 inexistante sans elle.
        built.append(Line(utf16Start: lineStartUTF16,
                          scalarStart: lineStartIndex,
                          utf16Length: utf16Offset - lineStartUTF16,
                          isASCII: lineIsASCII))

        self.lines = built
        self.utf16Length = utf16Offset
    }

    /// Nombre de lignes, en comptant la dernière même si elle est vide.
    var lineCount: Int { lines.count }

    /// Offset UTF-16 d'une position `swift-markdown`.
    ///
    /// - Parameters:
    ///   - line: numéro de ligne **à partir de 1**, comme cmark.
    ///   - column: numéro de colonne **à partir de 1**, compté en **octets UTF-8**.
    ///
    /// Les positions hors bornes sont ramenées dans le texte plutôt que de
    /// déclencher une erreur : cmark place parfois la fin d'un nœud une colonne
    /// après le dernier caractère d'une ligne, et ce n'est pas un défaut à
    /// signaler mais une convention à absorber.
    func utf16Offset(line: Int, column: Int) -> Int {
        guard line >= 1 else { return 0 }
        guard line <= lines.count else { return utf16Length }

        let target = lines[line - 1]
        let byteOffset = max(0, column - 1)

        if target.isASCII {
            return target.utf16Start + min(byteOffset, target.utf16Length)
        }

        var bytesSeen = 0
        var unitsSeen = 0
        var index = target.scalarStart
        while bytesSeen < byteOffset, index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\n" { break }
            bytesSeen += UTF8.width(scalar)
            unitsSeen += UTF16.width(scalar)
            index = scalars.index(after: index)
        }
        return target.utf16Start + min(unitsSeen, target.utf16Length)
    }

    /// Plage UTF-16 correspondant à un intervalle de positions cmark.
    ///
    /// La borne de fin de `swift-markdown` est **exclusive** — vérifié sur la
    /// bibliothèque, pas supposé : `"ab **cd** ef"` donne pour le `Strong` les
    /// colonnes 4 → 10, soit les octets 3 à 8 inclus, c'est-à-dire exactement
    /// les six octets de `**cd**`. Elle se transpose donc telle quelle en plage
    /// Cocoa, sans ajouter la largeur du dernier caractère.
    func range(fromLine: Int, fromColumn: Int, toLine: Int, toColumn: Int) -> NSRange {
        let start = utf16Offset(line: fromLine, column: fromColumn)
        let end = max(start, utf16Offset(line: toLine, column: toColumn))
        return NSRange(location: start, length: end - start)
    }

    /// Plage UTF-16 de la ligne contenant `location`, terminateur **exclu**.
    /// Sert aux constructions à portée ligne du §2.2.
    func lineRange(containing location: Int) -> NSRange {
        let line = lines[lineIndex(containing: location)]
        return NSRange(location: line.utf16Start, length: line.utf16Length)
    }

    /// Recherche dichotomique. Appelée à chaque déplacement du curseur, donc
    /// sur le trajet le plus sensible de l'app.
    private func lineIndex(containing location: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        var found = 0
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].utf16Start <= location {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }
}
