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
        // La ligne vide n'est pas un ornement : sans elle, le premier mot tapé
        // ensuite serait une continuation paresseuse de « premier ».
        XCTAssertEqual(edit?.replacement, "\n")
        XCTAssertEqual(edit?.caret, 11)
    }

    func testLeavingAListReallyLeavesIt() {
        // Le test qui compte : ce que dit le **fichier** une fois la phrase
        // tapée. Sans la ligne vide, cmark range « Après » dans la puce, et
        // l'éditeur qui affichait un paragraphe à part mentait sur le document.
        let text = "- premier\n- "
        let edit = try? XCTUnwrap(TypingBehaviour.newline(in: text, selection: NSRange(location: 12, length: 0)))
        let after = (text as NSString).replacingCharacters(in: edit!.range, with: edit!.replacement)
        let typed = (after as NSString).replacingCharacters(in: NSRange(location: edit!.caret, length: 0),
                                                           with: "Après.")
        XCTAssertEqual(typed, "- premier\n\nAprès.")

        let spans = MarkdownParser.parse(typed).spans
        let items = spans.filter { if case .listItem = $0.kind { return true } else { return false } }
        XCTAssertEqual(items.count, 1, "Un seul item : « Après. » est dehors")
        XCTAssertFalse(items.contains { NSLocationInRange(typed.utf16.count - 1, $0.range) },
                       "La dernière phrase ne doit appartenir à aucun item")
    }

    func testLeavingAListDoesNotStackBlankLines() {
        // Une ligne vide au-dessus suffit déjà à couper la continuation : en
        // ajouter une seconde creuserait un trou dans le document.
        let text = "du texte\n\n- "
        let edit = TypingBehaviour.newline(in: text, selection: NSRange(location: 12, length: 0))
        XCTAssertEqual(edit?.replacement, "")
        XCTAssertEqual(edit?.caret, 10)
    }

    func testLeavingAListAtTheTopOfTheDocumentAddsNothing() {
        // Rien au-dessus, donc rien à couper : un document qui s'ouvrirait sur
        // une ligne vide serait une régression à lui tout seul.
        let edit = TypingBehaviour.newline(in: "- ", selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.replacement, "")
        XCTAssertEqual(edit?.caret, 0)
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
        // **La sélection survit au formatage**, sur le même texte qu'avant.
        //
        // Elle ne survivait pas : `⌘B` la repliait en un curseur, et le `⌘I`
        // qui suit n'avait plus rien à mettre en italique. La frappe d'un `*`
        // sur une sélection, elle, la conservait déjà (voir `autoPair`) : deux
        // chemins vers le même geste, deux comportements. Le curseur reste
        // entre les étoiles dans les deux cas.
        XCTAssertEqual(edit.caret, 5, "Le mot commence après les deux étoiles ouvrantes")
        XCTAssertEqual(edit.selectionLength, 3, "Le mot reste sélectionné, prêt pour un second format")
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

    // MARK: - Cocher une tâche

    /// La case est dessinée : cocher, c'est réécrire **un signe** du fichier.
    func testTogglingATaskChangesOneCharacter() throws {
        let text = "- [ ] à faire"
        let edit = try XCTUnwrap(TypingBehaviour.toggleTask(in: text,
                                                            marker: NSRange(location: 0, length: 6),
                                                            caret: 9))
        XCTAssertEqual(edit.range, NSRange(location: 3, length: 1))
        XCTAssertEqual(edit.replacement, "x")
        XCTAssertEqual(edit.caret, 9, "Cocher ne déplace pas le curseur")
    }

    func testTogglingBackClearsTheBox() throws {
        let edit = try XCTUnwrap(TypingBehaviour.toggleTask(in: "- [x] fait",
                                                            marker: NSRange(location: 0, length: 6),
                                                            caret: 0))
        XCTAssertEqual(edit.replacement, " ")
    }

    /// Le §5 vaut aussi pour ce que l'app écrit elle-même : un `[X]` majuscule
    /// se décoche, il ne se normalise pas.
    func testAnUppercaseBoxIsRecognisedAndNotRewritten() throws {
        let edit = try XCTUnwrap(TypingBehaviour.toggleTask(in: "- [X] fait",
                                                            marker: NSRange(location: 0, length: 6),
                                                            caret: 0))
        XCTAssertEqual(edit.replacement, " ", "Un [X] est bien lu comme coché")
    }

    func testAPlainListItemHasNothingToToggle() {
        XCTAssertNil(TypingBehaviour.toggleTask(in: "- un item",
                                                marker: NSRange(location: 0, length: 2),
                                                caret: 0))
    }

    // MARK: - Insérer un lien

    func testALinkWrapsTheSelectionAndTakesTheURLFromTheClipboard() {
        let edit = TypingBehaviour.link(in: "Voir le site ici",
                                        selection: NSRange(location: 13, length: 3),
                                        url: "https://exemple.fr")
        XCTAssertEqual(edit.replacement, "[ici](https://exemple.fr)")
        XCTAssertEqual(edit.caret, 38, "Le curseur sort du lien, prêt à continuer la phrase")
    }

    func testALinkWithoutAnAddressPutsTheCaretWhereOneWritesIt() {
        let edit = TypingBehaviour.link(in: "Voir le site ici",
                                        selection: NSRange(location: 13, length: 3),
                                        url: nil)
        XCTAssertEqual(edit.replacement, "[ici]()")
        XCTAssertEqual(edit.caret, 19, "Entre les parenthèses : il ne reste qu'à coller l'adresse")
    }

    func testALinkWithoutSelectionPutsTheCaretWhereOneWritesTheLabel() {
        let edit = TypingBehaviour.link(in: "", selection: NSRange(location: 0, length: 0), url: nil)
        XCTAssertEqual(edit.replacement, "[]()")
        XCTAssertEqual(edit.caret, 1, "Entre les crochets : on écrit le texte avant l'adresse")
    }

    /// Deviner large ferait coller n'importe quelle phrase copiée entre les
    /// parenthèses d'un lien, ce qui est plus pénible à défaire qu'à taper.
    func testOnlyRealAddressesAreTakenFromTheClipboard() {
        XCTAssertTrue(TypingBehaviour.looksLikeURL("https://exemple.fr"))
        XCTAssertTrue(TypingBehaviour.looksLikeURL("www.exemple.fr"))
        XCTAssertTrue(TypingBehaviour.looksLikeURL("mailto:elior@exemple.fr"))
        XCTAssertFalse(TypingBehaviour.looksLikeURL("une phrase copiée"))
        XCTAssertFalse(TypingBehaviour.looksLikeURL("exemple.fr"))
        XCTAssertFalse(TypingBehaviour.looksLikeURL(""))
    }

    // MARK: - Paires automatiques

    /// Outil : ce que la frappe produit, en texte, pour lire les cas d'un coup
    /// d'œil. Le curseur est marqué `|`, la sélection par deux `|`.
    private func typing(_ character: Character, into text: String,
                        selection: NSRange, insideCode: Bool = false) -> String {
        guard let edit = TypingBehaviour.autoPair(typing: character, in: text,
                                                  selection: selection, insideCode: insideCode)
        else { return "—" }
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit.range, with: edit.replacement)
        result.insert("|", at: edit.caret + edit.selectionLength)
        if edit.selectionLength > 0 { result.insert("|", at: edit.caret) }
        return result as String
    }

    func testAnOpeningBracketPosesItsClosing() {
        XCTAssertEqual(typing("(", into: "Voir ", selection: NSRange(location: 5, length: 0)),
                       "Voir (|)")
        XCTAssertEqual(typing("[", into: "", selection: NSRange(location: 0, length: 0)), "[|]")
    }

    /// Le cas qui décide de tout en français : l'apostrophe est une lettre du
    /// mot. Aucune paire, jamais, quel que soit le contexte.
    func testTheApostropheIsNeverPaired() {
        XCTAssertEqual(typing("'", into: "l", selection: NSRange(location: 1, length: 0)), "—")
        XCTAssertEqual(typing("'", into: "", selection: NSRange(location: 0, length: 0)), "—")
        XCTAssertEqual(typing("'", into: "dit ", selection: NSRange(location: 4, length: 0)), "—")
    }

    /// `2*3` ne doit pas poser d'étoile fantôme, ni `snake_case` d'italique.
    func testAMarkdownMarkerNeverOpensInsideAWord() {
        XCTAssertEqual(typing("*", into: "2", selection: NSRange(location: 1, length: 0)), "—")
        XCTAssertEqual(typing("_", into: "snake", selection: NSRange(location: 5, length: 0)), "—")
        XCTAssertEqual(typing("*", into: "du ", selection: NSRange(location: 3, length: 0)), "du *|*")
    }

    /// Une paire au milieu d'un mot serait presque toujours fausse ; devant une
    /// ponctuation fermante, elle est presque toujours juste.
    func testAPairOnlyOpensBeforeABoundary() {
        XCTAssertEqual(typing("(", into: "abc", selection: NSRange(location: 0, length: 0)), "—")
        XCTAssertEqual(typing("(", into: " abc", selection: NSRange(location: 0, length: 0)), "(|) abc")
        XCTAssertEqual(typing("*", into: "du .", selection: NSRange(location: 3, length: 0)), "du *|*.")
    }

    func testABackslashCancelsThePair() {
        XCTAssertEqual(typing("*", into: "un \\", selection: NSRange(location: 4, length: 0)), "—")
    }

    /// Retaper la fermeture avance au lieu d'en écrire une seconde : c'est ce
    /// qui rend la paire invisible à l'usage.
    func testRetypingTheClosingStepsOverIt() {
        XCTAssertEqual(typing(")", into: "(essai)", selection: NSRange(location: 6, length: 0)),
                       "(essai)|")
        // Qui tape les deux étoiles de fermeture à la main les franchit toutes
        // les deux : `**gras|**` puis `*` puis `*` donne `**gras**|`.
        XCTAssertEqual(typing("*", into: "**gras**", selection: NSRange(location: 6, length: 0)),
                       "**gras*|*")
        XCTAssertEqual(typing("*", into: "**gras**", selection: NSRange(location: 7, length: 0)),
                       "**gras**|")
    }

    /// Le cœur du confort : `**` puis le texte puis `⇥`. Ici, la première
    /// moitié — la pose de `****` avec le curseur au milieu.
    func testTypingTwoStarsLandsBetweenFour() {
        XCTAssertEqual(typing("*", into: "du ", selection: NSRange(location: 3, length: 0)), "du *|*")
        XCTAssertEqual(typing("*", into: "du **", selection: NSRange(location: 4, length: 0)), "du **|**")
    }

    func testMarkdownMarkersAreNotPairedInsideCode() {
        XCTAssertEqual(typing("*", into: "let a = ", selection: NSRange(location: 8, length: 0),
                              insideCode: true), "—")
        // Les parenthèses, elles, gardent tout leur sens dans du code.
        XCTAssertEqual(typing("(", into: "print", selection: NSRange(location: 5, length: 0),
                              insideCode: true), "print(|)")
    }

    /// Avec du texte sélectionné, la touche entoure au lieu d'effacer — et la
    /// sélection reste sur le même texte, pour pouvoir enchaîner `*` puis `*`.
    func testASelectionIsSurroundedAndKept() {
        XCTAssertEqual(typing("*", into: "du gras ici", selection: NSRange(location: 3, length: 4)),
                       "du *|gras|* ici")
        XCTAssertEqual(typing("(", into: "un aparté", selection: NSRange(location: 3, length: 6)),
                       "un (|aparté|)")
    }

    func testAnUnpairedCharacterIsLeftAlone() {
        XCTAssertEqual(typing("a", into: "", selection: NSRange(location: 0, length: 0)), "—")
        XCTAssertEqual(typing("a", into: "mot", selection: NSRange(location: 0, length: 3)), "—")
    }

    /// Revenir sur une parenthèse qu'on n'a pas voulue ne doit pas laisser sa
    /// jumelle orpheline.
    func testBackspaceBetweenAPairRemovesBoth() throws {
        let edit = try XCTUnwrap(TypingBehaviour.deletingPair(in: "Voir ()",
                                                              selection: NSRange(location: 6, length: 0)))
        XCTAssertEqual(edit.range, NSRange(location: 5, length: 2))
        XCTAssertEqual(edit.replacement, "")
        XCTAssertEqual(edit.caret, 5)
    }

    func testBackspaceElsewhereIsLeftAlone() {
        // La fermeture n'est pas collée : ce que l'on efface n'est plus une paire.
        XCTAssertNil(TypingBehaviour.deletingPair(in: "Voir (a)", selection: NSRange(location: 6, length: 0)))
        XCTAssertNil(TypingBehaviour.deletingPair(in: "Voir ()", selection: NSRange(location: 7, length: 0)))
        XCTAssertNil(TypingBehaviour.deletingPair(in: "", selection: NSRange(location: 0, length: 0)))
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

    /// **Devant le marqueur, `⏎` reste un `⏎`.**
    ///
    /// Le curseur peut se poser au tout début d'une ligne de liste — `⌘←` l'y
    /// envoie, et la règle de révélation l'y laisse entrer. La continuation
    /// s'appliquait quand même : on obtenait `- - item`, une seconde puce
    /// devant celle qu'on n'avait pas quittée. Ce qu'on veut là est une ligne
    /// vide au-dessus, c'est-à-dire le comportement ordinaire.
    func testNewlineBeforeTheMarkerDoesNotDuplicateIt() {
        XCTAssertNil(TypingBehaviour.newline(in: "- un item", selection: NSRange(location: 0, length: 0)),
                     "En tête de ligne, ⏎ doit rester un simple retour")
        XCTAssertNil(TypingBehaviour.newline(in: "- un item", selection: NSRange(location: 1, length: 0)),
                     "Dans le marqueur non plus, la liste ne se continue pas")

        // Juste après le marqueur, en revanche, la continuation reprend : c'est
        // le geste qui crée l'item vide au-dessus.
        let edit = TypingBehaviour.newline(in: "- un item", selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.replacement, "\n- ")
    }
}
