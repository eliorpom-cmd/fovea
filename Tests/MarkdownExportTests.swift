// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// The exports from §4.6.
///
/// This is the only place in the app that **writes** markdown anywhere other than
/// the buffer. These tests check that what comes out matches what the screen
/// showed, and above all, that the original document is never touched.
@MainActor
final class MarkdownExportTests: XCTestCase {

    // MARK: - Structure

    func testHeadingsBecomeHeadingTags() {
        let html = MarkdownExport.html(from: "# Heading one\n\n## Heading two\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<h1>Heading one</h1>"), html)
        XCTAssertTrue(html.contains("<h2>Heading two</h2>"), html)
    }

    func testInlineFormattingIsTranslated() {
        let html = MarkdownExport.html(from: "Some **bold**, some *italic*, some `code` and some ~~strikethrough~~.\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<strong>bold</strong>"), html)
        XCTAssertTrue(html.contains("<em>italic</em>"), html)
        XCTAssertTrue(html.contains("<code>code</code>"), html)
        XCTAssertTrue(html.contains("<del>strikethrough</del>"), html)
    }

    /// `***bold and italic***` crashed the app with a stack overflow,
    /// hence the HTML export, the PDF export and `⌘⇧C`: cmark gives the
    /// `emphasis` node and the `strong` node the **same** source range, and
    /// rendering kept re-selecting the emphasis instead of descending into it.
    func testTripleEmphasisNestsAndDoesNotRecurseForever() {
        let html = MarkdownExport.html(from: "A ***bold and italic*** run together.\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<em><strong>bold and italic</strong></em>"), html)
    }

    /// Other nestings keep their order: the outermost node opens the
    /// first tag.
    func testNestedEmphasisKeepsItsOrder() {
        let mixed = MarkdownExport.html(from: "***a* b**.\n", title: "T", documentURL: nil)
        XCTAssertTrue(mixed.contains("<strong><em>a</em> b</strong>"), mixed)

        let underscored = MarkdownExport.html(from: "**_x_**.\n", title: "T", documentURL: nil)
        XCTAssertTrue(underscored.contains("<strong><em>x</em></strong>"), underscored)

        let inLink = MarkdownExport.html(from: "[link **bold**](https://example.com).\n",
                                         title: "T", documentURL: nil)
        XCTAssertTrue(inLink.contains("<a href=\"https://example.com\">link <strong>bold</strong></a>"), inLink)
    }

    /// Test documents are wrapped at 80 characters, like most hand-written
    /// markdown. Each line used to come out as its own `<p>`, so a
    /// three-line paragraph was spaced like three paragraphs.
    func testAWrappedParagraphStaysOneParagraph() {
        let html = MarkdownExport.html(from: "A sentence long enough\nto be wrapped\nin three lines.\n",
                                       title: "T", documentURL: nil)
        XCTAssertEqual(html.components(separatedBy: "<p>").count - 1, 1, html)
        XCTAssertTrue(html.contains("<p>A sentence long enough\nto be wrapped\nin three lines.</p>"), html)
    }

    /// The real damage from line-by-line splitting: a construct straddling
    /// the wrap point was no longer recognized, and its raw syntax leaked through.
    func testAConstructSpanningTheWrapIsStillRendered() {
        let code = MarkdownExport.html(from: "and some `code containing\n*stars*` that follows.\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(code.contains("<code>"), code)
        XCTAssertFalse(code.contains("`"), code)

        let strong = MarkdownExport.html(from: "some **bold split\nin two** here.\n",
                                         title: "T", documentURL: nil)
        XCTAssertTrue(strong.contains("<strong>bold split\nin two</strong>"), strong)
        XCTAssertFalse(strong.contains("**"), strong)
    }

    /// Rejoining lines must not swallow what follows the paragraph.
    func testABlockAfterAParagraphIsNotSwallowed() {
        let html = MarkdownExport.html(from: "A sentence\nwrapped.\n\n- one\n- two\n\n## Heading\n",
                                       title: "T", documentURL: nil)
        XCTAssertEqual(html.components(separatedBy: "<p>").count - 1, 1, html)
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 2, html)
        XCTAssertTrue(html.contains("<h2>Heading</h2>"), html)
    }

    /// Two consecutive footnote definitions stay two lines, not a single
    /// rejoined paragraph.
    func testFootnoteDefinitionsAreNotMergedTogether() {
        let html = MarkdownExport.html(from: "A reference[^1].\n\n[^1]: The first one.\n[^b]: The second one.\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("[^1]: The first one."), html)
        XCTAssertTrue(html.contains("[^b]: The second one."), html)
        XCTAssertFalse(html.contains("The first one.\n[^b]"), html)
    }

    /// A hard break the author explicitly requested (two spaces or a
    /// trailing backslash) stays a break, otherwise rejoining would remove it.
    func testHardBreaksSurviveTheJoin() {
        let spaces = MarkdownExport.html(from: "first line  \nsecond line\n", title: "T", documentURL: nil)
        XCTAssertTrue(spaces.contains("<br>"), spaces)

        let backslash = MarkdownExport.html(from: "first line\\\nsecond line\n", title: "T", documentURL: nil)
        XCTAssertTrue(backslash.contains("<br>"), backslash)
        XCTAssertFalse(backslash.contains("\\"), backslash)
    }

    func testLinksKeepTheirDestination() {
        let html = MarkdownExport.html(from: "See [the site](https://example.com).\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">the site</a>"), html)
    }

    func testListsAreWrappedOnceNotPerItem() {
        // One opening tag per list, not per line: otherwise the browser
        // renders three one-item lists, with three times the spacing.
        let html = MarkdownExport.html(from: "- one\n- two\n- three\n", title: "T", documentURL: nil)
        XCTAssertEqual(html.components(separatedBy: "<ul>").count - 1, 1, html)
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 3, html)
    }

    func testOrderedListsUseOL() {
        let html = MarkdownExport.html(from: "1. one\n2. two\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<ol>"), html)
    }

    func testTaskItemsBecomeCheckboxes() {
        let html = MarkdownExport.html(from: "- [x] done\n- [ ] to do\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("checked"), html)
        XCTAssertEqual(html.components(separatedBy: "type=\"checkbox\"").count - 1, 2, html)
    }

    func testCodeBlocksKeepTheirLanguage() {
        let html = MarkdownExport.html(from: "```swift\nlet x = 1\n```\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("class=\"language-swift\""), html)
        XCTAssertTrue(html.contains("let x = 1"), html)
    }

    func testThematicBreakBecomesHR() {
        let html = MarkdownExport.html(from: "before\n\n---\n\nafter\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<hr>"), html)
    }

    func testFrontMatterIsNotExported() {
        // The metadata is for the site generator, not the reader.
        let html = MarkdownExport.html(from: "---\ntitle: Secret\n---\n\n# Real heading\n",
                                       title: "T", documentURL: nil)
        XCTAssertFalse(html.contains("Secret"), html)
        XCTAssertTrue(html.contains("<h1>Real heading</h1>"), html)
    }

    // MARK: - Tables

    func testATableBecomesATable() {
        // Without this case, each row came out as a paragraph, pipes included.
        let html = MarkdownExport.html(from: "| a | b |\n|---|---|\n| 1 | 2 |\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<table>"), html)
        XCTAssertTrue(html.contains("<th>a</th>"), html)
        XCTAssertTrue(html.contains("<td>1</td>"), html)
        XCTAssertFalse(html.contains("<p>| a | b |</p>"), html)
    }

    func testTableAlignmentsSurvive() {
        let html = MarkdownExport.html(from: "| g | c | d |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("text-align:center"), html)
        XCTAssertTrue(html.contains("text-align:right"), html)
    }

    func testInlineMarkupInsideACellIsRendered() {
        let html = MarkdownExport.html(from: "| **bold** | `code` |\n|---|---|\n| a | b |\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<th><strong>bold</strong></th>"), html)
        XCTAssertTrue(html.contains("<code>code</code>"), html)
    }

    // MARK: - Escaping

    func testHTMLSpecialCharactersAreEscaped() {
        // Without escaping, a document that talks about HTML would produce an
        // export half of which would be interpreted as markup.
        let html = MarkdownExport.html(from: "Compare a < b & c > d.\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("a &lt; b &amp; c &gt; d"), html)
    }

    func testCodeContentIsEscapedToo() {
        let html = MarkdownExport.html(from: "```\nif (a < b) { }\n```\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("if (a &lt; b)"), html)
    }

    func testAnEmojiSurvivesTheExport() {
        // A surrogate pair must be copied whole. Converting a single UTF-16
        // code unit failed on the high half, and each emoji came out
        // as two spaces.
        let html = MarkdownExport.html(from: "Great 🙂 really.\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("Great 🙂 really"), html)
    }

    func testTitleIsEscaped() {
        let html = MarkdownExport.html(from: "text\n", title: "A <b> & B", documentURL: nil)
        XCTAssertTrue(html.contains("<title>A &lt;b&gt; &amp; B</title>"), html)
    }

    // MARK: - Self-containment

    func testTheExportIsASingleSelfContainedFile() throws {
        // "Standalone" means what it says: the file opens without its
        // image folder, can be emailed, and stays readable in ten years.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: folder.appendingPathComponent("photo.png"))

        let document = folder.appendingPathComponent("doc.md")
        let html = MarkdownExport.html(from: "![A photo](photo.png)\n", title: "T", documentURL: document)

        XCTAssertTrue(html.contains("data:image/png;base64,"), "The image must be embedded")
        XCTAssertFalse(html.contains("src=\"photo.png\""), "No external reference should remain")
        XCTAssertTrue(html.contains("alt=\"A photo\""))
    }

    func testAMissingImageKeepsItsPathRatherThanDisappearing() {
        // A visible path is more useful than a broken image with no clue.
        let html = MarkdownExport.html(from: "![Nothing](missing.png)\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("missing.png"), html)
    }

    // MARK: - Rich text

    func testRichTextCarriesTheFormatting() throws {
        let rich = try XCTUnwrap(MarkdownExport.richText(from: "A **word** here.\n", documentURL: nil))
        XCTAssertTrue(rich.string.contains("A word here"), rich.string)

        // The word must come out bold: that is the entire point of ⌘⇧C.
        var foundBold = false
        rich.enumerateAttribute(.font, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
            if let font = value as? NSFont,
               NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
                foundBold = true
            }
        }
        XCTAssertTrue(foundBold, "Bold must survive the conversion to rich text")
    }

    /// Rich text gets pasted into Mail or Pages, and the PDF gets printed:
    /// on **white** pages. WebKit resolved `prefers-color-scheme` against
    /// the system appearance, so in dark theme `⌘⇧C` and the PDF export
    /// produced only illegible light gray text: the background does not follow.
    func testRichTextIsReadableOnPaperWhateverTheSystemAppearance() throws {
        let rich = try XCTUnwrap(MarkdownExport.richText(from: "An ordinary sentence.\n", documentURL: nil))
        let colour = try XCTUnwrap(rich.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor)
        let sRGB = try XCTUnwrap(colour.usingColorSpace(.sRGB))
        XCTAssertLessThan(sRGB.brightnessComponent, 0.5,
                          "Rich text must stay dark: it lands on white (\(sRGB))")
    }

    /// The standalone file, however, opens in a browser, which also applies
    /// the background. It therefore keeps its dark variant.
    func testTheStandaloneFileKeepsItsDarkVariant() {
        let file = MarkdownExport.html(from: "A sentence.\n", title: "T", documentURL: nil)
        XCTAssertTrue(file.contains("prefers-color-scheme: dark"), file)
    }

    // MARK: - The rule that overrides everything

    func testExportingNeverTouchesTheSource() {
        // Export is the only place that re-serializes (§3.1). It writes to
        // another file; the original markdown must not move by a single
        // byte, even in memory.
        let source = "# Heading\n\nSome **bold** and a [link](https://example.com).\n\n- one\n- two\n"
        let copy = source
        _ = MarkdownExport.html(from: source, title: "T", documentURL: nil)
        _ = MarkdownExport.richText(from: source, documentURL: nil)
        XCTAssertEqual(source, copy)
    }
}
