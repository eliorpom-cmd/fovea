// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import XCTest
@testable import Fovea

/// The parser only produces positions. These tests verify that they
/// designate **exactly** the syntax characters, and nothing else: a marker
/// too wide would eat a letter of the author's text, a marker too narrow
/// would leave an orphaned star on screen.
final class MarkdownParserTests: XCTestCase {

    // MARK: - Inline

    func testStrongMarkersAreTheStarsAndOnlyTheStars() throws {
        let span = try firstSpan(in: "A word **important** here") { if case .strong = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.range, NSRange(location: 7, length: 13))
        XCTAssertEqual(span.markers, [NSRange(location: 7, length: 2), NSRange(location: 18, length: 2)])
        XCTAssertEqual(span.content, NSRange(location: 9, length: 9))
    }

    func testEmphasisKeepsTheAuthorsMarkerCharacter() throws {
        // `_text_` and `*text*` mean the same thing. The rendering is
        // identical, but the revealed marker must be the one written
        // in the file: otherwise the reveal would misrepresent the content.
        let underscore = try firstSpan(in: "an _egg_ here") { if case .emphasis = $0.kind { return true } else { return false } }
        XCTAssertEqual(underscore.markers, [NSRange(location: 3, length: 1), NSRange(location: 7, length: 1)])
    }

    func testInlineCodeCountsItsBackticks() throws {
        // Inline code can be delimited by several backticks when it contains
        // backticks itself: ``a `b` c``.
        let single = try firstSpan(in: "an `code` here") { if case .inlineCode = $0.kind { return true } else { return false } }
        XCTAssertEqual(single.content, NSRange(location: 4, length: 4))

        let double = try firstSpan(in: "an ``a `b` c`` here") { if case .inlineCode = $0.kind { return true } else { return false } }
        XCTAssertEqual(double.markers.first, NSRange(location: 3, length: 2))
        XCTAssertEqual(double.content, NSRange(location: 5, length: 7))
    }

    func testLinkSplitsBracketsFromDestination() throws {
        let span = try firstSpan(in: "see [the site](https://example.com) here") { if case .link = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.content, NSRange(location: 5, length: 8), "Only \"the site\" is content")
        XCTAssertEqual(span.markers, [NSRange(location: 4, length: 1), NSRange(location: 13, length: 22)])
    }

    // MARK: - Blocks

    func testHeadingMarkerIncludesTheTrailingSpace() throws {
        // `## ` and not `##`: leaving the space visible would shift the heading
        // by one character relative to the rest of the text.
        let span = try firstSpan(in: "## Heading text") { if case .heading = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers, [NSRange(location: 0, length: 3)])
        XCTAssertEqual(span.content, NSRange(location: 3, length: 12))
    }

    func testListItemProducesAMarkerAndABullet() throws {
        let spans = MarkdownParser.parse("- one\n- two\n").spans
        let items = spans.filter { if case .listItem = $0.kind { return true } else { return false } }
        XCTAssertEqual(items.count, 2, "Each item carries its own marker")
        XCTAssertEqual(items[0].markers, [NSRange(location: 0, length: 2)])
        XCTAssertEqual(items[1].markers, [NSRange(location: 6, length: 2)])
    }

