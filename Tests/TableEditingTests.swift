// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
@testable import Fovea

/// Écrire dans un tableau sans jamais voir ses `|` (§2.6).
///
/// La grille ne se replie plus sous le curseur. Le prix de ce choix, ce sont
/// les positions du tampon que plus rien n'affiche : les `|`, les blancs de
/// remplissage, la ligne `|---|`. Ces tests vérifient qu'aucune d'elles n'est
/// atteignable — c'est la seule chose qui rende le reste utilisable.
final class TableEditingTests: XCTestCase {

    private let source = """
    | Colonne A | Colonne B | C |
    |---|:---:|---:|
    | une | deux | trois |
    | quatre |  | six |
    """

    private func table(_ text: String? = nil) throws -> MarkdownTable {
        let utf16 = Array((text ?? source).utf16)
        return try XCTUnwrap(MarkdownTable.scan(utf16: utf16, in: NSRange(location: 0, length: utf16.count)))
    }

    // MARK: - L'invariant

    /// **Aucune position du tableau ne laisse le curseur hors d'une cellule.**
    ///
    /// C'est ce qu'une interception commande par commande ne saurait démontrer,
    /// et c'est pour ça que la correction se fait après coup, en un seul point.
    func testEveryPositionEndsUpInACell() throws {
        let grid = try table()
        let length = (source as NSString).length

        for caret in 0...length {
            for forward in [true, false] {
                let corrected = TableEditing.correctedCaret(caret, in: grid, forward: forward) ?? caret
                XCTAssertTrue(TableEditing.isEditable(corrected, in: grid),
                              "Position \(caret) (sens \(forward ? "→" : "←")) → \(corrected), hors cellule")
            }
        }
    }

    func testAPositionAlreadyInACellIsLeftAlone() throws {
        let grid = try table()
        let cell = try XCTUnwrap(TableEditing.cellContents(of: grid).first)
        XCTAssertNil(TableEditing.correctedCaret(cell.location, in: grid, forward: true))
        XCTAssertNil(TableEditing.correctedCaret(cell.upperBound, in: grid, forward: false))
    }

    /// Une cellule vide est une plage de longueur nulle. Si sa seule position
    /// n'était pas valide, on ne pourrait jamais remplir un tableau neuf.
    func testAnEmptyCellIsStillAPlaceToWrite() throws {
        let grid = try table()
        let empty = try XCTUnwrap(TableEditing.cellContents(of: grid).first { $0.length == 0 })
        XCTAssertTrue(TableEditing.isEditable(empty.location, in: grid))
        XCTAssertNil(TableEditing.correctedCaret(empty.location, in: grid, forward: true))
    }

    // MARK: - Le sens du déplacement

    func testMovingForwardLandsOnTheNextCellNotThePrevious() throws {
        let grid = try table()
        let contents = TableEditing.cellContents(of: grid)
        // Juste après la fin de la première cellule : dans le `|` qui suit.
        let inSeparator = contents[0].upperBound + 1
        XCTAssertEqual(TableEditing.correctedCaret(inSeparator, in: grid, forward: true), contents[1].location)
        XCTAssertEqual(TableEditing.correctedCaret(inSeparator, in: grid, forward: false), contents[0].upperBound)
    }

    /// La ligne de délimitation est invisible mais reste une ligne : une flèche
    /// vers le bas depuis l'en-tête y tombe. Elle doit en ressortir **dans la
    /// même colonne**, sinon la colonne qu'on suivait des yeux est perdue à
    /// chaque traversée.
    func testTheDelimiterLineKeepsTheColumn() throws {
        let grid = try table()
        let secondColumn = try XCTUnwrap(grid.delimiterCells.indices.contains(1) ? grid.delimiterCells[1] : nil)
        let corrected = TableEditing.correctedCaret(secondColumn.location, in: grid, forward: true)

        let position = try XCTUnwrap(TableEditing.position(of: try XCTUnwrap(corrected), in: grid))
        XCTAssertEqual(position.column, 1, "On doit ressortir dans la colonne où l'on est entré")
        XCTAssertEqual(position.row, 1, "…et dans la ligne d'après, pas dans l'en-tête")
    }

    // MARK: - Tabulation et retour

    func testTabWalksThroughTheCellsInOrder() throws {
        let grid = try table()
        let contents = TableEditing.cellContents(of: grid)

        var visited: [NSRange] = []
        var caret = contents[0].location
        while let next = TableEditing.neighbouringCell(from: caret, in: grid, forward: true) {
            visited.append(next)
            caret = next.location
        }
        XCTAssertEqual(visited, Array(contents.dropFirst()), "⇥ doit parcourir toutes les cellules, dans l'ordre")
    }

    func testShiftTabWalksBack() throws {
        let grid = try table()
        let contents = TableEditing.cellContents(of: grid)
        let last = try XCTUnwrap(contents.last)
        XCTAssertEqual(TableEditing.neighbouringCell(from: last.location, in: grid, forward: false),
                       contents[contents.count - 2])
        XCTAssertNil(TableEditing.neighbouringCell(from: contents[0].location, in: grid, forward: false),
                     "Reculer depuis la première cellule ne mène nulle part")
    }

