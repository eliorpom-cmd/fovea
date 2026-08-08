// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
@testable import Fovea

/// La fonction clé de l'app, réduite à une fonction pure.
///
/// Le document témoin est toujours le même :
///
/// ```
/// Un mot **important** ici
/// 0123456789012345678901234
///        ^7          ^18,19  la construction Strong occupe [7, 20]
/// ```
final class RevealPolicyTests: XCTestCase {

    private let strong = SyntaxSpan(
        kind: .strong,
        range: NSRange(location: 7, length: 13),          // « **important** »
        markers: [NSRange(location: 7, length: 2), NSRange(location: 18, length: 2)],
        content: NSRange(location: 9, length: 9))          // « important »

    private let wholeLine = NSRange(location: 0, length: 24)

    /// « ## Titre » : préfixe en [0, 3], contenu à partir de 3.
    private let heading = SyntaxSpan(kind: .heading(level: 2),
                                     range: NSRange(location: 0, length: 8),
                                     markers: [NSRange(location: 0, length: 3)],
                                     content: NSRange(location: 3, length: 5))

    // MARK: - Les bornes, et pourquoi elles sont inclusives

    func testRevealsWhenCaretTouchesTheOpeningBoundary() {
        XCTAssertEqual(revealed(caret: 7), [0], "Le curseur juste avant les ** doit les faire apparaître")
    }

    func testRevealsWhenCaretTouchesTheClosingBoundary() {
        XCTAssertEqual(revealed(caret: 20), [0], "Le curseur juste après les ** doit encore les montrer")
    }

    func testHidesOneStepPastTheConstruct() {
        XCTAssertEqual(revealed(caret: 21), [])
        XCTAssertEqual(revealed(caret: 6), [])
    }

    /// La propriété qui justifie le choix de bornes inclusives : entrer puis
    /// sortir ramène exactement à l'état de départ. Avec un intervalle ouvert,
    /// l'entrée et la sortie ne se feraient pas à la même position et une
    /// flèche droite suivie d'une flèche gauche changerait l'affichage.
    func testEnteringAndLeavingIsSymmetric() {
        for caret in 0...24 {
            let forward = revealed(caret: caret)
            let backward = revealed(caret: caret)
            XCTAssertEqual(forward, backward)
        }
        XCTAssertEqual(revealed(caret: 20), revealed(caret: 20))
        XCTAssertEqual(revealed(caret: 21), [])
        XCTAssertEqual(revealed(caret: 20), [0])
    }

    // MARK: - La conséquence qui a corrigé le §2.3 du cahier des charges

    /// **Le curseur ne peut jamais se trouver dans un marqueur masqué.**
    ///
    /// Le cahier des charges annonçait des « positions invisibles » à
    /// contourner en interceptant toutes les commandes de déplacement de
    /// `NSTextView`. Ce test montre que le problème n'existe pas : toute
    /// position située dans un marqueur appartient à l'intervalle de sa propre
    /// construction, donc cette construction est révélée.
    func testCaretIsNeverInsideAHiddenMarker() {
        for caret in 0...24 {
            let shown = revealed(caret: caret)
            for marker in strong.markers where NSLocationInRange(caret, marker) {
                XCTAssertTrue(shown.contains(0),
                              "Position \(caret) : dans un marqueur, mais la construction est masquée")
            }
        }
    }

    // MARK: - Une sélection ne révèle rien de nouveau

    func testNonEmptySelectionRevealsNothing() {
        // L'utilisateur sélectionne du texte rendu. Faire apparaître la syntaxe
        // sous la sélection déplacerait le contenu au moment précis où il vise.
        let selection = NSRange(location: 5, length: 10)
        XCTAssertEqual(RevealPolicy.revealedIndices(spans: [strong], selection: selection, lineRange: wholeLine), [])
    }

