// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// The block insertion menu (§4.5).
///
/// Half the work is knowing **when not to open**. A menu that pops up on
/// every forward slash would make the key unusable in text that talks about
/// file paths or dates.
final class SlashCommandTests: XCTestCase {

    private func trigger(_ line: String, caret: Int? = nil,
                         lineStart: Int = 0) -> TypingBehaviour.SlashTrigger? {
        TypingBehaviour.slashTrigger(inLine: line,
                                     lineStart: lineStart,
                                     caret: lineStart + (caret ?? line.utf16.count))
    }

    // MARK: - When it opens

    func testASlashAloneOpensTheMenu() throws {
        let found = try XCTUnwrap(trigger("/"))
        XCTAssertEqual(found.query, "")
        XCTAssertEqual(found.range, NSRange(location: 0, length: 1))
    }

    func testWhatFollowsTheSlashBecomesTheQuery() throws {
        let found = try XCTUnwrap(trigger("/tab"))
        XCTAssertEqual(found.query, "tab")
        XCTAssertEqual(found.range, NSRange(location: 0, length: 4))
    }

    func testThePositionIsAbsoluteInTheDocument() throws {
        // The line is passed alone, but the returned range must point into
        // the document: it's what gets replaced by the block.
        let found = try XCTUnwrap(trigger("/code", lineStart: 420))
        XCTAssertEqual(found.range, NSRange(location: 420, length: 5))
    }

    // MARK: - When it doesn't open

    /// The rule that replaces "only on a blank line": **the `/` must open a
    /// word**. Glued to a character, it stays a forward slash.
    func testASlashGluedToACharacterIsJustASlash() {
        XCTAssertNil(trigger("see docs/api"))
        XCTAssertNil(trigger("on 12/08/2026"))
        XCTAssertNil(trigger("https://example.com"))
        XCTAssertNil(trigger("and/or"))
    }

    /// And its counterpart, which is the whole point of the change: in the
    /// middle of a sentence, after a space, the menu opens. Without that, it
    /// only served people who already knew a blank line was needed first.
    func testASlashAfterASpaceOpensTheMenuMidSentence() throws {
        let found = try XCTUnwrap(trigger("Here's a table /tab"))
        XCTAssertEqual(found.query, "tab")
        XCTAssertEqual(found.range, NSRange(location: 15, length: 4))
        XCTAssertTrue(found.startsNewLine, "The block must start on its own line")
    }

    func testASpaceClosesTheMenu() {
        // "/note to self" is a sentence, not a command.
        XCTAssertNil(trigger("/note to"))
    }

    func testTextAfterTheCaretClosesTheMenu() {
        // A block is inserted between two words, not in the middle of one.
        XCTAssertNil(trigger("/tab and the rest", caret: 4))
    }

    func testTheCaretMustBeAfterTheSlash() {
        XCTAssertNil(trigger("/tab", caret: 0))
    }

    // MARK: - Filtering

    func testTheQueryFindsByPrefix() {
        XCTAssertEqual(SlashCommand.matching("tab").first, .table)
        XCTAssertEqual(SlashCommand.matching("cit").first, .quote)
    }

    func testTheQueryFindsBySubsequence() {
        // Same rule as ⌘K: typing `tb` must find `Table`.
        XCTAssertEqual(SlashCommand.matching("tb").first, .table)
    }

    func testEnglishKeywordsWorkToo() {
        // Half of people type /code or /todo without thinking.
        XCTAssertEqual(SlashCommand.matching("todo").first, .taskList)
        XCTAssertEqual(SlashCommand.matching("hr").first, .rule)
    }

    func testAnEmptyQueryShowsEverything() {
        XCTAssertEqual(SlashCommand.matching("").count, SlashCommand.allCases.count)
    }

    func testNonsenseMatchesNothing() {
        // The menu then closes, and typing becomes ordinary text again.
        XCTAssertTrue(SlashCommand.matching("zzzzq").isEmpty)
    }

    // MARK: - What gets inserted

    private func insertion(_ command: SlashCommand, at location: Int, length: Int,
                           startsNewLine: Bool = false) -> TypingBehaviour.Edit {
        TypingBehaviour.insertion(
            of: command,
            replacing: .init(range: NSRange(location: location, length: length),
                             query: "", startsNewLine: startsNewLine))
    }

    func testTheSlashIsReplacedNotKept() {
        let edit = insertion(.heading2, at: 10, length: 3)
        XCTAssertEqual(edit.range, NSRange(location: 10, length: 3))
        XCTAssertEqual(edit.replacement, "## ")
    }

    /// A block requested in the middle of a sentence starts on its own
    /// line: glued to what precedes it, a `## ` wouldn't be a heading, and
    /// a table would swallow the rest of the sentence into its first cell.
    func testABlockAskedMidSentenceStartsOnItsOwnLine() {
        let edit = insertion(.heading2, at: 10, length: 3, startsNewLine: true)
        XCTAssertEqual(edit.replacement, "\n## ")
        XCTAssertEqual(edit.caret, 14, "The caret follows the added newline")
    }

    func testTheCaretLandsWhereOneWrites() {
        // Inside the code block, not after its closing fence.
        let code = insertion(.codeBlock, at: 0, length: 1)
        XCTAssertEqual(code.replacement, "```\n\n```")
        XCTAssertEqual(code.caret, 4, "The caret must be on the blank line, between the fences")

        // In the table's first cell, not on the next line.
        XCTAssertEqual(insertion(.table, at: 0, length: 1).caret, 2)
    }

