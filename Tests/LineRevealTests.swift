// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// When a line shows the prefix it starts with (§2.2).
///
/// The rule was written against **vertical** navigation: revealing on the
/// whole line made every heading, bullet and quote crossed by the down arrow
/// jump sideways and settle back. That part is unchanged, and this file
/// guards it.
///
/// What it also governed, and should not have, was the click. An alpha tester
/// reported that the markers "only show on double click" — and that was
/// exactly right: double-clicking the first word of a heading puts the caret
/// at the end of the `## `, the single position on that line touching the
/// marker. Clicking anywhere else on the same line showed nothing at all.
@MainActor
final class LineRevealTests: XCTestCase {

    private let source = "A paragraph.\n\n## Second heading\n\nAnd another one."
    /// Offset of the `##`, and a caret in the middle of the heading's text.
    private let hashes = 14
    private let insideTheHeading = 22

    private func editor() -> EditorController {
        let controller = EditorController(typography: .default)
        controller.textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.textView.textContainer?.size = NSSize(width: 860,
                                                         height: CGFloat.greatestFiniteMagnitude)
        controller.textView.textContainer?.widthTracksTextView = false
        controller.setText(source)
        return controller
    }

    /// `↑` and `↓` reveal nothing: reading a document must not make it move.
    func testCrossingLinesRevealsNothing() throws {
        let controller = editor()
        let storage = try XCTUnwrap(controller.textView.textStorage)

        controller.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        controller.textView.setSelectedRange(NSRange(location: insideTheHeading, length: 0))

        XCTAssertTrue(MarkerMask.isMasked(storage, at: hashes),
                      "Passing through a heading must not bring its hashes back")
    }

    /// Landing on a line on purpose — a click, a horizontal move — shows what
    /// that line is made of, wherever on it the caret came to rest.
    func testLandingOnALineRevealsItsPrefix() throws {
        let controller = editor()
        let storage = try XCTUnwrap(controller.textView.textStorage)

        // `mouseDown` sets the same flag; a synthetic click cannot be sent
        // here without entering AppKit's drag-tracking loop, so the gesture
        // is represented by the other one that sets it.
        controller.textView.doCommand(by: #selector(NSResponder.moveRight(_:)))
        controller.textView.setSelectedRange(NSRange(location: insideTheHeading, length: 0))

        XCTAssertFalse(MarkerMask.isMasked(storage, at: hashes),
                       "A line the caret was aimed at must show its `## `")
    }

    /// And it closes back up as soon as the caret leaves, exactly as the
    /// latch always did.
    func testThePrefixHidesAgainOnTheNextLine() throws {
        let controller = editor()
        let storage = try XCTUnwrap(controller.textView.textStorage)

        controller.textView.doCommand(by: #selector(NSResponder.moveRight(_:)))
        controller.textView.setSelectedRange(NSRange(location: insideTheHeading, length: 0))
        XCTAssertFalse(MarkerMask.isMasked(storage, at: hashes))

        controller.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        controller.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(MarkerMask.isMasked(storage, at: hashes),
                      "Leaving the line hides the prefix again")
    }

    /// A document opens rendered. Nothing has been aimed at yet, so the line
    /// the reading position lands on keeps its syntax hidden.
    func testADocumentOpensWithNothingRevealed() throws {
        let controller = editor()
        let storage = try XCTUnwrap(controller.textView.textStorage)
        controller.textView.setSelectedRange(NSRange(location: insideTheHeading, length: 0))

        XCTAssertTrue(MarkerMask.isMasked(storage, at: hashes))
    }

    /// Editing is not arriving. A `⌫` on a heading reached from the line
    /// above must not make its `## ` reappear: that is the line shifting
    /// under the fingers, at the worst possible moment.
    func testTypingAndDeletingDoNotOpenTheLine() throws {
        let controller = editor()
        let storage = try XCTUnwrap(controller.textView.textStorage)

        controller.textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        controller.textView.setSelectedRange(NSRange(location: insideTheHeading, length: 0))
        controller.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))

        XCTAssertTrue(MarkerMask.isMasked(storage, at: hashes))
    }

    /// Dragging a selection across a line reveals nothing either: the text
    /// must not move under the pointer while it is being aimed at.
    func testASelectionDoesNotOpenTheLine() throws {
        let controller = editor()
        let storage = try XCTUnwrap(controller.textView.textStorage)

        controller.textView.doCommand(by: #selector(NSResponder.moveRight(_:)))
        controller.textView.setSelectedRange(NSRange(location: insideTheHeading, length: 5))

        XCTAssertTrue(MarkerMask.isMasked(storage, at: hashes))
    }
}
