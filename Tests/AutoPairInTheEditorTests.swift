// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// The full typing loop, in a real editor.
///
/// The pure functions are covered elsewhere; what's checked here is the
/// wiring: that `⇥` really does exit a format instead of indenting, and
/// that a pair placed then typed through leaves nothing behind.
@MainActor
final class AutoPairInTheEditorTests: XCTestCase {

    private func editor(_ source: String) -> EditorController {
        let controller = EditorController(typography: .default)
        controller.textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.textView.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        controller.textView.textContainer?.widthTracksTextView = false
        controller.setText(source)
        return controller
    }

    /// The gesture auto-pairs enable: `⇥` right up against the closing
    /// marker jumps past it, and the caret comes out of the bold.
    func testTabLeavesAnInlineFormat() {
        let controller = editor("In **bold** too.")
        // `In **bold|** too.` — the end of the content, just before the closing marker.
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        XCTAssertTrue(controller.textView.handlesIndent?(false) ?? false)
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 11, length: 0))
        XCTAssertEqual(controller.text, "In **bold** too.", "Leaving a format doesn't change the text")
    }

    /// From inside a link, `⇥` exits the whole thing — address included.
    /// One press is enough, where MarkText needs two.
    func testTabLeavesTheWholeLink() {
        let controller = editor("See [the site](https://example.com) here.")
        controller.textView.setSelectedRange(NSRange(location: 13, length: 0))
        XCTAssertTrue(controller.textView.handlesIndent?(false) ?? false)
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 35, length: 0))
    }

    /// Elsewhere, `⇥` must stay what it was: nothing stolen from
    /// indentation.
    func testTabInTheMiddleOfAWordIsNotStolen() {
        let controller = editor("In **bold** too.")
        controller.textView.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertFalse(controller.textView.handlesIndent?(false) ?? true)
    }

    func testTabStillIndentsAListItem() {
        let controller = editor("- an item")
        controller.textView.setSelectedRange(NSRange(location: 9, length: 0))
        XCTAssertTrue(controller.textView.handlesIndent?(false) ?? false)
        XCTAssertEqual(controller.text, "  - an item")
    }

    /// What matters in the end: the file. Typing `(` then closing it by
    /// hand must leave neither an extra parenthesis nor a missing one.
    func testTypingAPairThenClosingItLeavesTheTextIntact() {
        let controller = editor("See ")
        controller.textView.setSelectedRange(NSRange(location: 4, length: 0))
        controller.textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(controller.text, "See ()")
        controller.textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.textView.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(controller.text, "See (a)")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 7, length: 0))
    }

    /// And the reverse: backing into the empty pair erases it with a
    /// single `⌫`.
    func testBackspaceRemovesBothHalves() {
        let controller = editor("See ")
        controller.textView.setSelectedRange(NSRange(location: 4, length: 0))
        controller.textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.textView.deleteBackward(nil)
        XCTAssertEqual(controller.text, "See ")
    }
}

/// Does the table grid really open?
@MainActor
final class TableSizePickerInTheEditorTests: XCTestCase {

    func testTheMenuOpensThePicker() {
        let controller = EditorController(typography: .default)
        controller.textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.setText("A paragraph.\n")
        controller.presentTableSizePicker()

        // The opening is deferred by one run-loop turn — see the comment
        // on `presentTableSizePicker`: that's what makes it visible from
        // the menu bar.
        let opened = expectation(description: "the table grid opens")
        DispatchQueue.main.async {
            XCTAssertTrue(controller.isTableSizePickerOpen)
            opened.fulfill()
        }
        wait(for: [opened], timeout: 1)
    }
}
