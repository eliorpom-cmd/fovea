// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// **Milestone 0: the technical bet from §3.4.**
///
/// These tests do not verify an intention, they **measure the actual
/// layout produced by TextKit 2**. A hidden marker must occupy zero width
/// on screen, otherwise the whole app is a lie: a `**` half a point wide
/// would be enough to make every bold word in a text shimmer.
///
/// The measurement is taken where it matters: the caret position. If the
/// caret placed before `**essential**` and the one placed before
/// `essential` land at the same spot, the two stars are taking up no space.
@MainActor
final class MarkerMaskTests: XCTestCase {

    /// Tolerance in points. It is not zero because TextKit rounds its
    /// positions to the sub-pixel; it stays far below what an eye can
    /// distinguish, and far below the width of the thinnest character.
    private let tolerance: CGFloat = 0.1

    // MARK: - The Decisive Measurement

    func testHiddenMarkersOccupyNoHorizontalSpace() throws {
        let withMarkers = try measureCaretX(in: "My box **essential** now", atUTF16: 9)
        let withoutMarkers = try measureCaretX(in: "My box essential now", atUTF16: 7)

        XCTAssertEqual(withMarkers, withoutMarkers, accuracy: tolerance,
                       """
                       The caret before "essential" is not at the same spot depending on whether \
                       the ** are there or not: masking does not make the range zero-width.
                       """)
    }

    func testCaretPositionsCollapseAcrossAHiddenMarker() throws {
        // Positions 7, 8 and 9 straddle the two stars. Hidden, all three
        // must render at the same x.
        let text = "My box **essential** now"
        let seven = try measureCaretX(in: text, atUTF16: 7, revealing: false)
        let eight = try measureCaretX(in: text, atUTF16: 8, revealing: false)
        let nine = try measureCaretX(in: text, atUTF16: 9, revealing: false)

        XCTAssertEqual(seven, eight, accuracy: tolerance)
        XCTAssertEqual(eight, nine, accuracy: tolerance)
    }

    func testRevealedMarkersDoTakeSpaceAgain() throws {
        // The counterpart of the previous test: once revealed, the markers
        // must become real characters again. Without that, they could not
        // be selected or edited.
        let text = "My box **essential** now"
        let hidden = try measureCaretX(in: text, atUTF16: 9, revealing: false)
        let shown = try measureCaretX(in: text, atUTF16: 9, revealing: true)

        XCTAssertGreaterThan(shown - hidden, 1.0,
                             "A revealed marker must occupy a visible width")
    }

    // MARK: - What Masking Must Not Break

    func testMaskingDoesNotChangeLineHeight() throws {
        // A 0.01 pt font could collapse the line height. It does not, as
        // long as another character on the line carries the normal font:
        // but this needed to be verified, not assumed.
        let plain = try measureLineHeight(in: "My box essential now")
        let masked = try measureLineHeight(in: "My box **essential** now")
        XCTAssertEqual(plain, masked, accuracy: 0.5)
    }

    func testMaskingLeavesTheBufferUntouched() throws {
        // The promise from §3.1: rendering is only a layer of attributes.
        // The text must come back out identical down to the last character.
        let source = "# Title\n\nSome **important** text and `some code`.\n"
        let view = try renderedView(source)
        XCTAssertEqual(view.string, source)
    }

    func testFindStillMatchesAcrossHiddenMarkers() throws {
        // `NSTextFinder` searches the buffer, not what is displayed.
        // Searching for "essential" must therefore find it, and that is
        // exactly the benefit of mechanism A over mechanism B from §3.4: no
        // range correspondence to maintain.
        let view = try renderedView("My box **essential** now")
        let found = (view.string as NSString).range(of: "essential")
        XCTAssertEqual(found, NSRange(location: 9, length: 9))
    }

