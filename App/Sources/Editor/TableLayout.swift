// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// Where each column of a table falls, in points.
///
/// # Why a separate structure
///
/// The geometry has **two readers**: the rendering, which translates it into
/// kerning on the hidden `|`, and the decoration layer, which draws the rules
/// with it. As long as there were only three rules (top, under the header row,
/// bottom), the decoration layer needed to know nothing. A real grid, though,
/// has to draw **between** columns, so it has to know their x-coordinates to
/// the point, and two separate calculations would have diverged the moment
/// the font changed.
///
/// # What it measures, and why it isn't what it looks like
///
/// Widths are **measured on the rendering**, not counted in characters:
/// `**Title**` renders six characters shorter than its source, and a column
/// sized on character count would be six too wide. This is also what lets a
/// table render in the body font instead of a monospaced one: the monospaced
/// font guaranteed alignment for free, but made every table look like a code
/// block.
@MainActor
struct TableLayout {

    /// X-coordinate of the left edge of each column, from the start of the row.
    var columnOrigins: [CGFloat]
    /// Width of the widest content in each column.
    var columnWidths: [CGFloat]
    /// Gutter between two columns: the air on either side of a rule.
    var gutter: CGFloat
    /// Total width of the grid, edges included.
    var width: CGFloat

    /// X-coordinate of the rule separating column `index` from the previous
    /// one.
    ///
    /// At the **middle** of the gutter: set against the text, it would make a
    /// tight frame instead of an airy grid.
    func separatorX(before index: Int) -> CGFloat? {
        guard index > 0, index < columnOrigins.count else { return nil }
        return (columnOrigins[index] - gutter / 2).rounded()
    }

    /// The geometry of a table, or `nil` if it does not fit in the column.
    ///
    /// Returning `nil` is a normal case, not an error: see §6. A grid wider
    /// than the column would wrap row by row and become unreadable, so the
    /// source is shown instead, which stays readable.
    ///
    /// The decision is made on the **measured** widths, so on what will
    /// actually be drawn. The old estimate counted the source characters in a
    /// monospaced font, which made it wrong in both directions as soon as a
    /// different font was in use.
    static func measure(_ table: MarkdownTable,
                        in storage: NSTextStorage,
                        typography: EditorTypography,
                        available: CGFloat) -> TableLayout? {
        guard !table.alignments.isEmpty else { return nil }

        // The gutter follows the body text: it is what gives the air, and it
        // has to grow with the font like everything else.
        let gutter = (typography.bodySize * 1.6).rounded()

        var widths = [CGFloat](repeating: 0, count: table.columnCount)
        for row in table.rows {
            for (column, cell) in row.cells.enumerated() where column < widths.count {
                widths[column] = max(widths[column], measure(storage, cell.content))
            }
        }
        // An empty column keeps a minimum width.
        //
        // It used to be 1.5 body sizes: just enough to keep two rules from
        // touching, nothing more. A table that was just inserted has only
        // empty cells: it came out as a 168-point rule in the middle of a
        // text column three times as wide, unreadable and nearly impossible
        // to click. Yet this is **the initial state of every table**: the one
        // seen before anything has been written. An empty cell is a place
        // that is about to be written into; it must have the size for it.
        let minimum = (typography.bodySize * 4.5).rounded()
        widths = widths.map { max($0, minimum) }

        /// The x-coordinates that follow from the widths, and the total width.
        func lay(_ widths: [CGFloat]) -> (origins: [CGFloat], total: CGFloat) {
            var origins: [CGFloat] = []
            var cursor = gutter / 2
            for width in widths {
                origins.append(cursor)
                cursor += width + gutter
            }
            return (origins, cursor - gutter / 2)
        }

        var (origins, total) = lay(widths)

        // Too wide for the column: it does not wrap, the source is shown
        // instead. This check is made on the **natural** width, before any
        // stretching.
        guard total <= available else { return nil }

        // The table occupies the whole text column.
        //
        // At its content size, its right edge fell wherever it happened to,
        // and in particular a table that had just been inserted (all empty
        // cells) shrank down to a rule lost in the middle of the page. The
        // extra space is shared out equally: the width differences between
        // columns are preserved, which keeps the wide column its emphasis.
        if total < available, !widths.isEmpty {
            let share = ((available - total) / CGFloat(widths.count)).rounded(.down)
            if share > 0 {
                widths = widths.map { $0 + share }
                (origins, total) = lay(widths)
            }
        }

        return TableLayout(columnOrigins: origins, columnWidths: widths,
                           gutter: gutter, width: total)
    }

    /// Width actually rendered for a range, attributes included.
    private static func measure(_ storage: NSTextStorage, _ range: NSRange) -> CGFloat {
        guard range.length > 0, range.upperBound <= storage.length else { return 0 }
        return storage.attributedSubstring(from: range).size().width
    }
}
