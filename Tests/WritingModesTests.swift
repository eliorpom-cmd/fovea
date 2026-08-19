// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// The §4.5 writing functions, tested as pure functions.
final class WritingModesTests: XCTestCase {

    // MARK: - Paragraph

    func testParagraphIsDelimitedByBlankLinesNotByLineBreaks() {
        // A markdown document is almost always hand-wrapped around 80
        // characters. Treating the line as the paragraph would dim half of
        // the sentence someone is currently writing.
        let text = "First line\nwhich continues here.\n\nAnother paragraph.\n" as NSString
        let range = WritingModes.paragraphRange(in: text, containing: 5)
        XCTAssertEqual(text.substring(with: range), "First line\nwhich continues here.\n")
    }

    func testParagraphAtTheEndOfTheDocument() {
        let text = "One.\n\nTwo." as NSString
        let range = WritingModes.paragraphRange(in: text, containing: 8)
        XCTAssertEqual(text.substring(with: range), "Two.")
    }

    // MARK: - Sentence

    func testSentenceStopsAtStrongPunctuation() {
        let text = "First sentence. Second sentence. Third." as NSString
        let range = WritingModes.sentenceRange(in: text, containing: 20)
        XCTAssertEqual(text.substring(with: range).trimmingCharacters(in: .whitespaces),
                       "Second sentence.")
    }

    func testSentenceIgnoresAbbreviations() {
        // "Mr. Smith" doesn't make two sentences, otherwise the dimming
        // would flicker in the middle of a proper noun.
        let text = "We saw Mr. Smith last night. Then we left." as NSString
        let range = WritingModes.sentenceRange(in: text, containing: 20)
        XCTAssertEqual(text.substring(with: range).trimmingCharacters(in: .whitespaces),
                       "We saw Mr. Smith last night.")
    }

    func testSentenceNeverEscapesItsParagraph() {
        let text = "A sentence with no final period\n\nAnother paragraph." as NSString
        let range = WritingModes.sentenceRange(in: text, containing: 5)
        XCTAssertLessThanOrEqual(range.upperBound, 32)
    }

    // MARK: - Statistics

    func testMarkdownSyntaxIsNotCountedAsWords() {
        // The `#` of a heading and the `**` of a bold word are not words.
        // Counting the source would give a total that inflates with every
        // bit of formatting.
        let source = "# Heading\n\nA word **important** here.\n"
        let stats = WritingModes.statistics(of: source, spans: MarkdownParser.parse(source).spans)
        XCTAssertEqual(stats.words, 5, "\"Heading A word important here\"")
    }

    func testLinkURLsAreNotCountedButLabelsAre() {
        let source = "See [the official site](https://example.com/a/long/page) here.\n"
        let stats = WritingModes.statistics(of: source, spans: MarkdownParser.parse(source).spans)
        XCTAssertEqual(stats.words, 5, "\"See the official site here\"")
    }

    func testReadingTimeIsNeverZeroForNonEmptyText() {
        let short = WritingModes.statistics(of: "Three little words.", spans: [])
        XCTAssertEqual(short.readingMinutes, 1)

        let empty = WritingModes.statistics(of: "", spans: [])
        XCTAssertEqual(empty.readingMinutes, 0)
        XCTAssertEqual(empty.words, 0)
    }

    // Accented text: exercises word counting on accented and CJK content.
    func testAccentedWordsAreCountedAsOne() {
        let stats = WritingModes.statistics(of: "Café naïve résumé façade 日本語", spans: [])
        XCTAssertEqual(stats.words, 5)
    }

    // MARK: - Selection statistics
    //
    // This is where the app used to crash. The status bar counts the
    // selection, so the editor maps constructs to the fragment's
    // coordinates by shifting them by `-selection.location`: a construct
    // that starts before the selection ends up at a negative position. The
    // original bound, `max(0, start)..<min(units, end)`, then inverted into
    // `0..<-3`, which Swift treats as a fatal error. Selecting two
    // paragraphs was enough to trigger it, and the crash hit while
    // dragging the mouse.

    /// Reproduces exactly what `EditorController.statistics` does.
    private func statisticsOfSelection(_ selection: NSRange, in source: String) -> WritingModes.Statistics {
        let spans = MarkdownParser.parse(source).spans
        let fragment = (source as NSString).substring(with: selection)
        let local = spans
            .filter { NSIntersectionRange($0.range, selection).length > 0 }
            .map { $0.shifted(by: -selection.location) }
        return WritingModes.statistics(of: fragment, spans: local)
    }

    func testASelectionStartingInsideABoldWordDoesNotCrash() {
        // "A word **crucial** here": the selection begins inside the bold
        // word, after the opening `**`, so that marker ends up at a
        // negative position.
        let source = "A word **crucial** here, and the rest of the paragraph continues.\n"
        let stats = statisticsOfSelection(NSRange(location: 11, length: 20), in: source)
        XCTAssertGreaterThan(stats.words, 0)
    }

