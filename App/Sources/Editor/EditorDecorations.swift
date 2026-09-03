// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import AppKit

/// What is **drawn** rather than written.
///
/// # Why this layer exists
///
/// Masking `- ` makes the dash disappear, but doesn't make any
/// bullet appear. And §3.1 forbids inserting even a single character into the buffer:
/// a `•` added to the text would end up in the file.
///
/// The way out is to **draw behind the text**. The bullet, the blockquote
/// bar, the horizontal rule and the code block background don't exist
/// anywhere in the document: they're marks applied by the editor, the same
/// way a caret is.
///
/// The code block background gains quality this way too. A `.backgroundColor`
/// applied character by character produces a jagged fringe that stops at the
/// last character of each line; drawn instead, it's a clean rounded rectangle
/// that covers the whole column.
struct EditorDecoration {

    enum Kind: Equatable {
        /// Vertical bar to the left of a blockquote.
        case quoteBar
        /// Bullet or number of a list item, drawn in the indent.
        case listMarker(String)
        /// Checkbox of a task list.
        case checkbox(checked: Bool)
        /// Horizontal rule from a `---`.
        case rule
        /// Rounded background of a code block.
        case codeBackground
        /// An image rendered inline (§4.4).
        case image(source: String, alt: String)
        /// One of a table's horizontal rules (§2.6).
        case tableRule(TableRule, width: CGFloat)
        /// The vertical rules between columns, spanning the full height of the
        /// table. The x-coordinates come from `TableLayout`, the same one that
        /// applied the kerning: the rules therefore land exactly between the
        /// columns, not beside them.
        case tableColumns(x: [CGFloat], width: CGFloat)
    }

    /// Where a horizontal rule sits within the range that carries it.
    ///
    /// # What changed, and why
    ///
    /// There used to be only three — top, under the header, bottom — on the
    /// grounds that "a full frame with vertical lines would look like a spreadsheet
    /// in the middle of a text". The intent was good, the result
    /// wasn't: without separation, the cells **aren't visible**. Three
    /// columns aligned with nothing between them read like three lists
    /// placed side by side, not like a table.
    ///
    /// The grid is therefore complete — a rule under every row, one between
    /// every column — but drawn in the separator color, at 10%:
    /// enough to structure, too little to add noise. Discretion is achieved
    /// through the weight of the line, not its absence.
    enum TableRule: Equatable {
        /// At the top of the first row.
        case top
        /// In the middle of the delimiter row, whose height has been reduced
        /// to make exactly this much room for it. Bolder than the others.
        case header
        /// Under a content row.
        case row
        /// Under the last row.
        case bottom
    }

    var kind: Kind
    /// The text range the mark relies on to find its position.
    var range: NSRange
    /// Left indent of the carrying paragraph, in points.
    var indent: CGFloat
}

extension EditorDecoration {

