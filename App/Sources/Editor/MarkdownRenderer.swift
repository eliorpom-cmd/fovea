// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import AppKit

/// Applies rendering attributes to the buffer.
///
/// This file **never modifies characters**: it only dresses up the ones
/// already there. This is the concrete implementation of §3.1: rendering
/// is just a layer of attributes over the source text.
@MainActor
struct MarkdownRenderer {

    var typography: EditorTypography

    /// The document's location, to resolve images with relative paths.
    var documentURL: URL?

    /// The width **actually available** for a table grid.
    ///
    /// # What the desired width doesn't reflect
    ///
    /// The measurement used to be taken against `typography.columnWidth`, i.e. the
    /// width *requested in settings* — that is, 68 characters, about 612 points.
    /// But `EditorController.applyColumnLayout` clamps the actual column to the
    /// space available: in a narrow window it drops to a fraction of that.
    ///
    /// The grid therefore kept being laid out at 612 points. It overflowed the
    /// container: since the view isn't horizontally resizable, it was
    /// **cut off cleanly by the window edge**, and the last column
    /// disappeared — with no scrolling, and without the fallback to source that §6
    /// provides precisely for this case, since that fallback was also decided
    /// based on the desired width.
    ///
    /// `nil` means "use the one from settings", for a caller with no
    /// container to consult.
    var availableWidth: CGFloat?

    var gridWidth: CGFloat { availableWidth ?? typography.columnWidth }

    /// Applies full rendering to a buffer.
    ///
    /// - Parameters:
    ///   - revealed: the indices, in `spans`, whose markers must
    ///     remain visible — computed by `RevealPolicy`.
    func render(_ storage: NSTextStorage,
                spans: [SyntaxSpan],
                revealed: Set<Int>,
                in range: NSRange) {
        storage.beginEditing()
        defer { storage.endEditing() }

        applyBaseStyle(storage, range: range)

        // Blocks first, inline second: a heading sets its font on
        // the whole line, and the bold text it contains must be able to build on
        // it by modifying it rather than being overwritten by it.
        let ordered = spans.indices.sorted { blockFirst(spans[$0], spans[$1]) }

        for index in ordered {
            let span = spans[index]
            // Bounds inclusive: see `EditorController.touches`. An empty edit
            // scope intersects nothing, and the fallback that used to fix this
            // case reprocessed the entire document.
            guard EditorController.touches(span.range, range) else { continue }
            applyContentStyle(storage, span: span)
        }

        // Masking comes last, on markers only: it must
        // win over any font attribute set earlier by the carrying
        // block, otherwise a heading's `#` would stay large and visible.
        for index in ordered where !isTable(spans[index]) {
            applyMarkers(storage, span: spans[index], revealed: revealed.contains(index))
        }

        // Tables come last of all, for a specific reason: the grid
        // places its columns based on the **actually rendered** width of each
        // cell. A cell containing bold text has already lost its `**` at
        // the previous step; measuring it before that step would have counted them.
        for index in ordered where isTable(spans[index]) {
            applyTable(storage, span: spans[index], revealed: revealed.contains(index))
        }

        applyRawTableLines(storage, spans: spans, in: range)
    }

    /// Lines that were meant to be a table and are not one, in the fixed-pitch
    /// font.
    ///
    /// # Why the renderer and not the parser
    ///
    /// A mistyped delimiter, a missing one, a row with the wrong number of
    /// cells: cmark sees no table, so there is no span to style. §6 says the
    /// source then stays displayed as is, and it does — every `|` is on
    /// screen. But it was displayed in the **body** font, where nothing lines
    /// up under anything, so the one thing a reader wants from a broken table
    /// — seeing which cell went wrong — was the thing hardest to do.
    ///
    /// This does not guess that the block *is* a table, which §6 forbids and
    /// which would mean re-implementing the parser's job. It notices something
    /// weaker and certain: **two or more lines in a row that open with `|`**.
    /// That is not prose. Whatever it is, it is read in columns.
    ///
    /// Detection reads the whole buffer, application stays inside the render
    /// scope: a run that starts above the edited scope is still recognised,
    /// and only the lines being re-rendered are touched.
    private func applyRawTableLines(_ storage: NSTextStorage, spans: [SyntaxSpan], in range: NSRange) {
        let text = storage.mutableString
        guard text.length > 0 else { return }

        // Anything cmark did claim belongs to somebody else: a real table has
        // its grid, a code block its own face, and a fence full of pipes is
        // code.
        let claimed = spans.compactMap { span -> NSRange? in
            switch span.kind {
            case .table, .codeBlock, .frontMatter: span.range
            default: nil
            }
        }
        func isRawLine(_ line: NSRange) -> Bool {
            opensWithPipe(text, line)
                && !claimed.contains { NSIntersectionRange($0, line).length > 0 }
        }

        // Back up to the first line of the run the scope starts inside, so a
        // run beginning above the edited region is still recognised as one.
        var first = text.lineRange(for: NSRange(location: min(range.location, text.length - 1), length: 0))
        while first.location > 0 {
            let previous = text.lineRange(for: NSRange(location: first.location - 1, length: 0))
            guard previous.location < first.location, isRawLine(previous) else { break }
            first = previous
        }

        // A single line that happens to open with `|` is a sentence, not a
        // table, so a run is only styled once its second line is known.
        var run: [NSRange] = []
        func flush() {
            defer { run.removeAll(keepingCapacity: true) }
            guard run.count >= 2 else { return }
            for line in run where EditorController.touches(line, range) {
                storage.addAttribute(.font, value: typography.codeBlock, range: line)
            }
        }

        var cursor = first.location
        while cursor < text.length {
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            guard line.length > 0 else { break }

            if isRawLine(line) {
                run.append(line)
            } else {
                flush()
                // Past the scope and not inside a run: nothing further can
                // touch the range being rendered.
                if line.location > range.upperBound { return }
            }

            // **The loop advances or it stops.** `lineRange(for:)` on the last
            // line of a buffer with no trailing newline answers with that same
            // line, so a cursor set from `upperBound` alone never moves and the
            // render never returns. Found by a test that hung rather than
            // failed, which is the expensive way to find it.
            guard line.upperBound > cursor else { break }
            cursor = line.upperBound
        }
        flush()
    }

