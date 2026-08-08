// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// La boucle de frappe complète, dans un vrai éditeur.
///
/// Les fonctions pures sont couvertes ailleurs ; ce qui se vérifie ici est le
/// câblage : que `⇥` ressorte bien d'un format au lieu d'indenter, et que la
/// paire posée puis franchie ne laisse rien derrière elle.
@MainActor
final class AutoPairInTheEditorTests: XCTestCase {

    private func editor(_ source: String) -> EditorController {
        let controller = EditorController(typography: .default)
        controller.textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.textView.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        controller.textView.textContainer?.widthTracksTextView = false
        controller.setText(source)
        return controller
    }

    /// Le geste que les paires automatiques ouvrent : `⇥` collé devant la
    /// fermeture saute par-dessus, et le curseur ressort du gras.
    func testTabLeavesAnInlineFormat() {
        let controller = editor("Du **gras** ici.")
        // `Du **gras|** ici.` — la fin du contenu, juste avant la fermeture.
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        XCTAssertTrue(controller.textView.handlesIndent?(false) ?? false)
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 11, length: 0))
        XCTAssertEqual(controller.text, "Du **gras** ici.", "Sortir d'un format ne change pas le texte")
    }

    /// Depuis un lien, `⇥` ressort du tout — adresse comprise. Une seule
    /// pression suffit, là où MarkText en demande deux.
    func testTabLeavesTheWholeLink() {
        let controller = editor("Voir [le site](https://exemple.fr) ici.")
        controller.textView.setSelectedRange(NSRange(location: 13, length: 0))
        XCTAssertTrue(controller.textView.handlesIndent?(false) ?? false)
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 34, length: 0))
    }

    /// Ailleurs, `⇥` doit rester ce qu'il était : rien à voler à l'indentation.
    func testTabInTheMiddleOfAWordIsNotStolen() {
        let controller = editor("Du **gras** ici.")
        controller.textView.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertFalse(controller.textView.handlesIndent?(false) ?? true)
    }

    func testTabStillIndentsAListItem() {
        let controller = editor("- un item")
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        XCTAssertTrue(controller.textView.handlesIndent?(false) ?? false)
        XCTAssertEqual(controller.text, "  - un item")
    }

    /// Ce qui compte au bout : le fichier. Taper `(` puis fermer à la main ne
    /// doit laisser ni parenthèse en trop ni parenthèse en moins.
    func testTypingAPairThenClosingItLeavesTheTextIntact() {
        let controller = editor("Voir ")
        controller.textView.setSelectedRange(NSRange(location: 5, length: 0))
        controller.textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(controller.text, "Voir ()")
        controller.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(controller.text, "Voir (a)")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 8, length: 0))
    }

    /// Et l'inverse : revenir sur la paire vide l'efface d'un seul `⌫`.
    func testBackspaceRemovesBothHalves() {
        let controller = editor("Voir ")
        controller.textView.setSelectedRange(NSRange(location: 5, length: 0))
        controller.textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.textView.deleteBackward(nil)
        XCTAssertEqual(controller.text, "Voir ")
    }
}