    func testTabPastTheLastCellHasNowhereToGo() throws {
        let grid = try table()
        let last = try XCTUnwrap(TableEditing.cellContents(of: grid).last)
        XCTAssertNil(TableEditing.neighbouringCell(from: last.location, in: grid, forward: true),
                     "L'appelant doit alors ajouter une ligne")
    }

    func testReturnGoesDownInTheSameColumn() throws {
        let grid = try table()
        let header = try XCTUnwrap(grid.rows.first?.cells[1].content)
        let below = try XCTUnwrap(TableEditing.cellBelow(header.location, in: grid))
        XCTAssertEqual(below, grid.rows[1].cells[1].content)
    }

    func testReturnOnTheLastRowHasNowhereToGo() throws {
        let grid = try table()
        let last = try XCTUnwrap(grid.rows.last?.cells.first?.content)
        XCTAssertNil(TableEditing.cellBelow(last.location, in: grid))
    }

    // MARK: - Ajouter une ligne

    func testTheAddedRowIsReadBackAsARowOfTheSameTable() throws {
        let grid = try table()
        let row = try XCTUnwrap(TableEditing.newRow(below: grid.rows.count - 1, in: grid))
        let grown = source + row.text

        let utf16 = Array(grown.utf16)
        let reparsed = try XCTUnwrap(MarkdownTable.scan(utf16: utf16,
                                                        in: NSRange(location: 0, length: utf16.count)))
        XCTAssertEqual(reparsed.rows.count, grid.rows.count + 1)
        XCTAssertEqual(reparsed.columnCount, grid.columnCount)
    }

    /// Le §5 vaut ici aussi : un tableau écrit sans `|` de bord ne doit pas en
    /// gagner un parce qu'on lui a ajouté une ligne.
    func testTheAddedRowFollowsTheStyleOfTheTable() throws {
        let borderless = """
        a | b
        --- | ---
        1 | 2
        """
        let grid = try table(borderless)
        let row = try XCTUnwrap(TableEditing.newRow(below: grid.rows.count - 1, in: grid))
        XCTAssertFalse(row.text.contains("|\n"), "Aucun bord gauche ne doit apparaître")
        XCTAssertFalse(row.text.hasPrefix("\n|"))
    }

    func testTheCaretLandsInTheFirstCellOfTheNewRow() throws {
        let grid = try table()
        let row = try XCTUnwrap(TableEditing.newRow(below: grid.rows.count - 1, in: grid))
        let inserted = (row.text as NSString)
        let index = row.caret
        XCTAssertLessThanOrEqual(index, inserted.length)
        // Le curseur doit être entouré de blancs : c'est une cellule vide.
        XCTAssertEqual(inserted.substring(with: NSRange(location: index - 1, length: 1)), " ")
    }

    // MARK: - Ce qui protège la grille

    func testBackspaceAtACellStartIsRecognised() throws {
        let grid = try table()
        let cell = try XCTUnwrap(TableEditing.cellContents(of: grid).dropFirst().first)
        XCTAssertTrue(TableEditing.isAtCellStart(cell.location, in: grid))
        XCTAssertFalse(TableEditing.isAtCellStart(cell.upperBound, in: grid),
                       "En fin de cellule, `⌫` doit effacer normalement")
    }
}

/// Les mêmes règles, mais **dans l'éditeur réel**.
///
/// Les tests ci-dessus vérifient la décision ; ceux-ci vérifient qu'elle arrive
/// jusqu'au curseur. C'est une distinction qui compte : la correction est
/// branchée sur `textViewDidChangeSelection`, donc sur un rappel d'AppKit qu'on
/// ne peut pas supposer — il faut le déclencher.
@MainActor
final class TableEditingInTheEditorTests: XCTestCase {

    private let source = """
    Avant.

    | Colonne A | Colonne B |
    |---|---|
    | une | deux |
    | trois | quatre |

    Après.
    """

    private func editor() -> EditorController {
        let controller = EditorController(typography: .default)
        controller.textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.textView.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        controller.textView.textContainer?.widthTracksTextView = false
        controller.setText(source)
        return controller
    }

    private func grid(_ controller: EditorController) throws -> MarkdownTable {
        for span in controller.spans {
            if case .table(let table?) = span.kind { return table }
        }
        throw XCTSkip("aucun tableau analysé")
    }

    /// Le curseur posé dans un `|` doit ressortir dans une cellule, tout seul.
    func testTheCaretNeverRestsInsideTheHiddenPipes() throws {
        let controller = editor()
        let table = try grid(controller)
        let cells = TableEditing.cellContents(of: table)

        // Entre la fin de la première cellule et le début de la deuxième, il n'y
        // a que du masqué : `|` et blancs de remplissage.
        for caret in (cells[0].upperBound + 1)..<cells[1].location {
            controller.textView.setSelectedRange(NSRange(location: caret, length: 0))
            let landed = controller.textView.selectedRange().location
            XCTAssertTrue(TableEditing.isEditable(landed, in: table),
                          "Posé en \(caret), le curseur s'est arrêté en \(landed), hors cellule")
        }
    }

