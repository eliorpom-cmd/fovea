// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import Foundation

/// The geometry of a GFM table, read **directly from the source**.
///
/// # Why not use cmark's tree
///
/// `swift-markdown` does give a `Table`, its rows and its cells, but it does
/// not give what the rendering needs: the position of each `|`, that of the
/// padding whitespace, and the delimiter row, which the parser consumes and
/// makes disappear. Yet those are exactly the characters that need to be
/// hidden.
///
/// The scan is therefore done here, by hand. It is short, has no ambiguity to
/// resolve, and works in the same UTF-16 units as the rest of the editor.
///
/// # The splitting rule
///
/// GFM splits cells on `|` **before** any other inline parsing. A `|` inside
/// a code span therefore still splits, and the only way to write one inside a
/// cell is `\|`. This is the rule that is applied here, not a smarter one
/// that would produce a rendering different from GitHub's.
struct MarkdownTable: Equatable, Sendable {

    struct Cell: Equatable, Sendable {
        /// The content, padding whitespace excluded. It is the only part
        /// that stays visible when the grid is displayed.
        var content: NSRange
        /// The whitespace between the `|` and the content. Hidden along with
        /// the `|`: the grid places the columns itself, the source's spacing
        /// is not its concern.
        var padding: [NSRange]
    }

    struct Row: Equatable, Sendable {
        var line: NSRange
        /// The `|` of the row, in the order they appear.
        var pipes: [NSRange]
        var cells: [Cell]
        /// True if the row opens with a `|`, which then serves as the left
        /// border.
        var hasLeadingPipe: Bool
    }

    /// The `|---|:--:|` row. It carries no content: entirely hidden when
    /// read, it leaves room for the header rule.
    var delimiter: NSRange
    /// The header row followed by the body. The delimiter row is not part of
    /// it.
    var rows: [Row]
    /// How many columns the delimiter row declares.
    ///
    /// The `:--`/`:-:`/`--:` alignments it can also carry are **read but not
    /// kept**: every cell is drawn from the same edge, because a grid whose
    /// columns each start somewhere different is harder to scan than one
    /// where every entry lands at the same point. The delimiter row still has
    /// to be validated — that is what makes the block a table at all — so the
    /// colons are parsed and then dropped. They stay in the file untouched.
    var columnCount: Int

    /// Everything that must disappear when read: the `|`, the padding
    /// whitespace, and the whole delimiter row.
    var markerRanges: [NSRange] {
        var result: [NSRange] = [delimiter]
        for row in rows {
            result.append(contentsOf: row.pipes)
            for cell in row.cells {
                result.append(contentsOf: cell.padding)
            }
        }
        return result.filter { $0.length > 0 }.sorted { $0.location < $1.location }
    }

    /// Shifts all positions, after a per-fragment parse (§3.3).
    func shifted(by delta: Int) -> MarkdownTable {
        guard delta != 0 else { return self }
        func move(_ range: NSRange) -> NSRange {
            NSRange(location: range.location + delta, length: range.length)
        }
        var copy = self
        copy.delimiter = move(delimiter)
        copy.rows = rows.map { row in
            var moved = row
            moved.line = move(row.line)
            moved.pipes = row.pipes.map(move)
            moved.cells = row.cells.map { cell in
                var movedCell = cell
                movedCell.content = move(cell.content)
                movedCell.padding = cell.padding.map(move)
                return movedCell
            }
            return moved
        }
        return copy
    }

    // MARK: - Scanning

    /// Reads a table inside `range`, or returns `nil` if it is not one.
    ///
    /// Returning `nil` is not a failure: it is the §6 behaviour for a
    /// malformed table. No grid is drawn, the source stays displayed as is,
    /// and intent is never guessed at.
    static func scan(utf16: [UInt16], in range: NSRange) -> MarkdownTable? {
        let lines = lineRanges(utf16: utf16, in: range)
        guard lines.count >= 2 else { return nil }

        let parsed = lines.map { row(utf16: utf16, line: $0) }
        guard let columnCount = delimiterColumnCount(parsed[1], utf16: utf16) else { return nil }

        return MarkdownTable(delimiter: lines[1],
                             rows: Array(parsed[..<1] + parsed[2...]),
                             columnCount: columnCount)
    }

    // MARK: - Splitting a row

    private static let pipe = UInt16(UnicodeScalar("|").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)