    /// Is the first thing on this line a `|`, after at most three spaces?
    ///
    /// Three, because that is markdown's own tolerance before a construct
    /// becomes indented code.
    private func opensWithPipe(_ text: NSString, _ line: NSRange) -> Bool {
        var offset = line.location
        var spaces = 0
        while offset < line.upperBound, spaces < 4 {
            let unit = text.character(at: offset)
            if unit == 32 || unit == 9 { spaces += 1; offset += 1; continue }
            return unit == UInt16(UnicodeScalar("|").value)
        }
        return false
    }

    func isTable(_ span: SyntaxSpan) -> Bool {
        if case .table = span.kind { return true }
        return false
    }

    /// Does this image occupy its line on its own?
    ///
    /// This is the condition for rendering it **as a block**: height reserved on
    /// the paragraph, source masked without reducing that height, drawing done in the
    /// space left this way.
    ///
    /// The opposite case is common and wasn't accounted for at first — `some text
    /// ![an image](a.png) followed by more text`. The reserved height then pushed the
    /// entire line apart, and the image, drawn across the whole width it was
    /// given, drew **over the neighboring words**. An inline image is
    /// therefore left as is: its brackets disappear, its
    /// alt text stays, and nothing around it moves.
    ///
    /// The measurement is done on the source, not on the render: it's called
    /// during attribute application, before TextKit has laid anything
    /// out at all.
    static func isBlockImage(_ span: SyntaxSpan, in text: NSString) -> Bool {
        guard case .image = span.kind,
              span.range.length > 0, span.range.upperBound <= text.length else { return false }

        let line = text.lineRange(for: NSRange(location: span.range.location, length: 0))
        guard span.range.upperBound <= line.upperBound else { return false }

        let before = NSRange(location: line.location, length: span.range.location - line.location)
        let after = NSRange(location: span.range.upperBound,
                            length: line.upperBound - span.range.upperBound)
        return isBlank(text, before) && isBlank(text, after)
    }

