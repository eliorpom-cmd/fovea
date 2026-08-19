// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
@testable import Fovea

/// **The §5 promise: the file outlives the app.**
///
/// A WYSIWYG editor that renormalizes on save produces unreadable diffs.
/// That's precisely what makes Typora unusable on a git repository. These
/// tests check that opening a file and re-saving it without touching
/// anything produces **exactly** the same bytes.
final class TextFileTests: XCTestCase {

    // MARK: - Round-trip

    // Accented text: exercises the UTF-8 -> UTF-16 offset conversion.
    func testRoundTripIsByteForByteIdentical() throws {
        let source = """
        # Heading

        A paragraph with accents: café, naïve, an emoji 🙂, and some 日本語.

        - a list
        * another bullet, deliberately different
        + and one more

        1) a parenthesis-style numbering

            a block indented by four spaces

        ```swift
        let x = 1
        ```

        Two trailing spaces force a line break:
        and here is the next line.
        """
        try assertRoundTrip(Data(source.utf8))
    }

    func testCRLFSurvivesUntouched() throws {
        // A Windows file must come back out as CRLF. Converting it to LF
        // would rewrite every line of the file in the diff.
        let data = Data("# Heading\r\n\r\nSome text.\r\n".utf8)
        try assertRoundTrip(data)
    }

    func testTrailingSpacesAreNeverTrimmed() throws {
        // Two trailing spaces are a forced line break in markdown: removing
        // them "to tidy up" would change how the document renders.
        let data = Data("line with two trailing spaces  \nnext line\n".utf8)
        try assertRoundTrip(data)
    }

    func testFinalNewlinePresenceIsPreserved() throws {
        try assertRoundTrip(Data("no trailing newline".utf8))
        try assertRoundTrip(Data("with trailing newline\n".utf8))
    }

    func testUnderscoreEmphasisIsNeverConvertedToStars() throws {
        // The §5 non-normalization rule, taken literally.
        try assertRoundTrip(Data("a _word_ and an __other__\n".utf8))
    }

    // MARK: - Line endings

    func testLineEndingDetectionUsesTheFirstTerminator() {
        XCTAssertEqual(TextFile.detectLineEnding("a\nb"), .lf)
        XCTAssertEqual(TextFile.detectLineEnding("a\r\nb"), .crlf)
        XCTAssertEqual(TextFile.detectLineEnding("a\rb"), .cr)
        XCTAssertEqual(TextFile.detectLineEnding("no newline at all"), .lf)
    }

    func testBufferAlwaysHoldsLFRegardlessOfTheFile() throws {
        // In memory the text lives as LF; otherwise `NSTextStorage` indices
        // and `swift-markdown` indices would drift by one character per line.
        let contents = try TextFile.read(Data("a\r\nb\r\nc".utf8))
        XCTAssertEqual(contents.text, "a\nb\nc")
        XCTAssertEqual(contents.lineEnding, .crlf)
    }

    // MARK: - Encodings

    func testUTF8WithBOMIsReadAndWrittenWithout() throws {
        // The BOM is stripped: it's the only deliberate deviation from §5,
        // and it matches every other tool in the chain, which treats it as
        // noise at the start of the file.
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("# Heading\n".utf8)
        let contents = try TextFile.read(data)
        XCTAssertEqual(contents.text, "# Heading\n")
        XCTAssertTrue(contents.hadBOM)
        XCTAssertEqual(TextFile.write(text: contents.text, lineEnding: contents.lineEnding),
                       Data("# Heading\n".utf8))
    }

    func testLatin1IsReadAsALastResort() throws {
        // A file written before UTF-8 became the norm must open rather than
        // return an error.
        let data = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in Latin-1
        let contents = try TextFile.read(data)
        XCTAssertEqual(contents.text, "café")
        XCTAssertNotEqual(contents.sourceEncoding, .utf8)
    }

    func testBinaryFileIsRefusedRatherThanShownAsGarbage() {
        // §6: a binary file renamed to `.md` must not open as a megabyte of
        // garbage.
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D, 0x0A, 0x1A])
        XCTAssertThrowsError(try TextFile.read(data)) { error in
            XCTAssertEqual(error as? TextFile.ReadError, .binary)
        }
    }

    func testUTF16WithBOMIsNotMistakenForBinary() throws {
        // UTF-16 is full of null bytes: without an exemption for its BOM,
        // the anti-binary guard would reject it.
        var data = Data([0xFF, 0xFE])
        data.append(contentsOf: Array("# Heading".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let contents = try TextFile.read(data)
        XCTAssertEqual(contents.text, "# Heading")
    }

    // MARK: - Helper

    private func assertRoundTrip(_ data: Data,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let contents = try TextFile.read(data)
        let written = TextFile.write(text: contents.text, lineEnding: contents.lineEnding)
        XCTAssertEqual(written, data,
                       "Round-trip changed the file",
                       file: file, line: line)
    }
}

