// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// **The budgets from §9, measured rather than hoped for.**
///
/// An exceeded budget blocks the milestone. The thresholds are hardcoded here
/// so that a failure is a test error rather than a line in a report nobody
/// reads.
///
/// Measurements are taken on a fixed corpus, built programmatically so that
/// two runs compare the same thing.
@MainActor
final class PerformanceTests: XCTestCase {

    // MARK: - The real cost: the reparse

    /// §9: keystroke → display cycle, 10,000-word document, budget **8 ms**,
    /// one frame at 120 Hz.
    func testKeystrokeCycleUnder8msAt10kWords() throws {
        let source = Corpus.document(words: 10_000)
        let elapsed = try measureKeystrokeCycle(on: source)
        XCTAssertLessThan(elapsed, 0.008,
                          "Keystroke cycle at 10,000 words: \(ms(elapsed)) for an 8 ms budget")
    }

    /// §9: same at 100,000 words, budget **16 ms**.
    func testKeystrokeCycleUnder16msAt100kWords() throws {
        let source = Corpus.document(words: 100_000)
        let elapsed = try measureKeystrokeCycle(on: source)
        XCTAssertLessThan(elapsed, 0.016,
                          "Keystroke cycle at 100,000 words: \(ms(elapsed)) for a 16 ms budget")
    }