    /// Et il ne bouge pas ailleurs : la correction ne doit toucher qu'aux
    /// tableaux, pas au reste du document.
    func testTheCaretIsLeftAloneOutsideTables() {
        let controller = editor()
        for caret in [0, 3, 6] {
            controller.textView.setSelectedRange(NSRange(location: caret, length: 0))
            XCTAssertEqual(controller.textView.selectedRange().location, caret)
        }
    }

    /// Une sélection est un geste en cours : on ne la déplace pas sous la main
    /// de l'utilisateur, même si elle traverse des `|`.
    func testASelectionAcrossTheGridIsNotCorrected() throws {
        let controller = editor()
        let table = try grid(controller)
        let cells = TableEditing.cellContents(of: table)
        let selection = NSRange(location: cells[0].location,
                                length: cells[2].upperBound - cells[0].location)

        controller.textView.setSelectedRange(selection)
        XCTAssertEqual(controller.textView.selectedRange(), selection)
    }

    func testTabMovesToTheNextCellAndSelectsIt() throws {
        let controller = editor()
        let table = try grid(controller)
        let cells = TableEditing.cellContents(of: table)

        controller.textView.setSelectedRange(NSRange(location: cells[0].location, length: 0))
        XCTAssertTrue(controller.textView.handlesIndent?(false) ?? false, "⇥ doit être pris en charge")
        XCTAssertEqual(controller.textView.selectedRange(), cells[1],
                       "Le contenu de la cellule d'arrivée est sélectionné : on remplace en tapant")
    }

    func testReturnGoesToTheRowBelowWithoutBreakingTheTable() throws {
        let controller = editor()
        let table = try grid(controller)
        let header = try XCTUnwrap(table.rows.first?.cells[1].content)

        controller.textView.setSelectedRange(NSRange(location: header.location, length: 0))
        XCTAssertTrue(controller.textView.handlesNewline?() ?? false)
        XCTAssertEqual(controller.text, source, "⏎ dans un tableau ne doit rien insérer")
        XCTAssertEqual(controller.textView.selectedRange(), table.rows[1].cells[1].content)
    }

    /// `⏎` sur la dernière ligne **sort du tableau**.
    ///
    /// C'est `⇥` qui ajoute une ligne. Si `⏎` le faisait aussi, il n'existerait
    /// aucun moyen de quitter un tableau par la touche qu'on essaie en premier :
    /// chaque tentative de sortie en aurait ajouté une.
    func testReturnOnTheLastRowLeavesTheTable() throws {
        let controller = editor()
        let table = try grid(controller)
        let last = try XCTUnwrap(table.rows.last?.cells.first?.content)

        controller.textView.setSelectedRange(NSRange(location: last.location, length: 0))
        XCTAssertTrue(controller.textView.handlesNewline?() ?? false)

        XCTAssertEqual(controller.text, source, "Sortir ne doit rien écrire quand il y a déjà une ligne après")
        XCTAssertGreaterThan(controller.textView.selectedRange().location, table.rows.last!.line.upperBound - 1)
        XCTAssertNil(TableEditing.position(of: controller.textView.selectedRange().location, in: table),
                     "Le curseur doit être hors du tableau")
    }

    /// Et quand le tableau finit le document, il faut bien lui écrire une sortie.
    func testReturnLeavesATableThatEndsTheDocument() throws {
        let controller = editor()
        controller.setText("| a | b |\n|---|---|\n| c | d |")
        let table = try grid(controller)
        let last = try XCTUnwrap(table.rows.last?.cells.first?.content)

        controller.textView.setSelectedRange(NSRange(location: last.location, length: 0))
        XCTAssertTrue(controller.textView.handlesNewline?() ?? false)
        XCTAssertTrue(controller.text.hasSuffix("\n\n"), "Une ligne où écrire doit apparaître")
        XCTAssertNil(TableEditing.position(of: controller.textView.selectedRange().location, in: table))
    }

    /// `⌫` au début d'une cellule mangerait le `|` qui précède, donc fusionnerait
    /// deux colonnes. Il recule d'une cellule à la place.
    func testBackspaceAtACellStartDoesNotBreakTheGrid() throws {
        let controller = editor()
        let table = try grid(controller)
        let second = TableEditing.cellContents(of: table)[1]

        controller.textView.setSelectedRange(NSRange(location: second.location, length: 0))
        controller.textView.deleteBackward(nil)

        XCTAssertEqual(controller.text, source, "Rien ne doit être supprimé")
        XCTAssertEqual(controller.textView.selectedRange().location,
                       TableEditing.cellContents(of: table)[0].upperBound)
    }
}
