// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// List items that span **multiple lines of source**.
///
/// A hand-written `.md` file is almost always wrapped around 80 characters:
/// a three-sentence item therefore spans three lines, two of which carry no
/// bullet. Those lines had no block style at all — the span's range stops at
/// the first line, so the bullet doesn't reappear when the caret is three
/// lines below — and fell back to zero indent: they were drawn **to the
/// left of their own bullet**, with their source indentation showing as
/// blank space in front. On the welcome document in the `drafts/` folder,
/// that was the first bug you'd see.
///
/// As with tables, what's checked here is not an intention but x-coordinates.
@MainActor
final class ListRenderingTests: XCTestCase {

    private let tolerance: CGFloat = 0.6

    func testAContinuationLineSitsUnderTheItemText() throws {
        let source = """
        - A first sentence.
          Its continuation.
        """
        let view = try render(source)
        let first = try caretX(atFirstOccurrenceOf: "A first", in: source, view: view)
        let next = try caretX(atFirstOccurrenceOf: "Its", in: source, view: view)
        XCTAssertEqual(next, first, accuracy: tolerance,
                       "The continuation falls under the item's text, not under the margin")
    }

    func testAContinuationLineIsIndentedPastTheBullet() throws {
        // The complementary assertion: before the fix, the continuation
        // wasn't just misaligned but **further left than the bullet**.
        let source = """
        - A first sentence.
          Its continuation.
        """
        let view = try render(source)
        let bullet = try caretX(at: 0, view: view)
        let next = try caretX(atFirstOccurrenceOf: "Its", in: source, view: view)
        XCTAssertGreaterThan(next, bullet, "The continuation stays to the right of the bullet")
    }

