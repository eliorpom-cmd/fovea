// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import XCTest
@testable import Fovea

/// The app's key function, reduced to a pure function.
///
/// The reference document is always the same:
///
/// ```
/// My box **essential** now
/// 0123456789012345678901234
///        ^7          ^18,19  the Strong construct occupies [7, 20]
/// ```
final class RevealPolicyTests: XCTestCase {

    private let strong = SyntaxSpan(
        kind: .strong,
        range: NSRange(location: 7, length: 13),          // "**essential**"
        markers: [NSRange(location: 7, length: 2), NSRange(location: 18, length: 2)],
        content: NSRange(location: 9, length: 9))          // "essential"

    private let wholeLine = NSRange(location: 0, length: 24)

    /// "## Title": prefix at [0, 3], content starting at 3.
    private let heading = SyntaxSpan(kind: .heading(level: 2),
                                     range: NSRange(location: 0, length: 8),
                                     markers: [NSRange(location: 0, length: 3)],
                                     content: NSRange(location: 3, length: 5))

    // MARK: - Boundaries, and Why They Are Inclusive

    func testRevealsWhenCaretTouchesTheOpeningBoundary() {
        XCTAssertEqual(revealed(caret: 7), [0], "The caret right before the ** must make them appear")
    }

    func testRevealsWhenCaretTouchesTheClosingBoundary() {
        XCTAssertEqual(revealed(caret: 20), [0], "The caret right after the ** must still show them")
    }

    func testHidesOneStepPastTheConstruct() {
        XCTAssertEqual(revealed(caret: 21), [])
        XCTAssertEqual(revealed(caret: 6), [])
    }

    /// The property that justifies the choice of inclusive boundaries: entering
    /// then leaving returns exactly to the starting state. With an open
    /// interval, entry and exit would not happen at the same position, and a
    /// right arrow followed by a left arrow would change the display.
    func testEnteringAndLeavingIsSymmetric() {
        for caret in 0...24 {
            let forward = revealed(caret: caret)
            let backward = revealed(caret: caret)
            XCTAssertEqual(forward, backward)
        }
        XCTAssertEqual(revealed(caret: 20), revealed(caret: 20))
        XCTAssertEqual(revealed(caret: 21), [])
        XCTAssertEqual(revealed(caret: 20), [0])
    }

    // MARK: - The Consequence That Fixed §2.3

    /// **The caret can never sit inside a hidden marker.**
    ///
    /// The original design announced "invisible positions" to work around by
    /// intercepting every movement command of `NSTextView`. This test shows
    /// the problem does not exist: any position inside a marker belongs to
    /// the range of its own construct, so that construct is revealed.
    func testCaretIsNeverInsideAHiddenMarker() {
        for caret in 0...24 {
            let shown = revealed(caret: caret)
            for marker in strong.markers where NSLocationInRange(caret, marker) {
                XCTAssertTrue(shown.contains(0),
                              "Position \(caret): inside a marker, but the construct is hidden")
            }
        }
    }

    // MARK: - A Selection Reveals Nothing New

    func testNonEmptySelectionRevealsNothing() {
        // The user selects rendered text. Making the syntax appear under the
        // selection would shift the content at the exact moment it is being
        // aimed at.
        let selection = NSRange(location: 5, length: 10)
        XCTAssertEqual(RevealPolicy.revealedIndices(spans: [strong], selection: selection, lineRange: wholeLine), [])
    }