    private static func row(utf16: [UInt16], line: NSRange) -> Row {
        var pipes: [NSRange] = []
        var offset = line.location
        while offset < line.upperBound {
            if utf16[offset] == pipe, !isEscaped(utf16: utf16, at: offset, from: line.location) {
                pipes.append(NSRange(location: offset, length: 1))
            }
            offset += 1
        }

        // The segments between the `|`, edges included.
        var segments: [NSRange] = []
        var start = line.location
        for pipeRange in pipes {
            segments.append(NSRange(location: start, length: pipeRange.location - start))
            start = pipeRange.upperBound
        }
        segments.append(NSRange(location: start, length: line.upperBound - start))

        // A border `|` does not open a cell: the segment preceding it,
        // empty or blank, is not one. Same on the right.
        var hasLeadingPipe = false
        if !pipes.isEmpty, let first = segments.first, isBlank(utf16: utf16, in: first) {
            hasLeadingPipe = true
            segments.removeFirst()
        }
        if !pipes.isEmpty, let last = segments.last, isBlank(utf16: utf16, in: last), segments.count > 1 {
            segments.removeLast()
        }

        let cells = segments.map { cell(utf16: utf16, in: $0) }
        return Row(line: line, pipes: pipes, cells: cells, hasLeadingPipe: hasLeadingPipe)
    }

    private static func cell(utf16: [UInt16], in segment: NSRange) -> Cell {
        var start = segment.location
        var end = segment.upperBound
        while start < end, isSpace(utf16[start]) { start += 1 }
        while end > start, isSpace(utf16[end - 1]) { end -= 1 }

        // An empty cell is only whitespace: the two loops meet against the
        // closing `|`, and anything typed there would get written there:
        // `|  Name|` instead of `| Name |`. A space is kept on each side,
        // which is the form everyone writes by hand.
        if start == end, segment.length >= 2 {
            start = segment.location + 1
            end = start
        }

        let content = NSRange(location: start, length: end - start)
        var padding: [NSRange] = []
        if start > segment.location {
            padding.append(NSRange(location: segment.location, length: start - segment.location))
        }
        if segment.upperBound > end {
            padding.append(NSRange(location: end, length: segment.upperBound - end))
        }
        return Cell(content: content, padding: padding)
    }

    /// Validates the delimiter row and counts its columns, or `nil` if it is
    /// not a delimiter row.
    private static func delimiterColumnCount(_ row: Row, utf16: [UInt16]) -> Int? {
        var count = 0
        for cell in row.cells {
            guard cell.content.length > 0 else { return nil }
            let colon = UInt16(UnicodeScalar(":").value)
            let dash = UInt16(UnicodeScalar("-").value)

            var offset = cell.content.location
            let end = cell.content.upperBound
            if utf16[offset] == colon { offset += 1 }
            var dashes = 0
            while offset < end, utf16[offset] == dash { offset += 1; dashes += 1 }
            if offset < end, utf16[offset] == colon { offset += 1 }

            // Nothing else is tolerated: `|--x--|` is not a delimiter, and
            // the block is then not a table.
            guard dashes >= 1, offset == end else { return nil }
            count += 1
        }
        return count > 0 ? count : nil
    }

    // MARK: - Tools

    /// The lines of a range, terminator excluded.
    private static func lineRanges(utf16: [UInt16], in range: NSRange) -> [NSRange] {
        let newline = UInt16(10)
        var result: [NSRange] = []
        var start = range.location
        var offset = range.location
        while offset < min(range.upperBound, utf16.count) {
            if utf16[offset] == newline {
                result.append(NSRange(location: start, length: offset - start))
                start = offset + 1
            }
            offset += 1
        }
        if start < min(range.upperBound, utf16.count) {
            result.append(NSRange(location: start, length: min(range.upperBound, utf16.count) - start))
        }
        return result
    }

    /// A `|` preceded by an **odd** number of backslashes is escaped.
    private static func isEscaped(utf16: [UInt16], at location: Int, from start: Int) -> Bool {
        var count = 0
        var offset = location - 1
        while offset >= start, utf16[offset] == backslash {
            count += 1
            offset -= 1
        }
        return count % 2 == 1
    }

    private static func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }

    private static func isBlank(utf16: [UInt16], in range: NSRange) -> Bool {
        for offset in range.location..<range.upperBound where !isSpace(utf16[offset]) {
            return false
        }
        return true
    }
}