    /// Builds decorations from the detected constructs.
    ///
    /// - Parameter revealed: the constructs the caret touches.
    ///
    /// # The rule: a drawn mark **replaces** a masked source
    ///
    /// A mark exists only because its syntax is hidden. As soon as the
    /// source reappears, the mark must therefore disappear, otherwise the screen
    /// shows the same thing twice — and that was the case: a list item
    /// under the caret showed `• - An item`, the bullet drawn by the editor
    /// right next to the file's dash. See also the bullet and dash of a
    /// horizontal rule, whose drawn line used to strike through the reappeared `---`.
    ///
    /// Two exceptions, and they're justified: a blockquote's bar and a
    /// code block's background **replace** nothing — they frame a block, and
    /// that block exists just as much under the caret as anywhere else.
    @MainActor
    static func build(from spans: [SyntaxSpan],
                      in storage: NSTextStorage,
                      typography: EditorTypography,
                      availableWidth: CGFloat? = nil,
                      revealed: Set<Int> = []) -> [EditorDecoration] {
        let text = storage.mutableString
        var decorations: [EditorDecoration] = []
        for (index, span) in spans.enumerated() {
            let isRevealed = revealed.contains(index)
            switch span.kind {
            // The rules no longer disappear under the caret: neither does the grid.
            // Editing happens inside it, so it must stay framed while being edited.
            case .table(let table?):
                decorations.append(contentsOf: rules(for: table, in: storage, typography: typography,
                                                     availableWidth: availableWidth))
            case .blockQuote:
                decorations.append(EditorDecoration(kind: .quoteBar,
                                                    range: span.range,
                                                    indent: typography.quoteIndent))

            case .listItem(let marker) where !isRevealed:
                decorations.append(EditorDecoration(
                    kind: .listMarker(symbol(for: marker)),
                    range: span.content,
                    indent: typography.listIndent(level: SyntaxSpan.listLevel(forDepth: span.depth))))

            case .taskItem(_, let checked) where !isRevealed:
                decorations.append(EditorDecoration(
                    kind: .checkbox(checked: checked),
                    range: span.content,
                    indent: typography.listIndent(level: SyntaxSpan.listLevel(forDepth: span.depth))))

            case .thematicBreak where !isRevealed:
                decorations.append(EditorDecoration(kind: .rule, range: span.range, indent: 0))

            case .codeBlock:
                decorations.append(EditorDecoration(kind: .codeBackground,
                                                    range: span.range,
                                                    indent: typography.codeBlockIndent))

            // An inline image isn't drawn: there's no reserved
            // space to put it in. See `MarkdownRenderer.isBlockImage`.
            case .image(let source, let alt)
                where !isRevealed && MarkdownRenderer.isBlockImage(span, in: text):
                decorations.append(EditorDecoration(kind: .image(source: source, alt: alt),
                                                    range: span.range,
                                                    indent: 0))

            default:
                break
            }
        }
        return decorations
    }

    /// Does this construct have a drawn mark that depends on its reveal
    /// state?
    ///
    /// Used by the caret-movement cycle, which must rebuild the
    /// decoration layer only when it has actually changed — this is
    /// the app's most frequent operation (§9).
    static func hasRevealDependentMark(_ kind: SyntaxSpan.Kind) -> Bool {
        switch kind {
        case .table, .listItem, .taskItem, .thematicBreak, .image: true
        default: false
        }
    }

    /// A table's grid, or nothing if it doesn't fit in the column —
    /// in which case the render shows the source, which must not be framed as a
    /// grid.
    @MainActor
    private static func rules(for table: MarkdownTable,
                              in storage: NSTextStorage,
                              typography: EditorTypography,
                              availableWidth: CGFloat?) -> [EditorDecoration] {
        // The same width used to apply the kerning: two different
        // measurements would give rules that land beside the columns.
        let renderer = MarkdownRenderer(typography: typography, availableWidth: availableWidth)
        guard let layout = renderer.gridLayout(for: table, in: storage),
              let first = table.rows.first, let last = table.rows.last else { return [] }

        let width = layout.width
        var decorations = [
            EditorDecoration(kind: .tableRule(.top, width: width), range: first.line, indent: 0),
            EditorDecoration(kind: .tableRule(.header, width: width), range: table.delimiter, indent: 0),
            EditorDecoration(kind: .tableRule(.bottom, width: width), range: last.line, indent: 0),
        ]

        // A rule under every row except the last — the bottom rule is
        // already there, and two lines at the same spot are visible.
        for row in table.rows.dropFirst().dropLast() {
            decorations.append(EditorDecoration(kind: .tableRule(.row, width: width),
                                                range: row.line, indent: 0))
        }

        // The rules between columns, **plus the two edges**. Without them the grid
        // was open on the left and right: the horizontal rules
        // stopped in mid-air, and a table read like underlined
        // lines rather than a box.
        var separators = (0..<table.columnCount).compactMap { layout.separatorX(before: $0) }
        separators.append(0)
        separators.append((width - 1).rounded())
        if !separators.isEmpty {
            decorations.append(EditorDecoration(kind: .tableColumns(x: separators, width: width),
                                                range: NSRange(location: first.line.location,
                                                               length: last.line.upperBound - first.line.location),
                                                indent: 0))
        }
        return decorations
    }

