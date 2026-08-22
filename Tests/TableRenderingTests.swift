// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// The table grid, **measured against actual layout** (§2.6).
///
/// As with milestone 0, this checks x-coordinates, not intent: a column is
/// aligned if the caret placed at the start of each cell lands at exactly the
/// same x. That is the only assertion that makes sense here: the grid only
/// exists in the kerning of the `|`, and nothing in the buffer would say
/// whether it is straight.
@MainActor
final class TableRenderingTests: XCTestCase {

    /// TextKit rounds to the sub-pixel; the tolerance stays well below the
    /// width of the narrowest character.
    private let tolerance: CGFloat = 0.6

    // MARK: - The assertion that matters

    func testColumnsLineUpAcrossRows() throws {
        // The contents don't have the same length from one row to the next:
        // without a grid, the second column would sit at three different x-coordinates.
        let source = """
        | a | x |
        |---|---|
        | bbbb | y |
        | cc | z |
        """
        let view = try render(source)
        let xs = try ["x", "y", "z"].map { try caretX(atFirstOccurrenceOf: $0, in: source, view: view) }

        XCTAssertEqual(xs[0], xs[1], accuracy: tolerance, "The header row and the first row must align")
        XCTAssertEqual(xs[1], xs[2], accuracy: tolerance, "The rows must align with each other")
    }

    func testTheSecondColumnStartsAfterTheWidestCellOfTheFirst() throws {
        let source = """
        | a | x |
        |---|---|
        | bbbbbbbb | y |
        """
        let view = try render(source)
        let firstColumn = try caretX(atFirstOccurrenceOf: "a", in: source, view: view)
        let secondColumn = try caretX(atFirstOccurrenceOf: "x", in: source, view: view)
        let widest = try width(of: "bbbbbbbb", in: source, view: view)

        // Eight characters plus the gutter: the next column cannot
        // start before that, otherwise "bbbbbbbb" would overflow into it.
        XCTAssertGreaterThan(secondColumn - firstColumn, widest)
    }

    // MARK: - Alignments

    /// **Every cell starts from the same edge.**
    ///
    /// The alignment of the `|:---:|---:|` line stays in the file: it simply
    /// isn't rendered anymore. A grid whose columns each start at a different
    /// edge is harder to scan than one whose entries all land at the same
    /// point, and rendering is what settled the question.
    func testEveryCellIsLeftAlignedWhateverTheDelimiterSays() throws {
        let source = """
        | g | c | d |
        |---|:-:|--:|
        | 1 | 1 | 1 |
        | 1234 | 1234 | 1234 |
        """
        let view = try render(source)
        for column in 0..<3 {
            let short = try cellStart(row: "| 1 | 1 | 1 |", column: column, in: source, view: view)
            let long = try cellStart(row: "| 1234 | 1234 | 1234 |", column: column, in: source, view: view)
            XCTAssertEqual(short, long, accuracy: tolerance,
                           "Column \(column) must start at the same x on both rows")
        }
    }

    func testACellIsNotGluedToItsRule() throws {
        // A little breathing room between the rule and the first letter: without
        // it, the grid reads like a table of numbers.
        let source = "| a | b |\n|---|---|\n| c | d |"
        let view = try render(source)
        let left = try caretX(at: 0, view: view)
        let text = try caretX(atFirstOccurrenceOf: "a", in: source, view: view)
        XCTAssertGreaterThan(text - left, 2, "Content keeps an indent relative to the edge")
    }

    // MARK: - Row height

    /// **An empty table stays a table.**
    ///
    /// Masked `|` measure a hundredth of a point: a row whose cells are all
    /// empty therefore had no natural height, and the line-spacing multiplier
    /// multiplied that nothingness. The table to fill in from "6 — Tables"
    /// collapsed to three stacked rules, with no row to place the caret in.
    func testAnEmptyTableKeepsClickableRows() throws {
        let full = try lineHeights(in: try render("| a | b |\n|---|---|\n| c | d |"))
        let empty = try lineHeights(in: try render("|  |  |\n|---|---|\n|  |  |"))

        XCTAssertEqual(empty.count, full.count)
        for (index, height) in empty.enumerated() {
            XCTAssertEqual(height, full[index], accuracy: tolerance,
                           "Empty row \(index) must be the height of a full row")
        }
    }

