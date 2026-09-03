// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import XCTest
@testable import Fovea

/// The typing behaviors from §2.5, tested as pure functions.
///
/// This whole file verifies text-to-text transformations: no window is
/// opened, no key is simulated. This is what makes it possible to cover
/// the twisted cases (empty item, nested list, formatting already applied)
/// without writing a single UI test.
final class TypingBehaviourTests: XCTestCase {

    // MARK: - List Continuation

    func testNewlineContinuesABulletList() {
        let edit = TypingBehaviour.newline(in: "- initial", selection: NSRange(location: 9, length: 0))
        XCTAssertEqual(edit?.replacement, "\n- ")
        XCTAssertEqual(edit?.caret, 12)
    }

    func testNewlineIncrementsAnOrderedList() {
        let edit = TypingBehaviour.newline(in: "3. the third", selection: NSRange(location: 12, length: 0))
        XCTAssertEqual(edit?.replacement, "\n4. ", "The next number, not a copy of the previous one")
    }

    func testNewlinePreservesNestingIndentation() {
        let text = "- parent\n  - infant"
        let edit = TypingBehaviour.newline(in: text, selection: NSRange(location: 19, length: 0))
        XCTAssertEqual(edit?.replacement, "\n  - ", "The next item stays at the same level")
    }

    func testNewlineOnAnEmptyItemLeavesTheList() {
        // Two `⏎` in a row leave the list: it is the gesture everyone makes,
        // and not accounting for it means having to erase the marker by
        // hand.
        let text = "- initial\n- "
        let edit = TypingBehaviour.newline(in: text, selection: NSRange(location: 12, length: 0))
        XCTAssertEqual(edit?.range, NSRange(location: 10, length: 2))
        // The blank line is not decorative: without it, the next word typed
        // would be a lazy continuation of "initial".
        XCTAssertEqual(edit?.replacement, "\n")
        XCTAssertEqual(edit?.caret, 11)
    }

    func testLeavingAListReallyLeavesIt() {
        // The test that matters: what the **file** says once the sentence
        // has been typed. Without the blank line, cmark files "After" inside
        // the bullet, and an editor that displayed it as a separate
        // paragraph would misrepresent the document.
        let text = "- initial\n- "
        let edit = try? XCTUnwrap(TypingBehaviour.newline(in: text, selection: NSRange(location: 12, length: 0)))
        let after = (text as NSString).replacingCharacters(in: edit!.range, with: edit!.replacement)
        let typed = (after as NSString).replacingCharacters(in: NSRange(location: edit!.caret, length: 0),
                                                           with: "After.")
        XCTAssertEqual(typed, "- initial\n\nAfter.")

        let spans = MarkdownParser.parse(typed).spans
        let items = spans.filter { if case .listItem = $0.kind { return true } else { return false } }
        XCTAssertEqual(items.count, 1, "Only one item: \"After.\" is outside")
        XCTAssertFalse(items.contains { NSLocationInRange(typed.utf16.count - 1, $0.range) },
                       "The last sentence must not belong to any item")
    }

    func testLeavingAListDoesNotStackBlankLines() {
        // A blank line above is already enough to break continuation: adding
        // a second one would dig a hole in the document.
        let text = "any text\n\n- "
        let edit = TypingBehaviour.newline(in: text, selection: NSRange(location: 12, length: 0))
        XCTAssertEqual(edit?.replacement, "")
        XCTAssertEqual(edit?.caret, 10)
    }

    func testLeavingAListAtTheTopOfTheDocumentAddsNothing() {
        // Nothing above, so nothing to cut: a document that opened on a
        // blank line would be a regression all by itself.
        let edit = TypingBehaviour.newline(in: "- ", selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.replacement, "")
        XCTAssertEqual(edit?.caret, 0)
    }

    func testNewlineOnATaskItemStartsAnUncheckedOne() {
        // A checked box is not copied as checked: nobody wants to create ten
        // tasks that are already done.
        let edit = TypingBehaviour.newline(in: "- [x] done", selection: NSRange(location: 10, length: 0))
        XCTAssertEqual(edit?.replacement, "\n- [ ] ")
    }

