// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
@testable import Fovea

/// The pitfall identified in §3.3: `swift-markdown` counts in UTF-8 bytes,
/// `NSTextStorage` in UTF-16 units.
///
/// These tests are the counterpart to that promise. They don't check that
/// the code "works": they check that it places attributes **at exactly the
/// right character** on text Fovea will encounter starting with the very
/// first accented sentence a user types.
final class SourcePositionMapTests: XCTestCase {

    // MARK: - The nominal case

    func testASCIIColumnsMapDirectly() {
        let map = SourcePositionMap(text: "ab **cd** ef")
        // Column 1 -> offset 0: cmark counts from 1, Cocoa counts from 0.
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 4), 3)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 10), 9)
    }

    // MARK: - The case that breaks a naive implementation

    // Accented text: exercises the UTF-8 -> UTF-16 offset conversion.
    func testAccentedCharactersShiftColumnsButNotOffsets() {
        // "é" is 2 UTF-8 bytes and 1 UTF-16 unit. The `**` is therefore at
        // column 6 for cmark, but at offset 3 for NSTextStorage.
        let text = "éé **cd** ef"
        let map = SourcePositionMap(text: text)
        XCTAssertEqual(text.utf8.count, 14)
        XCTAssertEqual(text.utf16.count, 12)

        XCTAssertEqual(map.utf16Offset(line: 1, column: 6), 3,
                       "A naive reading of the column would give 5 and shift all the rendering")
        XCTAssertEqual(map.utf16Offset(line: 1, column: 12), 9)
    }

    func testEmojiCountsFourBytesAndTwoUnits() {
        // "🙂" is 4 UTF-8 bytes and 2 UTF-16 units: the two gaps move in
        // opposite directions, which a simple constant factor could not
        // correct for.
        let text = "🙂 **cd** ef"
        let map = SourcePositionMap(text: text)
        XCTAssertEqual(text.utf8.count, 14)
        XCTAssertEqual(text.utf16.count, 12)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 6), 3)
    }

    func testCJKCountsThreeBytesAndOneUnit() {
        let text = "日本語 **cd**"
        let map = SourcePositionMap(text: text)
        // 3 ideographs x 3 bytes + space + ** + cd + ** = 9 + 1 + 6 = 16.
        XCTAssertEqual(text.utf8.count, 16)
        // The same in UTF-16: 3 + 1 + 6 = 10. The 6-unit gap with the byte
        // count comes entirely from the ideographs.
        XCTAssertEqual(text.utf16.count, 10)
        // The opening `**` starts at byte 10, so at column 11, but at
        // UTF-16 offset 4, right after "日本語".
        XCTAssertEqual(map.utf16Offset(line: 1, column: 11), 4)
    }

    // Accented text: exercises the UTF-8 -> UTF-16 offset conversion.
    func testCombiningMarksAreCountedAsWritten() {
        // "e" + U+0301 is one character on screen, two scalars, three
        // bytes. That's what pasting from some PDFs produces.
        let text = "e\u{0301}x"
        let map = SourcePositionMap(text: text)
        XCTAssertEqual(text.utf8.count, 4)
        XCTAssertEqual(text.utf16.count, 3)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 4), 2)
    }

    // MARK: - Lines

    // Accented text: exercises the UTF-8 -> UTF-16 offset conversion.
    func testMultilineOffsetsAccumulateAcrossLines() {
        let map = SourcePositionMap(text: "Zoë\nwords\nverse")
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 1), 4)   // "Zoë" = 3 units + line break
        XCTAssertEqual(map.utf16Offset(line: 3, column: 1), 10)
    }

    func testLineRangeExcludesTheTerminator() {
        let map = SourcePositionMap(text: "up\nover\nunder")
        XCTAssertEqual(map.lineRange(containing: 0), NSRange(location: 0, length: 2))
        XCTAssertEqual(map.lineRange(containing: 4), NSRange(location: 3, length: 4))
        XCTAssertEqual(map.lineRange(containing: 12), NSRange(location: 8, length: 5))
    }

    func testTrailingNewlineProducesAnEmptyLastLine() {
        // Without this phantom line, a caret placed after the last line
        // break would have no line to belong to.
        let map = SourcePositionMap(text: "hi\n")
        XCTAssertEqual(map.lineCount, 2)
        XCTAssertEqual(map.lineRange(containing: 3), NSRange(location: 3, length: 0))
    }

    func testEmptyTextStillHasOneLine() {
        let map = SourcePositionMap(text: "")
        XCTAssertEqual(map.lineCount, 1)
        XCTAssertEqual(map.utf16Length, 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
    }

    // MARK: - Bounds

    func testOutOfBoundsPositionsAreClampedRatherThanFatal() {
        // cmark sometimes places the end of a node one column past the last
        // character. That's not a bug to report, it's a convention to
        // absorb: otherwise the app crashes on a valid document.
        let map = SourcePositionMap(text: "abc")
        XCTAssertEqual(map.utf16Offset(line: 1, column: 99), 3)
        XCTAssertEqual(map.utf16Offset(line: 99, column: 1), 3)
        XCTAssertEqual(map.utf16Offset(line: 0, column: 1), 0)
    }

    func testRangeUsesExclusiveUpperBound() {
        // Verified against `swift-markdown`: for "ab **cd** ef", the
        // `Strong` node covers columns 4 -> 10, exactly the six bytes of
        // "**cd**". The upper bound is exclusive.
        let map = SourcePositionMap(text: "ab **cd** ef")
        let range = map.range(fromLine: 1, fromColumn: 4, toLine: 1, toColumn: 10)
        XCTAssertEqual(range, NSRange(location: 3, length: 6))
    }

    func testRangeAcrossLines() {
        let map = SourcePositionMap(text: "> one\n> four")
        let range = map.range(fromLine: 1, fromColumn: 1, toLine: 2, toColumn: 7)
        XCTAssertEqual(range, NSRange(location: 0, length: 12))
    }
}