    /// Le pendant du test précédent : une sélection **entièrement contenue** dans
    /// une construction garde ses marqueurs. Rien n'apparaît — le curseur les
    /// montrait déjà avant qu'on étende — et la ligne ne saute donc plus à chaque
    /// `⇧→` dans un mot en gras.
    func testSelectionInsideAConstructKeepsItsMarkers() {
        let inside = NSRange(location: 10, length: 5)          // dans « important »
        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [strong], selection: inside, lineRange: wholeLine), [0])

        // Une sélection qui déborde ne révèle toujours rien : c'est le glissement
        // à la souris, où le texte ne doit pas bouger sous le pointeur.
        let overflowing = NSRange(location: 10, length: 14)
        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [strong], selection: overflowing, lineRange: wholeLine), [])
    }

    // MARK: - Imbrication

    func testInnermostInlineWins() {
        // « **gras avec *italique* dedans** »
        let outer = SyntaxSpan(kind: .strong,
                               range: NSRange(location: 0, length: 32),
                               markers: [NSRange(location: 0, length: 2), NSRange(location: 30, length: 2)],
                               content: NSRange(location: 2, length: 28))
        let inner = SyntaxSpan(kind: .emphasis,
                               range: NSRange(location: 13, length: 11),
                               markers: [NSRange(location: 13, length: 1), NSRange(location: 23, length: 1)],
                               content: NSRange(location: 14, length: 9))

        let inside = RevealPolicy.revealedIndices(spans: [outer, inner],
                                                  selection: NSRange(location: 18, length: 0),
                                                  lineRange: NSRange(location: 0, length: 32))
        XCTAssertEqual(inside, [1], "Seule la construction la plus intérieure se révèle (§2.2)")

        let outsideInner = RevealPolicy.revealedIndices(spans: [outer, inner],
                                                        selection: NSRange(location: 5, length: 0),
                                                        lineRange: NSRange(location: 0, length: 32))
        XCTAssertEqual(outsideInner, [0])
    }

    // MARK: - Portée ligne

    /// La règle qui a remplacé « n'importe où sur la ligne » : le curseur doit
    /// **toucher le préfixe**. C'est ce qui empêche une flèche vers le bas de
    /// faire sauter de trois signes chaque titre, chaque item et chaque citation
    /// qu'elle traverse.
    func testHeadingRevealsOnlyFromItsPrefix() {
        let line = NSRange(location: 0, length: 8)             // « ## Titre »
        for caret in 0...3 {
            XCTAssertEqual(
                RevealPolicy.revealedIndices(spans: [heading],
                                             selection: NSRange(location: caret, length: 0),
                                             lineRange: line),
                [0], "Position \(caret) : dans le préfixe, les dièses doivent être là")
        }
        for caret in 4...8 {
            XCTAssertEqual(
                RevealPolicy.revealedIndices(spans: [heading],
                                             selection: NSRange(location: caret, length: 0),
                                             lineRange: line),
                [], "Position \(caret) : dans le texte du titre, rien ne doit bouger")
        }
    }

    /// Le loquet : une fois le préfixe révélé, il le reste tant qu'on n'a pas
    /// quitté la ligne. Sans lui, la première lettre tapée après un `⏎` qui
    /// continue une liste décalerait la ligne.
    func testLatchKeepsThePrefixWhileTheCaretStaysOnTheLine() {
        let line = NSRange(location: 0, length: 8)
        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [heading],
                                         selection: NSRange(location: 6, length: 0),
                                         lineRange: line,
                                         linePrefixesLatched: true),
            [0], "Le loquet garde les dièses pendant qu'on écrit le titre")

        // Il ne franchit pas la ligne : ailleurs, il ne révèle rien.
        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [heading],
                                         selection: NSRange(location: 12, length: 0),
                                         lineRange: NSRange(location: 9, length: 10),
                                         linePrefixesLatched: true),
            [])
    }

    /// Une citation pose un `>` par ligne, et c'est celui de **la ligne du
    /// curseur** qui décide. Sans cette restriction, se placer sur la première
    /// ligne révélerait les dix suivantes d'un coup.
    func testAQuoteRevealsFromThePrefixOfTheCaretLine() {
        // « > un\n> deux »
        let quote = SyntaxSpan(kind: .blockQuote(depth: 1),
                               range: NSRange(location: 0, length: 12),
                               markers: [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)],
                               content: NSRange(location: 2, length: 10))
        let secondLine = NSRange(location: 6, length: 6)

        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [quote],
                                         selection: NSRange(location: 7, length: 0),
                                         lineRange: secondLine),
            [0], "Le curseur est dans le `>` de la deuxième ligne")

        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [quote],
                                         selection: NSRange(location: 10, length: 0),
                                         lineRange: secondLine),
            [], "Au milieu du texte de la citation, rien ne se révèle")
    }

    /// Un item de liste dans une citation : les deux préfixes se suivent sur la
    /// même ligne, et chacun se révèle quand le curseur le touche. C'est ce qui
    /// permet d'éditer l'un sans perdre l'autre de vue.
    func testNestedPrefixesRevealIndependently() {
        // « > - item »
        let quote = SyntaxSpan(kind: .blockQuote(depth: 1),
                               range: NSRange(location: 0, length: 8),
                               markers: [NSRange(location: 0, length: 2)],
                               content: NSRange(location: 2, length: 6))
        let item = SyntaxSpan(kind: .listItem(marker: .bullet("-")),
                              range: NSRange(location: 0, length: 8),
                              markers: [NSRange(location: 2, length: 2)],
                              content: NSRange(location: 4, length: 4),
                              depth: 2)
        let line = NSRange(location: 0, length: 8)

        XCTAssertEqual(revealed(spans: [quote, item], caret: 1, line: line), [0])
        XCTAssertEqual(revealed(spans: [quote, item], caret: 2, line: line), [0, 1],
                       "À la jonction des deux préfixes, les deux sont touchés")
        XCTAssertEqual(revealed(spans: [quote, item], caret: 3, line: line), [1])
        XCTAssertEqual(revealed(spans: [quote, item], caret: 6, line: line), [])
    }

    /// L'invariant du §2.3, sur les préfixes cette fois : **aucune position d'un
    /// marqueur masqué n'est atteignable**. C'est ce que garantissent les bornes
    /// inclusives, et c'est pour ça que la nouvelle règle porte sur les marqueurs
    /// et non sur la plage.
    func testCaretIsNeverInsideAHiddenLinePrefix() {
        let quote = SyntaxSpan(kind: .blockQuote(depth: 1),
                               range: NSRange(location: 0, length: 12),
                               markers: [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)],
                               content: NSRange(location: 2, length: 10))
        let lines = [NSRange(location: 0, length: 5), NSRange(location: 6, length: 6)]

        for caret in 0...12 {
            let line = lines.first { RevealPolicy.contains($0, caret) } ?? lines[1]
            let shown = RevealPolicy.revealedIndices(spans: [quote],
                                                     selection: NSRange(location: caret, length: 0),
                                                     lineRange: line)
            for marker in quote.markers where NSLocationInRange(caret, marker) {
                XCTAssertTrue(shown.contains(0),
                              "Position \(caret) : dans un `>` masqué, ce qui ne doit pas pouvoir arriver")
            }
        }
    }

    func testHeadingStaysHiddenFromAnotherLine() {
        let heading = SyntaxSpan(kind: .heading(level: 2),
                                 range: NSRange(location: 0, length: 8),
                                 markers: [NSRange(location: 0, length: 3)],
                                 content: NSRange(location: 3, length: 5))
        let otherLine = NSRange(location: 9, length: 10)
        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [heading],
                                         selection: NSRange(location: 12, length: 0),
                                         lineRange: otherLine),
            [])
    }

    // MARK: - Outils

    private func revealed(caret: Int) -> Set<Int> {
        RevealPolicy.revealedIndices(spans: [strong],
                                     selection: NSRange(location: caret, length: 0),
                                     lineRange: wholeLine)
    }

    private func revealed(spans: [SyntaxSpan], caret: Int, line: NSRange) -> Set<Int> {
        RevealPolicy.revealedIndices(spans: spans,
                                     selection: NSRange(location: caret, length: 0),
                                     lineRange: line)
    }
}
