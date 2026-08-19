// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import Foundation

/// Write **inside** a table without ever seeing its `|`.
///
/// # What this file replaces
///
/// The first version collapsed the grid as soon as the caret entered: `| one |
/// two |` would reappear, the source got edited, then the caret exited again.
/// That was the fallback specified by §2.6, and it was honest, but it requires
/// knowing markdown table syntax, which is exactly what the app promises not to
/// impose anymore. Nobody writes a table by hand.
///
/// The grid therefore stays displayed at all times, and this is where the
/// price gets paid: **caret positions that correspond to nothing on screen**.
///
/// # The problem, precisely
///
/// The `|`, the padding whitespace and the `|---|` row are hidden. §2.3 shows
/// that the caret can never land inside a hidden marker, but that proof relies
/// on a construct revealing itself when the caret touches it. A grid that
/// **never** collapses falls outside that reasoning: the buffer contains
/// characters that nothing will display, and a right arrow can place the caret
/// in the middle of them.
///
/// The answer is not to intercept movement commands one by one: there are
/// about thirty of them with their selection variants, and one would
/// eventually be missed. The answer is to **correct the caret after the
/// fact**: whatever the gesture (arrow key, click, `⌘↓`, dictation), if it
/// lands outside a cell, the caret is brought back into the nearest one, in
/// the direction it was moving.
///
/// Everything here is pure and AppKit-free: that is what makes it possible to
/// verify by test that **no position in a real table leaves the caret outside
/// a cell**, something no interception approach could prove.
enum TableEditing {

    /// The content ranges of the cells, in document order.
    ///
    /// The delimiter row is not part of it: it never renders, so nothing is
    /// ever written into it.
    static func cellContents(of table: MarkdownTable) -> [NSRange] {
        table.rows.flatMap { $0.cells.map(\.content) }
    }

    /// Is this point a writable location?
    ///
    /// Bounds inclusive: the start and end of a cell are inside the cell. An
    /// empty cell is a zero-length range, and its only position is valid;
    /// otherwise a fresh table could never be filled in.
    static func isEditable(_ location: Int, in table: MarkdownTable) -> Bool {
        cellContents(of: table).contains { RevealPolicy.contains($0, location) }
    }

    /// Brings the caret back into a cell.
    ///
    /// - Parameter forward: the direction of the movement that just happened.
    ///   When moving forward, the first valid position **after** is used;
    ///   when moving backward, the last one **before** is used. This is what
    ///   makes a right arrow keep advancing instead of bouncing back to the
    ///   cell it just left.
    /// - Returns: `nil` when the position is already valid, or when none is.
    static func correctedCaret(_ location: Int, in table: MarkdownTable, forward: Bool) -> Int? {
        guard !isEditable(location, in: table) else { return nil }

        // On the delimiter row, the column is known: the caret exits into the
        // **same column**, one row further down. Without this, a down arrow
        // from the header row would send the caret back to the start of the
        // table, and the column being followed visually would be lost on
        // every crossing.
        if RevealPolicy.contains(table.delimiter, location),
           let column = table.delimiterCells.firstIndex(where: { RevealPolicy.contains($0, location) })
               ?? nearestColumn(to: location, among: table.delimiterCells),
           let target = cell(row: forward ? 1 : 0, column: column, in: table) {
            return target.location
        }

        let contents = cellContents(of: table)
        if forward, let next = contents.first(where: { $0.location >= location }) {
            return next.location
        }
        if !forward, let previous = contents.last(where: { $0.upperBound <= location }) {
            return previous.upperBound
        }
        // Edge of the table: the caret falls back to the other end rather
        // than being left inside the `|`.
        return forward ? contents.last?.upperBound : contents.first?.location
    }

    /// The neighbouring cell, for `⇥` and `⇧⇥`.
    ///
    /// It is returned **whole**: Tab selects the entire content of the
    /// destination cell, which lets typing replace it. This is the gesture of
    /// a spreadsheet, and of Apple Notes.
    ///
    /// - Returns: `nil` past the last cell; the caller then creates a new
    ///   row.
    static func neighbouringCell(from location: Int, in table: MarkdownTable, forward: Bool) -> NSRange? {
        let contents = cellContents(of: table)
        guard let index = contents.firstIndex(where: { RevealPolicy.contains($0, location) })
            ?? contents.firstIndex(where: { $0.location >= location })
        else { return nil }

        let target = forward ? index + 1 : index - 1
        return contents.indices.contains(target) ? contents[target] : nil
    }

    /// The cell in the same column on the next row, for `⏎`.
    static func cellBelow(_ location: Int, in table: MarkdownTable) -> NSRange? {
        guard let position = position(of: location, in: table) else { return nil }
        return cell(row: position.row + 1, column: position.column, in: table)
    }

    /// Where this caret sits, as (row, column).
    static func position(of location: Int, in table: MarkdownTable) -> (row: Int, column: Int)? {
        for (row, line) in table.rows.enumerated() {
            for (column, cell) in line.cells.enumerated()
            where RevealPolicy.contains(cell.content, location) {
                return (row, column)
            }
        }
        return nil
    }

    /// Is the caret at the first position of a cell?
    ///
    /// Used by `⌫`: deleting there would eat the preceding `|`, silently
    /// merging two columns.
    static func isAtCellStart(_ location: Int, in table: MarkdownTable) -> Bool {
        cellContents(of: table).contains { $0.location == location }
    }

    // MARK: - Adding a row

    /// The empty row to insert below `row`, and where to place the caret in
    /// it.
    ///
    /// The style follows the row above (leading pipe or not), because §5
    /// applies here too: a table written without a border `|` must not gain
    /// one just because a row was added to it.
    static func newRow(below row: Int, in table: MarkdownTable) -> (text: String, caret: Int)? {
        guard table.rows.indices.contains(row) else { return nil }
        let model = table.rows[row]
        let columns = max(1, table.columnCount)

        var line = model.hasLeadingPipe ? "|" : ""
        // An empty cell, not a blank: `|  |` reads back as an empty cell, and
        // the caret lands there without crossing spaces.
        for _ in 0..<columns { line += "  |" }
        if !model.hasLeadingPipe { line.removeLast() }

        let caret = (model.hasLeadingPipe ? 1 : 0) + 1
        return ("\n" + line, caret + 1)
    }

    // MARK: - Details

    private static func cell(row: Int, column: Int, in table: MarkdownTable) -> NSRange? {
        guard table.rows.indices.contains(row) else { return nil }
        let cells = table.rows[row].cells
        guard !cells.isEmpty else { return nil }
        return cells[min(column, cells.count - 1)].content
    }

    /// The column whose range is closest, for a position that fell between
    /// two `---` on the delimiter row.
    private static func nearestColumn(to location: Int, among cells: [NSRange]) -> Int? {
        cells.indices.min { left, right in
            distance(from: location, to: cells[left]) < distance(from: location, to: cells[right])
        }
    }

    private static func distance(from location: Int, to range: NSRange) -> Int {
        if location < range.location { return range.location - location }
        if location > range.upperBound { return location - range.upperBound }
        return 0
    }
}
