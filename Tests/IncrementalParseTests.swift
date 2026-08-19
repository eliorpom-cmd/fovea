// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
@testable import Fovea

/// Incremental parsing exists for speed. It's worthless unless it produces
/// **exactly** the same result as a full parse: an editor that renders
/// correctly at rest but wrong while typing is worse than a slow editor.
///
/// These tests are therefore written as a property: for any given edit,
/// `incremental == full`.
final class IncrementalParseTests: XCTestCase {

    // MARK: - The property

    func testIncrementalMatchesFullParseOnOrdinaryEdits() {
        let base = """
        # Heading

        A paragraph with **bold** and *italic*.

        - one item
        - another

        > a quote

        One last paragraph.
        """
        // An insertion in each block, to cover each scoping case.
        for insertionPoint in [10, 30, 60, 78, 95] where insertionPoint < base.utf16.count {
            assertIncrementalMatchesFull(base: base, insert: "text ", at: insertionPoint)
        }
    }

    func testIncrementalMatchesFullParseWithAccents() {
        // The intersection of two risks: block splitting and UTF-8 -> UTF-16
        // range conversion. Accented text: exercises the offset conversion
        // on purpose.
        let base = "Café **crucial**.\n\nDéjà vu: café, naïve, résumé.\n\n- An accented café item\n"
        for insertionPoint in stride(from: 0, to: base.utf16.count, by: 5) {
            assertIncrementalMatchesFull(base: base, insert: "é", at: insertionPoint)
        }
    }

    // MARK: - Cases where splitting isn't enough

    func testTypingAFenceForcesAFullReparse() {
        // Typing ``` changes the interpretation of **everything that
        // follows**: the rest of the document becomes code, or stops being
        // code. This is the §6 case, and the only one block splitting
        // cannot see.
        let text = "One paragraph.\n\n```\n" as NSString
        let scope = IncrementalParse.scope(in: text,
                                           editedRange: NSRange(location: 16, length: 3),
                                           inserted: "```",
                                           existingCodeBlocks: [])
        XCTAssertNil(scope, "A code block fence must force a full re-parse")
    }

    func testEditingInsideACodeBlockForcesAFullReparse() {
        // Inside a code block, blank lines no longer delimit anything:
        // block scoping makes no sense.
        let text = "```\nfirst line\n\nsecond line\n```\n" as NSString
        let scope = IncrementalParse.scope(in: text,
                                           editedRange: NSRange(location: 18, length: 1),
                                           inserted: "x",
                                           existingCodeBlocks: [NSRange(location: 0, length: 31)])
        XCTAssertNil(scope)
    }

    func testAnOrdinaryEditStaysLocal() throws {
        // A document long enough for incremental parsing to make sense. On
        // a three-line document, `scope` deliberately returns `nil`:
        // reparsing everything costs less than splitting it, which is
        // exactly what the half rule says.
        let blocks = (1...60).map { "Block number \($0), with some text to give it some body.\n" }
        let text = blocks.joined(separator: "\n") as NSString

        let scope = try XCTUnwrap(IncrementalParse.scope(in: text,
                                                         editedRange: NSRange(location: text.length / 2, length: 1),
                                                         inserted: "x",
                                                         existingCodeBlocks: []))
        XCTAssertLessThan(scope.length, text.length / 4,
                          "Ordinary typing must only re-parse a neighbourhood")
    }

    func testAShortDocumentIsReparsedWhole() {
        // The half rule: splitting a three-line document costs more than
        // reparsing it whole.
        let text = "Block one.\n\nBlock two.\n\nBlock three.\n" as NSString
        XCTAssertNil(IncrementalParse.scope(in: text,
                                            editedRange: NSRange(location: 16, length: 1),
                                            inserted: "x",
                                            existingCodeBlocks: []))
    }

    // MARK: - The neighbourhood margin

    func testScopeIncludesTheNeighbouringBlocks() {
        // A `setext` heading is underlined by the line after it; a list that
        // has its blank line removed merges with the next one. A margin
        // block on each side covers these cases.
        let text = "One.\n\nTwo.\n\nThree.\n\nFour.\n\nFive.\n" as NSString
        let scope = IncrementalParse.blockRange(in: text, around: NSRange(location: 13, length: 0))
        XCTAssertLessThan(scope.location, 12, "The scope must reach back before the edited block")
        XCTAssertGreaterThan(scope.upperBound, 18, "And forward past it")
    }

    // MARK: - The splice

    func testSpliceShiftsWhatComesAfterTheScope() {
        let previous = [
            span(at: NSRange(location: 0, length: 5)),
            span(at: NSRange(location: 10, length: 5)),
            span(at: NSRange(location: 30, length: 5)),
        ]
        let fresh = [span(at: NSRange(location: 10, length: 8))]
        let result = MarkdownParser.splice(previous,
                                           replacing: NSRange(location: 8, length: 14),
                                           with: fresh,
                                           delta: 3)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].range, NSRange(location: 0, length: 5), "Before the scope: unchanged")
        XCTAssertEqual(result[1].range, NSRange(location: 10, length: 8), "Inside the scope: replaced")
        XCTAssertEqual(result[2].range, NSRange(location: 33, length: 5), "After the scope: shifted by delta")
    }

    // MARK: - Helpers

    private func assertIncrementalMatchesFull(base: String, insert: String, at location: Int,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let edited = (base as NSString).replacingCharacters(in: NSRange(location: location, length: 0),
                                                            with: insert)
        let editedRange = NSRange(location: location, length: insert.utf16.count)
        let delta = insert.utf16.count

        let full = MarkdownParser.parse(edited).spans
        let before = MarkdownParser.parse(base).spans
        let codeBlocks = before.compactMap { span -> NSRange? in
            if case .codeBlock = span.kind { return span.range } else { return nil }
        }

        guard let scope = IncrementalParse.scope(in: edited as NSString,
                                                 editedRange: editedRange,
                                                 inserted: insert,
                                                 existingCodeBlocks: codeBlocks) else {
            return // Full re-parse requested: nothing to compare.
        }
        let fragment = (edited as NSString).substring(with: scope)
        let fresh = MarkdownParser.parse(fragment, offsetBy: scope.location)
        let incremental = MarkdownParser.splice(before, replacing: scope, with: fresh, delta: delta)

        XCTAssertEqual(normalise(incremental), normalise(full),
                       "Inserting \(insert.debugDescription) at \(location)",
                       file: file, line: line)
    }

    /// Compares what matters for rendering: the kind and the ranges. The
    /// order of the list depends on the AST traversal and carries no
    /// meaning of its own.
    private func normalise(_ spans: [SyntaxSpan]) -> [String] {
        spans
            .map { "\($0.kind) \($0.range) \($0.markers) \($0.content)" }
            .sorted()
    }

    private func span(at range: NSRange) -> SyntaxSpan {
        SyntaxSpan(kind: .strong, range: range, markers: [range], content: range)
    }
}