    /// A bulleted list's bullet is always `•`, whatever character it's
    /// written with: `-`, `*` and `+` mean the same thing, and rendering three
    /// different symbols would suggest three different lists.
    ///
    /// A numbered list's number, on the other hand, is the one from the file, not
    /// one the editor would recalculate: a document where the author wrote `1.` on
    /// every line must read exactly as they wrote it.
    private static func symbol(for marker: SyntaxSpan.ListMarker) -> String {
        switch marker {
        case .bullet: "•"
        case .ordered(let number, let delimiter): "\(number)\(delimiter)"
        }
    }
}

// MARK: - Drawing

@MainActor
struct DecorationPainter {

    var typography: EditorTypography
    /// The document's location, to resolve relative image paths.
    var documentURL: URL?

    /// Draws the marks in the view, behind the text.
    ///
    /// - Parameter dirtyRect: in view coordinates. Off-screen marks
    ///   are discarded before any position calculation, which is the expensive part.
    func draw(_ decorations: [EditorDecoration],
              in view: NSTextView,
              dirtyRect: NSRect) {
        guard let layout = view.textLayoutManager,
              let content = view.textContentStorage else { return }

        let origin = view.textContainerOrigin
        let columnWidth = view.textContainer?.size.width ?? view.bounds.width
        let onScreen = characterRange(coveredBy: dirtyRect, in: view, layout: layout, content: content)

        for decoration in decorations {
            guard touches(decoration.range, onScreen) else { continue }
            guard let frame = boundingFrame(of: decoration.range, layout: layout, content: content) else { continue }
            let placed = frame.offsetBy(dx: origin.x, dy: origin.y)
            guard placed.intersects(dirtyRect) else { continue }
            paint(decoration, at: placed, columnLeft: origin.x, columnWidth: columnWidth)
        }
    }

