// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
@testable import Fovea

/// The language of a code block, and the table grid.
///
/// Two pure functions for two floating panels: what decides **when** to
/// open and **what to write** can be tested without ever opening a window.
final class CodeFenceTests: XCTestCase {

    // MARK: - When the language picker opens

    func testTheCaretAfterTheBackticksOffersTheLanguage() throws {
        let trigger = try XCTUnwrap(CodeFence.languageTrigger(inLine: "```", lineStart: 0, caret: 3))
        XCTAssertEqual(trigger.query, "")
        XCTAssertEqual(trigger.range, NSRange(location: 3, length: 0))
    }

    func testWhatIsAlreadyTypedFiltersTheList() throws {
        let trigger = try XCTUnwrap(CodeFence.languageTrigger(inLine: "```swi", lineStart: 0, caret: 6))
        XCTAssertEqual(trigger.query, "swi")
        // The range covers the whole word: picking from the list replaces
        // it, rather than blindly completing what's already there.
        XCTAssertEqual(trigger.range, NSRange(location: 3, length: 3))
    }

    func testTheOffsetOfTheLineIsRespected() throws {
        let trigger = try XCTUnwrap(CodeFence.languageTrigger(inLine: "```py", lineStart: 120, caret: 125))
        XCTAssertEqual(trigger.range, NSRange(location: 123, length: 2))
    }

    /// A caret placed **inside** the backticks wants to edit them, not name
    /// a language.
    func testTheCaretInsideTheFenceOffersNothing() {
        XCTAssertNil(CodeFence.languageTrigger(inLine: "```", lineStart: 0, caret: 2))
        XCTAssertNil(CodeFence.languageTrigger(inLine: "```swift", lineStart: 0, caret: 0))
    }

    func testAnOrdinaryLineOffersNothing() {
        XCTAssertNil(CodeFence.languageTrigger(inLine: "some text", lineStart: 0, caret: 4))
        // Two backticks aren't a fence: that's inline code.
        XCTAssertNil(CodeFence.languageTrigger(inLine: "``x``", lineStart: 0, caret: 3))
    }

    /// `~~~` is as legitimate a fence as backticks, and up to three spaces
    /// can precede it.
    func testTildesAndIndentationAreAccepted() throws {
        XCTAssertNotNil(CodeFence.languageTrigger(inLine: "~~~json", lineStart: 0, caret: 7))
        XCTAssertNotNil(CodeFence.languageTrigger(inLine: "  ```json", lineStart: 0, caret: 9))
        // Four spaces makes an indented code block: no longer a fence.
        XCTAssertNil(CodeFence.languageTrigger(inLine: "    ```json", lineStart: 0, caret: 11))
    }

    /// `csv no header` is a note the author wrote to themselves, not a name
    /// to complete: opening a menu on every space would be unbearable.
    func testAnInfoStringWithSpacesIsLeftAlone() {
        XCTAssertNil(CodeFence.languageTrigger(inLine: "```csv no header", lineStart: 0, caret: 16))
    }

    // MARK: - Filtering

    func testThePrefixComesFirst() {
        // You type the start of a word, not its middle: `s` must offer
        // `swift` before `css`.
        let matches = CodeFence.matching("s")
        XCTAssertEqual(matches.first, "swift")
        XCTAssertTrue(matches.contains("css"))
        XCTAssertLessThan(matches.firstIndex(of: "swift")!, matches.firstIndex(of: "css")!)
    }

    func testAnEmptyQueryOffersEverything() {
        XCTAssertEqual(CodeFence.matching(""), CodeFence.languages)
    }

    func testOnlyLanguagesTheHighlighterKnowsAreOffered() {
        // Offering a language it couldn't highlight would be an empty
        // promise.
        for language in CodeFence.languages {
            XCTAssertNotNil(CodeHighlighter.Grammar.all[language],
                            "`\(language)` is offered but has no grammar")
        }
    }

    // MARK: - The table grid

    func testTheTableHasTheRequestedShape() {
        let (markdown, caret) = CodeFence.table(columns: 3, rows: 2)
        XCTAssertEqual(markdown, """
        |  |  |  |
        |---|---|---|
        |  |  |  |
        |  |  |  |
        """)
        // The caret lands in the first cell, the one about to be filled in.
        XCTAssertEqual(caret, 2)
    }

    func testASingleColumnTableIsStillATable() {
        let (markdown, _) = CodeFence.table(columns: 1, rows: 1)
        XCTAssertEqual(markdown, "|  |\n|---|\n|  |")
    }

    func testTheTableIsReparsedAsAGrid() throws {
        // The real test: what the grid builder writes must come back out
        // of the parser as a table, otherwise the grid will never render.
        let (markdown, _) = CodeFence.table(columns: 4, rows: 3)
        let utf16 = Array(markdown.utf16)
        let table = try XCTUnwrap(MarkdownTable.scan(utf16: utf16,
                                                    in: NSRange(location: 0, length: utf16.count)))
        XCTAssertEqual(table.rows.count, 4, "The header row plus three body rows")
        XCTAssertEqual(table.rows[0].cells.count, 4)
    }
}
