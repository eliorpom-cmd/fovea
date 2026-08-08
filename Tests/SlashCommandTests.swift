// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Le menu d'insertion de bloc (§4.5).
///
/// La moitié du travail est de savoir **quand ne pas s'ouvrir**. Un menu qui
/// surgit sur chaque barre oblique rendrait la touche inutilisable dans un
/// texte qui parle de chemins de fichiers ou de dates.
final class SlashCommandTests: XCTestCase {

    private func trigger(_ line: String, caret: Int? = nil,
                         lineStart: Int = 0) -> TypingBehaviour.SlashTrigger? {
        TypingBehaviour.slashTrigger(inLine: line,
                                     lineStart: lineStart,
                                     caret: lineStart + (caret ?? line.utf16.count))
    }

    // MARK: - Quand il s'ouvre

    func testASlashAloneOpensTheMenu() throws {
        let found = try XCTUnwrap(trigger("/"))
        XCTAssertEqual(found.query, "")
        XCTAssertEqual(found.range, NSRange(location: 0, length: 1))
    }

    func testWhatFollowsTheSlashBecomesTheQuery() throws {
        let found = try XCTUnwrap(trigger("/tab"))
        XCTAssertEqual(found.query, "tab")
        XCTAssertEqual(found.range, NSRange(location: 0, length: 4))
    }

    func testThePositionIsAbsoluteInTheDocument() throws {
        // La ligne est passée seule, mais la plage rendue doit désigner le
        // document : c'est elle qui sera remplacée par le bloc.
        let found = try XCTUnwrap(trigger("/code", lineStart: 420))
        XCTAssertEqual(found.range, NSRange(location: 420, length: 5))
    }

    // MARK: - Quand il ne s'ouvre pas

    func testASlashInTheMiddleOfATextIsJustASlash() {
        XCTAssertNil(trigger("voir docs/api"))
        XCTAssertNil(trigger("le 12/08/2026"))
    }

    func testASpaceClosesTheMenu() {
        // « /note à moi » est une phrase, pas une commande.
        XCTAssertNil(trigger("/note à"))
    }

    func testTextAfterTheCaretClosesTheMenu() {
        // On insère un bloc sur une ligne vide, pas au milieu d'un texte déjà
        // écrit qui se retrouverait poussé dans le tableau.
        XCTAssertNil(trigger("/tab et la suite", caret: 4))
    }

    func testTheCaretMustBeAfterTheSlash() {
        XCTAssertNil(trigger("/tab", caret: 0))
    }

    // MARK: - Filtrage

    func testTheQueryFindsByPrefix() {
        XCTAssertEqual(SlashCommand.matching("tab").first, .table)
        XCTAssertEqual(SlashCommand.matching("cit").first, .quote)
    }

    func testTheQueryFindsBySubsequence() {
        // Même règle que ⌘K : taper « tb » doit trouver « Tableau ».
        XCTAssertEqual(SlashCommand.matching("tb").first, .table)
    }

    func testEnglishKeywordsWorkToo() {
        // La moitié des gens tapent /code ou /todo sans réfléchir.
        XCTAssertEqual(SlashCommand.matching("todo").first, .taskList)
        XCTAssertEqual(SlashCommand.matching("hr").first, .rule)
    }

    func testAnEmptyQueryShowsEverything() {
        XCTAssertEqual(SlashCommand.matching("").count, SlashCommand.allCases.count)
    }

    func testNonsenseMatchesNothing() {
        // Le menu se referme alors, et la frappe redevient du texte ordinaire.
        XCTAssertTrue(SlashCommand.matching("zzzzq").isEmpty)
    }

    // MARK: - Ce qui est inséré

    func testTheSlashIsReplacedNotKept() {
        let edit = TypingBehaviour.insertion(of: .heading2,
                                             replacing: NSRange(location: 10, length: 3))
        XCTAssertEqual(edit.range, NSRange(location: 10, length: 3))
        XCTAssertEqual(edit.replacement, "## ")
    }

    func testTheCaretLandsWhereOneWrites() {
        // Dans le bloc de code, pas après sa clôture.
        let code = TypingBehaviour.insertion(of: .codeBlock, replacing: NSRange(location: 0, length: 1))
        XCTAssertEqual(code.replacement, "```\n\n```")
        XCTAssertEqual(code.caret, 4, "Le curseur doit être sur la ligne vide, entre les clôtures")

        // Dans la première cellule du tableau, pas à la ligne suivante.
        let table = TypingBehaviour.insertion(of: .table, replacing: NSRange(location: 0, length: 1))
        XCTAssertEqual(table.caret, 2)
    }

    func testEveryInsertedBlockIsValidMarkdown() {
        // Le menu existe parce que les marqueurs sont masqués : ce qu'il pose
        // doit être relu par le parseur comme la construction annoncée.
        for command in SlashCommand.allCases {
            let edit = TypingBehaviour.insertion(of: command, replacing: NSRange(location: 0, length: 0))
            let spans = MarkdownParser.parse(edit.replacement + "texte\n").spans
            XCTAssertFalse(spans.isEmpty, "« \(command.title) » ne produit aucune construction")
        }
    }

