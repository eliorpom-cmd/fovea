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
        let current = text.lineRange(for: NSRange(location: position, length: 0))

        // **Sur une ligne vide, l'unité est cette ligne.**
        //
        // Les deux boucles partaient sinon de part et d'autre du curseur et se
        // rejoignaient nulle part : le paragraphe du dessus **et** celui du
        // dessous restaient en pleine intensité. C'est l'état où l'on se trouve
        // après chaque `⏎ ⏎`, c'est-à-dire à chaque changement de paragraphe.
        guard !isBlank(text, current) else { return current }

        // Un titre est un bloc d'**une** ligne : sans ce cas, il absorbait le
        // paragraphe écrit juste en dessous, et le mode focus laissait les deux
        // en pleine intensité. Un item de liste, lui, peut se continuer sur la
        // ligne suivante — c'est la boucle du bas qui s'en charge.
        if startsHeading(text, current) { return current }

        var start = current.location
        // **Un item de liste et un titre sont leurs propres blocs.**
        //
        // Une liste markdown n'a pas de ligne vide entre ses items : elle était
        // donc **un seul paragraphe**, et comme un item n'a presque jamais de
        // ponctuation forte, l'unité « phrase » retombait dessus. Dix items,
        // mode focus coché, curseur au milieu : aucune atténuation. Le mode
        // avait l'air cassé alors qu'il appliquait sa règle.
        if !startsBlock(text, current) {
            while start > 0 {
                let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
                // Un titre est une frontière qu'on ne franchit pas ; l'item de
                // liste au-dessus, lui, est la tête du bloc où l'on écrit : on
                // le prend, puis on s'arrête.
                if isBlank(text, previous) || startsHeading(text, previous) { break }
                start = previous.location
                if startsListItem(text, previous) { break }
            }
        }

        var end = current.upperBound
        while end < text.length {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            if isBlank(text, next) || startsBlock(text, next) { break }
            end = next.upperBound
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Cette ligne ouvre-t-elle un bloc à elle seule — un titre, un item de
    /// liste ?
    ///
    /// Lue directement sur la `NSString`, sans construire de tableau UTF-16 :
    /// la fonction est appelée pour chaque ligne parcourue, à chaque
    /// déplacement du curseur.
    static func startsBlock(_ text: NSString, _ line: NSRange) -> Bool {
        startsHeading(text, line) || startsListItem(text, line)
    }

    /// Un titre : jusqu'à six « # », puis une espace.
    static func startsHeading(_ text: NSString, _ line: NSRange) -> Bool {
        guard var index = contentStart(text, line) else { return false }
        let limit = line.upperBound
        guard text.character(at: index) == 35 else { return false }
        var hashes = 0
        while index < limit, text.character(at: index) == 35 {
            index += 1
            hashes += 1
        }
        return hashes <= 6 && index < limit && isSpace(text.character(at: index))
    }

    /// Un item de liste : une puce ou un numéro, puis une espace.
    static func startsListItem(_ text: NSString, _ line: NSRange) -> Bool {
        guard var index = contentStart(text, line) else { return false }
        let limit = line.upperBound

        // Une puce : « - », « * » ou « + », puis une espace.
        let first = text.character(at: index)
        if first == 45 || first == 42 || first == 43 {
            return index + 1 < limit && isSpace(text.character(at: index + 1))
        }

        // Un numéro : des chiffres, « . » ou « ) », puis une espace.
        var digits = 0
        while index < limit, text.character(at: index) >= 48, text.character(at: index) <= 57 {
            index += 1
            digits += 1
        }
        guard digits > 0, index < limit else { return false }
        let delimiter = text.character(at: index)
        guard delimiter == 46 || delimiter == 41 else { return false }
        return index + 1 < limit && isSpace(text.character(at: index + 1))
    }

    /// Le premier signe non blanc d'une ligne, si elle en a un et qu'il n'est
    /// pas trop en retrait — au-delà de trois espaces, ce n'est plus un
    /// marqueur de bloc.
    private static func contentStart(_ text: NSString, _ line: NSRange) -> Int? {
        var index = line.location
        var indent = 0
        while index < line.upperBound, isSpace(text.character(at: index)) {
            index += 1
            indent += 1
        }
        guard indent <= 3, index < line.upperBound else { return nil }
        return index
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
    /// Les constructions reçues **ne sont pas garanties de tenir dans le
    /// texte**, et c'est ce qui a fait planter l'app.
    ///
    /// Sur une sélection, l'appelant ramène les constructions aux coordonnées du
    /// fragment sélectionné en les décalant de `-selection.location`. Une
    /// construction qui *commence avant* la sélection — un `**gras**` dont on
    /// n'a pris que la fin, un lien à cheval sur la bordure — se retrouve alors
    /// à une position **négative**, et une qui finit après déborde de l'autre
    /// côté.
    ///
    /// L'ancien bornage écrivait `max(0, début)..<min(units, fin)`. Chaque borne
    /// prise séparément semble prudente ; ensemble, elles s'inversent dès que la
    /// plage tombe entièrement d'un côté ou de l'autre — `0..<-3` — et Swift
    /// arrête le programme. Sélectionner deux paragraphes suffisait à
    /// déclencher un `Range requires lowerBound <= upperBound`, à chaque
    /// mouvement de la souris pendant le glissement.
    ///
    /// D'où l'intersection, qui est ce que les deux bornes voulaient dire.
    private static func clamped(_ range: NSRange, to units: Int) -> Range<Int>? {
        let lower = max(0, range.location)
        let upper = min(units, range.upperBound)
        return lower < upper ? lower..<upper : nil
    }

    static func statistics(of text: String, spans: [SyntaxSpan]) -> Statistics {
        let units = text.utf16.count
        var isSyntax = [Bool](repeating: false, count: units)
        for span in spans {
            for marker in span.markers {
                guard let range = clamped(marker, to: units) else { continue }
                for offset in range { isSyntax[offset] = true }
            }
            // Une URL n'est pas du texte à lire ; le libellé du lien, si.
            if case .link = span.kind {
                let url = NSRange(location: span.content.upperBound,
                                  length: max(0, span.range.upperBound - span.content.upperBound))
                guard let range = clamped(url, to: units) else { continue }
                for offset in range { isSyntax[offset] = true }
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
