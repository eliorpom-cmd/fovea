// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Links, in every form a README writes them (§2.4).
///
/// An alpha tester reported that the app "doesn't seem to allow links
/// formatting". It did — for the one form they had not used. A README's links
/// are relative paths, anchors and bare addresses, and those three were
/// exactly the ones that led nowhere.
@MainActor
final class LinkTests: XCTestCase {

    /// The text of every link found, with the address it carries.
    private func links(in source: String) -> [(text: String, destination: String)] {
        let text = source as NSString
        return MarkdownParser.parse(source).spans.compactMap { span in
            guard case .link(let destination) = span.kind else { return nil }
            return (text.substring(with: span.range), destination)
        }
    }

    // MARK: - Bare addresses

    func testABareAddressIsALink() {
        let found = links(in: "See https://example.com for the rest.")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.text, "https://example.com")
    }

    /// The full stop belongs to the sentence, not to the address.
    func testTrailingPunctuationIsGivenBack() {
        for source in ["Read https://example.com.",
                       "Read https://example.com,",
                       "Read (https://example.com)",
                       "Read https://example.com!"] {
            XCTAssertEqual(links(in: source).first?.text, "https://example.com", source)
        }
    }

    /// A parenthesis the address itself opened is part of it.
    func testAParenthesisTheAddressOpenedIsKept() {
        let source = "https://en.wikipedia.org/wiki/Fovea_(anatomy)"
        XCTAssertEqual(links(in: source).first?.text, source)
    }

    func testWwwIsAnAddressToo() {
        XCTAssertEqual(links(in: "Go to www.example.com now.").first?.text, "www.example.com")
    }

    func testASchemeWithNoHostIsNotAnAddress() {
        XCTAssertTrue(links(in: "The https:// scheme, and www. as a prefix.").isEmpty)
    }

    // MARK: - What must not be found twice

    func testAnAddressInsideAMarkdownLinkIsFoundOnce() {
        let found = links(in: "[the site](https://example.com)")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.destination, "https://example.com")
    }

    func testAnAngleBracketAutolinkIsFoundOnce() {
        XCTAssertEqual(links(in: "<https://example.com>").count, 1)
    }

    func testAnAddressInCodeIsNotALink() {
        XCTAssertTrue(links(in: "Type `https://example.com` in the bar.").isEmpty)
        XCTAssertTrue(links(in: "```\ncurl https://example.com\n```").isEmpty)
    }

    func testAnImageSourceIsNotALinkOfItsOwn() {
        XCTAssertTrue(links(in: "![a badge](https://example.com/badge.svg)").isEmpty)
    }

    // MARK: - Where a link leads

    func testAnAbsoluteAddressOpens() {
        XCTAssertEqual(MarkdownRenderer.openableURL("https://example.com")?.scheme, "https")
        XCTAssertEqual(MarkdownRenderer.openableURL("mailto:a@example.com")?.scheme, "mailto")
        XCTAssertEqual(MarkdownRenderer.openableURL("www.example.com")?.scheme, "https")
    }

    /// **The most common link in the most common markdown file.**
    ///
    /// `[the licence](LICENSE)` in a README leads to the file sitting next to
    /// it. Only a scheme used to be accepted, so this one silently did
    /// nothing at all.
    func testARelativePathLeadsToTheFileNextToTheDocument() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let document = folder.appendingPathComponent("README.md")
        try "# Title".write(to: document, atomically: true, encoding: .utf8)
        let neighbour = folder.appendingPathComponent("LICENSE")
        try "GPL".write(to: neighbour, atomically: true, encoding: .utf8)

        let resolved = MarkdownRenderer.openableURL("LICENSE", relativeTo: document)
        XCTAssertEqual(resolved?.standardizedFileURL, neighbour.standardizedFileURL)

        // A path that leads nowhere is not a link: no hand cursor, and
        // `⌘`-click opens no error in the reader's face.
        XCTAssertNil(MarkdownRenderer.openableURL("MISSING.md", relativeTo: document))
        // And with no document on disk yet, there is nothing to resolve
        // against.
        XCTAssertNil(MarkdownRenderer.openableURL("LICENSE"))
    }

    /// An anchor has no URL: it is the editor that goes there.
    func testAnAnchorIsNotHandedToTheSystem() {
        XCTAssertNil(MarkdownRenderer.openableURL("#a-heading"))
    }

    func testAnUnknownSchemeIsRefused() {
        XCTAssertNil(MarkdownRenderer.openableURL("javascript:alert(1)"))
        XCTAssertNil(MarkdownRenderer.openableURL("ftp://example.com"))
    }

    /// The slug is GitHub's, so an anchor copied from a rendered README lands
    /// in the same place here.
    func testTheAnchorSlugIsGitHubs() {
        XCTAssertEqual(EditorController.anchorSlug("Second heading"), "second-heading")
        XCTAssertEqual(EditorController.anchorSlug("**Bold** title!"), "bold-title")
        XCTAssertEqual(EditorController.anchorSlug("Étape 1 : c'est parti"), "étape-1--cest-parti")
    }
}