    func testTheInsertedTableIsReadAsAGrid() throws {
        let edit = TypingBehaviour.insertion(of: .table, replacing: NSRange(location: 0, length: 0))
        let spans = MarkdownParser.parse(edit.replacement + "\n").spans
        let table = try XCTUnwrap(spans.first { if case .table = $0.kind { return true } else { return false } })
        guard case .table(let grid?) = table.kind else {
            return XCTFail("Le tableau inséré doit être lu comme une grille")
        }
        XCTAssertEqual(grid.columnCount, 2)
        XCTAssertEqual(grid.rows.count, 2)
    }

    func testEveryCommandHasATitleAndAHint() {
        for command in SlashCommand.allCases {
            XCTAssertFalse(command.title.isEmpty)
            XCTAssertFalse(command.hint.isEmpty, "Le menu montre la syntaxe qu'il pose")
        }
    }
}

/// Le panneau lui-même.
///
/// Ce qui est vérifié ici n'est pas l'apparence mais **le contrat** : il
/// s'ouvre, il se place sous le curseur, il ne prend jamais le focus, et il se
/// referme tout seul quand plus rien ne correspond.
@MainActor
final class SlashMenuTests: XCTestCase {

    private func host() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.orderBack(nil)
        return window
    }

    func testItNeverBecomesKey() {
        // Tout le principe : le curseur reste dans le texte et la frappe
        // continue d'y aller pendant que le menu filtre.
        XCTAssertFalse(SlashMenu().canBecomeKey)
    }

    func testItOpensAndCarriesTheMatchingEntries() {
        let menu = SlashMenu()
        let window = host()
        let caret = NSRect(x: 300, y: 500, width: 1, height: 20)

        XCTAssertTrue(menu.present(query: "ta", caretRect: caret, over: window))
        XCTAssertTrue(menu.isOpen)
        menu.dismiss()
    }

    func testItSitsUnderTheCaret() {
        let menu = SlashMenu()
        let window = host()
        let caret = NSRect(x: 300, y: 500, width: 1, height: 20)
        _ = menu.present(query: "", caretRect: caret, over: window)

        XCTAssertEqual(menu.frame.minX, caret.minX, accuracy: 1,
                       "Aligné sur le curseur, pas sur la fenêtre")
        XCTAssertLessThanOrEqual(menu.frame.maxY, caret.minY,
                                 "Posé dessus, il masquerait le mot en cours de frappe")
        menu.dismiss()
    }

    func testItFlipsAboveTheCaretWhenThereIsNoRoomBelow() {
        let menu = SlashMenu()
        let window = host()
        // Un curseur tout en bas de l'écran : le menu doit repasser au-dessus
        // plutôt que de sortir par le bas.
        let screen = window.screen ?? NSScreen.main!
        let caret = NSRect(x: 300, y: screen.visibleFrame.minY + 4, width: 1, height: 20)
        _ = menu.present(query: "", caretRect: caret, over: window)

        XCTAssertGreaterThanOrEqual(menu.frame.minY, caret.maxY)
        menu.dismiss()
    }

    func testItClosesItselfWhenNothingMatches() {
        let menu = SlashMenu()
        let window = host()
        _ = menu.present(query: "", caretRect: NSRect(x: 300, y: 500, width: 1, height: 20), over: window)
        XCTAssertTrue(menu.isOpen)

        // La frappe redevient du texte ordinaire, et l'appelant l'apprend par
        // la valeur de retour.
        XCTAssertFalse(menu.present(query: "zzzzq",
                                    caretRect: NSRect(x: 300, y: 500, width: 1, height: 20),
                                    over: window))
        XCTAssertFalse(menu.isOpen)
    }

    func testConfirmingRunsTheSelectedEntry() {
        let menu = SlashMenu()
        let window = host()
        var chosen: SlashCommand?
        menu.onChoose = { chosen = $0 }

        _ = menu.present(query: "tab", caretRect: NSRect(x: 300, y: 500, width: 1, height: 20), over: window)
        menu.confirmSelection()

        XCTAssertEqual(chosen, .table)
        XCTAssertFalse(menu.isOpen, "Valider referme le menu")
    }

    func testArrowsMoveWithinTheList() {
        let menu = SlashMenu()
        let window = host()
        var chosen: SlashCommand?
        menu.onChoose = { chosen = $0 }

        _ = menu.present(query: "", caretRect: NSRect(x: 300, y: 500, width: 1, height: 20), over: window)
        menu.moveSelection(by: 1)
        menu.confirmSelection()

        XCTAssertEqual(chosen, SlashCommand.allCases[1])
    }

    func testSelectionStopsAtTheEnds() {
        let menu = SlashMenu()
        let window = host()
        var chosen: SlashCommand?
        menu.onChoose = { chosen = $0 }

        _ = menu.present(query: "", caretRect: NSRect(x: 300, y: 500, width: 1, height: 20), over: window)
        // Remonter depuis la première entrée ne doit pas sortir de la liste.
        menu.moveSelection(by: -5)
        menu.confirmSelection()

        XCTAssertEqual(chosen, SlashCommand.allCases.first)
    }
}
