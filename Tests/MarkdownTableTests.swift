// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import XCTest
@testable import Fovea

/// Reading the grid (§2.6).
///
/// This is the layer that decides **which characters disappear** in a
/// table. A one-off error here and an entire column shifts, or a `|`
/// stays on screen in the middle of a grid.
final class MarkdownTableTests: XCTestCase {

    private func scan(_ source: String) -> MarkdownTable? {
        let utf16 = Array(source.utf16)
        return MarkdownTable.scan(utf16: utf16, in: NSRange(location: 0, length: utf16.count))
    }

    private func text(_ source: String, _ range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    // MARK: - General shape

    func testAPlainTableIsRead() throws {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        let table = try XCTUnwrap(scan(source))

        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.rows.count, 2, "The header row and body, without the delimiter row")
        XCTAssertEqual(text(source, table.delimiter), "|---|---|")
        XCTAssertEqual(table.rows.map { $0.cells.map { text(source, $0.content) } },
                       [["a", "b"], ["1", "2"]])
    }

    func testATableWithoutOuterPipesIsRead() {
        // GFM allows them, and many people write tables that way.
        let source = "a | b\n--|--\n1 | 2"
        guard let table = scan(source) else { return XCTFail("The table should be read") }
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertFalse(table.rows[0].hasLeadingPipe)
        XCTAssertEqual(table.rows[0].cells.map { text(source, $0.content) }, ["a", "b"])
    }

    /// The delimiter row is what declares how many columns there are, and the
    /// alignments it may also carry are validated and then dropped: every cell
    /// renders from the same edge. They stay in the file untouched.
    func testTheDelimiterRowDeclaresTheColumnCount() throws {
        let table = try XCTUnwrap(scan("| a | b | c | d |\n|:--|--:|:-:|---|\n| 1 | 2 | 3 | 4 |"))
        XCTAssertEqual(table.columnCount, 4)
    }

    // MARK: - What disappears

    func testEveryPipeAndEveryPadIsAMarker() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        guard let table = scan(source) else { return XCTFail("The table should be read") }

        // Everything except cell content must be covered: whatever isn't
        // hidden stays on screen, and a single forgotten `|` stands out immediately.
        var covered = Set<Int>()
        for marker in table.markerRanges {
            for offset in marker.location..<marker.upperBound { covered.insert(offset) }
        }
        var expected = Set(0..<(source as NSString).length)
        for row in table.rows {
            for cell in row.cells {
                for offset in cell.content.location..<cell.content.upperBound { expected.remove(offset) }
            }
        }
        // Line breaks are neither content nor markers.
        for (offset, unit) in Array(source.utf16).enumerated() where unit == 10 { expected.remove(offset) }
        XCTAssertEqual(covered, expected)
    }

    func testTheDelimiterLineIsEntirelyAMarker() throws {
        let source = "| a |\n|:--|\n| 1 |"
        let table = try XCTUnwrap(scan(source))
        XCTAssertTrue(table.markerRanges.contains(table.delimiter))
    }

    // MARK: - The case that would break everything

    func testAnEscapedPipeDoesNotSplitACell() throws {
        // `\|` is the only way to write a `|` inside a cell. Treating it
        // as a separator would split the cell in two and shift every
        // subsequent column.
        let source = "| a \\| b | c |\n|---|---|\n| 1 | 2 |"
        let table = try XCTUnwrap(scan(source))
        XCTAssertEqual(table.rows[0].cells.map { text(source, $0.content) }, ["a \\| b", "c"])
    }

    func testAPipeInsideACodeSpanStillSplits() throws {
        // This is the GFM rule, however surprising: cell splitting happens
        // before inline parsing. Rendering it differently would produce a
        // table different from GitHub's.
        let source = "| `a|b` | c |\n|---|---|\n| 1 | 2 |"
        let table = try XCTUnwrap(scan(source))
        XCTAssertEqual(table.rows[0].cells.count, 3)
    }

    func testAnEmptyCellSurvives() throws {
        let source = "| a || c |\n|---|---|---|\n| 1 | 2 | 3 |"
        let table = try XCTUnwrap(scan(source))
        XCTAssertEqual(table.rows[0].cells.map { text(source, $0.content) }, ["a", "", "c"])
    }

    // MARK: - What isn't a table (§6)

    func testAMalformedDelimiterYieldsNoGrid() {
        // §6: no grid, the source stays displayed as-is. Never guess.
        XCTAssertNil(scan("| a | b |\n| x | y |\n| 1 | 2 |"))
        XCTAssertNil(scan("| a | b |\n|--x|---|\n| 1 | 2 |"))
        XCTAssertNil(scan("| a | b |"))
    }

    // MARK: - Positions

    func testShiftingMovesEveryPosition() throws {
        let source = "| a |\n|---|\n| 1 |"
        let table = try XCTUnwrap(scan(source))
        let moved = table.shifted(by: 100)

        XCTAssertEqual(moved.delimiter.location, table.delimiter.location + 100)
        XCTAssertEqual(moved.rows[0].pipes[0].location, table.rows[0].pipes[0].location + 100)
        XCTAssertEqual(moved.rows[0].cells[0].content.location,
                       table.rows[0].cells[0].content.location + 100)
        XCTAssertEqual(moved.columnCount, table.columnCount)
    }

    // MARK: - Integration with the parser

    func testTheParserAttachesTheGridToTheSpan() throws {
        let source = "Before.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter.\n"
        let spans = MarkdownParser.parse(source).spans
        let table = try XCTUnwrap(spans.first { if case .table = $0.kind { return true } else { return false } })

        guard case .table(let grid?) = table.kind else { return XCTFail("The grid must be attached") }
        XCTAssertEqual(grid.columnCount, 2)
        // Positions are relative to the whole document, not to the block.
        XCTAssertEqual(text(source, grid.rows[0].cells[0].content), "a")
    }

    func testAnAccentedTableStaysAligned() throws {
        // The pitfall from §3.3: cmark counts in bytes, the buffer in UTF-16
        // code units. A table full of accented characters is the best way to
        // reveal a mismatch.
        // Accented text: exercises the UTF-8 → UTF-16 offset conversion.
        let source = "| Café | Naïve |\n|---|---|\n| Zoë | Hi |\n"
        let spans = MarkdownParser.parse(source).spans
        let table = try XCTUnwrap(spans.first { if case .table = $0.kind { return true } else { return false } })
        guard case .table(let grid?) = table.kind else { return XCTFail("The grid must be attached") }

        XCTAssertEqual(text(source, grid.rows[0].cells[0].content), "Café")
        XCTAssertEqual(text(source, grid.rows[1].cells[0].content), "Zoë")
    }
}
