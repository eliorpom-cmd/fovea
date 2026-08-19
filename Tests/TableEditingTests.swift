// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
@testable import Fovea

/// Writing into a table without ever seeing its `|` (§2.6).
///
/// The grid no longer collapses under the caret. The price of that choice is
/// the buffer positions that nothing displays anymore: the `|`, the padding
/// spaces, the `|---|` delimiter row. These tests check that none of them is
/// reachable: that is the only thing that makes the rest usable.
final class TableEditingTests: XCTestCase {

    private let source = """
    | Column A | Column B | C |
    |---|:---:|---:|
    | one | two | three |
    | four |  | six |
    """

    private func table(_ text: String? = nil) throws -> MarkdownTable {
        let utf16 = Array((text ?? source).utf16)
        return try XCTUnwrap(MarkdownTable.scan(utf16: utf16, in: NSRange(location: 0, length: utf16.count)))
    }

    // MARK: - The invariant

    /// **No position in the table leaves the caret outside a cell.**
    ///
    /// This is something a command-by-command interception could never prove,
    /// which is why the correction happens after the fact, at a single point.
    func testEveryPositionEndsUpInACell() throws {
        let grid = try table()
        let length = (source as NSString).length

        for caret in 0...length {
            for forward in [true, false] {
                let corrected = TableEditing.correctedCaret(caret, in: grid, forward: forward) ?? caret
                XCTAssertTrue(TableEditing.isEditable(corrected, in: grid),
                              "Position \(caret) (direction \(forward ? "→" : "←")) → \(corrected), outside a cell")
            }
        }
    }

    func testAPositionAlreadyInACellIsLeftAlone() throws {
        let grid = try table()
        let cell = try XCTUnwrap(TableEditing.cellContents(of: grid).first)
        XCTAssertNil(TableEditing.correctedCaret(cell.location, in: grid, forward: true))
        XCTAssertNil(TableEditing.correctedCaret(cell.upperBound, in: grid, forward: false))
    }

    /// An empty cell is a zero-length range. If its only position
    /// weren't valid, a new table could never be filled in.
    func testAnEmptyCellIsStillAPlaceToWrite() throws {
        let grid = try table()
        let empty = try XCTUnwrap(TableEditing.cellContents(of: grid).first { $0.length == 0 })
        XCTAssertTrue(TableEditing.isEditable(empty.location, in: grid))
        XCTAssertNil(TableEditing.correctedCaret(empty.location, in: grid, forward: true))
    }

    // MARK: - Direction of movement

    func testMovingForwardLandsOnTheNextCellNotThePrevious() throws {
        let grid = try table()
        let contents = TableEditing.cellContents(of: grid)
        // Right after the end of the first cell: inside the `|` that follows.
        let inSeparator = contents[0].upperBound + 1
        XCTAssertEqual(TableEditing.correctedCaret(inSeparator, in: grid, forward: true), contents[1].location)
        XCTAssertEqual(TableEditing.correctedCaret(inSeparator, in: grid, forward: false), contents[0].upperBound)
    }

    /// The delimiter row is invisible but is still a row: pressing the down
    /// arrow from the header row lands on it. It must come back out **in the
    /// same column**, otherwise the column being tracked visually is lost on
    /// every crossing.
    func testTheDelimiterLineKeepsTheColumn() throws {
        let grid = try table()
        let secondColumn = try XCTUnwrap(grid.delimiterCells.indices.contains(1) ? grid.delimiterCells[1] : nil)
        let corrected = TableEditing.correctedCaret(secondColumn.location, in: grid, forward: true)

        let position = try XCTUnwrap(TableEditing.position(of: try XCTUnwrap(corrected), in: grid))
        XCTAssertEqual(position.column, 1, "Must come back out in the column that was entered")
        XCTAssertEqual(position.row, 1, "…and in the row after, not in the header row")
    }

    // MARK: - Tab and return

    func testTabWalksThroughTheCellsInOrder() throws {
        let grid = try table()
        let contents = TableEditing.cellContents(of: grid)

        var visited: [NSRange] = []
        var caret = contents[0].location
        while let next = TableEditing.neighbouringCell(from: caret, in: grid, forward: true) {
            visited.append(next)
            caret = next.location
        }
        XCTAssertEqual(visited, Array(contents.dropFirst()), "⇥ must walk through every cell, in order")
    }

