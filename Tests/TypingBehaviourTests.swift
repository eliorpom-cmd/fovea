// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
@testable import Fovea

/// Les comportements de frappe du §2.5, testés comme des fonctions pures.
///
/// Tout ce fichier vérifie des transformations texte → texte : aucune fenêtre
/// n'est ouverte, aucune touche n'est simulée. C'est ce qui permet de couvrir
/// les cas tordus — item vide, liste imbriquée, formatage déjà posé — sans
/// écrire un seul test d'interface.
final class TypingBehaviourTests: XCTestCase {

    // MARK: - Continuation de liste

    func testNewlineContinuesABulletList() {
        let edit = TypingBehaviour.newline(in: "- premier", selection: NSRange(location: 9, length: 0))
        XCTAssertEqual(edit?.replacement, "\n- ")
        XCTAssertEqual(edit?.caret, 12)
    }

    func testNewlineIncrementsAnOrderedList() {
        let edit = TypingBehaviour.newline(in: "3. troisième", selection: NSRange(location: 12, length: 0))
        XCTAssertEqual(edit?.replacement, "\n4. ", "Le numéro suivant, pas une copie du précédent")
    }

    func testNewlinePreservesNestingIndentation() {
        let text = "- parent\n  - enfant"
        let edit = TypingBehaviour.newline(in: text, selection: NSRange(location: 19, length: 0))
        XCTAssertEqual(edit?.replacement, "\n  - ", "L'item suivant reste au même niveau")
    }

    func testNewlineOnAnEmptyItemLeavesTheList() {
        // Deux `⏎` de suite sortent de la liste : c'est le geste que tout le
        // monde fait, et ne pas le prévoir oblige à effacer le marqueur à la
        // main.
        let text = "- premier\n- "
        let edit = TypingBehaviour.newline(in: text, selection: NSRange(location: 12, length: 0))
        XCTAssertEqual(edit?.range, NSRange(location: 10, length: 2))
        XCTAssertEqual(edit?.replacement, "")
        XCTAssertEqual(edit?.caret, 10)
    }

    func testNewlineOnATaskItemStartsAnUncheckedOne() {
        // Une case cochée ne se recopie pas cochée : personne ne veut créer dix
        // tâches déjà faites.
        let edit = TypingBehaviour.newline(in: "- [x] fait", selection: NSRange(location: 10, length: 0))
        XCTAssertEqual(edit?.replacement, "\n- [ ] ")
    }

    func testNewlineOutsideAListIsLeftAlone() {
        XCTAssertNil(TypingBehaviour.newline(in: "du texte", selection: NSRange(location: 8, length: 0)),
                     "Hors liste, ⏎ doit garder son comportement habituel")
    }

    func testNewlineIgnoresADashWithoutASpace() {
        // `-texte` n'est pas une liste. Le confondre transformerait un tiret
        // cadratin mal tapé en puce.
        XCTAssertNil(TypingBehaviour.newline(in: "-texte", selection: NSRange(location: 6, length: 0)))
    }

    // MARK: - Indentation

    func testTabIndentsAListItem() {
        let edit = TypingBehaviour.indent(in: "- item", selection: NSRange(location: 6, length: 0), outdent: false)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(edit?.replacement, "  ")
        XCTAssertEqual(edit?.caret, 8)
    }

    func testShiftTabOutdents() {
        let edit = TypingBehaviour.indent(in: "  - item", selection: NSRange(location: 8, length: 0), outdent: true)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(edit?.replacement, "")
    }

    func testShiftTabAtTheLeftMarginDoesNothing() {
        XCTAssertNil(TypingBehaviour.indent(in: "- item", selection: NSRange(location: 6, length: 0), outdent: true))
    }

    func testTabOutsideAListStaysATab() {
        XCTAssertNil(TypingBehaviour.indent(in: "du texte", selection: NSRange(location: 4, length: 0), outdent: false),
                     "Hors liste, ⇥ doit rester une tabulation")
    }

    // MARK: - Encadrement

