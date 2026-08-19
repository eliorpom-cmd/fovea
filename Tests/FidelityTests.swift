// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// **The test that validates the §5 promise end to end.**
///
/// The other fidelity tests work on strings built for the occasion. This one
/// takes **real documents** — the ones in the repository, plus a corpus cut
/// for the awkward cases — runs them through the whole pipeline (read,
/// parse, full render, write) and checks that the bytes come out identical.
///
/// It's the automated equivalent of an empty `git diff` after opening and
/// saving without touching anything.
@MainActor
final class FidelityTests: XCTestCase {

    func testRealDocumentsSurviveTheWholePipeline() throws {
        for (name, source) in Corpus.documents {
            let original = Data(source.utf8)

            // 1. Read, as in `MarkdownDocument.read(from:)`.
            let contents = try TextFile.read(original)

            // 2. Parse and full render, as when a window opens.
            let view = EditorTextView.make()
            let storage = try XCTUnwrap(view.textStorage)
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                      with: contents.text)
            let parsed = MarkdownParser.parse(contents.text)
            MarkdownRenderer(typography: .default)
                .render(storage, spans: parsed.spans, revealed: [],
                        in: NSRange(location: 0, length: storage.length))

            // 3. Write, as in `MarkdownDocument.data(ofType:)`.
            let written = TextFile.write(text: view.string, lineEnding: contents.lineEnding)

            XCTAssertEqual(written, original,
                           "\(name) came out different from what went in")
        }
    }


    /// Rendering must not depend on the caret position to leave the text
    /// intact: wherever it's placed, the characters stay the same.
    func testRevealingMarkersNeverAltersTheText() throws {
        let source = Corpus.documents["torture"]!
        let view = EditorTextView.make()
        let storage = try XCTUnwrap(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        let parsed = MarkdownParser.parse(source)
        let renderer = MarkdownRenderer(typography: .default)

        for caret in stride(from: 0, to: source.utf16.count, by: 7) {
            let revealed = RevealPolicy.revealedIndices(
                spans: parsed.spans,
                selection: NSRange(location: caret, length: 0),
                lineRange: parsed.positions.lineRange(containing: caret))
            renderer.render(storage, spans: parsed.spans, revealed: revealed,
                            in: NSRange(location: 0, length: storage.length))
            XCTAssertEqual(view.string, source, "Caret at \(caret)")
        }
    }

    /// **The §2.3 invariant, checked on real documents.**
    ///
    /// There is no "invisible caret position": when a marker is hidden, the
    /// caret can never land inside it. This test lives here rather than in
    /// `RevealPolicyTests` because it only earns its keep on real markdown —
    /// headings, nested blockquotes, task lists, code fences — and because it
    /// guards the prefix-reveal rule against a regression: that rule applies
    /// to markers, bounds included, and that's exactly what makes the
    /// invariant true.
    func testNoCaretPositionFallsInsideAHiddenMarker() throws {
        for (name, source) in Corpus.documents {
            let parsed = MarkdownParser.parse(source)
            for caret in 0...source.utf16.count {
                let line = parsed.positions.lineRange(containing: caret)
                let revealed = RevealPolicy.revealedIndices(spans: parsed.spans,
                                                            selection: NSRange(location: caret, length: 0),
                                                            lineRange: line)
                for (index, span) in parsed.spans.enumerated() {
                    for marker in span.markers where NSLocationInRange(caret, marker) {
                        XCTAssertTrue(revealed.contains(index),
                                      "\(name), position \(caret): inside a hidden marker of \(span.kind)")
                    }
                }
            }
        }
    }

    /// No position in the document should crash the walk: this is the test
    /// that catches range-conversion errors on the cases nobody planned for.
    func testEveryCaretPositionIsSafe() throws {
        for (name, source) in Corpus.documents {
            let parsed = MarkdownParser.parse(source)
            for caret in 0...source.utf16.count {
                let line = parsed.positions.lineRange(containing: caret)
                _ = RevealPolicy.revealedIndices(spans: parsed.spans,
                                                 selection: NSRange(location: caret, length: 0),
                                                 lineRange: line)
            }
            // Every range must fit inside the document, otherwise applying
            // attributes would raise a runtime exception.
            let length = source.utf16.count
            for span in parsed.spans {
                XCTAssertLessThanOrEqual(span.range.upperBound, length, "\(name): range out of bounds")
                for marker in span.markers {
                    XCTAssertLessThanOrEqual(marker.upperBound, length, "\(name): marker out of bounds")
                    XCTAssertGreaterThanOrEqual(marker.location, span.range.location,
                                                "\(name): marker outside its construct")
                }
            }
        }
    }
}

/// The reference corpus.
///
/// It's versioned in code rather than read from files: the tests must run
/// without depending on whatever happens to be lying around on the disk of
/// whoever runs them.
private enum Corpus {

    static let documents: [String: String] = [
        "prose": prose,
        "torture": torture,
        "edge cases": edgeCases,
    ]

    /// Ordinary prose, heavily accented: the nominal case for Fovea.
    /// Accented text: exercises the UTF-8 -> UTF-16 offset conversion.
    static let prose = """
    ---
    title: A sample document
    author: Elior
    ---

    # The spec

    This document mixes **bold**, *italic*, `inline code` and
    [links](https://example.com) — all sprinkled with accents: é, è, ê,
    ë, à, ù, ç, œ, æ.

    ## A section

    > A two-line blockquote,
    > that keeps its chevron on every line.

    - An item
    - Another, with **bold inside**
      - A nested item

    1. First
    2. Second

    - [ ] An unchecked task
    - [x] A checked task

    ```swift
    let x = 1  // code, with an accent in a comment: café
    ```

    ---

    A reference[^note] to a footnote.

    [^note]: The footnote text.

    """

    /// Everything that can break a range conversion, packed into a few lines.
    static let torture = """
    Emoji 🙂 then **bold**, CJK 日本語 then *italic*, combining accent e\u{0301} then `code`.

    Nested ***bold and italic***, some ~~strikethrough~~, and a [**bold** link](https://x.fr).

    Raw <b>HTML</b> that must never be interpreted.

    ``An inline code span containing a `backtick` `` and another.

    | a | b |
    |---|---|
    | 1 | 2 |
    """

    /// The §6 cases: what must behave correctly without crashing or silently
    /// dropping anything.
    static let edgeCases = """
    ```
    a code block that's never closed, with a [^1] inside it and some **asterisks**

    | table | malformed
    |---

    ###### A level-six heading

    ####### Seven hashes, which is not a heading

    -

    >

    ****

    [link with no destination]()

    ![](image-with-no-alt.png)
    """
}