    func testASelectionEndingInsideAConstructDoesNotCrash() {
        // The symmetric case: the closing `**` overflows past the end of
        // the fragment.
        let source = "A [link](https://example.com) and some **bold** text over there.\n"
        let stats = statisticsOfSelection(NSRange(location: 0, length: 44), in: source)
        XCTAssertGreaterThan(stats.words, 0)
    }

    /// The real user gesture: dragging from one block to another. Every
    /// intermediate position triggers a computation, so each one must hold.
    func testEveryPossibleSelectionOfARealDocumentIsSafe() {
        let source = """
        # Heading

        A word **important**, some *italic*, some `code` and a
        [link](https://example.com/page) in the sentence.

        - A list item
        - [x] A finished task

        > A quote that spans
        > two whole lines.
        """
        let length = (source as NSString).length
        for start in stride(from: 0, to: length, by: 3) {
            for end in stride(from: start + 1, through: length, by: 7) {
                let stats = statisticsOfSelection(NSRange(location: start, length: end - start), in: source)
                XCTAssertGreaterThanOrEqual(stats.characters, 0)
            }
        }
    }

    /// **The veil is drawn in the same coordinate space as the text.**
    ///
    /// `NSTextView` is flipped; an ordinary `NSView` is not. As long as the
    /// veil wasn't flipped too, the active unit's bounds (computed by
    /// layout, hence in top-down coordinates) were drawn in a bottom-up
    /// coordinate space: the clear band was the vertical mirror of the
    /// correct one, landed on a different paragraph, and its edges cut
    /// straight through the middle of lines. Measured on the heading of
    /// "1 — Article": clear up to pixel 345, veiled from 346 to 366, right
    /// in the middle of the letters.
    @MainActor
    func testTheFocusVeilUsesTheSameCoordinatesAsTheText() {
        let controller = EditorController(typography: .default)
        controller.textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.setText("A sentence. Another one.\n")
        controller.textView.focusRange = NSRange(location: 0, length: 11)

        let veil = controller.textView.subviews.first { String(describing: type(of: $0)).contains("FocusOverlay") }
        XCTAssertNotNil(veil, "the veil must be a subview")
        XCTAssertTrue(veil?.isFlipped ?? false,
                      "the veil must be flipped just like the text view it covers")
        XCTAssertTrue(controller.textView.isFlipped, "the text view is flipped")
    }


    // MARK: - What focus mode failed to delimit

    /// The caret **on** a blank line: the unit is that line, not the two
    /// paragraphs surrounding it.
    ///
    /// The two loops started from each side and kept both the one above
    /// **and** the one below at full intensity: that is, the state right
    /// after every `⏎ ⏎`.
    func testABlankLineIsItsOwnUnit() {
        let text = "First paragraph.\n\nSecond paragraph.\n" as NSString
        let blank = text.range(of: "\n\n").location + 1
        let unit = WritingModes.paragraphRange(in: text, containing: blank)

        XCTAssertFalse(text.substring(with: unit).contains("First"))
        XCTAssertFalse(text.substring(with: unit).contains("Second"))
    }

    /// Each list item is its own block.
    ///
    /// A markdown list has no blank line between its items: it used to be
    /// treated as a single paragraph, and since an item almost never has
    /// strong punctuation, the "sentence" unit fell back to the whole
    /// thing. Ten items, focus mode on, caret in the middle: **no dimming
    /// at all**.
    func testEachListItemIsItsOwnUnit() {
        let text = "- first\n- second\n- third\n" as NSString
        let caret = text.range(of: "second").location
        let unit = WritingModes.paragraphRange(in: text, containing: caret)

        XCTAssertEqual(text.substring(with: unit).trimmingCharacters(in: .newlines), "- second")
    }

    /// A heading doesn't blend into the paragraph that follows it.
    func testAHeadingIsItsOwnUnit() {
        let text = "# The heading\nThe paragraph that follows.\n" as NSString
        let heading = WritingModes.paragraphRange(in: text, containing: 3)
        XCTAssertEqual(text.substring(with: heading).trimmingCharacters(in: .newlines), "# The heading")

        let caret = text.range(of: "paragraph").location
        let body = WritingModes.paragraphRange(in: text, containing: caret)
        XCTAssertFalse(text.substring(with: body).contains("heading"))
    }

    /// What doesn't open a block doesn't become a boundary either: a
    /// hyphen stuck to a word, a hash with no space, a number with no
    /// delimiter.
    func testWhatDoesNotStartABlock() {
        let text = "-stuck\n#nospacehere\n2024 is not a year\n" as NSString
        for line in [NSRange(location: 0, length: 6),
                     NSRange(location: 7, length: 12),
                     NSRange(location: 20, length: 18)] {
            XCTAssertFalse(WritingModes.startsBlock(text, line), text.substring(with: line))
        }
    }
}
