// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// The document outline (§4.5).
///
/// It's a list of headings, so text read over someone's shoulder: it must
/// read like the document, not like its source.
@MainActor
final class OutlinePanelTests: XCTestCase {

    private func title(of source: String) -> String {
        let spans = MarkdownParser.parse(source).spans
        let heading = spans.first { if case .heading = $0.kind { return true } else { return false } }
        guard let heading else { return "" }
        return OutlinePanel.plainText(of: heading.content, spans: spans, text: source as NSString)
    }

    /// The outline used to show the source: a heading's `**` read verbatim
    /// there, the one place in the app that let them show — and in a narrow
    /// panel, they eat into the space of the text being searched for.
    func testAHeadingLosesItsInlineMarkers() {
        XCTAssertEqual(title(of: "## 2. Tasks — see **2 — Meeting Notes**\n"),
                       "2. Tasks — see 2 — Meeting Notes")
        XCTAssertEqual(title(of: "### Tables — see **3 — Docs** or **6 — Tables**\n"),
                       "Tables — see 3 — Docs or 6 — Tables")
        XCTAssertEqual(title(of: "# Some *italic* and some `code`\n"), "Some italic and some code")
    }

    /// A link keeps only its label, not its address: that's what's read on
    /// screen.
    func testALinkKeepsOnlyItsLabel() {
        XCTAssertEqual(title(of: "## See [the guide](https://example.com) here\n"),
                       "See the guide here")
    }

    /// A heading with nothing to strip must not be damaged along the way.
    func testAPlainHeadingIsUntouched() {
        XCTAssertEqual(title(of: "# What there is to test\n"), "What there is to test")
        XCTAssertEqual(title(of: "## 4. Links\n"), "4. Links")
    }

    /// The marker list, pulled out of the function so it's computed only
    /// once per document, must produce **exactly** the same text.
    ///
    /// That's the whole point of the optimization: the outline rebuilds on
    /// every keystroke, and refiltering every construct by heading was
    /// quadratic. A heading near the bottom of a long document now goes
    /// through a binary search; if it came out one word short, it would
    /// show up here.
    func testThePrecomputedMarkersGiveTheSameTitles() {
        let source = """
        # A *first* heading

        Some text with **bold** and a [link](https://example.com) in the middle.

        ## The **second**, further down

        More text, some `code` and some *italics* to interleave.

        ### A `third` one at the bottom
        """
        let text = source as NSString
        let spans = MarkdownParser.parse(source).spans
        let markers = OutlinePanel.inlineMarkers(of: spans)

        let headings = spans.filter { if case .heading = $0.kind { return true } else { return false } }
        XCTAssertEqual(headings.count, 3)
        for heading in headings {
            XCTAssertEqual(OutlinePanel.plainText(of: heading.content, markers: markers, text: text),
                           OutlinePanel.plainTextByScan(of: heading.content, spans: spans, text: text))
        }
    }
}