    /// A link's address, when it leads somewhere that can be opened.
    ///
    /// Deliberately restricted to schemes that make sense outside the document.
    /// A `#section` anchor or a relative path aren't addresses to
    /// hand off to Finder or a browser: the former would say nothing, the latter
    /// would open a file at random, depending on where the app was launched from.
    static func openableURL(_ destination: String, relativeTo documentURL: URL? = nil) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // An anchor leads inside the open document: there is no URL for that,
        // and the editor scrolls to the heading itself. See
        // `EditorController.jumpToAnchor`.
        guard !trimmed.hasPrefix("#") else { return nil }
        if trimmed.hasPrefix("www.") { return URL(string: "https://" + trimmed) }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            return ["http", "https", "mailto", "file"].contains(scheme) ? url : nil
        }

        // **A relative path leads to the file next to the document.**
        //
        // `[the licence](LICENSE)`, `[building](docs/BUILDING.md)`: this is
        // the most common link in the most common markdown file there is, a
        // README — and it was the one link that did nothing. Only a scheme
        // was accepted, so every relative path failed the test silently, and
        // an alpha tester reasonably concluded the app did not do links.
        //
        // The file has to exist for the link to be one: a path that leads
        // nowhere gets no `.link`, so no hand cursor, and `⌘`-click does not
        // open a Finder error in the reader's face.
        guard let documentURL else { return nil }
        let path = trimmed.components(separatedBy: "#")[0]
        guard !path.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: path.removingPercentEncoding ?? path,
                           relativeTo: documentURL.deletingLastPathComponent()).standardizedFileURL
        return FileManager.default.fileExists(atPath: resolved.path) ? resolved : nil
    }

    private static func isBlank(_ text: NSString, _ range: NSRange) -> Bool {
        guard range.length > 0 else { return true }
        let blanks = CharacterSet.whitespacesAndNewlines
        return text.rangeOfCharacter(from: blanks.inverted, options: [], range: range).location == NSNotFound
    }

    /// Toggles the markers of a single construct, **without touching the rest
    /// of its rendering**.
    ///
    /// This is the path taken on every caret move, and it must
    /// stay separate from `render(_:)`: that one starts by resetting the
    /// attributes of the range, which would erase the word's bold styling at the exact moment
    /// its asterisks reappear.
    func applyMarkers(_ storage: NSTextStorage, span: SyntaxSpan, revealed: Bool) {
        // A table has its own geometry: its `|` characters aren't masked to
        // zero width but to a computed width. See `applyTable`.
        if case .table = span.kind {
            applyTable(storage, span: span, revealed: revealed)
            return
        }
        // An inline image is not a block: see `isBlockImage`.
        // It keeps its alt text — nothing will replace it — and
        // its markers are masked to zero width like any others.
        let blockImage = Self.isBlockImage(span, in: storage.mutableString)

        // The alt text of a block image, on the other hand, is part of what
        // disappears: the image replaces it on screen, and leaving it visible
        // would overlay the same information twice.
        if blockImage, !revealed, span.content.length > 0,
           span.content.upperBound <= storage.length {
            MarkerMask.hideKeepingMetrics(in: storage, range: span.content, font: typography.body)
        }
        for marker in span.markers {
            guard marker.length > 0, marker.upperBound <= storage.length else { continue }
            if revealed {
                MarkerMask.reveal(in: storage, range: marker, font: markerFont(for: span))
            } else if blockImage {
                // The source is masked **without reducing the height**: the line
                // must keep the space reserved for the image, otherwise the drawing
                // would have nowhere to go.
                MarkerMask.hideKeepingMetrics(in: storage, range: marker, font: typography.body)
            } else if case .thematicBreak = span.kind {
                // The whole line is a marker: masking it to zero width
                // would make the line itself disappear, and the rule would have
                // nowhere left to draw itself.
                MarkerMask.hideKeepingMetrics(in: storage, range: marker, font: typography.body)
            } else {
                MarkerMask.hide(in: storage, range: marker)
            }
        }
    }

    // MARK: - Tables (§2.6)

    /// Height reserved for the delimiter row, as a fraction of the body size.
    /// It shows nothing, but it carries the header rule.
    /// The height of the `|---|` line, which shows nothing.
    ///
    /// It used to be 0.7 body size — 12.6 points that spilled on either
    /// side of the header rule, half under the header, half onto the
    /// first row. Measured result: four rows at three different heights
    /// (53, 51, 42, 42 pixels), none centered the same way. An
    /// invisible line must carry no weight: all it has left is the space of the
    /// rule it carries.
    static let tableRuleHeight: CGFloat = 0.12

    /// Does the grid fit in the text column?
    ///
    /// The measurement is done on the **render**, by `TableLayout`. The
    /// previous version counted source characters in monospaced pitch: an
    /// estimate that was only accurate as long as the table *was* rendered in
    /// monospaced pitch, which is precisely what made it look like a
    /// code block.
    func gridLayout(for table: MarkdownTable, in storage: NSTextStorage) -> TableLayout? {
        TableLayout.measure(table, in: storage, typography: typography,
                            available: gridWidth)
    }

    /// Applies — or removes — a table's grid.
    ///
    /// # Grid while reading, source while editing (§2.6)
    ///
    /// The grid is a **reading** affordance. A table renders as aligned
    /// columns for as long as the caret is elsewhere; the moment it enters,
    /// the whole block reveals and the `|` come back, to be edited as the
    /// plain text they are.
    ///
    /// Nothing here has to arrange that: a table's `revealScope` is
    /// `.wholeBlock`, so the reveal engine does it, exactly as it does for a
    /// code fence. `revealed` is simply passed through.
    ///
    /// An earlier design aimed for a truly editable grid, with a `firstResponder`
    /// nested per cell. It would have meant two undo stacks to keep in sync, a
    /// selection that no longer crosses the table, and a `⌘F` that stops at
    /// its edges — a second editor inside the editor, for a construct nobody
    /// reaches for in the forty seconds this app is open. Here there is still
    /// only a single buffer: the selection crosses the grid, search finds
    /// matches in it, and undo is the same undo as for typing.
    ///
    /// # How the grid holds together without a single character added
    ///
    /// Each `|` is masked, but receives **a computed advance**: the one
    /// needed for the next cell to land on its column. The source's padding
    /// whitespace is set to zero: the grid does the spacing
    /// now, not the author. The `|---|` line is masked entirely and its height
    /// reduced to the space of a rule.
    ///
    /// Columns are measured, not counted: `**Title**` renders six characters
    /// shorter than its source, and a column computed from character count would be
    /// six too wide.
    func applyTable(_ storage: NSTextStorage, span: SyntaxSpan, revealed: Bool) {
        guard case .table(let table) = span.kind, let table,
              span.range.upperBound <= storage.length else { return }

        // **The caret in the block shows the source.** Without this the grid
        // is drawn unconditionally, and the buffer keeps `|` characters, cell
        // padding and a whole `|---|` row that nothing will ever display: the
        // caret lands inside them, `⌫` eats a character nobody can see, and
        // the columns shift with no visible cause. §2.3's invariant — the
        // caret is never inside a masked marker — holds only because a
        // construct reveals itself when touched, and a table is a construct
        // like any other.
        guard !revealed else {
            showTableSource(storage, table: table)
            return
        }

        // The source is also what gets shown for what **can't** be drawn: a
        // malformed table, and a table wider than the column — which would
        // wrap line by line, and a wrapped grid can't be read at all.
        guard let layout = TableLayout.measure(table, in: storage, typography: typography,
                                               available: gridWidth) else {
            showTableSource(storage, table: table)
            return
        }
        layOutTable(storage, table: table, layout: layout)
    }

    /// The table as written: `|` characters and whitespace visible, delimiter
    /// row at its normal height. This is the state under the caret, and
    /// the state of a table too wide for the column.
    ///
    /// **In the fixed-pitch font**, like `⌥⌘S`. The pipes were revealed in the
    /// body font, where they do not line up under each other: a grid the app
    /// gave up on came back as ragged text, which is harder to read than the
    /// source the author actually typed. A monospaced face restores the
    /// alignment they wrote it with, and says the same thing source mode says.
    private func showTableSource(_ storage: NSTextStorage, table: MarkdownTable) {
        let whole = NSRange(location: table.rows.first?.line.location ?? table.delimiter.location,
                            length: 0)
        let end = max(table.delimiter.upperBound, table.rows.last?.line.upperBound ?? 0)
        let block = NSRange(location: whole.location, length: max(0, end - whole.location))
        if block.length > 0, block.upperBound <= storage.length {
            storage.addAttribute(.font, value: typography.codeBlock, range: block)
        }

        for marker in table.markerRanges where marker.upperBound <= storage.length {
            MarkerMask.reveal(in: storage, range: marker, font: typography.codeBlock)
        }
        // Line wrapping is **restored**: the pipe-delimited source is wider
        // than the grid it replaces, and clipping it would hide from the author
        // half of what they're editing.
        applyRowStyles(storage, table: table, clipping: false, reducedRuleLine: false)
    }

    private func layOutTable(_ storage: NSTextStorage, table: MarkdownTable, layout: TableLayout) {
        // 1. Everything that's syntax disappears first, at zero width. The
        //    useful advances will be rewritten right after; the ones that
        //    aren't — a right-edge `|` — must stay at zero.
        for marker in table.markerRanges where marker.upperBound <= storage.length {
            MarkerMask.hide(in: storage, range: marker)
        }

        // 2. Row heights, including the — reduced — delimiter row height.
        applyRowStyles(storage, table: table, clipping: true, reducedRuleLine: true)

        // 3. Each `|` receives the advance that leads to the start of its cell. The
        //    geometry comes from `TableLayout`, which the decoration layer also
        //    reads: the rules must land exactly between the columns that
        //    the kerning has just set.
        let origins = layout.columnOrigins
        for row in table.rows {
            var pen: CGFloat = 0
            for (column, cell) in row.cells.enumerated() {
                let own = measure(storage, cell.content)
                let origin = column < origins.count ? origins[column] : pen

                // **The cell sits against the edge its column declares**
                // (§2.6). The `|:---:|---:|` line used to be parsed and
                // then ignored, so a column written `--:` — a column of
                // figures, always — came out flush left here and flush
                // right in every other reader of the same file.
                //
                // The offset is measured against the column's own width,
                // the stretched one: it is the width the grid actually
                // draws, so a centred cell lands between the two rules the
                // reader can see rather than between the ones the content
                // would have had.
                let columnWidth = column < layout.columnWidths.count ? layout.columnWidths[column] : own
                let offset: CGFloat = switch table.alignment(of: column) {
                case .left: 0
                case .center: max(0, (columnWidth - own) / 2).rounded()
                case .right: max(0, columnWidth - own).rounded()
                }

                // The separator preceding the cell: the left-edge `|`
                // for the first one, the one separating it from the previous cell otherwise.
                let pipeIndex = row.hasLeadingPipe ? column : column - 1
                if pipeIndex >= 0, pipeIndex < row.pipes.count,
                   row.pipes[pipeIndex].upperBound <= storage.length {
                    MarkerMask.hide(in: storage, range: row.pipes[pipeIndex],
                                    advance: origin + offset - pen)
                    pen = origin + offset
                }
                pen += own
            }
            // 4. After the kerning, never before: it's the kerning that just
            //    rewrote the font of each `|`.
            keepRowMetrics(storage, row: row)
        }
    }

    /// The paragraph styles of the table's rows.
    ///
    /// The space above the block goes only on the **first** line. Applied over
    /// the entire range, as it originally was, it applied to every source
    /// line — that is, every row — and the table read as
    /// airy as a sequence of paragraphs.
    private func applyRowStyles(_ storage: NSTextStorage, table: MarkdownTable,
                                clipping: Bool, reducedRuleLine: Bool) {
        for (index, row) in table.rows.enumerated() {
            let style = tableParagraphStyle(clipping: clipping)
            if index == 0 { style.paragraphSpacingBefore = (typography.bodySize * 0.6).rounded() }
            storage.addAttribute(.paragraphStyle, value: style,
                                 range: paragraph(of: row.line, in: storage))
        }

        let ruleStyle = tableParagraphStyle(clipping: clipping)
        if reducedRuleLine {
            // The line shows nothing: its height is that of the rule it
            // carries, not that of an empty row.
            ruleStyle.minimumLineHeight = (typography.bodySize * Self.tableRuleHeight).rounded()
            ruleStyle.maximumLineHeight = ruleStyle.minimumLineHeight
            ruleStyle.lineHeightMultiple = 1
            // Its height is stated explicitly: row padding has nothing
            // to add to it.
            ruleStyle.lineSpacing = 0
        }
        storage.addAttribute(.paragraphStyle, value: ruleStyle,
                             range: paragraph(of: table.delimiter, in: storage))
    }

    /// Gives a row with no content the height of an ordinary row.
    ///
    /// A masked `|` carries a font a hundredth of a point in size: that's what
    /// gives it zero width, and that's what makes a row **whose
    /// cells are all empty** end up with no metrics at all. Its natural height
    /// would drop to a hundredth of a point, line spacing would multiply that near-nothing, and
    /// the fill-in table from "6 — Tables" would collapse to three stacked
    /// rules — with no row left to place the caret in.
    ///
    /// A single `|` reset to the body font is enough to bring the line back to its
    /// height. It stays invisible, and its glyph advance doesn't shift anything
    /// since the row, by definition, has nothing to shift.
    private func keepRowMetrics(_ storage: NSTextStorage, row: MarkdownTable.Row) {
        guard row.cells.allSatisfy({ $0.content.length == 0 }),
              let pipe = row.pipes.first, pipe.upperBound <= storage.length else { return }
        storage.addAttribute(.font, value: typography.body, range: pipe)
    }

    /// Actual rendered width of a range, attributes included.
    private func measure(_ storage: NSTextStorage, _ range: NSRange) -> CGFloat {
        guard range.length > 0, range.upperBound <= storage.length else { return 0 }
        return storage.attributedSubstring(from: range).size().width
    }

    /// The range of the paragraph carrying a line, terminator included.
    ///
    /// A paragraph style applied to the line without its `\n` leaves TextKit
    /// reading the style of the next character instead: the reduced height wouldn't take effect.
    private func paragraph(of line: NSRange, in storage: NSTextStorage) -> NSRange {
        var range = line
        if range.upperBound < storage.length,
           storage.mutableString.character(at: range.upperBound) == 10 {
            range.length += 1
        }
        return NSRange(location: range.location, length: min(range.length, storage.length - range.location))
    }

    /// Tightened line spacing: a table is a grid, not prose.
    ///
    /// - Parameter clipping: true when the grid is applied. A row must
    ///   then never wrap — the width calculation guarantees that it
    ///   fits, and wrapping would shift every row below it. In source,
    ///   on the contrary, wrapping is what makes the block readable.
    private func tableParagraphStyle(clipping: Bool) -> NSMutableParagraphStyle {
        let style = typography.paragraphStyle()
        // Tighter than prose, but not so tight that the text touches
        // the rules: a cell needs air above and below it, otherwise
        // the grid reads like a table of figures.
        //
        // **The extra space goes entirely above the line, and there's no fixing that.**
        // A line-height multiplier stacks it there and places the baseline at the very
        // bottom. `.baselineOffset` doesn't compensate for it: TextKit raises the baseline
        // *and* the frame along with it. `lineSpacing` doesn't either: it only
        // slots in *between* lines of the same paragraph, but a row is a
        // single-line paragraph. `paragraphSpacing` doesn't either: it doesn't
        // count within the line's rectangle, TextKit carries it over to
        // the origin of the next paragraph, so it opens a gap that
        // belongs to no row.
        //
        // Centering is therefore adjusted where it can actually be adjusted: at draw time. See
        // `rowRuleOffset(_:)`.
        if clipping {
            style.lineHeightMultiple = 1 + (Self.rowLeading - 1) / 2
        } else {
            style.lineHeightMultiple = Self.rowLeading
        }
        style.lineBreakMode = clipping ? .byClipping : .byWordWrapping
        return style
    }

    /// A row's line spacing, relative to the body's natural height.
    static let rowLeading: CGFloat = 1.45

    /// How far to drop the rules so the text falls **in the middle** of
    /// its row.
    ///
    /// The extra line spacing is placed entirely above the line
    /// (see `tableParagraphStyle`), so the text ends up pressed
    /// against the bottom rule — measured to the pixel: 23 points of air above, 3
    /// below. Since the line's frame can't be moved, it's the
    /// rules that get dropped by half the gap, which amounts to the same thing:
    /// the visible band of a row is what separates two rules, not what
    /// TextKit calls its line.
    static func rowRuleOffset(_ typography: EditorTypography) -> CGFloat {
        let font = typography.body
        let natural = naturalHeight(font)
        let box = natural * (1 + (rowLeading - 1) / 2)
        let above = box - natural                       // the extra space, right at the top
        let below = box - above - (font.ascender - font.descender)
        // Centering the typographic frame leaves the text visibly high: the
        // ascender rises higher than capital letters, and almost no word
        // descends all the way to the descender. This corrects toward the **optical**
        // middle.
        //
        // The factor is tuned by measurement, not derived: centering exactly on
        // cap height flipped the bias to the other side (7 pixels
        // above, 11 below, where it used to be 11 and 7). Half lands right,
        // verified to the pixel on "6 — Tables".
        let optical = (font.ascender - font.capHeight) / 4
        return max(0, (above - below) / 2 + optical).rounded()
    }

    /// What TextKit would give a line in this font on its own.
    private static func naturalHeight(_ font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }


    // MARK: - Base style

    private func applyBaseStyle(_ storage: NSTextStorage, range: NSRange) {
        let target = range.length > 0 ? range : NSRange(location: 0, length: storage.length)
        guard target.length > 0 else { return }
        storage.setAttributes([
            .font: typography.body,
            .foregroundColor: Theme.NS.label,
            .paragraphStyle: typography.paragraphStyle(),
        ], range: target)
    }

    // MARK: - Content style

    private func applyContentStyle(_ storage: NSTextStorage, span: SyntaxSpan) {
        let content = clamp(span.content, to: storage.length)
        let whole = clamp(span.range, to: storage.length)

        switch span.kind {
        case .strong:
            addTrait(storage, range: content, bold: true)

        case .emphasis:
            addTrait(storage, range: content, italic: true)

        case .strikethrough:
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .strikethroughColor: Theme.NS.labelSecondary], range: content)

        case .inlineCode:
            storage.addAttributes([.font: typography.inlineCode,
                                   .backgroundColor: Theme.NS.fillQuaternary], range: content)

        case .link(let destination):
            // Underlined and not colored: the only colored object allowed is
            // the user's content (§7).
            var attributes: [NSAttributedString.Key: Any] = [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: Theme.NS.labelTertiary,
                .cursor: NSCursor.pointingHand,
            ]
            // **The address is hidden, so it must remain readable.** The
            // `(url)` is a marker, so it's masked; without a tooltip, the only
            // way to know where a link leads would be to place the caret
            // on it to make its syntax reappear.
            if !destination.isEmpty {
                attributes[.toolTip] = "\(destination)\n⌘-click to open"
            }
            // And without this attribute, `⌘`-click found **nothing**: the view
            // looks for a `.link` that nobody was setting, and the opening promised
            // in §2.4 never happened.
            if let url = Self.openableURL(destination, relativeTo: documentURL) {
                attributes[.link] = url
            }
            storage.addAttributes(attributes, range: content)

        case .image(let source, _):
            // **Reserve the space, without inserting a single character.**
            //
            // An image can't be an `NSTextAttachment`: an attachment
            // replaces a character, and §3.1 forbids adding one. The
            // height is therefore reserved via `minimumLineHeight` on the
            // paragraph, the source is masked to zero width like any
            // other marker, and `DecorationPainter` paints into the space
            // left this way.
            //
            // None of this applies to an inline image: reserving the
            // height would push apart the line it's in, and the drawing would
            // land on top of the surrounding words.
            guard Self.isBlockImage(span, in: storage.mutableString) else {
                markMissingInline(storage, span: span, source: source)
                break
            }
            let style = typography.paragraphStyle()
            style.minimumLineHeight = reservedHeight(for: source)
            style.lineHeightMultiple = 1
            style.paragraphSpacingBefore = typography.bodySize * 0.5
            storage.addAttributes([.paragraphStyle: style], range: whole)

        case .footnoteReference:
            // The superscript applies only to the identifier: the brackets are
            // markers and will be masked, but the number must stay
            // on screen, otherwise the author loses the reference to their note.
            storage.addAttributes([.font: typography.font(size: typography.bodySize * 0.7),
                                   .baselineOffset: typography.bodySize * 0.32,
                                   .foregroundColor: Theme.NS.labelSecondary], range: content)

        case .footnoteDefinition(let identifier):
            // The note reads like a note: one notch smaller, in a
            // secondary tint, with an indent that aligns its text under itself
            // when it wraps to a new line. This is the layout a book has
            // given it for five centuries.
            let style = typography.paragraphStyle()
            let hanging = typography.bodySize * 1.4
            style.firstLineHeadIndent = 0
            style.headIndent = hanging
            storage.addAttributes([.font: typography.font(size: typography.bodySize * 0.9),
                                   .foregroundColor: Theme.NS.labelSecondary,
                                   .paragraphStyle: style], range: whole)
            // The identifier stays superscript, like its reference: this is what
            // makes the pair recognizable at a glance.
            let label = NSRange(location: span.range.location + 2,
                                length: max(0, identifier.utf16.count))
            if label.upperBound <= storage.length {
                storage.addAttributes([.font: typography.font(size: typography.bodySize * 0.7),
                                       .baselineOffset: typography.bodySize * 0.32,
                                       .foregroundColor: Theme.NS.label], range: label)
            }

        case .heading(let level):
            let style = typography.paragraphStyle()
            style.paragraphSpacingBefore = typography.spacingBefore(headingLevel: level)
            // A level-1 or level-2 heading is closed by a rule (§2.4), and
            // the rule needs somewhere to be: the space below the line is
            // reserved here, and `DecorationPainter` draws into it.
            if level <= 2 { style.paragraphSpacing = typography.headingRuleSpacing }
            storage.addAttributes([.font: typography.heading(level: level),
                                   .paragraphStyle: style], range: whole)

        case .blockQuote:
            let style = typography.paragraphStyle()
            style.firstLineHeadIndent = typography.quoteIndent
            style.headIndent = typography.quoteIndent
            storage.addAttributes([.foregroundColor: Theme.NS.labelSecondary,
                                   .paragraphStyle: style], range: whole)

        case .taskItem(_, let checked) where checked:
            // A done task is dimmed. That's the only information a task
            // list needs to give at a glance — what's left — and
            // the checked box alone doesn't give it: it reads item by item.
            // Dimming, not strikethrough: strikethrough already has a meaning in markdown,
            // and using it here would make `~~text~~` unreadable inside a task.
            let style = typography.paragraphStyle()
            let indent = typography.listIndent(level: SyntaxSpan.listLevel(forDepth: span.depth))
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            let body = clamp(span.layoutRange, to: storage.length)
            storage.addAttributes([.paragraphStyle: style,
                                   .foregroundColor: Theme.NS.labelSecondary], range: body)
            hideContinuationIndents(storage, item: span)

        case .listItem, .taskItem:
            // `firstLineHeadIndent` **and** `headIndent`. The second alone
            // only shifts continuation lines: the first would stay
            // stuck to the margin, and the bullet, drawn to its left, would land at
            // a negative x-coordinate — outside the view, in other words.
            let style = typography.paragraphStyle()
            let indent = typography.listIndent(level: SyntaxSpan.listLevel(forDepth: span.depth))
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            storage.addAttributes([.paragraphStyle: style],
                                  range: clamp(span.layoutRange, to: storage.length))
            hideContinuationIndents(storage, item: span)

        case .thematicBreak:
            // Rendered as a rule rather than text: the whole line is a
            // marker, so it will be masked, and it's the paragraph's
            // border that draws the line.
            break

        case .codeBlock(let language):
            // No `.backgroundColor`: applied character by character, it
            // produces a jagged fringe that stops at the last character of each
            // line. The background is drawn by `DecorationPainter`, as a single
            // rounded rectangle that covers the whole column.
            let style = typography.paragraphStyle()
            style.lineHeightMultiple = 1.25
            style.firstLineHeadIndent = typography.codeBlockIndent
            style.headIndent = typography.codeBlockIndent
            storage.addAttributes([.font: typography.codeBlock,
                                   .paragraphStyle: style], range: whole)
            highlightCode(storage, content: content, language: language)

        case .frontMatter:
            storage.addAttributes([.font: typography.codeBlock,
                                   .foregroundColor: Theme.NS.labelSecondary], range: whole)

        case .table(let table):
            // **The body font, no more monospaced pitch.** Monospacing guaranteed
            // alignment for free — every character has the same width —
            // but made every table look like a code block. The
            // columns are now measured and then placed via kerning
            // (`TableLayout`), which no longer needs a fixed-pitch font.
            storage.addAttributes([.font: typography.body,
                                   .paragraphStyle: tableParagraphStyle(clipping: false)],
                                  range: whole)

            // The header in bold. It stays bold under the caret too: it's the
            // only structural information that the pipe-delimited source doesn't
            // give on its own.
            if let header = table?.rows.first {
                let bold = typography.bodyEmphasized
                for cell in header.cells {
                    let range = clamp(cell.content, to: storage.length)
                    guard range.length > 0 else { continue }
                    storage.addAttribute(.font, value: bold, range: range)
                }
            }
        }
    }

    /// Height to reserve for an image, including the missing-image frame.
    private func reservedHeight(for source: String) -> CGFloat {
        switch ImageStore.shared.entry(for: source, relativeTo: documentURL) {
        case .loaded(let image, _):
            ImageStore.displaySize(of: image, columnWidth: typography.columnWidth).height
        case .oversized(let thumbnail, _):
            thumbnail.map { ImageStore.displaySize(of: $0, columnWidth: typography.columnWidth).height }
                ?? ImageStore.missingPlaceholderHeight
        case .missing:
            ImageStore.missingPlaceholderHeight
        }
    }

    /// Colors the content of a code block.
    ///
    /// A missing or unknown language produces no category: the block stays
    /// monospaced, uncolored. Never an error, never an empty block (§4.3).
    private func highlightCode(_ storage: NSTextStorage, content: NSRange, language: String?) {
        guard content.length > 0, content.upperBound <= storage.length else { return }
        let code = storage.attributedSubstring(from: content).string
        let font = typography.codeBlock
        for (range, category) in CodeHighlighter.categorize(code, language: language, offset: content.location) {
            guard range.upperBound <= storage.length else { continue }
            storage.addAttributes(CodeHighlighter.monochromeAttributes(for: category, font: font),
                                  range: range)
        }
    }

    /// Adds a weight or an italic style **without losing what's already applied**:
    /// this is what lets `***text***` come out bold *and* italic,
    /// whereas two successive `.font` applications would have overwritten each other.
    private func addTrait(_ storage: NSTextStorage, range: NSRange, bold: Bool = false, italic: Bool = false) {
        guard range.length > 0 else { return }
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let current = (value as? NSFont) ?? typography.body
            var traits = NSFontManager.shared.traits(of: current)
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            let converted = NSFontManager.shared.font(withFamily: current.familyName ?? current.fontName,
                                                      traits: traits,
                                                      weight: bold ? 9 : 5,
                                                      size: current.pointSize)
            storage.addAttribute(.font, value: converted ?? current, range: subrange)
        }
    }

    /// The font of a revealed marker: that of its carrying block, so the
    /// `##` of a heading isn't rendered at body text size in the
    /// middle of a heading line.
    private func markerFont(for span: SyntaxSpan) -> NSFont {
        switch span.kind {
        case .heading(let level): typography.heading(level: level)
        case .codeBlock, .frontMatter, .table: typography.codeBlock
        case .inlineCode: typography.inlineCode
        default: typography.body
        }
    }

    private func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        return NSRange(location: location, length: max(0, min(range.length, length - location)))
    }

    /// Application order: blocks before inline, outermost before
    /// innermost.
    /// Flags an inline image that leads nowhere.
    ///
    /// A missing block image gets its "Image not found" frame (§6):
    /// the editor never leaves an empty gap that would look like a bug. In the
    /// middle of a sentence, there's no room for a frame — but until now there
    /// was **no sign of it at all**: `![inline](photos/missing.png)`
    /// would read as "inline", alt text indistinguishable from the
    /// surrounding prose. The link could have been dead for months without anything
    /// saying so.
    ///
    /// The alt text therefore switches to a tertiary tint, underlined with dots.
    /// A text attribute rather than a drawn mark: it follows the wrap across
    /// multiple lines, whereas a frame drawn around the whole range
    /// would enclose both lines in a single rectangle. Nothing changes
    /// height, and placing the caret on the line brings the path back in clear text.
    private func markMissingInline(_ storage: NSTextStorage, span: SyntaxSpan, source: String) {
        let content = clamp(span.content, to: storage.length)
        guard content.length > 0,
              case .missing = ImageStore.shared.entry(for: source, relativeTo: documentURL) else { return }
        storage.addAttributes([
            .foregroundColor: Theme.NS.labelTertiary,
            .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: Theme.NS.labelTertiary,
        ], range: content)
    }

    /// Erases the source indentation of an item's continuation lines.
    ///
    /// The two spaces in `  lines.` are syntax: they're what keeps
    /// the sentence **inside** the bullet. Rendered as is, they added to the indent
    /// that `headIndent` just applied, and the continuation landed one notch further
    /// right than the first line instead of directly below it. Masked, the two
    /// align down to the point.
    ///
    /// The first line is left intact: its own indentation belongs
    /// to the marker, which the reveal rule must be able to bring back (§2.2).
    private func hideContinuationIndents(_ storage: NSTextStorage, item: SyntaxSpan) {
        guard let block = item.blockRange else { return }
        let text = storage.mutableString
        let end = min(block.upperBound, storage.length)
        var cursor = min(item.range.upperBound, end)
        // Cross the `\n` that closes the first line, otherwise the loop
        // would start by masking the marker itself.
        if cursor < end, text.character(at: cursor) == 10 { cursor += 1 }

        while cursor < end {
            let line = text.lineRange(for: NSRange(location: cursor, length: 0))
            cursor = max(line.upperBound, cursor + 1)

            var width = 0
            while line.location + width < line.upperBound,
                  text.character(at: line.location + width) == 32
                    || text.character(at: line.location + width) == 9 { width += 1 }

            // A fully blank line separates two paragraphs of an item:
            // masking it would collapse its height and merge the two blocks together.
            guard width > 0, line.location + width < storage.length,
                  text.character(at: line.location + width) != 10 else { continue }
            MarkerMask.hide(in: storage, range: NSRange(location: line.location, length: width))
        }
    }

    private func blockFirst(_ a: SyntaxSpan, _ b: SyntaxSpan) -> Bool {
        let rank = { (span: SyntaxSpan) -> Int in
            switch span.kind.revealScope {
            case .wholeBlock: 0
            case .wholeLine: 1
            case .innermostInline: 2
            }
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.depth < b.depth
    }
}

@MainActor
private extension EditorTypography {
    /// Body font at an arbitrary size — for footnote superscripts.
    func font(size: CGFloat) -> NSFont {
        FontCache.shared.font(name: bodyFontName, size: size, weight: .regular)
    }
}
