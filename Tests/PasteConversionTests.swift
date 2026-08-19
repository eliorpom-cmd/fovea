// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Rich text paste (§2.5).
///
/// Pasting from a browser is one of the most frequent actions in a notes
/// editor. Losing links and bold text in the process would be just as
/// visible as broken rendering.
@MainActor
final class PasteConversionTests: XCTestCase {

    // MARK: - Markdown recognition

    func testStructuredMarkdownIsRecognizedAndLeftAlone() {
        // Converting it from its HTML version would send it round-trip and
        // replace `_` with `*`, which §5 forbids.
        XCTAssertTrue(PasteConversion.looksLikeMarkdown("# A heading\n\nSome text."))
        XCTAssertTrue(PasteConversion.looksLikeMarkdown("- an item\n- another one"))
        XCTAssertTrue(PasteConversion.looksLikeMarkdown("Some **bold** in a sentence."))
        XCTAssertTrue(PasteConversion.looksLikeMarkdown("See [the site](https://example.com)."))
        XCTAssertTrue(PasteConversion.looksLikeMarkdown("```swift\nlet x = 1\n```"))
    }

    func testOrdinaryProseIsNotMistakenForMarkdown() {
        // The benefit of the doubt goes to plain text, which carries no risk.
        XCTAssertFalse(PasteConversion.looksLikeMarkdown("An ordinary sentence, with nothing special."))
        XCTAssertFalse(PasteConversion.looksLikeMarkdown("2 * 3 * 4 = 24"))
        XCTAssertFalse(PasteConversion.looksLikeMarkdown("#nospace is not a heading"))
    }

    // MARK: - Attribute conversion

