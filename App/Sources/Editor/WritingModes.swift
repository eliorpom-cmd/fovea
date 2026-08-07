// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Les fonctions d'écriture du §4.5 : mode focus, machine à écrire,
/// statistiques.
///
/// Toute la partie calculable est ici, en fonctions pures : quelle est l'unité
/// courante, combien de mots, où doit se trouver la ligne active. La partie
/// AppKit se réduit à poser une opacité et à faire défiler.
enum WritingModes {

    // MARK: - Mode focus

    /// La plage à laisser en pleine intensité, tout le reste étant atténué.
    ///
    /// - Parameter unit: phrase ou paragraphe, au choix de l'utilisateur.
    static func focusRange(in text: NSString, caret: Int, unit: AppSettings.FocusUnit) -> NSRange {
        switch unit {
        case .paragraph:
            return paragraphRange(in: text, containing: caret)
        case .sentence:
            return sentenceRange(in: text, containing: caret)
        }
    }

    /// Le paragraphe : délimité par des lignes vides, et non par un simple
    /// saut de ligne.
    ///
    /// Un document markdown est presque toujours coupé à la main autour de 80
    /// signes. Prendre la ligne pour le paragraphe atténuerait la moitié de la
    /// phrase qu'on est en train d'écrire.
    static func paragraphRange(in text: NSString, containing caret: Int) -> NSRange {
        let position = min(max(0, caret), text.length)
        var start = text.lineRange(for: NSRange(location: position, length: 0)).location
        while start > 0 {
            let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
            if isBlank(text, previous) { break }
            start = previous.location
        }
        var end = text.lineRange(for: NSRange(location: position, length: 0)).upperBound
        while end < text.length {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            if isBlank(text, next) { break }
            end = next.upperBound
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// La phrase, bornée par son paragraphe.
    ///
    /// La ponctuation forte fait la frontière, mais pas quand elle suit une
    /// abréviation courante : « M. Dupont » ou « etc. » ne terminent pas une
    /// phrase, et l'atténuation clignoterait au milieu d'un mot.
    static func sentenceRange(in text: NSString, containing caret: Int) -> NSRange {
        let paragraph = paragraphRange(in: text, containing: caret)
        guard paragraph.length > 0 else { return paragraph }
        let position = min(max(paragraph.location, caret), paragraph.upperBound)

        var start = paragraph.location
        var index = paragraph.location
        var lastBoundary = paragraph.location
        while index < paragraph.upperBound {
            let character = text.character(at: index)
            if character == 46 || character == 33 || character == 63 { // . ! ?
                var after = index + 1
                while after < paragraph.upperBound,
                      isSpace(text.character(at: after)) || isClosingPunctuation(text.character(at: after)) {
                    after += 1
                }
                if after > position { break }
                if !endsWithAbbreviation(text, endingAt: index) {
                    lastBoundary = after
                }
            }
            index += 1
        }
        start = lastBoundary

        var end = paragraph.upperBound
        index = max(start, position)
        while index < paragraph.upperBound {
            let character = text.character(at: index)
            if character == 46 || character == 33 || character == 63,
               !endsWithAbbreviation(text, endingAt: index) {
                var after = index + 1
                while after < paragraph.upperBound, isClosingPunctuation(text.character(at: after)) {
                    after += 1
                }
                end = after
                break
            }
            index += 1
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Statistiques

    struct Statistics: Equatable {
        var words: Int
        var characters: Int
        /// Minutes, arrondies au supérieur, jamais nulles pour un texte non vide.
        var readingMinutes: Int
    }

    /// Compte les mots comme un lecteur les compterait.
    ///
    /// La syntaxe markdown est exclue : les `#` d'un titre, les `**` d'un mot
    /// gras et l'URL d'un lien ne sont pas des mots. Compter la source donnerait
    /// un total qui n'a de sens pour personne — et qui gonflerait à chaque
    /// formatage.
    static func statistics(of text: String, spans: [SyntaxSpan]) -> Statistics {
        let units = text.utf16.count
        var isSyntax = [Bool](repeating: false, count: units)
        for span in spans {
            for marker in span.markers {
                for offset in max(0, marker.location)..<min(units, marker.upperBound) {
                    isSyntax[offset] = true
                }
            }
            // Une URL n'est pas du texte à lire ; le libellé du lien, si.
            if case .link = span.kind {
                for offset in max(0, span.content.upperBound)..<min(units, span.range.upperBound) {
                    isSyntax[offset] = true
                }
            }
        }

        var words = 0
        var characters = 0
        var inWord = false
        let string = text as NSString
        for offset in 0..<units where !isSyntax[offset] {
            let character = string.character(at: offset)
            if isSpace(character) || character == 10 {
                inWord = false
            } else {
                characters += 1
                if !inWord { words += 1; inWord = true }
            }
        }

        // 200 mots par minute : la vitesse de lecture silencieuse couramment
        // retenue pour de la prose.
        let minutes = words == 0 ? 0 : max(1, Int((Double(words) / 200).rounded(.up)))
        return Statistics(words: words, characters: characters, readingMinutes: minutes)
    }

    // MARK: - Détails

    private static func isBlank(_ text: NSString, _ line: NSRange) -> Bool {
        for offset in line.location..<line.upperBound {
            let character = text.character(at: offset)
            guard character == 10 || character == 13 || character == 32 || character == 9 else { return false }
        }
        return true
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 32 || character == 9 || character == 160
    }

    private static func isClosingPunctuation(_ character: unichar) -> Bool {
        character == 34 || character == 39 || character == 41 || character == 93 // " ' ) ]
            || character == 0x00BB || character == 0x201D // » ”
    }

    /// « M. », « etc. », « cf. » : une ponctuation forte qui ne termine rien.
    private static func endsWithAbbreviation(_ text: NSString, endingAt dotIndex: Int) -> Bool {
        let abbreviations = ["M", "Mme", "Mlle", "Dr", "St", "etc", "cf", "ex", "p", "vol", "no", "n°"]
        var start = dotIndex
        while start > 0 {
            let character = text.character(at: start - 1)
            guard !isSpace(character), character != 10 else { break }
            start -= 1
        }
        guard start < dotIndex else { return false }
        let word = text.substring(with: NSRange(location: start, length: dotIndex - start))
        return abbreviations.contains(word)
    }
}