    func testTheSourceIndentOfAContinuationIsMasked() throws {
        // The two spaces are syntax: they're what keeps the sentence inside
        // the bullet. Left visible, they added to the indent and pushed the
        // continuation one notch too far.
        let source = "- An item.\n  Its sequel.\n"
        let view = try render(source)
        let storage = try XCTUnwrap(view.textStorage)
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 11), "The first continuation space")
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 12), "The second continuation space")
        XCTAssertFalse(MarkerMask.isMasked(storage, at: 13), "The first character of the continuation is content")
    }

    func testABlankLineInsideAnItemKeepsItsHeight() throws {
        // An item spanning two paragraphs. The blank line carries only
        // whitespace: masking it would collapse its height and weld the two
        // blocks together.
        let source = "- First paragraph.\n\n  Second paragraph.\n"
        let view = try render(source)
        let heights = try lineHeights(in: view)
        XCTAssertFalse(heights.contains { $0 < 1 },
                       "No line should collapse to zero height: \(heights)")
    }

    func testANestedItemKeepsItsOwnDeeperIndent() throws {
        // The parent's layout range covers the child. The child's style is
        // applied afterward — otherwise a nested item would rise back to
        // its parent's indent.
        let source = """
        - Parent.
          - Child.
        """
        let view = try render(source)
        let parent = try caretX(atFirstOccurrenceOf: "Parent", in: source, view: view)
        let child = try caretX(atFirstOccurrenceOf: "Child", in: source, view: view)
        XCTAssertGreaterThan(child, parent, "The child stays to the right of its parent")
    }

    func testANestedItemWithChildrenStaysAtItsOwnLevel() throws {
        // cmark starts a nested item at its marker, after the source indent.
        // Its layout range started there too, so the paragraph's first
        // characters — the indent — kept the parent's style, and a paragraph
        // takes its style from its first character: `B`, which has a child of
        // its own, was drawn at the parent's level while `A` was not.
        let source = """
        - Parent
          - A
          - B
            - C
        """
        let view = try render(source)
        let a = try caretX(atFirstOccurrenceOf: "A", in: source, view: view)
        let b = try caretX(atFirstOccurrenceOf: "B", in: source, view: view)
        let c = try caretX(atFirstOccurrenceOf: "C", in: source, view: view)
        XCTAssertEqual(b, a, accuracy: tolerance, "Two siblings share one level, children or not")
        XCTAssertGreaterThan(c, b, "The grandchild stays to the right of its parent")
    }

    func testAListInsideAQuoteIsIndentedPastTheQuote() throws {
        // The item's indent used to replace the quote's instead of adding to
        // it: the bullet landed on the quote's bar.
        let plain = try render("- Item\n")
        let quoted = try render("> - Item\n")
        let inside = try caretX(atFirstOccurrenceOf: "Item", in: "> - Item\n", view: quoted)
        let outside = try caretX(atFirstOccurrenceOf: "Item", in: "- Item\n", view: plain)
        XCTAssertEqual(inside - outside, EditorTypography.default.quoteIndent, accuracy: tolerance,
                       "A quoted item moves right by exactly one quote indent")
    }

    func testTheCheckboxOfAWrappedTaskSitsOnItsFirstLine() throws {
        // The mark was bottom-aligned on the union of the whole first source
        // line: on an item that wraps, that union ends on the last visual
        // line, and the box (and a bullet, by the same path) sat next to the
        // end of the sentence.
        let source = "- [ ] " + String(repeating: "word ", count: 80) + "end\n"
        let view = try render(source)
        view.decorations = EditorDecoration.build(from: MarkdownParser.parse(source).spans,
                                                  in: try XCTUnwrap(view.textStorage),
                                                  typography: .default)
        let painter = DecorationPainter(typography: .default)
        let box = try XCTUnwrap(painter.checkboxTargets(among: view.decorations, in: view).first?.box)

        let firstLine = try lineFrame(at: 6, view: view)
        let lastLine = try lineFrame(at: (source as NSString).range(of: "end").location, view: view)
        XCTAssertGreaterThan(lastLine.minY, firstLine.maxY - 1, "The task wraps onto several lines")
        let origin = view.textContainerOrigin
        XCTAssertTrue(firstLine.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -50, dy: 0)
                        .contains(NSPoint(x: firstLine.minX + origin.x, y: box.midY)),
                      "The box sits on the first line: box \(box), first line \(firstLine)")
    }

    // MARK: - A quote inside an item

    func testAQuoteInsideAnItemTakesTheItemIndent() throws {
        // The quote's indent replaced the item's instead of adding to it: a
        // quote nested in an item started at the margin, left of its bullet.
        let source = "- Item\n  > Quoted\n"
        let style = try quoteStyle(in: source, at: "  > Quoted")
        let expected = try itemIndent(in: source, of: 0) + EditorTypography.default.quoteIndent
        XCTAssertEqual(style.firstLineHeadIndent, expected, accuracy: tolerance)
        XCTAssertEqual(style.headIndent, expected, accuracy: tolerance)

        let view = try render(source)
        let item = try caretX(atFirstOccurrenceOf: "Item", in: source, view: view)
        let quoted = try caretX(atFirstOccurrenceOf: "Quoted", in: source, view: view)
        XCTAssertEqual(quoted - item, EditorTypography.default.quoteIndent, accuracy: tolerance,
                       "The quote's text sits one quote indent right of the item's text")
    }

    func testAQuoteInsideANestedItemTakesTheNestedIndent() throws {
        let source = "- Parent\n  - Child\n    > Quoted\n"
        let style = try quoteStyle(in: source, at: "    > Quoted")
        let child = (source as NSString).range(of: "  - Child").location
        let expected = try itemIndent(in: source, of: child) + EditorTypography.default.quoteIndent
        XCTAssertEqual(style.firstLineHeadIndent, expected, accuracy: tolerance)
        XCTAssertEqual(style.headIndent, expected, accuracy: tolerance)
        XCTAssertGreaterThan(expected,
                             try itemIndent(in: source, of: 0) + EditorTypography.default.quoteIndent,
                             "The level-2 item's indent is the one taken, not its parent's")
    }

    func testAQuoteInsideATaskItemTakesTheItemIndent() throws {
        let source = "- [ ] Task\n  > Quoted\n"
        let style = try quoteStyle(in: source, at: "  > Quoted")
        let expected = try itemIndent(in: source, of: 0) + EditorTypography.default.quoteIndent
        XCTAssertEqual(style.firstLineHeadIndent, expected, accuracy: tolerance)
        XCTAssertEqual(style.headIndent, expected, accuracy: tolerance)
    }

    func testAQuoteOutsideAnyListIsUnchanged() throws {
        let style = try quoteStyle(in: "> Quoted\n", at: "> Quoted")
        XCTAssertEqual(style.firstLineHeadIndent, EditorTypography.default.quoteIndent, accuracy: tolerance)
        XCTAssertEqual(style.headIndent, EditorTypography.default.quoteIndent, accuracy: tolerance)
    }

    func testTheBarOfAQuoteInsideAnItemSitsAtTheItemText() throws {
        let typography = EditorTypography.default
        let source = "- Item\n  > Quoted\n"
        let inside = try quoteBar(in: source)
        let outside = try quoteBar(in: "> Quoted\n")
        let itemText = try itemIndent(in: source, of: 0)

        XCTAssertEqual(typography.quoteOrigin(indent: outside.indent), 0, accuracy: tolerance,
                       "A top-level quote starts at the margin")
        XCTAssertEqual(typography.quoteOrigin(indent: inside.indent), itemText, accuracy: tolerance,
                       "A quote inside an item starts at the item's text, not at 0")
        XCTAssertEqual(typography.quoteBarX(indent: inside.indent)
                        - typography.quoteBarX(indent: outside.indent),
                       itemText, accuracy: tolerance,
                       "The bar moves right by exactly the item's text indent")
    }

    private func quoteStyle(in source: String, at line: String) throws -> NSParagraphStyle {
        let view = try render(source)
        let storage = try XCTUnwrap(view.textStorage)
        // A paragraph takes its style from its first character: the start
        // of the line, not the `>`.
        let start = (source as NSString).range(of: line).location
        XCTAssertNotEqual(start, NSNotFound, "\"\(line)\" not found")
        return try XCTUnwrap(storage.attribute(.paragraphStyle, at: start,
                                               effectiveRange: nil) as? NSParagraphStyle)
    }

    /// The text indent of the item that starts at `location`.
    private func itemIndent(in source: String, of location: Int) throws -> CGFloat {
        let item = try XCTUnwrap(MarkdownParser.parse(source).spans.first { span in
            switch span.kind {
            case .listItem, .taskItem: span.layoutRange.location == location
            default: false
            }
        }, "No item at \(location)")
        return EditorTypography.default.itemIndent(for: item)
    }

    private func quoteBar(in source: String) throws -> EditorDecoration {
        let view = try render(source)
        let decorations = EditorDecoration.build(from: MarkdownParser.parse(source).spans,
                                                 in: try XCTUnwrap(view.textStorage),
                                                 typography: .default)
        return try XCTUnwrap(decorations.first { $0.kind == .quoteBar })
    }

    // MARK: - Helpers

    private func lineFrame(at offset: Int, view: EditorTextView) throws -> NSRect {
        let layout = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(view.textContentStorage)
        let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: offset))
        var frame: NSRect?
        layout.enumerateTextSegments(in: NSTextRange(location: location),
                                     type: .selection, options: []) { _, segment, _, _ in
            frame = segment
            return false
        }
        return try XCTUnwrap(frame)
    }

    private func render(_ source: String) throws -> EditorTextView {
        let view = EditorTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false

        let storage = try XCTUnwrap(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)

        let parsed = MarkdownParser.parse(source)
        MarkdownRenderer(typography: .default)
            .render(storage, spans: parsed.spans, revealed: [],
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
