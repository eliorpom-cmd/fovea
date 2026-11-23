// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import XCTest
import AppKit
import PDFKit
@testable import Fovea

/// `File > Print…`: the rendered document on paper. See `DocumentPrinting`.
@MainActor
final class PrintingTests: XCTestCase {

    private let a4 = NSSize(width: 595, height: 842)

    func testTheFileMenuOffersPrintOnCommandP() throws {
        let items = MainMenu.build().items.compactMap(\.submenu).flatMap(\.items)
        let print = try XCTUnwrap(items.first { $0.action == #selector(NSDocument.printDocument(_:)) })
        XCTAssertEqual(print.keyEquivalent, "p")
        XCTAssertEqual(print.keyEquivalentModifierMask, [.command])
        let setup = try XCTUnwrap(items.first { $0.action == #selector(NSDocument.runPageLayout(_:)) })
        XCTAssertEqual(setup.keyEquivalentModifierMask, [.command, .shift])
    }

    func testPaperUsesASmallerBodySize() {
        XCTAssertEqual(DocumentPrinting.printTypography(from: .default).bodySize, 11)
        var large = EditorTypography.default
        large.bodySize = 24
        XCTAssertGreaterThan(DocumentPrinting.printTypography(from: large).bodySize, 11,
                             "A larger screen size keeps a larger print")
    }

    func testNothingIsRevealedOnPaper() throws {
        // No caret on paper: every marker is hidden, including those of the
        // first line, where the caret of an open document usually sits.
        let source = "# Title\n\n**bold** and `code`\n"
        let view = DocumentPrinting.renderedView(for: source, documentURL: nil,
                                                 typography: .default, width: 480)
        let storage = try XCTUnwrap(view.textStorage)
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 0), "The heading's #")
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 9), "The opening **")
        XCTAssertFalse(view.isEditable)
    }

    func testThePrintedPageCarriesTheMarks() throws {
        // A TextKit 2 text view doesn't run `drawBackground(in:)` when it
        // prints, which is where bullets and checkboxes are drawn: the page
        // must hold them itself.
        let view = DocumentPrinting.renderedView(for: "- Item\n- [ ] Task\n", documentURL: nil,
                                                 typography: .default, width: 480)
        XCTAssertEqual(view.decorations.count, 2, "One bullet, one checkbox")
        let page = PrintedPage(text: view)
        XCTAssertEqual(page.frame.size, view.frame.size)
        XCTAssertTrue(page.isFlipped, "Same coordinates as the text view")
        XCTAssertFalse(view.drawsBackground, "The text must not paint over the marks")
    }

    func testAPageBreakNeverCutsALine() throws {
        let source = (1...30).map { "Paragraph \($0) " + String(repeating: "word ", count: 60) }
            .joined(separator: "\n\n")
        let view = DocumentPrinting.renderedView(for: source, documentURL: nil,
                                                 typography: DocumentPrinting.printTypography(from: .default),
                                                 width: 483)
        let page = PrintedPage(text: view)
        let layout = try XCTUnwrap(view.textLayoutManager)

        // Every line's letters, in view coordinates.
        var lines: [NSRect] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                lines.append(line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                                             dy: fragment.layoutFragmentFrame.minY))
            }
            return true
        }
        XCTAssertGreaterThan(lines.count, 50)

        // Propose a break in the middle of each of a few lines.
        for line in lines.dropFirst(10).prefix(20) {
            var bottom: CGFloat = 0
            page.adjustPageHeightNew(&bottom, top: 0, bottom: line.midY, limit: 0)
            XCTAssertLessThan(bottom, line.midY, "The break moves up out of the line")
            XCTAssertGreaterThanOrEqual(bottom, line.minY, "…but no further than the line")
            XCTAssertLessThanOrEqual(bottom, line.maxY - DocumentPrinting.printTypography(from: .default).body.ascender,
                                     "…and above the top of its letters")
        }
    }

    func testABreakAboveTheLettersNeverMovesDown() throws {
        // The surplus of line spacing sits above a line's letters. A break
        // falling there is already clean; moving it to the letters' top would
        // move it **down**, and AppKit raises on that.
        let view = DocumentPrinting.renderedView(for: "One\n\nTwo\n", documentURL: nil,
                                                 typography: .default, width: 480)
        let page = PrintedPage(text: view)
        let layout = try XCTUnwrap(view.textLayoutManager)
        var second: NSRect?
        var index = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                if index == 1 || (index > 0 && second == nil && line.characterRange.length > 0) {
                    second = line.typographicBounds.offsetBy(dx: 0, dy: fragment.layoutFragmentFrame.minY)
                }
                index += 1
            }
            return second == nil
        }
        let line = try XCTUnwrap(second)
        let justBelowTop = line.minY + 1
        var bottom: CGFloat = 0
        page.adjustPageHeightNew(&bottom, top: 0, bottom: justBelowTop, limit: 0)
        XCTAssertLessThanOrEqual(bottom, justBelowTop)
    }

    func testABreakBetweenLinesStaysWhereItIs() throws {
        let view = DocumentPrinting.renderedView(for: "Short.\n", documentURL: nil,
                                                 typography: .default, width: 480)
        let page = PrintedPage(text: view)
        var bottom: CGFloat = 0
        page.adjustPageHeightNew(&bottom, top: 0, bottom: view.frame.height + 200, limit: 0)
        XCTAssertEqual(bottom, view.frame.height + 200, "Below the text, nothing to avoid")
    }

    func testPrintingALongDocumentProducesSeveralPages() throws {
        let source = (1...40).map { "- Item \($0) " + String(repeating: "word ", count: 40) }
            .joined(separator: "\n")
        let info = NSPrintInfo()
        info.paperSize = a4
        let operation = DocumentPrinting.operation(for: source, documentURL: nil,
                                                   typography: .default, printInfo: info)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fovea-print-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false

        XCTAssertTrue(operation.run())
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        // The print system snaps to its own A4 (595.2 × 841.8).
        let size = try XCTUnwrap(pdf.page(at: 0)?.bounds(for: .mediaBox).size)
        XCTAssertEqual(size.width, a4.width, accuracy: 1)
        XCTAssertEqual(size.height, a4.height, accuracy: 1)
        XCTAssertTrue(pdf.string?.contains("Item 40") == true, "The last item made it to paper")
    }
}