    func testNewlineOutsideAListIsLeftAlone() {
        XCTAssertNil(TypingBehaviour.newline(in: "any text", selection: NSRange(location: 8, length: 0)),
                     "Outside a list, ⏎ must keep its usual behavior")
    }

    func testNewlineIgnoresADashWithoutASpace() {
        // `-words` is not a list. Treating it as one would turn a mistyped
        // dash into a bullet.
        XCTAssertNil(TypingBehaviour.newline(in: "-words", selection: NSRange(location: 6, length: 0)))
    }

    // MARK: - Indentation

    func testTabIndentsAListItem() {
        let edit = TypingBehaviour.indent(in: "- item", selection: NSRange(location: 6, length: 0), outdent: false)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(edit?.replacement, "  ")
        XCTAssertEqual(edit?.caret, 8)
    }

    func testShiftTabOutdents() {
        let edit = TypingBehaviour.indent(in: "  - item", selection: NSRange(location: 8, length: 0), outdent: true)
        XCTAssertEqual(edit?.range, NSRange(location: 0, length: 2))
        XCTAssertEqual(edit?.replacement, "")
    }

    func testShiftTabAtTheLeftMarginDoesNothing() {
        XCTAssertNil(TypingBehaviour.indent(in: "- item", selection: NSRange(location: 6, length: 0), outdent: true))
    }

    func testTabOutsideAListStaysATab() {
        XCTAssertNil(TypingBehaviour.indent(in: "any text", selection: NSRange(location: 4, length: 0), outdent: false),
                     "Outside a list, ⇥ must stay a tab")
    }

    // MARK: - Wrapping

    func testWrapSurroundsTheSelection() {
        let edit = TypingBehaviour.wrap("my box now", selection: NSRange(location: 3, length: 3), with: "**")
        XCTAssertEqual(edit.replacement, "**box**")
        // **The selection survives formatting**, on the same text as before.
        //
        // It did not survive: `⌘B` collapsed it to a caret, and the `⌘I`
        // that follows had nothing left to italicize. Typing a `*` over a
        // selection, on the other hand, already kept it (see `autoPair`):
        // two paths to the same gesture, two behaviors. The caret stays
        // between the stars in both cases.
        XCTAssertEqual(edit.caret, 5, "The word starts after the two opening stars")
        XCTAssertEqual(edit.selectionLength, 3, "The word stays selected, ready for a second format")
    }

    func testWrapOnACaretPlacesItBetweenTheMarkers() {
        // The user asked for bold to write in bold, not to place two stars
        // and then hunt for where to type.
        let edit = TypingBehaviour.wrap("my  now", selection: NSRange(location: 3, length: 0), with: "**")
        XCTAssertEqual(edit.replacement, "****")
        XCTAssertEqual(edit.caret, 5)
    }

    func testWrapOnAlreadyFormattedTextRemovesTheFormatting() {
        // §2.5: applied to already-formatted text, the shortcuts remove the
        // formatting rather than stacking a second level.
        let text = "my **box** now"
        let edit = TypingBehaviour.wrap(text, selection: NSRange(location: 5, length: 3), with: "**")
        XCTAssertEqual(edit.range, NSRange(location: 3, length: 7))
        XCTAssertEqual(edit.replacement, "box")
    }

    func testWrapHandlesAccentedSelections() {
        // Accented text: exercises the UTF-8 → UTF-16 offset conversion.
        let edit = TypingBehaviour.wrap("Zoë crucial", selection: NSRange(location: 4, length: 7), with: "*")
        XCTAssertEqual(edit.replacement, "*crucial*")
    }

    // MARK: - Heading Level