    /// The table occupies **the entire text column**.
    ///
    /// Sized to its content, a table that was just inserted, with every cell
    /// empty, collapsed to a 168-point rule in the middle of a column three
    /// times as wide: there was nowhere visible to click.
    func testATableFillsTheTextColumn() throws {
        let typography = EditorTypography.default
        for source in ["|  |  |  |\n|---|---|---|\n|  |  |  |",
                       "| a | b |\n|---|---|\n| c | d |",
                       "| Pitfall | Symptom | Fix |\n|---|---|---|\n| a | b | c |"] {
            let view = try render(source)
            let storage = try XCTUnwrap(view.textStorage)
            let table = try XCTUnwrap(firstTable(in: source))
            let layout = try XCTUnwrap(TableLayout.measure(table, in: storage,
                                                          typography: typography,
                                                          available: typography.columnWidth))
            XCTAssertEqual(layout.width, typography.columnWidth, accuracy: 3,
                           "The table must fill the entire column: \(source)")
        }
    }

    /// Stretching must not rescue a table that's too wide: that one stays in
    /// source form, and the test is done on its **natural** width.
    func testAnOversizedTableIsStillRefusedBeforeStretching() throws {
        let source = """
        | A column with an endless title | A second one just as long | A third one to finish | And a fourth |
        |---|---|---|---|
        | a | b | c | d |
        """
        let view = try render(source)
        let storage = try XCTUnwrap(view.textStorage)
        let table = try XCTUnwrap(firstTable(in: source))
        XCTAssertNil(TableLayout.measure(table, in: storage,
                                         typography: .default,
                                         available: EditorTypography.default.columnWidth))
    }

    private func firstTable(in source: String) -> MarkdownTable? {
        for span in MarkdownParser.parse(source).spans {
            if case .table(let table?) = span.kind { return table }
        }
        return nil
    }

    // MARK: - The two states from §2.1

