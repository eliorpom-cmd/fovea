// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// The §6 edge states.
///
/// §6 sets the rule: each one has a defined behaviour, and **none of
/// them is allowed to be a default state**. An empty screen, a false
/// message, or silence are three ways of getting the same thing wrong.
@MainActor
final class EdgeStateTests: XCTestCase {

    // MARK: - What the banner says, and when it stays silent

    func testAnOrdinaryDocumentSaysNothing() {
        // By far the most frequent case. A banner that shows up for
        // nothing would be exactly the chrome that §7 forbids.
        XCTAssertTrue(DocumentBanner.messages(byteCount: 4_000, encoding: .utf8, isWritable: true).isEmpty)
    }

    func testALargeDocumentSuggestsSourceModeWithoutSwitching() {
        let messages = DocumentBanner.messages(byteCount: 2_000_000, encoding: .utf8, isWritable: true)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("⌥⌘S"), messages[0])
        // "The app never switches on its own": the message informs, it
        // doesn't say it acted.
        XCTAssertFalse(messages[0].lowercased().contains("switched"))
    }

    func testTheThresholdIsAMegabyte() {
        XCTAssertTrue(DocumentBanner.messages(byteCount: 1_000_000, encoding: .utf8, isWritable: true).isEmpty)
        XCTAssertFalse(DocumentBanner.messages(byteCount: 1_000_001, encoding: .utf8, isWritable: true).isEmpty)
    }

    func testALegacyEncodingAnnouncesTheConversion() {
        let messages = DocumentBanner.messages(byteCount: 100, encoding: .isoLatin1, isWritable: true)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("ISO-8859-1"), messages[0])
        XCTAssertTrue(messages[0].contains("UTF-8"), messages[0])
    }

    func testAReadOnlyFileSaysHowToKeepChanges() {
        // §6: the document opens and stays editable in memory. What will
        // not work is saving, and it's better to learn that before writing
        // three pages.
        let messages = DocumentBanner.messages(byteCount: 100, encoding: .utf8, isWritable: false)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("Save As"), messages[0])
    }

    func testSeveralFactsAreAllSaid() {
        // A large, read-only, Latin-1 file: all three get said, none hides
        // another.
        let messages = DocumentBanner.messages(byteCount: 2_000_000, encoding: .windowsCP1252,
                                               isWritable: false)
        XCTAssertEqual(messages.count, 3)
    }

    // MARK: - Images (§6)

    /// **A broken image inline in a sentence must be visible.**
    ///
    /// As a block, a missing image gets its "Image not found" frame: §6
    /// forbids the emptiness that would look like a bug. Inline in the
    /// text there's no room for a frame, and until now there was *no*
    /// sign at all: `![inline in the text](missing.png)` read as "inline
    /// in the text", alt text indistinguishable from the prose. The link
    /// could have been dead for months without anything saying so.
    func testAMissingInlineImageIsMarked() throws {
        let source = "Some text ![a photo](missing.png) in the middle.\n"
        let view = EditorTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        let storage = try XCTUnwrap(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)

        let parsed = MarkdownParser.parse(source)
        MarkdownRenderer(typography: .default)
            .render(storage, spans: parsed.spans, revealed: [],
                    in: NSRange(location: 0, length: storage.length))

        let alt = (source as NSString).range(of: "a photo")
        let underline = storage.attribute(.underlineStyle, at: alt.location, effectiveRange: nil) as? Int
        XCTAssertNotNil(underline, "The alt text of a missing image must be underlined")

        // And the surrounding prose didn't pick up anything along the way.
        let prose = (source as NSString).range(of: "in the middle")
        XCTAssertNil(storage.attribute(.underlineStyle, at: prose.location, effectiveRange: nil),
                     "Neighbouring text stays ordinary text")
    }

    func testAnOversizedImageIsNotCalledMissing() throws {
        // The file exists: labeling it "not found" would be wrong, yet
        // that was the previous behaviour.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A real image, but flagged too heavy by its size on disk.
        let image = NSImage(size: NSSize(width: 2000, height: 2000))
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: 2000, height: 2000).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
        try XCTSkipUnless(data.count > 20 * 1024 * 1024,
                          "The test image doesn't reach the 20 MB threshold")

        let file = folder.appendingPathComponent("huge.tiff")
        try data.write(to: file)

        ImageStore.shared.invalidate()
        defer { ImageStore.shared.invalidate() }
        let document = folder.appendingPathComponent("doc.md")
        guard case .oversized = ImageStore.shared.entry(for: "huge.tiff", relativeTo: document) else {
            return XCTFail("An oversized image must be reported as such, not as missing")
        }
    }

    func testAStillImageIsNotReportedAsAnimated() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("still.png"))

        ImageStore.shared.invalidate()
        defer { ImageStore.shared.invalidate() }
        let document = folder.appendingPathComponent("doc.md")
        guard case .loaded(_, let animated) = ImageStore.shared.entry(for: "still.png", relativeTo: document) else {
            return XCTFail("The image should have loaded")
        }
        XCTAssertFalse(animated)
    }

    func testARemoteURLIsNeverFetched() {
        // An editor that reaches out to the network while typing is an
        // editor that freezes.
        XCTAssertNil(ImageStore.resolve("https://example.com/photo.png", relativeTo: nil))
    }

    // MARK: - Source mode with a selection (§6)

    func testSwitchingToSourceExtendsTheSelectionToItsMarkers() {
        // Selecting a bold word only selects the word: its `**` markers
        // were invisible. Without extension, a ⌘X in source mode would
        // leave an orphaned `**`.
        let controller = EditorController()
        controller.setText("A word **important** here.\n")

        let word = ("A word **important** here.\n" as NSString).range(of: "important")
        controller.textView.setSelectedRange(word)
        controller.toggleSourceMode()

        let extended = controller.textView.selectedRange()
        XCTAssertEqual(extended, NSRange(location: 7, length: 13),
                       "The selection must cover **important**, asterisks included")
    }

    func testSwitchingBackDoesNotShrinkTheSelection() {
        // Switching back to rendering removes nothing: whatever was
        // selected stays selected, otherwise the round trip would lose
        // text.
        let controller = EditorController()
        controller.setText("A word **important** here.\n")
        controller.textView.setSelectedRange(NSRange(location: 7, length: 13))

        controller.toggleSourceMode()
        let inSource = controller.textView.selectedRange()
        controller.toggleSourceMode()

        XCTAssertEqual(controller.textView.selectedRange(), inSource)
    }

    func testAnEmptySelectionIsLeftAlone() {
        // A lone caret isn't a selection: extending it would move the
        // insertion point without anyone asking for that.
        let controller = EditorController()
        controller.setText("A word **important** here.\n")
        controller.textView.setSelectedRange(NSRange(location: 12, length: 0))

        controller.toggleSourceMode()
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 12, length: 0))
    }

    // MARK: - Empty document

    func testAnEmptyDocumentRendersWithoutComplaint() {
        // "A caret, a column of text, and nothing else."
        let controller = EditorController()
        controller.setText("")
        XCTAssertEqual(controller.text, "")
        XCTAssertTrue(controller.spans.isEmpty)
    }
}
