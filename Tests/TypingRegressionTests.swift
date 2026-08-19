// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// What the UI audit found under real fingers, and that must never come
/// back.
///
/// Two bugs triggered on every use, with no test ever seeing them: the
/// third keystroke of a code block fence, and the caret after removing
/// formatting.
@MainActor
final class TypingRegressionTests: XCTestCase {

    private func editor(_ source: String) -> EditorController {
        let controller = EditorController(typography: .default)
        controller.textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.textView.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        controller.textView.textContainer?.widthTracksTextView = false
        controller.setText(source)
        return controller
    }

    // MARK: - The Code Block Fence

    /// The first two keystrokes double up, the third opens the block.
    ///
    /// Without this case, auto-pairing produced six backticks for three
    /// keystrokes, and the most common markdown gesture did not work.
    func testTheThirdBacktickOpensABlock() {
        let edit = TypingBehaviour.codeFence(typing: "`", in: "````",
                                             selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 4))
        XCTAssertEqual(edit?.replacement, "```\n\n```")
        XCTAssertEqual(edit?.caret, 4, "The caret goes inside the block, not after its fence")
    }

    /// The complete gesture, in a real editor: three keystrokes, one block.
    func testTypingThreeBackticksInTheEditorGivesAFence() {
        let controller = editor("")
        // `insertText` is the point through which the keyboard, dictation
        // and character palette all pass: it is what calls the pairing
        // logic.
        for _ in 0..<3 {
            controller.textView.insertText("`", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        XCTAssertEqual(controller.text, "```\n\n```")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 4, length: 0))
    }

    /// In the middle of a sentence, three backticks are not a block: the
    /// pair keeps control.
    func testTheFenceOnlyOpensALine() {
        XCTAssertNil(TypingBehaviour.codeFence(typing: "`", in: "my ````",
                                               selection: NSRange(location: 5, length: 0)))
    }

    /// Up to three spaces of indentation still count as opening a block.
    func testAnIndentedFenceStillOpens() {
        XCTAssertNotNil(TypingBehaviour.codeFence(typing: "`", in: "  ````",
                                                  selection: NSRange(location: 4, length: 0)))
        XCTAssertNil(TypingBehaviour.codeFence(typing: "`", in: "     ````",
                                               selection: NSRange(location: 7, length: 0)),
                     "Beyond three spaces, it is no longer a fence")
    }

    /// Four backticks around the caret are required: exactly the shape the
    /// first two keystrokes produce, and nothing else.
    func testTheFenceNeedsThePairItReplaces() {
        XCTAssertNil(TypingBehaviour.codeFence(typing: "`", in: "``",
                                               selection: NSRange(location: 1, length: 0)))
        XCTAssertNil(TypingBehaviour.codeFence(typing: "a", in: "````",
                                               selection: NSRange(location: 2, length: 0)))
    }

    // MARK: - The Caret After Removing Formatting

    /// `⌫` at the end of a bold word removes the formatting **and leaves
    /// the caret at the end of the word**.
    ///
    /// It used to jump to the start of the content: `**word**` would be
    /// typed, the bold removed, and the next keystroke would land in front
    /// of the word.
    func testDeletingAFormatKeepsTheCaretWhereItWas() {
        let controller = editor("My **bold** now.")
        // `My **bold**|`: right after the closing markers, where `⌫`
        // removes the formatting.
        controller.textView.setSelectedRange(NSRange(location: 11, length: 0))
        controller.textView.deleteBackward(nil)

        XCTAssertEqual(controller.text, "My bold now.")
        XCTAssertEqual(controller.textView.selectedRange(),
                       NSRange(location: 7, length: 0),
                       "The caret stays at the end of the word, minus the markers erased in front of it")
    }

    /// The same gesture **between the two stars of an opening marker**.
    ///
    /// The position is reachable (the marker is revealed there), and `⌫`
    /// used to see a `*|*` pair to undo before seeing the construct:
    /// `**bold**` became `bold**`, a lone closing marker in the middle of
    /// the sentence.
    func testDeletingFromTheOpeningMarkerRemovesTheWholeConstruct() {
        let controller = editor("My **bold** now.")
        // `My *|*bold**`: inside the opening marker, one character from its
        // start.
        controller.textView.setSelectedRange(NSRange(location: 4, length: 0))
        controller.textView.deleteBackward(nil)

        XCTAssertEqual(controller.text, "My bold now.")
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 3, length: 0))
    }

    // MARK: - Dead Keys

    /// On a French keyboard, `` ` `` and `~` are dead keys: the character
    /// completes a composition and never arrives through the door that
    /// auto-pairing was watching. It therefore **never** triggered on the
    /// two markdown markers that need it the most.
    func testTheClosingHalfIsStillPlacedAfterADeadKey() {
        // `my |`: the backtick has just been typed, the caret is right
        // behind it.
        let edit = TypingBehaviour.autoPairAfterTyping("`", in: "my `", caret: 4, insideCode: false)
        XCTAssertEqual(edit?.range, NSRange(location: 4, length: 0))
        XCTAssertEqual(edit?.replacement, "`")
        XCTAssertEqual(edit?.caret, 4, "The caret stays between the two halves")
    }

    /// Retyping the closing character steps over it, instead of writing a
    /// second one.
    func testRetypingTheClosingHalfStepsOverItAfterADeadKey() {
        // `` `box`|` ``: the backtick was just retyped in front of the one
        // that was already closing the pair.
        let edit = TypingBehaviour.autoPairAfterTyping("`", in: "`box``", caret: 5, insideCode: false)
        XCTAssertEqual(edit?.range, NSRange(location: 4, length: 1), "The one just typed gets removed")
        XCTAssertEqual(edit?.replacement, "")
        XCTAssertEqual(edit?.caret, 5)
    }

    /// Inside code, a markdown marker does not pair up: not even through
    /// this second door.
    func testTheDeadKeyPathRespectsCode() {
        XCTAssertNil(TypingBehaviour.autoPairAfterTyping("`", in: "my `", caret: 4, insideCode: true))
    }

    /// And the third backtick still opens a block, no matter which path it
    /// arrived through.
    func testTheFenceAlsoOpensAfterADeadKey() {
        // `` ```|`` ``: five backticks, the caret after the third one.
        let edit = TypingBehaviour.codeFenceAfterTyping("`", in: "`````", caret: 3)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 5))
        XCTAssertEqual(edit?.replacement, "```\n\n```")
        XCTAssertEqual(edit?.caret, 4)
    }

    // The complete dead-key gesture is not replayed here: `setMarkedText`
    // needs an input session that the test harness does not have, and
    // emulating it by passing the selection as the replacement range does
    // not reproduce the composition. The contract is the one from the four
    // functions above; the full path is verified in the app, with a French
    // keyboard in hand.
}