    /// §9: opening and first display, 100,000 words, budget **500 ms**.
    func testOpeningA100kWordDocumentUnder500ms() throws {
        let source = Corpus.document(words: 100_000)
        let controller = EditorController(typography: .default)
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        // What is measured is the path **up to the first display**:
        // progressive opening does just enough to paint, and finishes parsing
        // on the next run loop turn.
        let start = CFAbsoluteTimeGetCurrent()
        controller.setText(source)
        let layout = try XCTUnwrap(controller.textView.textLayoutManager)
        layout.ensureLayout(for: NSRect(x: 0, y: 0, width: 700, height: 600))
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 0.5,
                          "First display of 100,000 words: \(ms(elapsed)) for a 500 ms budget")
    }

    /// Progressive opening must not leave the document half-parsed: once the
    /// run loop has turned, everything must be there.
    func testProgressiveOpeningCompletesTheWholeDocument() async throws {
        let source = Corpus.document(words: 100_000)
        let controller = EditorController(typography: .default)
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.setText(source)

        let head = controller.spans.count
        try await Task.sleep(for: .milliseconds(2000))

        XCTAssertGreaterThan(controller.spans.count, head,
                             "Parsing of the rest of the document must have happened")
        let last = try XCTUnwrap(controller.spans.last)
        XCTAssertGreaterThan(last.range.upperBound, source.utf16.count / 2,
                             "Constructs must cover the end of the document")
    }

    /// The most frequent operation in the whole app: an arrow key. It must
    /// stay **under a millisecond** regardless of document size, because it
    /// only recomputes what changed.
    func testCaretMovementIsSubMillisecondAt100kWords() throws {
        let source = Corpus.document(words: 100_000)
        let parsed = MarkdownParser.parse(source)
        let length = source.utf16.count

        // The index is built at parse time, not on every movement: that is
        // what `EditorController` does, and that is what must be measured.
        let index = SpanIndex(parsed.spans)
        let start = CFAbsoluteTimeGetCurrent()
        var iterations = 0
        for caret in stride(from: 0, to: length, by: max(1, length / 200)) {
            _ = RevealPolicy.revealedIndices(
                index: index,
                selection: NSRange(location: caret, length: 0),
                lineRange: parsed.positions.lineRange(containing: caret))
            iterations += 1
        }
        let perMove = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations)

        XCTAssertLessThan(perMove, 0.001,
                          "Caret movement: \(ms(perMove)) for a 1 ms budget")
    }

    // MARK: - Geometry must not move under the caret

    /// **Painting the background only lays out what is visible.**
    ///
    /// This is the test for the most serious regression the app has had.
    /// `DecorationPainter` discarded off-screen marks *after* asking them for
    /// their position, and asking a range for its position lays it out. With
    /// one mark per list item, per blockquote and per code block, every
    /// paint pass laid out the **entire** document, from inside the paint
    /// pass itself.
    ///
    /// What the user saw: the text view resized in the middle of its own
    /// display, the scroll view caught up, and the text jumped: under the
    /// caret while typing, under the pointer while selecting, where the
    /// selection would then land far from the mouse.
    ///
    /// The test measures the **laid-out height**, not a duration: that is
    /// the quantity that describes the bug, and it does not depend on the
    /// machine. Before the fix, it went from 634 to 35,160 points.
    func testPaintingTheBackgroundDoesNotLayOutTheWholeDocument() throws {
        let controller = EditorController(typography: .default)
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.applyColumnLayout()
        controller.setText(Corpus.document(words: 40_000))

        let view = controller.textView
        let layout = try XCTUnwrap(view.textLayoutManager)
        let viewport = NSRect(x: 0, y: 0, width: 900, height: 600)
        layout.ensureLayout(for: viewport)
        let laidOut = layout.usageBoundsForTextContainer.height

        XCTAssertGreaterThan(view.decorations.count, 100,
                             "The corpus must carry enough marks for the test to be meaningful")

        let image = NSImage(size: viewport.size)
        image.lockFocus()
        DecorationPainter(typography: .default, documentURL: nil)
            .draw(view.decorations, in: view, dirtyRect: viewport)
        image.unlockFocus()

        // A margin: a block that overflows the visible area is legitimately
        // laid out. What must no longer happen is the entire document.
        XCTAssertLessThan(layout.usageBoundsForTextContainer.height, laidOut * 1.5,
                          "Painting the background laid out \(layout.usageBoundsForTextContainer.height) points "
                          + "where only \(laidOut) were on screen")
    }

    /// The reverse of the previous test: **what is visible still gets drawn**.
    ///
    /// Discarding marks by their range is what makes drawing cheap; it is
    /// also what could make marks disappear. The test scrolls to the middle
    /// of a long document and verifies that the checkboxes at that
    /// height, and only those, do get a hit box.
    func testMarksStayVisibleAfterScrolling() throws {
        var source = "# Tasks\n\n"
        for index in 0..<400 {
            source += "- [ ] Task number \(index), with a label long enough to fill the line\n"
        }

        let controller = EditorController(typography: .default)
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.applyColumnLayout()
        controller.setText(source)

        let view = controller.textView
        let layout = try XCTUnwrap(view.textLayoutManager)
        layout.ensureLayout(for: NSRect(x: 0, y: 0, width: 900, height: 20_000))
        view.frame = NSRect(x: 0, y: 0, width: 900, height: layout.usageBoundsForTextContainer.height + 128)

        let painter = DecorationPainter(typography: .default, documentURL: nil)
        let clip = controller.scrollView.contentView
        clip.setBoundsOrigin(NSPoint(x: 0, y: 4_000))

        let targets = painter.checkboxTargets(among: view.decorations, in: view)
        XCTAssertFalse(targets.isEmpty,
                       "No checkbox laid out in the middle of the document: range-based culling discarded too much")

        // All the ones that are drawn do fall within the visible area.
        let visible = view.visibleRect.insetBy(dx: 0, dy: -200)
        for target in targets {
            XCTAssertTrue(visible.intersects(target.box),
                          "A checkbox was laid out outside the visible area: \(target.box) outside \(visible)")
        }
    }

    // MARK: - Instrumentation

    /// A keystroke cycle **as it actually happens**: through
    /// `EditorController`, hence through the incremental path.
    ///
    /// Measuring a full parse and a full render would give the naive
    /// implementation's number, not the one the user feels. That is exactly
    /// the mistake the first version of this test made.
    private func measureKeystrokeCycle(on source: String) throws -> TimeInterval {
        let controller = EditorController(typography: .default)
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.setText(source)

        let view = controller.textView
        let storage = try XCTUnwrap(view.textStorage)
        // Typing happens in the middle of a paragraph: the nominal case, and
        // the one where the block-level splitting must do its job.
        let caret = storage.length / 2
        view.setSelectedRange(NSRange(location: caret, length: 0))

        var total: TimeInterval = 0
        let rounds = 20
        for round in 0..<rounds {
            let start = CFAbsoluteTimeGetCurrent()
            view.insertText("a", replacementRange: NSRange(location: caret + round, length: 0))
            total += CFAbsoluteTimeGetCurrent() - start
        }
        return total / Double(rounds)
    }

    private func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }
}

/// A document of a chosen size, built programmatically.
///
/// It deliberately mixes expensive constructs (bold, links, lists,
/// blockquotes, code blocks) with accented text, which forces the slow path
/// of range conversion. A purely ASCII corpus would give flattering and
/// wrong numbers.
private enum Corpus {

    static func document(words: Int) -> String {
        var text = "# A document of \(words) words\n\n"
        var written = 0
        var block = 0
        while written < words {
            switch block % 6 {
            case 0:
                text += "## Section \(block / 6 + 1)\n\n"
                written += 3
            case 1, 2:
                text += "A paragraph with some **bold**, some *italics*, some `code` and a "
                text += "[link](https://example.com): very accented café, naïve, façade.\n\n"
                written += 24
            case 3:
                text += "- First item of the list\n- Second one, with **bold inside**\n"
                text += "- Third one, and a `bit of code`\n\n"
                written += 20
            case 4:
                text += "> A blockquote spanning two full lines,\n"
                text += "> and keeping its chevron on each one.\n\n"
                written += 16
            default:
                text += "```swift\nlet value = \(block) // an accented comment already: café\n```\n\n"
                written += 10
            }
            block += 1
        }
        return text
    }
}