    func testMaskedRangesAreQueryable() throws {
        let view = try renderedView("My box **essential** now")
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertTrue(MarkerMask.isMasked(storage, at: 7), "The opening star must be marked hidden")
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 18))
        XCTAssertFalse(MarkerMask.isMasked(storage, at: 9), "The content is never hidden")
        XCTAssertEqual(MarkerMask.maskedRange(in: storage, at: 7), NSRange(location: 7, length: 2))
    }

    func testAccentedTextKeepsMarkersAligned() throws {
        // The crossing of the two traps: an accent before the bold shifts
        // the cmark columns, and a conversion bug would mask the wrong
        // character: here, an "ë" would become invisible.
        let view = try renderedView("Zoë **crucial** now")
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertFalse(MarkerMask.isMasked(storage, at: 0), "\"Zoë\" must not be masked")
        XCTAssertFalse(MarkerMask.isMasked(storage, at: 1))
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 4), "The ** are at offsets 4 and 5")
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 5))
        XCTAssertFalse(MarkerMask.isMasked(storage, at: 6), "\"crucial\" starts at offset 6")
    }

    // MARK: - A Drawn Mark Replaces a Hidden Source

    /// The most visible bug in the editor: under the caret, a list item
    /// displayed `• - My item` — the bullet drawn by the editor **and**
    /// the dash from the file, side by side.
    ///
    /// The bullet exists only because the dash is hidden. As soon as the
    /// dash comes back, it must go.
    func testTheDrawnBulletDisappearsWhenItsDashComesBack() throws {
        let source = "- A list item"
        let parsed = MarkdownParser.parse(source)
        let line = NSRange(location: 0, length: (source as NSString).length)

        let atPrefix = RevealPolicy.revealedIndices(spans: parsed.spans,
                                                    selection: NSRange(location: 1, length: 0),
                                                    lineRange: line)
        XCTAssertFalse(atPrefix.isEmpty, "The caret is inside the `- `: it must show")
        XCTAssertTrue(marks(parsed.spans, source, revealed: atPrefix).isEmpty,
                      "The drawn bullet must disappear while the dash is visible")

        let inTheText = RevealPolicy.revealedIndices(spans: parsed.spans,
                                                     selection: NSRange(location: 8, length: 0),
                                                     lineRange: line)
        XCTAssertTrue(inTheText.isEmpty, "In the middle of the text, the dash stays hidden")
        XCTAssertEqual(marks(parsed.spans, source, revealed: inTheText).count, 1,
                       "…and the bullet is what replaces it")
    }

    /// The counterpart for a horizontal rule, whose drawn line used to
    /// strike through its `---` once it came back, and for a checkbox.
    func testDrawnMarksYieldToTheirSourceEverywhere() throws {
        for source in ["---", "- [x] A task done"] {
            let parsed = MarkdownParser.parse(source)
            let line = NSRange(location: 0, length: (source as NSString).length)
            let revealed = RevealPolicy.revealedIndices(spans: parsed.spans,
                                                        selection: NSRange(location: 1, length: 0),
                                                        lineRange: line)
            XCTAssertTrue(marks(parsed.spans, source, revealed: revealed).isEmpty,
                          "\"\(source)\": the drawn mark duplicates its source")
            XCTAssertFalse(marks(parsed.spans, source, revealed: []).isEmpty,
                           "\"\(source)\": without a caret, the mark must be there")
        }
    }

    /// An image in the middle of a sentence is not a block: reserving
    /// height for it pushed the line apart, and the drawing was painted
    /// **over the words** around it.
    func testAnImageInsideASentenceIsNotDrawnAsABlock() throws {
        let inline = "Some text ![an image](a.png) and more."
        let alone = "![an image](a.png)"

        for (source, expected) in [(inline, 0), (alone, 1)] {
            let parsed = MarkdownParser.parse(source)
            let images = marks(parsed.spans, source, revealed: []).filter {
                if case .image = $0.kind { return true } else { return false }
            }
            XCTAssertEqual(images.count, expected, "\"\(source)\"")
        }
    }

    private func marks(_ spans: [SyntaxSpan], _ text: String, revealed: Set<Int>) -> [EditorDecoration] {
        let storage = NSTextStorage(string: text)
        // The quote bar and the code block background do not replace
        // anything: they frame a block, and that block still exists under
        // the caret.
        return EditorDecoration.build(from: spans, in: storage,
                                      typography: .default, revealed: revealed)
            .filter { $0.kind != .quoteBar && $0.kind != .codeBackground }
    }

    // MARK: - Measurement Tools

    /// Builds a rendered view, off-screen but with a real layout.
    private func renderedView(_ source: String,
                              caret: Int? = nil,
                              revealing: Bool = false) throws -> EditorTextView {
        let view = EditorTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false

        let storage = try XCTUnwrap(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)

        let parsed = MarkdownParser.parse(source)
        let renderer = MarkdownRenderer(typography: .default)
        let revealed: Set<Int>
        if revealing, let caret {
            revealed = RevealPolicy.revealedIndices(
                spans: parsed.spans,
                selection: NSRange(location: caret, length: 0),
                lineRange: parsed.positions.lineRange(containing: caret))
        } else {
            revealed = []
        }
        renderer.render(storage, spans: parsed.spans, revealed: revealed,
                        in: NSRange(location: 0, length: storage.length))

        let layout = try XCTUnwrap(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        return view
    }

    /// Caret x-position at a given UTF-16 offset, in container coordinates.
    private func measureCaretX(in source: String, atUTF16 offset: Int, revealing: Bool = false) throws -> CGFloat {
        let view = try renderedView(source, caret: offset, revealing: revealing)
        let layout = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(view.textContentStorage)
        let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: offset))
        let range = NSTextRange(location: location)

        var x: CGFloat?
        layout.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
            x = frame.origin.x
            return false
        }
        return try XCTUnwrap(x, "No text segment at offset \(offset)")
    }

    private func measureLineHeight(in source: String) throws -> CGFloat {
        let view = try renderedView(source)
        let layout = try XCTUnwrap(view.textLayoutManager)
        var height: CGFloat?
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            height = fragment.layoutFragmentFrame.height
            return false
        }
        return try XCTUnwrap(height)
    }
}