    func testShiftTabWalksBack() throws {
        let grid = try table()
        let contents = TableEditing.cellContents(of: grid)
        let last = try XCTUnwrap(contents.last)
        XCTAssertEqual(TableEditing.neighbouringCell(from: last.location, in: grid, forward: false),
                       contents[contents.count - 2])
        XCTAssertNil(TableEditing.neighbouringCell(from: contents[0].location, in: grid, forward: false),
                     "Moving backward from the first cell leads nowhere")
    }

    func testTabPastTheLastCellHasNowhereToGo() throws {
        let grid = try table()
        let last = try XCTUnwrap(TableEditing.cellContents(of: grid).last)
        XCTAssertNil(TableEditing.neighbouringCell(from: last.location, in: grid, forward: true),
                     "The caller must then add a row")
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

    // MARK: - Adding a row

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

    /// §5 applies here too: a table written without border `|` must not
    /// gain one just because a row was added to it.
    func testTheAddedRowFollowsTheStyleOfTheTable() throws {
        let borderless = """
        a | b
        --- | ---
        1 | 2
        """
        let grid = try table(borderless)
        let row = try XCTUnwrap(TableEditing.newRow(below: grid.rows.count - 1, in: grid))
        XCTAssertFalse(row.text.contains("|\n"), "No left border should appear")
        XCTAssertFalse(row.text.hasPrefix("\n|"))
    }

    func testTheCaretLandsInTheFirstCellOfTheNewRow() throws {
        let grid = try table()
        let row = try XCTUnwrap(TableEditing.newRow(below: grid.rows.count - 1, in: grid))
        let inserted = (row.text as NSString)
        let index = row.caret
        XCTAssertLessThanOrEqual(index, inserted.length)
        // The caret must be surrounded by spaces: it's an empty cell.
        XCTAssertEqual(inserted.substring(with: NSRange(location: index - 1, length: 1)), " ")
    }

    // MARK: - What protects the grid

    func testBackspaceAtACellStartIsRecognised() throws {
        let grid = try table()
        let cell = try XCTUnwrap(TableEditing.cellContents(of: grid).dropFirst().first)
        XCTAssertTrue(TableEditing.isAtCellStart(cell.location, in: grid))
        XCTAssertFalse(TableEditing.isAtCellStart(cell.upperBound, in: grid),
                       "At the end of a cell, `⌫` must delete normally")
    }
}

/// The same rules, but **in the real editor**.
///
/// The tests above check the decision; these check that it reaches the
/// caret. This distinction matters: the correction is wired into
/// `textViewDidChangeSelection`, an AppKit callback that cannot be assumed
/// to fire on its own: it has to be triggered.
@MainActor
final class TableEditingInTheEditorTests: XCTestCase {

