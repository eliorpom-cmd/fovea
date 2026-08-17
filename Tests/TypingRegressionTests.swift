// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Ce que l'audit UI a trouvé sous les doigts, et qui ne doit plus revenir.
///
/// Deux défauts s'y déclenchaient à chaque usage, sans qu'aucun test ne les
/// voie : la troisième touche d'une clôture de bloc de code, et le curseur
/// après un retrait de format.
@MainActor
final class TypingRegressionTests: XCTestCase {

    private func editor(_ source: String) -> EditorController {
        let controller = EditorController(typography: .default)
        controller.textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.textView.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        controller.textView.textContainer?.widthTracksTextView = false
        controller.setText(source)
        return controller
    }

    // MARK: - La clôture de bloc de code

    /// Les deux premières touches doublent, la troisième ouvre le bloc.
    ///
    /// Sans ce cas, les paires automatiques donnaient six accents graves pour
    /// trois touches, et le geste le plus courant du markdown ne marchait pas.
    func testTheThirdBacktickOpensABlock() {
        let edit = TypingBehaviour.codeFence(typing: "`", in: "````",
                                             selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 4))
        XCTAssertEqual(edit?.replacement, "```\n\n```")
        XCTAssertEqual(edit?.caret, 4, "Le curseur va dans le bloc, pas après sa clôture")
    }

    /// Le geste complet, dans un vrai éditeur : trois touches, un bloc.
    func testTypingThreeBackticksInTheEditorGivesAFence() {
        let controller = editor("")
        // `insertText` est le point où passent le clavier, la dictée et la
        // palette de caractères : c'est lui qui appelle les paires.
        for _ in 0..<3 {
            controller.textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        XCTAssertEqual(controller.text, "```\n\n```")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 4, length: 0))
    }

    /// Au fil d'une phrase, trois accents graves ne sont pas un bloc : la paire
    /// garde la main.
    func testTheFenceOnlyOpensALine() {
        XCTAssertNil(TypingBehaviour.codeFence(typing: "`", in: "du ````",
                                               selection: NSRange(location: 5, length: 0)))
    }

    /// Jusqu'à trois espaces d'indentation restent une ouverture de bloc.
    func testAnIndentedFenceStillOpens() {
        XCTAssertNotNil(TypingBehaviour.codeFence(typing: "`", in: "  ````",
                                                  selection: NSRange(location: 4, length: 0)))
        XCTAssertNil(TypingBehaviour.codeFence(typing: "`", in: "     ````",
                                               selection: NSRange(location: 7, length: 0)),
                     "Au-delà de trois espaces, ce n'est plus une clôture")
    }

    /// Il faut bien quatre accents graves autour du curseur : la forme exacte
    /// que les deux premières touches produisent, et rien d'autre.
    func testTheFenceNeedsThePairItReplaces() {
        XCTAssertNil(TypingBehaviour.codeFence(typing: "`", in: "``",
                                               selection: NSRange(location: 1, length: 0)))
        XCTAssertNil(TypingBehaviour.codeFence(typing: "a", in: "````",
                                               selection: NSRange(location: 2, length: 0)))
    }

    // MARK: - Le curseur après un retrait de format

    /// `⌫` en fin de mot gras retire le format **et laisse le curseur en fin de
    /// mot**.
    ///
    /// Il partait au début du contenu : on tapait `**mot**`, on effaçait le
    /// gras, et la frappe suivante s'écrivait devant le mot.
    func testDeletingAFormatKeepsTheCaretWhereItWas() {
        let controller = editor("Du **gras** ici.")
        // `Du **gras**|` — juste après la fermeture, là où `⌫` retire le format.
        controller.textView.setSelectedRange(NSRange(location: 11, length: 0))
        controller.textView.deleteBackward(nil)

        XCTAssertEqual(controller.text, "Du gras ici.")
        XCTAssertEqual(controller.textView.selectedRange(),
                       NSRange(location: 7, length: 0),
                       "Le curseur reste en fin de mot, moins les marqueurs effacés devant lui")
    }

    /// Le même geste **entre les deux étoiles d'une ouverture**.
    ///
    /// La position est atteignable — le marqueur y est révélé — et `⌫` y voyait
    /// une paire `*|*` à défaire avant de voir la construction : `**gras**`
    /// devenait `gras**`, un marqueur de fermeture seul au milieu de la phrase.
    func testDeletingFromTheOpeningMarkerRemovesTheWholeConstruct() {
        let controller = editor("Du **gras** ici.")
        // `Du *|*gras**` — dans l'ouverture, à un signe de son début.
        controller.textView.setSelectedRange(NSRange(location: 4, length: 0))
        controller.textView.deleteBackward(nil)

        XCTAssertEqual(controller.text, "Du gras ici.")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 3, length: 0))
    }

    // MARK: - Les touches mortes

    /// Sur un clavier français, `` ` `` et `~` sont des touches mortes : le
    /// caractère conclut une composition et n'arrive jamais par la porte que
    /// surveillaient les paires automatiques. Elles ne se déclenchaient donc
    /// **jamais** sur les deux marqueurs markdown qui en ont le plus besoin.
    func testTheClosingHalfIsStillPlacedAfterADeadKey() {
        // `du |` — l'accent grave vient d'être écrit, le curseur est derrière.
        let edit = TypingBehaviour.autoPairAfterTyping("`", in: "du `", caret: 4, insideCode: false)
        XCTAssertEqual(edit?.range, NSRange(location: 4, length: 0))
        XCTAssertEqual(edit?.replacement, "`")
        XCTAssertEqual(edit?.caret, 4, "Le curseur reste entre les deux moitiés")
    }

    /// Retaper la fermeture la franchit, au lieu d'en écrire une seconde.
    func testRetypingTheClosingHalfStepsOverItAfterADeadKey() {
        // `` `mot`|` `` — on vient de retaper l'accent grave devant celui qui
        // fermait déjà.
        let edit = TypingBehaviour.autoPairAfterTyping("`", in: "`mot``", caret: 5, insideCode: false)
        XCTAssertEqual(edit?.range, NSRange(location: 4, length: 1), "On retire celui qu'on vient d'écrire")
        XCTAssertEqual(edit?.replacement, "")
        XCTAssertEqual(edit?.caret, 5)
    }

    /// Dans du code, un marqueur markdown ne s'apparie pas — même par cette
    /// seconde porte.
    func testTheDeadKeyPathRespectsCode() {
        XCTAssertNil(TypingBehaviour.autoPairAfterTyping("`", in: "du `", caret: 4, insideCode: true))
    }

    /// Et le troisième accent grave ouvre toujours un bloc, quel que soit le
    /// chemin par lequel il est arrivé.
    func testTheFenceAlsoOpensAfterADeadKey() {
        // `` ```|`` `` — cinq accents graves, le curseur après le troisième.
        let edit = TypingBehaviour.codeFenceAfterTyping("`", in: "`````", caret: 3)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 5))
        XCTAssertEqual(edit?.replacement, "```\n\n```")
        XCTAssertEqual(edit?.caret, 4)
    }

    // Le geste complet par touche morte n'est pas rejoué ici : `setMarkedText`
    // demande une session de saisie que le harnais de test n'a pas, et
    // l'émuler en passant la sélection comme plage de remplacement ne reproduit
    // pas la composition. Le contrat est celui des quatre fonctions ci-dessus ;
    // le chemin complet se vérifie dans l'app, clavier français en main.
}