    func testOrderedListKeepsTheAuthorsNumbering() throws {
        // A document where the author wrote `1.` on every line must read
        // exactly as written: the editor does not renumber items for display.
        let spans = MarkdownParser.parse("1. one\n1. two\n").spans
        let items = spans.compactMap { span -> SyntaxSpan.ListMarker? in
            if case .listItem(let marker) = span.kind { return marker } else { return nil }
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0], .ordered(number: 1, delimiter: "."))
        XCTAssertEqual(items[1], .ordered(number: 1, delimiter: "."))
    }

    func testTaskItemMarkerCoversTheWholeCheckbox() throws {
        let span = try firstSpan(in: "- [x] done") { if case .taskItem = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers, [NSRange(location: 0, length: 6)], "`- [x]` as a single unit")
        if case .taskItem(_, let checked) = span.kind {
            XCTAssertTrue(checked)
        } else {
            XCTFail("Expected a task")
        }
    }

    func testBlockQuoteMarksEveryLine() throws {
        // The `>` repeats: a single marker at the top of the block would leave
        // the chevrons of the following lines visible.
        let span = try firstSpan(in: "> one\n> two\n") { if case .blockQuote = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers.count, 2)
        XCTAssertEqual(span.markers[0], NSRange(location: 0, length: 2))
        XCTAssertEqual(span.markers[1], NSRange(location: 6, length: 2))
    }

    func testFencedCodeBlockMarksBothFences() throws {
        let span = try firstSpan(in: "```swift\nlet x = 1\n```\n") { if case .codeBlock = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers.count, 2, "The opening fence with its language, and the closing fence")
        XCTAssertEqual(span.markers[0], NSRange(location: 0, length: 8))
        if case .codeBlock(let language) = span.kind {
            XCTAssertEqual(language, "swift")
        }
    }

    func testThematicBreakIsEntirelyAMarker() throws {
        let span = try firstSpan(in: "before\n\n---\n\nafter") { if case .thematicBreak = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers, [span.range], "None of the line is content")
        XCTAssertEqual(span.content.length, 0)
    }

    // MARK: - Front matter

    func testFrontMatterIsRecognizedAndSwallowsTheDelimiters() throws {
        let source = "---\ntitle: Demo\n---\n\n# Title\n"
        let span = try firstSpan(in: source) { if case .frontMatter = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.range.location, 0)
        XCTAssertEqual(span.markers.count, 2)
    }

    /// The bug found on screen: `cmark` ignores the front matter and reads its
    /// closing `---` as the underline of a `setext` heading. Without a filter,
    /// `title: Demo` would display as a large heading above the document.
    func testFrontMatterIsNotParsedAsASetextHeading() throws {
        let spans = MarkdownParser.parse("---\ntitle: Demo\ndate: 2026-08-07\n---\n\n# Real heading\n").spans
        let headings = spans.filter { if case .heading = $0.kind { return true } else { return false } }
        XCTAssertEqual(headings.count, 1, "Only one heading: the one in the body")
        XCTAssertGreaterThan(headings[0].range.location, 36)
    }

    func testAThematicBreakLowerInTheDocumentIsNotFrontMatter() throws {
        // The block must start on the very first line. A `---` further down
        // is a horizontal rule, and confusing the two would split the rendering in two.
        let spans = MarkdownParser.parse("Some text\n\n---\n\nMore content\n").spans
        XCTAssertFalse(spans.contains { if case .frontMatter = $0.kind { return true } else { return false } })
        XCTAssertTrue(spans.contains { if case .thematicBreak = $0.kind { return true } else { return false } })
    }

    // MARK: - Footnotes

    func testFootnoteReferencesAreFoundByTheHomeMadePass() throws {
        // `swift-markdown` does not parse them: `[^1]` comes out as plain
        // text. The fallback described in §4.1 is what finds them.
        let span = try firstSpan(in: "A reference[^1] here") {
            if case .footnoteReference = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(span.range, NSRange(location: 11, length: 4))
        // The brackets are the syntax, the identifier is the content: hiding
        // everything would make the reference disappear from the screen.
        XCTAssertEqual(span.markers, [NSRange(location: 11, length: 2), NSRange(location: 14, length: 1)])
        XCTAssertEqual(span.content, NSRange(location: 13, length: 1))
        if case .footnoteReference(let identifier) = span.kind {
            XCTAssertEqual(identifier, "1")
        }
    }

    func testFootnoteDefinitionIsItsOwnConstruct() throws {
        // `[^1]: the note` at the start of a line is the **definition**, not a
        // reference. Applying reference rendering to it would hide the brackets
        // and leave only an incomprehensible `: the note`; that is what
        // displayed on the first attempt.
        let spans = MarkdownParser.parse("A reference[^1]\n\n[^1]: the note\n").spans
        let references = spans.filter { if case .footnoteReference = $0.kind { return true } else { return false } }
        XCTAssertEqual(references.count, 1, "Only one reference")
        XCTAssertEqual(references[0].range.location, 11)

        let definition = try XCTUnwrap(spans.first {
            if case .footnoteDefinition = $0.kind { return true } else { return false }
        })
        // The marker covers `[^` then `]:`: what remains visible is the
        // identifier, as a superscript, and the text of the note.
        XCTAssertEqual(definition.markers, [NSRange(location: 17, length: 2),
                                            NSRange(location: 20, length: 2)])
        // The space after the `:` remains visible: it is what separates the
        // superscript from the first word of the note.
        XCTAssertEqual(definition.content, NSRange(location: 22, length: 9))
        // Revealed at the line level, like a heading: placing the caret on it
        // makes the syntax visible, and therefore editable.
        XCTAssertEqual(definition.kind.revealScope, .wholeLine)
    }

    func testAFootnoteDefinitionStopsAtItsLine() throws {
        // Without this boundary, the definition would swallow the following paragraph.
        let spans = MarkdownParser.parse("[^a]: the note\nAnother line\n").spans
        let definition = try XCTUnwrap(spans.first {
            if case .footnoteDefinition = $0.kind { return true } else { return false }
        })
        XCTAssertEqual(definition.range, NSRange(location: 0, length: 14))
    }

    func testFootnotePatternIsIgnoredInsideCode() throws {
        // Without this guard, a `[^1]` inside a code block would become a
        // reference, and disappear from the screen since everything in it is a marker.
        let spans = MarkdownParser.parse("```\nregex = \"[^1]\"\n```\n").spans
        XCTAssertFalse(spans.contains { if case .footnoteReference = $0.kind { return true } else { return false } })
    }

    // MARK: - What must never be swallowed

    func testRawHTMLIsNeverTurnedIntoAMarker() throws {
        // §6: an element that isn't understood is never hidden. Hiding text
        // that could not be parsed would make it disappear.
        let spans = MarkdownParser.parse("an <b>bold</b> html\n").spans
        for span in spans {
            for marker in span.markers {
                XCTAssertFalse(NSLocationInRange(3, marker), "The `<` of `<b>` must never be hidden")
            }
        }
    }

    func testAccentsDoNotShiftMarkerPositions() throws {
        // The intersection of the two pitfalls from §3.3 and §2: if the range
        // conversion were wrong, accented letters would become invisible.
        // Accented text: exercises the UTF-8 → UTF-16 offset conversion.
        let span = try firstSpan(in: "Zoë **crucial** here") { if case .strong = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers, [NSRange(location: 4, length: 2), NSRange(location: 13, length: 2)])
        XCTAssertEqual(span.content, NSRange(location: 6, length: 7))
    }

    // MARK: - Utilities

    private func firstSpan(in source: String,
                           where predicate: (SyntaxSpan) -> Bool,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> SyntaxSpan {
        let spans = MarkdownParser.parse(source).spans
        return try XCTUnwrap(spans.first(where: predicate),
                             "No matching construct in \(source.debugDescription)",
                             file: file, line: line)
    }
}
