// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
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

    // MARK: - Helpers

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
