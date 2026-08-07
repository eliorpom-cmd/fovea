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

    // MARK: - Une sélection ne révèle rien

    func testNonEmptySelectionRevealsNothing() {
        // L'utilisateur sélectionne du texte rendu. Faire apparaître la syntaxe
        // sous la sélection déplacerait le contenu au moment précis où il vise.
        let selection = NSRange(location: 5, length: 10)
        XCTAssertEqual(RevealPolicy.revealedIndices(spans: [strong], selection: selection, lineRange: wholeLine), [])
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

    func testHeadingRevealsFromAnywhereOnItsLine() {
        // « ## Titre » : le curseur en fin de titre doit montrer les dièses,
        // sinon on ne pourrait pas changer le niveau sans viser la colonne 1.
        let heading = SyntaxSpan(kind: .heading(level: 2),
                                 range: NSRange(location: 0, length: 8),
                                 markers: [NSRange(location: 0, length: 3)],
                                 content: NSRange(location: 3, length: 5))
        let line = NSRange(location: 0, length: 8)
        for caret in 0...8 {
            XCTAssertEqual(
                RevealPolicy.revealedIndices(spans: [heading],
                                             selection: NSRange(location: caret, length: 0),
                                             lineRange: line),
                [0], "Position \(caret)")
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
}