    private let source = """
    Before.

    | Column A | Column B |
    |---|---|
    | one | two |
    | three | four |

    After.
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
        throw XCTSkip("no table parsed")
    }

    /// A caret placed inside a `|` must come back out inside a cell, alone.
    func testTheCaretNeverRestsInsideTheHiddenPipes() throws {
        let controller = editor()
        let table = try grid(controller)
        let cells = TableEditing.cellContents(of: table)

        // Between the end of the first cell and the start of the second, there
        // is only hidden content: `|` and padding spaces.
        for caret in (cells[0].upperBound + 1)..<cells[1].location {
            controller.textView.setSelectedRange(NSRange(location: caret, length: 0))
            let landed = controller.textView.selectedRange().location
            XCTAssertTrue(TableEditing.isEditable(landed, in: table),
                          "Placed at \(caret), the caret stopped at \(landed), outside a cell")
        }
    }

    /// And it doesn't move elsewhere: the correction must only affect
    /// tables, not the rest of the document.
    func testTheCaretIsLeftAloneOutsideTables() {
        let controller = editor()
        for caret in [0, 3, 6] {
            controller.textView.setSelectedRange(NSRange(location: caret, length: 0))
            XCTAssertEqual(controller.textView.selectedRange().location, caret)
        }
    }

    /// A selection is a gesture in progress: it must not be moved out from
    /// under the user, even if it crosses `|`.
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
        XCTAssertTrue(controller.textView.handlesIndent?(false) ?? false, "⇥ must be handled")
        XCTAssertEqual(controller.textView.selectedRange(), cells[1],
                       "The content of the destination cell is selected: typing replaces it")
    }

    func testReturnGoesToTheRowBelowWithoutBreakingTheTable() throws {
        let controller = editor()
        let table = try grid(controller)
        let header = try XCTUnwrap(table.rows.first?.cells[1].content)

        controller.textView.setSelectedRange(NSRange(location: header.location, length: 0))
        XCTAssertTrue(controller.textView.handlesNewline?() ?? false)
        XCTAssertEqual(controller.text, source, "⏎ inside a table must not insert anything")
        XCTAssertEqual(controller.textView.selectedRange(), table.rows[1].cells[1].content)
    }

    /// `⏎` on the last row **leaves the table**.
    ///
    /// It's `⇥` that adds a row. If `⏎` did too, there would be no way to
    /// leave a table using the key one tries first: every attempt to exit
    /// would have added another row.
    func testReturnOnTheLastRowLeavesTheTable() throws {
        let controller = editor()
        let table = try grid(controller)
        let last = try XCTUnwrap(table.rows.last?.cells.first?.content)

        controller.textView.setSelectedRange(NSRange(location: last.location, length: 0))
        XCTAssertTrue(controller.textView.handlesNewline?() ?? false)

        XCTAssertEqual(controller.text, source, "Leaving must not write anything when there is already a line after")
        XCTAssertGreaterThan(controller.textView.selectedRange().location, table.rows.last!.line.upperBound - 1)
        XCTAssertNil(TableEditing.position(of: controller.textView.selectedRange().location, in: table),
                     "The caret must be outside the table")
    }

    /// And when the table ends the document, an exit line has to be written for it.
    func testReturnLeavesATableThatEndsTheDocument() throws {
        let controller = editor()
        controller.setText("| a | b |\n|---|---|\n| c | d |")
        let table = try grid(controller)
        let last = try XCTUnwrap(table.rows.last?.cells.first?.content)

        controller.textView.setSelectedRange(NSRange(location: last.location, length: 0))
        XCTAssertTrue(controller.textView.handlesNewline?() ?? false)
        XCTAssertTrue(controller.text.hasSuffix("\n\n"), "A line to write into must appear")
        XCTAssertNil(TableEditing.position(of: controller.textView.selectedRange().location, in: table))
    }

    /// The typed word must stay **inside its cell**.
    ///
    /// The caret correction runs on selection change, which precedes
    /// re-parsing: it therefore placed the caret according to the geometry
    /// from **before** the keystroke. In an empty cell, the first letter
    /// typed sent the caret into the next cell, and the word spread across
    /// the whole row: typing "Amy" produced `|  A| my |  |`.
    func testAWordTypedInAnEmptyCellStaysInIt() throws {
        let controller = editor()
        controller.setText("|  |  |  |\n|---|---|---|\n|  |  |  |\n")
        let table = try grid(controller)
        // Where inserting a new table places the caret.
        let first = TableEditing.cellContents(of: table)[0]
        controller.textView.setSelectedRange(NSRange(location: first.location, length: 0))

        for letter in ["A", "m", "y"] {
            controller.textView.insertText(letter, replacementRange: controller.textView.selectedRange())
        }

        let firstRow = controller.text.components(separatedBy: "\n")[0]
        XCTAssertEqual(firstRow, "| Amy |  |  |",
                       "The three letters must fit in the first cell")
    }

    /// The same thing where a cell already has content: typing continues
    /// there, without jumping to another column.
    func testTypingContinuesInsideAFilledCell() throws {
        let controller = editor()
        let table = try grid(controller)
        let first = TableEditing.cellContents(of: table)[0]
        controller.textView.setSelectedRange(NSRange(location: first.upperBound, length: 0))

        controller.textView.insertText("X", replacementRange: controller.textView.selectedRange())

        XCTAssertTrue(controller.text.contains("| Column AX |"), controller.text)
    }

    /// `⌫` at the start of a cell would eat the `|` that precedes it, thus
    /// merging two columns. It moves back a cell instead.
    func testBackspaceAtACellStartDoesNotBreakTheGrid() throws {
        let controller = editor()
        let table = try grid(controller)
        let second = TableEditing.cellContents(of: table)[1]

        controller.textView.setSelectedRange(NSRange(location: second.location, length: 0))
        controller.textView.deleteBackward(nil)

        XCTAssertEqual(controller.text, source, "Nothing should be deleted")
        XCTAssertEqual(controller.textView.selectedRange().location,
                       TableEditing.cellContents(of: table)[0].upperBound)
    }
}