    func testPipesTakeNoWidthWhenTheCaretIsElsewhere() throws {
        let source = "| a | b |\n|---|---|\n| c | d |"
        let view = try render(source)
        let storage = try XCTUnwrap(view.textStorage)

        // The left border `|` of the first row.
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 0))
        // The padding spaces too: it's the grid that provides the spacing.
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 1))
        XCTAssertFalse(MarkerMask.isMasked(storage, at: 2), "\"a\" is content")
    }

    /// **The grid collapses to source under the caret** (§2.6).
    ///
    /// Grid while reading, source while editing. The app once wrote into the
    /// grid directly, with the `|` never reappearing, and paid for it with a
    /// second editor: the caret could land inside a masked marker, so every
    /// caret move had to be corrected after the fact and `⌫` at a cell
    /// boundary intercepted. That machinery is gone, which makes this reveal
    /// load-bearing rather than cosmetic — without it the buffer holds pipes,
    /// padding and a whole `|---|` row that nothing displays, and `⌫` deletes
    /// a character nobody can see.
    func testTheGridCollapsesToSourceUnderTheCaret() throws {
        let source = "| a | b |\n|---|---|\n| c | d |"
        let storage = try XCTUnwrap(render(source, caret: 2).textStorage)

        XCTAssertFalse(MarkerMask.isMasked(storage, at: 0), "The `|` must come back")
        XCTAssertNotNil(storage.attribute(.foveaRevealed, at: 0, effectiveRange: nil))
    }

    /// And the caret elsewhere draws the grid again.
    func testTheGridComesBackWhenTheCaretLeaves() throws {
        let source = "A paragraph.\n\n| a | b |\n|---|---|\n| c | d |"
        let storage = try XCTUnwrap(render(source, caret: 0).textStorage)

        let pipe = (source as NSString).range(of: "|").location
        XCTAssertTrue(MarkerMask.isMasked(storage, at: pipe), "The `|` must be hidden again")
    }

    func testTheDelimiterLineIsShorterThanARow() throws {
        // It shows nothing: its height is that of the rule it carries.
        let source = "| a |\n|---|\n| c |"
        let view = try render(source)
        let heights = try lineHeights(in: view)
        XCTAssertEqual(heights.count, 3)
        XCTAssertLessThan(heights[1], heights[0] * 0.9,
                          "The |---| line must be collapsed, not rendered as a row")
    }

    // MARK: - When there is no grid (§6)

    func testAMalformedTableKeepsItsSourceIntact() throws {
        // No grid, no masking: intent is never guessed.
        let source = "| a | b |\n| x | y |\n| 1 | 2 |"
        let view = try render(source)
        let storage = try XCTUnwrap(view.textStorage)
        for offset in 0..<storage.length {
            XCTAssertFalse(MarkerMask.isMasked(storage, at: offset),
                           "Nothing should be masked at offset \(offset)")
        }
    }

    func testATableTooWideForTheColumnStaysInSource() throws {
        // A grid wider than the column would wrap row by row and become
        // unreadable. The readable source is better.
        let wide = String(repeating: "x", count: 60)
        let source = "| \(wide) | \(wide) |\n|---|---|\n| a | b |"
        let view = try render(source)
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertFalse(MarkerMask.isMasked(storage, at: 0))
        XCTAssertNotNil(storage.attribute(.foveaRevealed, at: 0, effectiveRange: nil))
    }

    // MARK: - The buffer is never touched (§3.1)

    func testRenderingATableAddsNoCharacter() throws {
        let source = "| a | b |\n|---|---|\n| c | d |"
        let view = try render(source)
        XCTAssertEqual(view.string, source,
                       "The grid is made of attributes alone: not a single character added")
    }

    // MARK: - Helpers

    private func render(_ source: String, caret: Int? = nil) throws -> EditorTextView {
        let view = EditorTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false

        let storage = try XCTUnwrap(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)

        let parsed = MarkdownParser.parse(source)
        let revealed: Set<Int> = caret.map {
            RevealPolicy.revealedIndices(spans: parsed.spans,
                                         selection: NSRange(location: $0, length: 0),
                                         lineRange: parsed.positions.lineRange(containing: $0))
        } ?? []

        MarkdownRenderer(typography: .default)
            .render(storage, spans: parsed.spans, revealed: revealed,
                    in: NSRange(location: 0, length: storage.length))

        let layout = try XCTUnwrap(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        return view
    }

    private func caretX(at offset: Int, view: EditorTextView) throws -> CGFloat {
        let layout = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(view.textContentStorage)
        let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: offset))

        var x: CGFloat?
        layout.enumerateTextSegments(in: NSTextRange(location: location),
                                     type: .selection, options: []) { _, frame, _, _ in
            x = frame.origin.x
            return false
        }
        return try XCTUnwrap(x, "No segment at offset \(offset)")
    }

    private func caretX(atFirstOccurrenceOf needle: String, in source: String,
                        view: EditorTextView) throws -> CGFloat {
        let range = (source as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "\"\(needle)\" not found")
        return try caretX(at: range.location, view: view)
    }

    /// X-coordinate of the first character of a cell, located by its source row.
    private func cellStart(row: String, column: Int, in source: String,
                           view: EditorTextView) throws -> CGFloat {
        let line = (source as NSString).range(of: row)
        XCTAssertNotEqual(line.location, NSNotFound, "Row \"\(row)\" not found")
        // `| a | b |`: the content of column n starts after the (n+1)th
        // `|` and its space.
        var offset = line.location
        var seen = 0
        while seen <= column, offset < line.upperBound {
            if (source as NSString).character(at: offset) == UInt16(UnicodeScalar("|").value) { seen += 1 }
            offset += 1
        }
        return try caretX(at: offset + 1, view: view)
    }

    /// Rendered width of a fragment, measured between its two ends.
    private func width(of needle: String, in source: String, view: EditorTextView) throws -> CGFloat {
        let range = (source as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "\"\(needle)\" not found")
        return try caretX(at: range.upperBound, view: view) - caretX(at: range.location, view: view)
    }

    private func lineHeights(in view: EditorTextView) throws -> [CGFloat] {
        let layout = try XCTUnwrap(view.textLayoutManager)
        var heights: [CGFloat] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            heights.append(fragment.layoutFragmentFrame.height)
            return true
        }
        return heights
    }
}