    /// - Parameters:
    ///   - frame: the position of the carrying text, **in view coordinates**.
    ///   - columnLeft: the x-coordinate of the column's left edge, in the same
    ///     coordinate space. Without it, anything meant to span the width of
    ///     the column was computed by mixing two coordinate systems: the rules and the
    ///     code block background received `columnWidth - frame.minX * 2`, where
    ///     `frame.minX` already counted the centering margin. In a
    ///     wide window — 1512 points, 612-point column — this width came out to **−288**:
    ///     the three rules of a table, the horizontal rule and the
    ///     code block background were drawn backwards, entirely in the left
    ///     margin. The bug wasn't visible in the default window, where the
    ///     margin is narrow enough for the count to stay positive.
    ///   - columnWidth: the width of the text container.
    private func paint(_ decoration: EditorDecoration, at frame: NSRect,
                       columnLeft: CGFloat, columnWidth: CGFloat) {
        /// The band occupied by the column at the height of the carrying text, once
        /// the carrying paragraph's indent has been removed from each side.
        func columnSpan(inset: CGFloat) -> (x: CGFloat, width: CGFloat) {
            let indent = max(0, frame.minX - inset - columnLeft)
            return (columnLeft + indent, max(0, columnWidth - indent * 2))
        }

        switch decoration.kind {
        case .quoteBar:
            // The text is inset by `indent`; the bar is placed a third of the way into
            // that space, which leaves it air on both sides.
            //
            // **The height isn't that of the frame.** With line spacing
            // greater than 1, TextKit adds all of its surplus **above** the
            // text: a line's rectangle therefore starts well above
            // the first letter, and the bar overshot by that much — very visible
            // on a single-line blockquote, where there's nothing to
            // catch the eye. That surplus is removed at the top; at the bottom, the frame
            // already stops at the descender.
            let leading = max(0, typography.lineHeight - (typography.body.ascender - typography.body.descender))
            let bar = NSRect(x: frame.minX - decoration.indent + (decoration.indent - 2) / 3,
                             y: frame.minY + leading,
                             width: 2,
                             height: max(1, frame.height - leading))
            Theme.NS.quoteBar.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()

        case .listMarker(let symbol):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: typography.body,
                .foregroundColor: Theme.NS.labelTertiary,
            ]
            let size = (symbol as NSString).size(withAttributes: attributes)
            // Right-aligned against the gap: two-digit numbers then stay
            // aligned with single-digit ones, which is the only way to
            // make a ten-item list readable.
            // Aligned by the **bottom**, not centered in the line box.
            // With line spacing greater than 1, TextKit adds its surplus
            // above the text: centering the bullet in the box would make it
            // float noticeably higher than the line it introduces.
            let point = NSPoint(x: frame.minX - size.width - typography.listMarkerGap,
                                y: frame.maxY - size.height)
            (symbol as NSString).draw(at: point, withAttributes: attributes)

        case .checkbox(let checked):
            let box = checkboxBox(at: frame)
            let side = box.width
            let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            if checked {
                Theme.NS.label.setFill()
                path.fill()
                // The check mark is drawn in negative within the filled square: no
                // color, only contrast (§7).
                //
                // Y-coordinates go downward: `NSTextView` is a
                // flipped view, and a path read as going "upward" would draw an
                // upside-down chevron there. The check mark's bottom point is therefore the one
                // with the **largest** y-coordinate.
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + side * 0.24, y: box.minY + side * 0.52))
                check.line(to: NSPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.72))
                check.line(to: NSPoint(x: box.maxX - side * 0.22, y: box.minY + side * 0.30))
                check.lineWidth = max(1.5, side * 0.14)
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                Theme.NS.window.setStroke()
                check.stroke()
            } else {
                Theme.NS.labelTertiary.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }

        case .rule:
            // The rule spans the whole column, not the width of the three
            // invisible dashes it rests on.
            let span = columnSpan(inset: 0)
            let rule = NSRect(x: span.x, y: frame.midY - 0.5, width: span.width, height: 1)
            Theme.NS.separator.setFill()
            NSBezierPath(rect: rule).fill()

        case .image(let source, let alt):
            paint(image: source, alt: alt, at: frame, columnWidth: columnWidth)

        case .tableRule(let position, let width):
            // The header rule is bolder than the others: it's the one that
            // separates the titles from the data, and it's the separation a
            // prose table needs most.
            let drop = MarkdownRenderer.rowRuleOffset(typography)
            let y: CGFloat = switch position {
            case .top: frame.minY + drop
            case .header: (frame.midY - 0.5).rounded() + drop
            case .row, .bottom: frame.maxY - 1 + drop
            }
            // The width is that of the **grid**, not that of the text
            // column: a rule that runs to the right edge around a three-word
            // table frames nothing, it underlines empty space.
            let rule = NSRect(x: frame.minX, y: y, width: width, height: 1)
            (position == .header ? Theme.NS.labelTertiary : Theme.NS.separator).setFill()
            NSBezierPath(rect: rule).fill()

        case .tableColumns(let positions, _):
            // Shifted the same way as the horizontal rules, otherwise the grid comes
            // apart by half a line height at every crossing.
            let drop = MarkdownRenderer.rowRuleOffset(typography)
            Theme.NS.separator.setFill()
            for x in positions {
                NSBezierPath(rect: NSRect(x: (frame.minX + x).rounded(), y: frame.minY + drop,
                                          width: 1, height: frame.height)).fill()
            }

        case .codeBackground:
            let padding = typography.bodySize * 0.5
            let span = columnSpan(inset: decoration.indent)
            let box = NSRect(x: span.x,
                             y: frame.minY - padding,
                             width: span.width,
                             height: frame.height + padding * 2)
            Theme.NS.fillQuaternary.setFill()
            NSBezierPath(roundedRect: box,
                         xRadius: Theme.Radius.codeBlock,
                         yRadius: Theme.Radius.codeBlock).fill()
        }
    }

    /// Draws the image, or its missing-image frame.
    ///
    /// The space has already been reserved via `minimumLineHeight` on the paragraph:
    /// this just paints into it.
    private func paint(image source: String, alt: String, at frame: NSRect, columnWidth: CGFloat) {
        switch ImageStore.shared.entry(for: source, relativeTo: documentURL) {
        case .loaded(let image, let animated):
            let size = ImageStore.displaySize(of: image, columnWidth: columnWidth)
            let box = NSRect(x: frame.minX, y: frame.minY, width: size.width, height: size.height)
            NSGraphicsContext.current?.imageInterpolation = .high
            // `.sourceOver`, not `.copy`: an image with an alpha channel must
            // composite over the background, not replace it with transparency.
            image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
            // §6: only the first frame is drawn. Stating this avoids
            // suggesting the animation is broken.
            if animated { paintTag("Animated", in: box) }

        case .oversized(let thumbnail, let bytes):
            // The file exists: labeling it "not found" would be wrong.
            let size = thumbnail.map { ImageStore.displaySize(of: $0, columnWidth: columnWidth) }
                ?? NSSize(width: min(columnWidth, 420), height: ImageStore.missingPlaceholderHeight - 8)
            let box = NSRect(x: frame.minX, y: frame.minY, width: size.width, height: size.height)
            if let thumbnail {
                NSGraphicsContext.current?.imageInterpolation = .high
                thumbnail.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
            }
            paintTag("\(bytes / (1024 * 1024)) MB — preview", in: box)

        case .missing:
            // §6: an outlined frame with the path, and never an empty space
            // that would suggest a bug in the editor.
            let box = NSRect(x: frame.minX, y: frame.minY,
                             width: min(columnWidth, 420),
                             height: ImageStore.missingPlaceholderHeight - 8)
            let path = NSBezierPath(roundedRect: box, xRadius: Theme.Radius.card, yRadius: Theme.Radius.card)
            path.lineWidth = 1
            Theme.NS.separator.setStroke()
            path.stroke()

            let title = alt.isEmpty ? "Image not found" : "Image not found — \(alt)"
            draw(title, in: box, at: 8, font: typography.uiFont(size: 12, weight: .medium),
                 color: Theme.NS.labelSecondary)
            draw(source, in: box, at: 26, font: typography.uiFont(size: 11, weight: .regular),
                 color: Theme.NS.labelTertiary)
        }
    }

    /// A discreet pill in the bottom-left corner of an image.
    ///
    /// Placed on the image, not beside it: it describes that specific image, and a
    /// line of text underneath would shift everything that follows.
    private func paintTag(_ text: String, in box: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: typography.uiFont(size: 10, weight: .medium),
            .foregroundColor: Theme.NS.window,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 5
        let pill = NSRect(x: box.minX + 8,
                          y: box.maxY - size.height - padding * 2 - 8,
                          width: size.width + padding * 2,
                          height: size.height + padding)
        Theme.NS.label.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + padding, y: pill.minY + padding / 2),
                                withAttributes: attributes)
    }

    private func draw(_ text: String, in box: NSRect, at offset: CGFloat,
                      font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        (text as NSString).draw(
            in: NSRect(x: box.minX + 12, y: box.minY + offset, width: box.width - 24, height: 18),
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    /// A task item's checkbox, placed to the left of its text.
    ///
    /// Aligned by the **bottom** of the line, not centered in its box: with
    /// line spacing greater than 1, TextKit adds its surplus above the
    /// text, and a centered box would float above the line it
    /// introduces. The extra hair's-width removed compensates for the descender.
    ///
    /// A single definition, because it has two readers: the drawing, and the
    /// click that checks it (§2.5). Two copies would have diverged at the first
    /// line-spacing change, and the box would have stopped responding where
    /// it appears.
    func checkboxBox(at frame: NSRect) -> NSRect {
        let side = typography.bodySize * 0.8
        return NSRect(x: frame.minX - side - typography.listMarkerGap,
                      y: frame.maxY - side - typography.bodySize * 0.22,
                      width: side, height: side)
    }

    /// The displayed checkboxes, with the range of the task each one carries.
    ///
    /// The hit area is widened by a few points around the drawing: a
    /// box is thirteen points to a side at the default size, and aiming for
    /// thirteen points with the mouse isn't an experience worth inflicting on anyone.
    /// It's used both for the click **and** the pointer, which must respond to exactly
    /// the same surface: a pointer that changes without the click doing anything is
    /// worse than no pointer at all.
    ///
    /// Only **visible** boxes are computed, for the same reason as
    /// the drawing: asking for a box's position lays out the portion of the
    /// document it's in. What the mouse can't reach has
    /// no hit zone to place anyway: `resetCursorRects` only cares
    /// about the visible field, and a click never lands anywhere else.
    func checkboxTargets(among decorations: [EditorDecoration],
                         in view: NSTextView) -> [(range: NSRange, box: NSRect)] {
        guard let layout = view.textLayoutManager, let content = view.textContentStorage else { return [] }
        let origin = view.textContainerOrigin
        let onScreen = characterRange(coveredBy: view.visibleRect, in: view,
                                      layout: layout, content: content)

        return decorations.compactMap { decoration in
            guard case .checkbox = decoration.kind, touches(decoration.range, onScreen),
                  let frame = boundingFrame(of: decoration.range, layout: layout, content: content)
            else { return nil }
            let box = checkboxBox(at: frame.offsetBy(dx: origin.x, dy: origin.y))
            return (decoration.range, box.insetBy(dx: -5, dy: -5))
        }
    }

    /// The task whose box is under this point, in view coordinates.
    func task(at point: NSPoint, among decorations: [EditorDecoration],
              in view: NSTextView) -> NSRange? {
        checkboxTargets(among: decorations, in: view).first { $0.box.contains(point) }?.range
    }

    /// The character range covered by a band of the view.
    ///
    /// # The bug this calculation fixes
    ///
    /// The drawing loop did discard off-screen marks — but
    /// **after** asking for their position. And asking for a range's position
    /// forces TextKit 2 to lay it out, and there's one mark per
    /// list item, per blockquote and per code block in the document. Painting the
    /// background therefore laid out the **entire** document, on every
    /// drawing pass, from inside that very pass.
    ///
    /// Measured on 40,000 words: the laid-out height went from 634 points
    /// — just the visible screen — to 35,160 during drawing, in 56 ms. The text
    /// view was therefore resizing itself in the middle of its own display, the
    /// scroll view was catching up, and the text jumped under the caret. The
    /// same calculation re-run after a keystroke cost 283 ms: the keystroke invalidates
    /// the layout, and the next drawing pass redid it entirely.
    ///
    /// The band is taken in view coordinates and converted to a character
    /// range via the fragments bordering it — something the viewport's layout
    /// has already computed, so it's free. A mark whose range doesn't
    /// touch it now costs nothing at all.
    ///
    /// - Returns: `nil` when the band can't be resolved, in which case
    ///   nothing is discarded: a slow drawing pass is better than no drawing at all.
    private func characterRange(coveredBy band: NSRect,
                                in view: NSTextView,
                                layout: NSTextLayoutManager,
                                content: NSTextContentStorage) -> NSRange? {
        // Enough to cover how far a mark overflows its carrying text:
        // the space above a heading, the margin of a code block background.
        // A block that crosses the band, on the other hand, is retained by its range — it
        // covers the visible characters — regardless of its height.
        let margin: CGFloat = 120
        let origin = view.textContainerOrigin
        let top = max(0, band.minY - origin.y - margin)
        let bottom = max(0, band.maxY - origin.y + margin)

        guard let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: top)) else { return nil }
        let end = layout.textLayoutFragment(for: CGPoint(x: 0, y: bottom))?.rangeInElement.endLocation
            ?? content.documentRange.endLocation

        let start = content.offset(from: content.documentRange.location,
                                   to: first.rangeInElement.location)
        let finish = content.offset(from: content.documentRange.location, to: end)
        guard start != NSNotFound, finish != NSNotFound, finish >= start else { return nil }
        return NSRange(location: start, length: finish - start)
    }

    /// Do the two ranges touch, bounds inclusive?
    ///
    /// `NSIntersectionRange` doesn't work here: a mark's range can be
    /// empty — a list item with no text — and an empty intersection would discard it
    /// even though it is in fact on screen.
    private func touches(_ range: NSRange, _ band: NSRange?) -> Bool {
        guard let band else { return true }
        return range.location <= band.upperBound && band.location <= range.upperBound
    }

    /// Bounding rectangle of a range, in text container coordinates.
    private func boundingFrame(of range: NSRange,
                               layout: NSTextLayoutManager,
                               content: NSTextContentStorage) -> NSRect? {
        guard range.length >= 0,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }

        var union: NSRect?
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        return union
    }
}