    func testEveryInsertedBlockIsValidMarkdown() {
        // The menu exists because markers are hidden: what it inserts must
        // be read back by the parser as the announced construct.
        for command in SlashCommand.allCases {
            let edit = insertion(command, at: 0, length: 0)
            let spans = MarkdownParser.parse(edit.replacement + "text\n").spans
            XCTAssertFalse(spans.isEmpty, "`\(command.title)` produces no construct")
        }
    }

    func testTheInsertedTableIsReadAsAGrid() throws {
        let edit = insertion(.table, at: 0, length: 0)
        let spans = MarkdownParser.parse(edit.replacement + "\n").spans
        let table = try XCTUnwrap(spans.first { if case .table = $0.kind { return true } else { return false } })
        guard case .table(let grid?) = table.kind else {
            return XCTFail("The inserted table must be read as a grid")
        }
        XCTAssertEqual(grid.columnCount, 2)
        XCTAssertEqual(grid.rows.count, 2)
    }

    func testEveryCommandHasATitleAndAHint() {
        for command in SlashCommand.allCases {
            XCTAssertFalse(command.title.isEmpty)
            XCTAssertFalse(command.hint.isEmpty, "The menu shows the syntax it inserts")
        }
    }
}

/// The panel itself.
///
/// What's checked here isn't the appearance but **the contract**: it opens,
/// it places itself under the caret, it never takes focus, and it closes
/// itself when nothing matches anymore.
@MainActor
final class SlashMenuTests: XCTestCase {

    private func host() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.orderBack(nil)
        return window
    }

    func testItNeverBecomesKey() {
        // The whole point: the caret stays in the text and typing keeps
        // going there while the menu filters.
        XCTAssertFalse(SlashMenu().canBecomeKey)
    }

    func testItOpensAndCarriesTheMatchingEntries() {
        let menu = SlashMenu()
        let window = host()
        let caret = NSRect(x: 300, y: 500, width: 1, height: 20)

        XCTAssertTrue(menu.present(query: "ta", caretRect: caret, over: window))
        XCTAssertTrue(menu.isOpen)
        menu.dismiss()
    }

    func testItSitsUnderTheCaret() {
        let menu = SlashMenu()
        let window = host()
        let caret = NSRect(x: 300, y: 500, width: 1, height: 20)
        _ = menu.present(query: "", caretRect: caret, over: window)

        XCTAssertEqual(menu.frame.minX, caret.minX, accuracy: 1,
                       "Aligned on the caret, not on the window")
        XCTAssertLessThanOrEqual(menu.frame.maxY, caret.minY,
                                 "Placed on top, it would hide the word being typed")
        menu.dismiss()
    }

    func testItFlipsAboveTheCaretWhenThereIsNoRoomBelow() {
        let menu = SlashMenu()
        let window = host()
        // A caret right at the bottom of the screen: the menu must flip
        // back above rather than run off the bottom.
        let screen = window.screen ?? NSScreen.main!
        let caret = NSRect(x: 300, y: screen.visibleFrame.minY + 4, width: 1, height: 20)
        _ = menu.present(query: "", caretRect: caret, over: window)

        XCTAssertGreaterThanOrEqual(menu.frame.minY, caret.maxY)
        menu.dismiss()
    }

    func testItClosesItselfWhenNothingMatches() {
        let menu = SlashMenu()
        let window = host()
        _ = menu.present(query: "", caretRect: NSRect(x: 300, y: 500, width: 1, height: 20), over: window)
        XCTAssertTrue(menu.isOpen)

        // Typing becomes ordinary text again, and the caller learns this
        // through the return value.
        XCTAssertFalse(menu.present(query: "zzzzq",
                                    caretRect: NSRect(x: 300, y: 500, width: 1, height: 20),
                                    over: window))
        XCTAssertFalse(menu.isOpen)
    }

    func testConfirmingRunsTheSelectedEntry() {
        let menu = SlashMenu()
        let window = host()
        var chosen: SlashCommand?
        menu.onChoose = { chosen = $0 }

        _ = menu.present(query: "tab", caretRect: NSRect(x: 300, y: 500, width: 1, height: 20), over: window)
        menu.confirmSelection()

        XCTAssertEqual(chosen, .table)
        XCTAssertFalse(menu.isOpen, "Confirming closes the menu")
    }

    func testArrowsMoveWithinTheList() {
        let menu = SlashMenu()
        let window = host()
        var chosen: SlashCommand?
        menu.onChoose = { chosen = $0 }

        _ = menu.present(query: "", caretRect: NSRect(x: 300, y: 500, width: 1, height: 20), over: window)
        menu.moveSelection(by: 1)
        menu.confirmSelection()

        XCTAssertEqual(chosen, SlashCommand.allCases[1])
    }

    func testSelectionStopsAtTheEnds() {
        let menu = SlashMenu()
        let window = host()
        var chosen: SlashCommand?
        menu.onChoose = { chosen = $0 }

        _ = menu.present(query: "", caretRect: NSRect(x: 300, y: 500, width: 1, height: 20), over: window)
        // Moving up from the first entry must not go outside the list.
        menu.moveSelection(by: -5)
        menu.confirmSelection()

        XCTAssertEqual(chosen, SlashCommand.allCases.first)
    }
}
