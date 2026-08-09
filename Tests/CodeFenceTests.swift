// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
@testable import Fovea

/// Le langage d'un bloc de code, et le tableau du damier.
///
/// Deux fonctions pures pour deux panneaux flottants : ce qui décide **quand**
/// s'ouvrir et **quoi écrire** se teste sans jamais ouvrir de fenêtre.
final class CodeFenceTests: XCTestCase {

    // MARK: - Quand le sélecteur de langage s'ouvre

    func testTheCaretAfterTheBackticksOffersTheLanguage() throws {
        let trigger = try XCTUnwrap(CodeFence.languageTrigger(inLine: "```", lineStart: 0, caret: 3))
        XCTAssertEqual(trigger.query, "")
        XCTAssertEqual(trigger.range, NSRange(location: 3, length: 0))
    }

    func testWhatIsAlreadyTypedFiltersTheList() throws {
        let trigger = try XCTUnwrap(CodeFence.languageTrigger(inLine: "```swi", lineStart: 0, caret: 6))
        XCTAssertEqual(trigger.query, "swi")
        // La plage couvre tout le mot : choisir dans la liste le remplace,
        // plutôt que de compléter à l'aveugle ce qui est déjà là.
        XCTAssertEqual(trigger.range, NSRange(location: 3, length: 3))
    }

    func testTheOffsetOfTheLineIsRespected() throws {
        let trigger = try XCTUnwrap(CodeFence.languageTrigger(inLine: "```py", lineStart: 120, caret: 125))
        XCTAssertEqual(trigger.range, NSRange(location: 123, length: 2))
    }

    /// Le curseur posé **dans** les accents graves veut les modifier, pas
    /// nommer un langage.
    func testTheCaretInsideTheFenceOffersNothing() {
        XCTAssertNil(CodeFence.languageTrigger(inLine: "```", lineStart: 0, caret: 2))
        XCTAssertNil(CodeFence.languageTrigger(inLine: "```swift", lineStart: 0, caret: 0))
    }

    func testAnOrdinaryLineOffersNothing() {
        XCTAssertNil(CodeFence.languageTrigger(inLine: "du texte", lineStart: 0, caret: 4))
        // Deux accents graves ne sont pas une clôture : c'est du code en ligne.
        XCTAssertNil(CodeFence.languageTrigger(inLine: "``x``", lineStart: 0, caret: 3))
    }

    /// `~~~` est une clôture aussi légitime que les accents graves, et jusqu'à
    /// trois espaces peuvent la précéder.
    func testTildesAndIndentationAreAccepted() throws {
        XCTAssertNotNil(CodeFence.languageTrigger(inLine: "~~~json", lineStart: 0, caret: 7))
        XCTAssertNotNil(CodeFence.languageTrigger(inLine: "  ```json", lineStart: 0, caret: 9))
        // Quatre espaces, c'est un bloc de code indenté : plus une clôture.
        XCTAssertNil(CodeFence.languageTrigger(inLine: "    ```json", lineStart: 0, caret: 11))
    }

    /// `csv sans en-tête` est une note que l'auteur s'est écrite, pas un nom à
    /// compléter : lui ouvrir un menu à chaque espace serait insupportable.
    func testAnInfoStringWithSpacesIsLeftAlone() {
        XCTAssertNil(CodeFence.languageTrigger(inLine: "```csv sans en-tête", lineStart: 0, caret: 19))
    }

    // MARK: - Le filtrage

    func testThePrefixComesFirst() {
        // On tape le début d'un mot, pas son milieu : `s` doit proposer
        // `swift` avant `css`.
        let matches = CodeFence.matching("s")
        XCTAssertEqual(matches.first, "swift")
        XCTAssertTrue(matches.contains("css"))
        XCTAssertLessThan(matches.firstIndex(of: "swift")!, matches.firstIndex(of: "css")!)
    }

    func testAnEmptyQueryOffersEverything() {
        XCTAssertEqual(CodeFence.matching(""), CodeFence.languages)
    }

    func testOnlyLanguagesTheHighlighterKnowsAreOffered() {
        // Proposer un langage qu'on ne saurait pas colorer serait une promesse
        // en l'air.
        for language in CodeFence.languages {
            XCTAssertNotNil(CodeHighlighter.Grammar.all[language],
                            "« \(language) » est proposé mais n'a pas de grammaire")
        }
    }

    // MARK: - Le tableau du damier

    func testTheTableHasTheRequestedShape() {
        let (markdown, caret) = CodeFence.table(columns: 3, rows: 2)
        XCTAssertEqual(markdown, """
        |  |  |  |
        |---|---|---|
        |  |  |  |
        |  |  |  |
        """)
        // Le curseur va dans la première cellule, celle qu'on va remplir.
        XCTAssertEqual(caret, 2)
    }

    func testASingleColumnTableIsStillATable() {
        let (markdown, _) = CodeFence.table(columns: 1, rows: 1)
        XCTAssertEqual(markdown, "|  |\n|---|\n|  |")
    }

    func testTheTableIsReparsedAsAGrid() throws {
        // Le vrai test : ce que le damier écrit doit ressortir du parseur comme
        // un tableau, sinon la grille ne s'affichera jamais.
        let (markdown, _) = CodeFence.table(columns: 4, rows: 3)
        let utf16 = Array(markdown.utf16)
        let table = try XCTUnwrap(MarkdownTable.scan(utf16: utf16,
                                                    in: NSRange(location: 0, length: utf16.count)))
        XCTAssertEqual(table.rows.count, 4, "L'en-tête et trois lignes de corps")
        XCTAssertEqual(table.rows[0].cells.count, 4)
    }
}