    func testSetHeadingLevelOnAPlainParagraph() {
        let edit = TypingBehaviour.setHeadingLevel(2, in: "My title", selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(edit.replacement, "## ")
        XCTAssertEqual(edit.caret, 6, "The caret follows the text, it does not stay at its absolute position")
    }

    func testChangingHeadingLevelReplacesTheExistingHashes() {
        let edit = TypingBehaviour.setHeadingLevel(3, in: "## My title", selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(edit.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(edit.replacement, "### ")
    }

    func testLevelZeroRemovesTheHeading() {
        let edit = TypingBehaviour.setHeadingLevel(0, in: "### My title", selection: NSRange(location: 6, length: 0))
        XCTAssertEqual(edit.replacement, "")
        XCTAssertEqual(edit.caret, 2)
    }

    // MARK: - Recognition While Typing

    func testRecognizedConstructs() {
        // It is not a feature but a consequence of §3.1: the marker is
        // already in the text, the parser sees it, the rendering follows.
        // This test states which ones are recognized instead of assuming it.
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "# "))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "###### Heading 6"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "- item"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "* item"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "1. item"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "12) item"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "> quote"))
        XCTAssertTrue(TypingBehaviour.recognizesConstruct(onLine: "  - indented item"))
    }

    func testNonConstructs() {
        XCTAssertFalse(TypingBehaviour.recognizesConstruct(onLine: "####### seven hashes"))
        XCTAssertFalse(TypingBehaviour.recognizesConstruct(onLine: "#no space"))
        XCTAssertFalse(TypingBehaviour.recognizesConstruct(onLine: "-no space"))
        XCTAssertFalse(TypingBehaviour.recognizesConstruct(onLine: "1.no space"))
        XCTAssertFalse(TypingBehaviour.recognizesConstruct(onLine: "ordinary text"))
    }

    // MARK: - Toggling a Task

    /// The checkbox is drawn: toggling it means rewriting **one character**
    /// in the file.
    func testTogglingATaskChangesOneCharacter() throws {
        let text = "- [ ] to do"
        let edit = try XCTUnwrap(TypingBehaviour.toggleTask(in: text,
                                                            marker: NSRange(location: 0, length: 6),
                                                            caret: 9))
        XCTAssertEqual(edit.range, NSRange(location: 3, length: 1))
        XCTAssertEqual(edit.replacement, "x")
        XCTAssertEqual(edit.caret, 9, "Toggling does not move the caret")
    }

    func testTogglingBackClearsTheBox() throws {
        let edit = try XCTUnwrap(TypingBehaviour.toggleTask(in: "- [x] done",
                                                            marker: NSRange(location: 0, length: 6),
                                                            caret: 0))
        XCTAssertEqual(edit.replacement, " ")
    }

    /// §5 also applies to what the app writes itself: an uppercase `[X]`
    /// gets unchecked, it does not get normalized.
    func testAnUppercaseBoxIsRecognisedAndNotRewritten() throws {
        let edit = try XCTUnwrap(TypingBehaviour.toggleTask(in: "- [X] done",
                                                            marker: NSRange(location: 0, length: 6),
                                                            caret: 0))
        XCTAssertEqual(edit.replacement, " ", "An [X] is indeed read as checked")
    }

    func testAPlainListItemHasNothingToToggle() {
        XCTAssertNil(TypingBehaviour.toggleTask(in: "- an item",
                                                marker: NSRange(location: 0, length: 2),
                                                caret: 0))
    }

    // MARK: - Inserting a Link

    func testALinkWrapsTheSelectionAndTakesTheURLFromTheClipboard() {
        let edit = TypingBehaviour.link(in: "View my site now",
                                        selection: NSRange(location: 13, length: 3),
                                        url: "https://example.fr")
        XCTAssertEqual(edit.replacement, "[now](https://example.fr)")
        XCTAssertEqual(edit.caret, 38, "The caret moves past the link, ready to continue the sentence")
    }

    func testALinkWithoutAnAddressPutsTheCaretWhereOneWritesIt() {
        let edit = TypingBehaviour.link(in: "View my site now",
                                        selection: NSRange(location: 13, length: 3),
                                        url: nil)
        XCTAssertEqual(edit.replacement, "[now]()")
        XCTAssertEqual(edit.caret, 19, "Between the parentheses: pasting the address is all that is left")
    }

    func testALinkWithoutSelectionPutsTheCaretWhereOneWritesTheLabel() {
        let edit = TypingBehaviour.link(in: "", selection: NSRange(location: 0, length: 0), url: nil)
        XCTAssertEqual(edit.replacement, "[]()")
        XCTAssertEqual(edit.caret, 1, "Between the brackets: the text is written before the address")
    }

    /// Guessing too broadly would paste any copied sentence between a
    /// link's parentheses, which is more painful to undo than to type.
    func testOnlyRealAddressesAreTakenFromTheClipboard() {
        XCTAssertTrue(TypingBehaviour.looksLikeURL("https://example.fr"))
        XCTAssertTrue(TypingBehaviour.looksLikeURL("www.example.fr"))
        XCTAssertTrue(TypingBehaviour.looksLikeURL("mailto:elior@example.fr"))
        XCTAssertFalse(TypingBehaviour.looksLikeURL("a copied sentence"))
        XCTAssertFalse(TypingBehaviour.looksLikeURL("example.fr"))
        XCTAssertFalse(TypingBehaviour.looksLikeURL(""))
    }

    // MARK: - Auto-Pairing

    /// Helper: what typing produces, as text, to read the cases at a
    /// glance. The caret is marked `|`, the selection by two `|`.
    private func typing(_ character: Character, into text: String,
                        selection: NSRange, insideCode: Bool = false) -> String {
        guard let edit = TypingBehaviour.autoPair(typing: character, in: text,
                                                  selection: selection, insideCode: insideCode)
        else { return "—" }
        let result = NSMutableString(string: text)
        result.replaceCharacters(in: edit.range, with: edit.replacement)
        result.insert("|", at: edit.caret + edit.selectionLength)
        if edit.selectionLength > 0 { result.insert("|", at: edit.caret) }
        return result as String
    }

    func testAnOpeningBracketPosesItsClosing() {
        XCTAssertEqual(typing("(", into: "View ", selection: NSRange(location: 5, length: 0)),
                       "View (|)")
        XCTAssertEqual(typing("[", into: "", selection: NSRange(location: 0, length: 0)), "[|]")
    }

    /// The case that decides everything in French: the apostrophe is a
    /// letter within the word. No pairing, ever, regardless of context.
    func testTheApostropheIsNeverPaired() {
        XCTAssertEqual(typing("'", into: "l", selection: NSRange(location: 1, length: 0)), "—")
        XCTAssertEqual(typing("'", into: "", selection: NSRange(location: 0, length: 0)), "—")
        XCTAssertEqual(typing("'", into: "cat ", selection: NSRange(location: 4, length: 0)), "—")
    }

    /// `2*3` must not place a phantom star, nor should `snake_case` produce
    /// italics.
    func testAMarkdownMarkerNeverOpensInsideAWord() {
        XCTAssertEqual(typing("*", into: "2", selection: NSRange(location: 1, length: 0)), "—")
        XCTAssertEqual(typing("_", into: "snake", selection: NSRange(location: 5, length: 0)), "—")
        XCTAssertEqual(typing("*", into: "my ", selection: NSRange(location: 3, length: 0)), "my *|*")
    }

    /// A pair in the middle of a word would almost always be wrong; before
    /// closing punctuation, it is almost always right.
    func testAPairOnlyOpensBeforeABoundary() {
        XCTAssertEqual(typing("(", into: "abc", selection: NSRange(location: 0, length: 0)), "—")
        XCTAssertEqual(typing("(", into: " abc", selection: NSRange(location: 0, length: 0)), "(|) abc")
        XCTAssertEqual(typing("*", into: "my .", selection: NSRange(location: 3, length: 0)), "my *|*.")
    }

    func testABackslashCancelsThePair() {
        XCTAssertEqual(typing("*", into: "my \\", selection: NSRange(location: 4, length: 0)), "—")
    }

    /// Retyping the closing character steps over it instead of writing a
    /// second one: that is what makes the pair invisible in use.
    func testRetypingTheClosingStepsOverIt() {
        XCTAssertEqual(typing(")", into: "(trial)", selection: NSRange(location: 6, length: 0)),
                       "(trial)|")
        // Typing both closing stars by hand steps over both of them:
        // `**bold|**` then `*` then `*` gives `**bold**|`.
        XCTAssertEqual(typing("*", into: "**bold**", selection: NSRange(location: 6, length: 0)),
                       "**bold*|*")
        XCTAssertEqual(typing("*", into: "**bold**", selection: NSRange(location: 7, length: 0)),
                       "**bold**|")
    }

    /// The heart of the convenience: `**` then the text then `⇥`. Here, the
    /// first half: placing `****` with the caret in the middle.
    func testTypingTwoStarsLandsBetweenFour() {
        XCTAssertEqual(typing("*", into: "my ", selection: NSRange(location: 3, length: 0)), "my *|*")
        XCTAssertEqual(typing("*", into: "my **", selection: NSRange(location: 4, length: 0)), "my **|**")
    }

    func testMarkdownMarkersAreNotPairedInsideCode() {
        XCTAssertEqual(typing("*", into: "let a = ", selection: NSRange(location: 8, length: 0),
                              insideCode: true), "—")
        // Parentheses, on the other hand, keep their full meaning inside code.
        XCTAssertEqual(typing("(", into: "print", selection: NSRange(location: 5, length: 0),
                              insideCode: true), "print(|)")
    }

    /// With text selected, the key surrounds instead of replacing: the
    /// selection stays on the same text, so `*` then `*` can be chained.
    func testASelectionIsSurroundedAndKept() {
        XCTAssertEqual(typing("*", into: "my bold now", selection: NSRange(location: 3, length: 4)),
                       "my *|bold|* now")
        XCTAssertEqual(typing("(", into: "my remark", selection: NSRange(location: 3, length: 6)),
                       "my (|remark|)")
    }

    func testAnUnpairedCharacterIsLeftAlone() {
        XCTAssertEqual(typing("a", into: "", selection: NSRange(location: 0, length: 0)), "—")
        XCTAssertEqual(typing("a", into: "box", selection: NSRange(location: 0, length: 3)), "—")
    }

    /// Backspacing over a parenthesis you did not want must not leave its
    /// twin orphaned.
    func testBackspaceBetweenAPairRemovesBoth() throws {
        let edit = try XCTUnwrap(TypingBehaviour.deletingPair(in: "View ()",
                                                              selection: NSRange(location: 6, length: 0)))
        XCTAssertEqual(edit.range, NSRange(location: 5, length: 2))
        XCTAssertEqual(edit.replacement, "")
        XCTAssertEqual(edit.caret, 5)
    }

    func testBackspaceElsewhereIsLeftAlone() {
        // The closing character is not adjacent: what gets deleted is no
        // longer a pair.
        XCTAssertNil(TypingBehaviour.deletingPair(in: "View (a)", selection: NSRange(location: 6, length: 0)))
        XCTAssertNil(TypingBehaviour.deletingPair(in: "View ()", selection: NSRange(location: 7, length: 0)))
        XCTAssertNil(TypingBehaviour.deletingPair(in: "", selection: NSRange(location: 0, length: 0)))
    }

    // MARK: - Line Analysis

    func testLineRangeExcludesTheTerminator() {
        let units = Array("my\ntext\nblock".utf16)
        XCTAssertEqual(TypingBehaviour.lineRange(units, containing: 0), NSRange(location: 0, length: 2))
        XCTAssertEqual(TypingBehaviour.lineRange(units, containing: 5), NSRange(location: 3, length: 4))
        XCTAssertEqual(TypingBehaviour.lineRange(units, containing: 13), NSRange(location: 8, length: 5))
    }

    func testListPrefixCoversTheWholeCheckbox() {
        let units = Array("- [ ] to do".utf16)
        let line = TypingBehaviour.lineRange(units, containing: 0)
        XCTAssertEqual(TypingBehaviour.listPrefix(units, line: line), NSRange(location: 0, length: 6))
    }

    /// **In front of the marker, `⏎` stays a `⏎`.**
    ///
    /// The caret can land at the very start of a list line: `⌘←` sends it
    /// there, and the reveal rule lets it in. Continuation still applied
    /// regardless: the result was `- - item`, a second bullet in front of
    /// the one that had not been left. What is wanted there is a blank line
    /// above, that is, the ordinary behavior.
    func testNewlineBeforeTheMarkerDoesNotDuplicateIt() {
        XCTAssertNil(TypingBehaviour.newline(in: "- an item", selection: NSRange(location: 0, length: 0)),
                     "At the start of a line, ⏎ must stay a simple return")
        XCTAssertNil(TypingBehaviour.newline(in: "- an item", selection: NSRange(location: 1, length: 0)),
                     "Within the marker either, the list must not continue")

        // Right after the marker, however, continuation resumes: this is
        // the gesture that creates the empty item above.
        let edit = TypingBehaviour.newline(in: "- an item", selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(edit?.replacement, "\n- ")
    }
}