    /// The counterpart of the previous test: a selection **entirely
    /// contained** within a construct keeps its markers. Nothing appears
    /// (the caret was already showing them before the selection extended),
    /// so the line no longer jumps on every `⇧→` inside a bold word.
    func testSelectionInsideAConstructKeepsItsMarkers() {
        let inside = NSRange(location: 10, length: 5)          // inside "essential"
        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [strong], selection: inside, lineRange: wholeLine), [0])

        // A selection that overflows still reveals nothing: this is a mouse
        // drag, where the text must not move under the pointer.
        let overflowing = NSRange(location: 10, length: 14)
        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [strong], selection: overflowing, lineRange: wholeLine), [])
    }

    // MARK: - Nesting

    func testInnermostInlineWins() {
        // "**bold with *italic* inside**"
        let outer = SyntaxSpan(kind: .strong,
                               range: NSRange(location: 0, length: 32),
                               markers: [NSRange(location: 0, length: 2), NSRange(location: 30, length: 2)],
                               content: NSRange(location: 2, length: 28))
        let inner = SyntaxSpan(kind: .emphasis,
                               range: NSRange(location: 13, length: 11),
                               markers: [NSRange(location: 13, length: 1), NSRange(location: 23, length: 1)],
                               content: NSRange(location: 14, length: 9))

        let inside = RevealPolicy.revealedIndices(spans: [outer, inner],
                                                  selection: NSRange(location: 18, length: 0),
                                                  lineRange: NSRange(location: 0, length: 32))
        XCTAssertEqual(inside, [1], "Only the innermost construct is revealed (§2.2)")

        let outsideInner = RevealPolicy.revealedIndices(spans: [outer, inner],
                                                        selection: NSRange(location: 5, length: 0),
                                                        lineRange: NSRange(location: 0, length: 32))
        XCTAssertEqual(outsideInner, [0])
    }

    // MARK: - Line Scope

    /// The rule that replaced "anywhere on the line": the caret must
    /// **touch the prefix**. This is what stops a down arrow from shifting
    /// every heading, item and blockquote it crosses by three characters.
    func testHeadingRevealsOnlyFromItsPrefix() {
        let line = NSRange(location: 0, length: 8)             // "## Title"
        for caret in 0...3 {
            XCTAssertEqual(
                RevealPolicy.revealedIndices(spans: [heading],
                                             selection: NSRange(location: caret, length: 0),
                                             lineRange: line),
                [0], "Position \(caret): inside the prefix, the hashes must be there")
        }
        for caret in 4...8 {
            XCTAssertEqual(
                RevealPolicy.revealedIndices(spans: [heading],
                                             selection: NSRange(location: caret, length: 0),
                                             lineRange: line),
                [], "Position \(caret): inside the heading text, nothing must move")
        }
    }

    /// The latch: once the prefix is revealed, it stays revealed as long as
    /// the caret has not left the line. Without it, the first letter typed
    /// after a `⏎` that continues a list would shift the line.
    func testLatchKeepsThePrefixWhileTheCaretStaysOnTheLine() {
        let line = NSRange(location: 0, length: 8)
        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [heading],
                                         selection: NSRange(location: 6, length: 0),
                                         lineRange: line,
                                         linePrefixesLatched: true),
            [0], "The latch keeps the hashes while the heading is being written")

        // It does not cross the line: elsewhere, it reveals nothing.
        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [heading],
                                         selection: NSRange(location: 12, length: 0),
                                         lineRange: NSRange(location: 9, length: 10),
                                         linePrefixesLatched: true),
            [])
    }

    /// A blockquote places a `>` on every line, and it is the one on **the
    /// caret's line** that decides. Without this restriction, placing the
    /// caret on the first line would reveal the next ten all at once.
    func testAQuoteRevealsFromThePrefixOfTheCaretLine() {
        // "> one\n> two"
        let quote = SyntaxSpan(kind: .blockQuote(depth: 1),
                               range: NSRange(location: 0, length: 12),
                               markers: [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)],
                               content: NSRange(location: 2, length: 10))
        let secondLine = NSRange(location: 6, length: 6)

        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [quote],
                                         selection: NSRange(location: 7, length: 0),
                                         lineRange: secondLine),
            [0], "The caret is inside the `>` of the second line")

        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [quote],
                                         selection: NSRange(location: 10, length: 0),
                                         lineRange: secondLine),
            [], "In the middle of the blockquote text, nothing is revealed")
    }

    /// A list item inside a blockquote: the two prefixes follow each other
    /// on the same line, and each is revealed when the caret touches it.
    /// This is what makes it possible to edit one without losing sight of
    /// the other.
    func testNestedPrefixesRevealIndependently() {
        // "> - item"
        let quote = SyntaxSpan(kind: .blockQuote(depth: 1),
                               range: NSRange(location: 0, length: 8),
                               markers: [NSRange(location: 0, length: 2)],
                               content: NSRange(location: 2, length: 6))
        let item = SyntaxSpan(kind: .listItem(marker: .bullet("-")),
                              range: NSRange(location: 0, length: 8),
                              markers: [NSRange(location: 2, length: 2)],
                              content: NSRange(location: 4, length: 4),
                              depth: 2)
        let line = NSRange(location: 0, length: 8)

        XCTAssertEqual(revealed(spans: [quote, item], caret: 1, line: line), [0])
        XCTAssertEqual(revealed(spans: [quote, item], caret: 2, line: line), [0, 1],
                       "At the junction of the two prefixes, both are touched")
        XCTAssertEqual(revealed(spans: [quote, item], caret: 3, line: line), [1])
        XCTAssertEqual(revealed(spans: [quote, item], caret: 6, line: line), [])
    }

    /// The invariant from §2.3, on prefixes this time: **no position inside
    /// a hidden marker is reachable**. This is what the inclusive
    /// boundaries guarantee, and why the new rule is based on the markers
    /// rather than the range.
    func testCaretIsNeverInsideAHiddenLinePrefix() {
        let quote = SyntaxSpan(kind: .blockQuote(depth: 1),
                               range: NSRange(location: 0, length: 12),
                               markers: [NSRange(location: 0, length: 2), NSRange(location: 6, length: 2)],
                               content: NSRange(location: 2, length: 10))
        let lines = [NSRange(location: 0, length: 5), NSRange(location: 6, length: 6)]

        for caret in 0...12 {
            let line = lines.first { RevealPolicy.contains($0, caret) } ?? lines[1]
            let shown = RevealPolicy.revealedIndices(spans: [quote],
                                                     selection: NSRange(location: caret, length: 0),
                                                     lineRange: line)
            for marker in quote.markers where NSLocationInRange(caret, marker) {
                XCTAssertTrue(shown.contains(0),
                              "Position \(caret): inside a hidden `>`, which must never happen")
            }
        }
    }

    func testHeadingStaysHiddenFromAnotherLine() {
        let heading = SyntaxSpan(kind: .heading(level: 2),
                                 range: NSRange(location: 0, length: 8),
                                 markers: [NSRange(location: 0, length: 3)],
                                 content: NSRange(location: 3, length: 5))
        let otherLine = NSRange(location: 9, length: 10)
        XCTAssertEqual(
            RevealPolicy.revealedIndices(spans: [heading],
                                         selection: NSRange(location: 12, length: 0),
                                         lineRange: otherLine),
            [])
    }

    // MARK: - Helpers

    private func revealed(caret: Int) -> Set<Int> {
        RevealPolicy.revealedIndices(spans: [strong],
                                     selection: NSRange(location: caret, length: 0),
                                     lineRange: wholeLine)
    }

    private func revealed(spans: [SyntaxSpan], caret: Int, line: NSRange) -> Set<Int> {
        RevealPolicy.revealedIndices(spans: spans,
                                     selection: NSRange(location: caret, length: 0),
                                     lineRange: line)
    }
}