    func testWrapSurroundsTheSelection() {
        let edit = TypingBehaviour.wrap("un mot ici", selection: NSRange(location: 3, length: 3), with: "**")
        XCTAssertEqual(edit.replacement, "**mot**")
        XCTAssertEqual(edit.caret, 8, "Le curseur reste après le mot, pas après les étoiles")
    }

    func testWrapOnACaretPlacesItBetweenTheMarkers() {
        // L'utilisateur a demandé du gras pour écrire en gras, pas pour poser
        // deux étoiles et chercher où taper.
        let edit = TypingBehaviour.wrap("un  ici", selection: NSRange(location: 3, length: 0), with: "**")
        XCTAssertEqual(edit.replacement, "****")
        XCTAssertEqual(edit.caret, 5)
    }

    func testWrapOnAlreadyFormattedTextRemovesTheFormatting() {
        // §2.5 : appliqués à du texte déjà formaté, les raccourcis retirent le
        // formatage plutôt que d'empiler un second niveau.
        let text = "un **mot** ici"
        let edit = TypingBehaviour.wrap(text, selection: NSRange(location: 5, length: 3), with: "**")
        XCTAssertEqual(edit.range, NSRange(location: 3, length: 7))
        XCTAssertEqual(edit.replacement, "mot")
    }

    func testWrapHandlesAccentedSelections() {
        let edit = TypingBehaviour.wrap("Été crucial", selection: NSRange(location: 4, length: 7), with: "*")
        XCTAssertEqual(edit.replacement, "*crucial*")
    }

    // MARK: - Niveau de titre

    func testSetHeadingLevelOnAPlainParagraph() {
        let edit = TypingBehaviour.setHeadingLevel(2, in: "Un titre", selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(edit.replacement, "## ")
        XCTAssertEqual(edit.caret, 6, "Le curseur suit le texte, il ne reste pas à sa position absolue")
    }

    func testChangingHeadingLevelReplacesTheExistingHashes() {
        let edit = TypingBehaviour.setHeadingLevel(3, in: "## Un titre", selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(edit.replacement, "### ")
    }

    func testLevelZeroRemovesTheHeading() {
        let edit = TypingBehaviour.setHeadingLevel(0, in: "### Un titre", selection: NSRange(location: 6, length: 0))
        XCTAssertEqual(edit.replacement, "")
        XCTAssertEqual(edit.caret, 2)
    }

    // MARK: - Reconnaissance à la frappe

    func testRecognizedConstructs() {
        // Elle n'est pas une fonctionnalité mais une conséquence du §3.1 : le
        // marqueur est déjà dans le texte, le parseur le voit, le rendu suit.
        // Ce test dit lesquelles sont reconnues plutôt que de le supposer.
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "# "))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "###### Titre 6"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "- item"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "* item"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "1. item"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "12) item"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "> citation"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "  - item indenté"))
    }

    func testNonConstructs() {
        XCTAssertFalse(TypingBehaviour.recognizesConstruct(onLine: "####### sept dièses"))
        XCTAssertFalse(TypingBehaviour.recognizesConstruct(onLine: "#sans espace"))
        XCTAssertFalse(TypingBehaviour.recognizesConstruct(onLine: "-sans espace"))
        XCTAssertFalse(TypingBehaviour.recognizesConstruct(onLine: "1.sans espace"))
        XCTAssertFalse(TypingBehaviour.recognizesConstruct(onLine: "du texte ordinaire"))
    }

    // MARK: - Analyse de ligne

    func testLineRangeExcludesTheTerminator() {
        let units = Array("un\ndeux\ntrois".utf16)
        XCTAssertEqual(TypingBehaviour.lineRange(units, containing: 0), NSRange(location: 0, length: 2))
        XCTAssertEqual(TypingBehaviour.lineRange(units, containing: 5), NSRange(location: 3, length: 4))
        XCTAssertEqual(TypingBehaviour.lineRange(units, containing: 13), NSRange(location: 8, length: 5))
    }

    func testListPrefixCoversTheWholeCheckbox() {
        let units = Array("- [ ] à faire".utf16)
        let line = TypingBehaviour.lineRange(units, containing: 0)
        XCTAssertEqual(TypingBehaviour.listPrefix(units, line: line), NSRange(location: 0, length: 6))
    }
}