    func testBoldBecomesStars() {
        let rich = NSMutableAttributedString(string: "an egg here")
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 3, length: 3))
        XCTAssertEqual(PasteConversion.convert(rich), "an **egg** here")
    }

    func testItalicBecomesOneStar() {
        let rich = NSMutableAttributedString(string: "an egg here")
        let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
        rich.addAttribute(.font, value: italic, range: NSRange(location: 3, length: 3))
        XCTAssertEqual(PasteConversion.convert(rich), "an *egg* here")
    }

    func testLinksKeepTheirDestination() {
        let rich = NSMutableAttributedString(string: "see the site here")
        rich.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 4, length: 8))
        XCTAssertEqual(PasteConversion.convert(rich), "see [the site](https://example.com) here")
    }

    func testMonospacedTextBecomesInlineCode() {
        let rich = NSMutableAttributedString(string: "call foo() here")
        rich.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                          range: NSRange(location: 5, length: 5))
        XCTAssertEqual(PasteConversion.convert(rich), "call `foo()` here")
    }

    func testWhitespaceStaysOutsideTheMarkers() {
        // `** bold **` is not bold to cmark: the whitespace must stay
        // outside, or the paste produces literal stars.
        let rich = NSMutableAttributedString(string: "an egg here")
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 2, length: 5))
        // `an **egg** here` does contain the sequence `**` followed by a
        // space: what matters is that no whitespace is **inside** the pair,
        // that is, right after the opening marker or right before the
        // closing one.
        let result = PasteConversion.convert(rich)
        XCTAssertEqual(result, "an **egg** here")
        XCTAssertFalse(result.contains("** e"), "Whitespace after the opening marker: \(result)")
        XCTAssertFalse(result.contains("g **"), "Whitespace before the closing marker: \(result)")
    }

    func testMarkdownCharactersAreEscaped() {
        // Pasting "2 * 3 * 4" from a web page must not produce italics
        // where there was only a multiplication.
        let rich = NSAttributedString(string: "2 * 3 * 4")
        XCTAssertEqual(PasteConversion.convert(rich), "2 \\* 3 \\* 4")
    }

    func testCodeIsNotEscaped() {
        // What is between backticks is literal: adding backslashes to it
        // would change the pasted code.
        let rich = NSMutableAttributedString(string: "arr[0] * 2")
        rich.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                          range: NSRange(location: 0, length: 10))
        XCTAssertEqual(PasteConversion.convert(rich), "`arr[0] * 2`")
    }

    // MARK: - From real HTML

    func testRealHTMLFromABrowser() throws {
        let html = """
        <p>A paragraph with <b>bold</b>, <i>italic</i> \
        and a <a href="https://example.com">link</a>.</p>
        """
        let rich = try XCTUnwrap(NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil))

        let markdown = PasteConversion.convert(rich)
        XCTAssertTrue(markdown.contains("**bold**"), markdown)
        XCTAssertTrue(markdown.contains("*italic*"), markdown)
        // The HTML importer for `NSAttributedString` normalizes the URL and
        // appends a trailing slash. That is its prerogative, and the link
        // stays correct.
        XCTAssertTrue(markdown.contains("](https://example.com"), markdown)
    }

    func testTheResultIsValidMarkdownThatParsesBack() throws {
        // The real criterion: what is pasted must read back. A paste that
        // produces markdown the parser does not recognize is worse than a
        // plain-text paste.
        let rich = NSMutableAttributedString(string: "an egg and a link")
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 3, length: 3))
        rich.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 13, length: 4))

        let markdown = PasteConversion.convert(rich)
        let spans = MarkdownParser.parse(markdown).spans
        XCTAssertTrue(spans.contains { if case .strong = $0.kind { return true } else { return false } },
                      "Pasted bold text must read back: \(markdown)")
        XCTAssertTrue(spans.contains { if case .link = $0.kind { return true } else { return false } },
                      "A pasted link must read back: \(markdown)")
    }

    // MARK: - Block structure

    /// An attributed string from real HTML, as the pasteboard delivers it
    /// when copying a web page.
    private func fromHTML(_ html: String) throws -> NSAttributedString {
        try XCTUnwrap(NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil))
    }

    /// **Headings and lists survive a paste.**
    ///
    /// `PasteConversion`'s header promises not to lose "headings, lists and
    /// links". Links made it through; the other two did not: only the
    /// inline content was handled, and a pasted article arrived as a series
    /// of flat paragraphs. That is exactly the loss the conversion exists
    /// to avoid.
    func testHeadingsAndListsSurviveAPaste() throws {
        let html = """
        <h1>The big heading</h1>
        <p>A paragraph with <strong>bold</strong> and a <a href="https://example.com">link</a>.</p>
        <h2>A subheading</h2>
        <ul><li>First item</li><li>Second with <em>emphasis</em></li></ul>
        <ol><li>One</li><li>Two</li></ol>
        """
        let converted = PasteConversion.convert(try fromHTML(html))

        XCTAssertTrue(converted.contains("# The big heading"), converted)
        XCTAssertTrue(converted.contains("## A subheading"), converted)
        XCTAssertTrue(converted.contains("- First item"), converted)
        XCTAssertTrue(converted.contains("- Second with *emphasis*"), converted)
        XCTAssertTrue(converted.contains("1. One"), converted)
        XCTAssertTrue(converted.contains("**bold**"), converted)

        // A heading is already bold: `# **The heading**` would say the same
        // thing twice, and leave stars in the file.
        XCTAssertFalse(converted.contains("# **"), converted)
        // The bullet the importer writes into the text must not double up
        // with markdown's own.
        XCTAssertFalse(converted.contains("- •"), converted)
        XCTAssertFalse(converted.contains("1. 1"), converted)
    }

    func testNestedListsKeepTheirDepth() throws {
        let html = "<ul><li>One<ul><li>One-one</li></ul></li><li>Two</li></ul>"
        let converted = PasteConversion.convert(try fromHTML(html))
        XCTAssertTrue(converted.contains("\n  - One-one"), converted)
    }

    /// The flip side: prose stays prose. An ordinary paragraph must gain
    /// neither a hash nor a dash.
    func testPlainProseGainsNoStructure() throws {
        let html = "<p>An ordinary sentence, with no particular structure.</p>"
        XCTAssertEqual(PasteConversion.convert(try fromHTML(html)),
                       "An ordinary sentence, with no particular structure.")
    }

    // MARK: - The blocks that pasting used to lose

    /// A pasted blockquote used to become an ordinary paragraph: nothing
    /// indicated it had been one. The HTML importer has no attribute for
    /// `<blockquote>`: what it sets is an indent.
    func testABlockquoteKeepsItsMarker() throws {
        let html = "<p>Before.</p><blockquote>A quote.</blockquote><p>After.</p>"
        let rich = try XCTUnwrap(NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil))
        let markdown = PasteConversion.convert(rich)
        XCTAssertTrue(markdown.contains("> A quote."), markdown)
    }

    /// A multi-line `<pre>` used to arrive on a single line, wrapped in
    /// single backticks: the block lost its line breaks and its fence.
    func testAPreBecomesAFencedBlock() throws {
        let html = "<pre><code>let x = 1\nlet y = 2\nprint(x + y)</code></pre>"
        let rich = try XCTUnwrap(NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil))
        let markdown = PasteConversion.convert(rich)
        XCTAssertTrue(markdown.hasPrefix("```"), markdown)
        XCTAssertTrue(markdown.hasSuffix("```"), markdown)
        XCTAssertTrue(markdown.contains("let x = 1"), markdown)
        XCTAssertTrue(markdown.contains("print(x + y)"), markdown)
        // The lines of the block must not be wrapped one by one.
        XCTAssertFalse(markdown.contains("`let x = 1`"), markdown)
    }

    /// But a code word in the middle of a sentence also arrives in a
    /// monospaced font: a single line must stay inline code, not a block.
    func testASingleMonospacedLineStaysInline() {
        let rich = NSMutableAttributedString(string: "arr[0] * 2")
        rich.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                          range: NSRange(location: 0, length: 10))
        XCTAssertEqual(PasteConversion.convert(rich), "`arr[0] * 2`")
    }

}
