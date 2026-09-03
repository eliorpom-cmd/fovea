// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import Foundation

/// Converts `swift-markdown` positions to `NSTextStorage` offsets.
///
/// # Why this class exists
///
/// The two sides do not count in the same unit:
///
/// | | Unit | `é` | `🙂` |
/// |---|---|---|---|
/// | `swift-markdown` (cmark) | **UTF-8 bytes** | 2 | 4 |
/// | `NSTextStorage` | **UTF-16 code units** | 1 | 2 |
///
/// A naive conversion, treating the column as a character index, misaligns
/// every attribute at the first accented letter. In French text, that means
/// right away. §3.3 flags this as non-negotiable; this is
/// where that promise is kept, and `SourcePositionMapTests` verifies it
/// against accented text, emoji and CJK.
///
/// # What it costs
///
/// The line table is built in a single pass on every full reparse. A purely
/// ASCII line (the majority, even in French, once punctuation and whitespace
/// are counted) converts through a single addition, without a scan. The
/// others are walked scalar by scalar, over the length of a line, not of the
/// document.
struct SourcePositionMap {

    private struct Line {
        /// UTF-16 offset of the first character of the line, from the start of the text.
        let utf16Start: Int
        /// Index of the line's first scalar, for traversal.
        let scalarStart: String.UnicodeScalarView.Index
        /// Length of the line in UTF-16 units, terminator excluded.
        let utf16Length: Int
        /// True if the line contains only ASCII: bytes and units coincide,
        /// the conversion is a single addition.
        let isASCII: Bool
    }

    private let scalars: String.UnicodeScalarView
    private let lines: [Line]

    /// Total length of the text in UTF-16 units.
    let utf16Length: Int

    init(text: String) {
        self.scalars = text.unicodeScalars

        var built: [Line] = []
        built.reserveCapacity(256)

        var utf16Offset = 0
        var lineStartUTF16 = 0
        var lineStartIndex = scalars.startIndex
        var lineIsASCII = true

        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\n" {
                built.append(Line(utf16Start: lineStartUTF16,
                                  scalarStart: lineStartIndex,
                                  utf16Length: utf16Offset - lineStartUTF16,
                                  isASCII: lineIsASCII))
                utf16Offset += 1 // the newline itself
                index = scalars.index(after: index)
                lineStartUTF16 = utf16Offset
                lineStartIndex = index
                lineIsASCII = true
                continue
            }
            if !scalar.isASCII { lineIsASCII = false }
            utf16Offset += UTF16.width(scalar)
            index = scalars.index(after: index)
        }

        // The last line, which is not terminated by a line break. It exists
        // even when the text is empty: cmark numbers lines starting at 1,
        // and would reference a nonexistent line 1 without it.
        built.append(Line(utf16Start: lineStartUTF16,
                          scalarStart: lineStartIndex,
                          utf16Length: utf16Offset - lineStartUTF16,
                          isASCII: lineIsASCII))

        self.lines = built
        self.utf16Length = utf16Offset
    }

    /// Number of lines, counting the last one even if it is empty.
    var lineCount: Int { lines.count }

    /// UTF-16 offset of a `swift-markdown` position.
    ///
    /// - Parameters:
    ///   - line: line number **starting at 1**, as cmark does.
    ///   - column: column number **starting at 1**, counted in **UTF-8 bytes**.
    ///
    /// Out-of-bounds positions are clamped into the text rather than
    /// triggering an error: cmark sometimes places the end of a node one
    /// column past the last character of a line, and that is not a defect
    /// to report but a convention to absorb.
    func utf16Offset(line: Int, column: Int) -> Int {
        guard line >= 1 else { return 0 }
        guard line <= lines.count else { return utf16Length }

        let target = lines[line - 1]
        let byteOffset = max(0, column - 1)

        if target.isASCII {
            return target.utf16Start + min(byteOffset, target.utf16Length)
        }

        var bytesSeen = 0
        var unitsSeen = 0
        var index = target.scalarStart
        while bytesSeen < byteOffset, index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\n" { break }
            bytesSeen += UTF8.width(scalar)
            unitsSeen += UTF16.width(scalar)
            index = scalars.index(after: index)
        }
        return target.utf16Start + min(unitsSeen, target.utf16Length)
    }

    /// UTF-16 range corresponding to an interval of cmark positions.
    ///
    /// `swift-markdown`'s end bound is **exclusive** — verified against the
    /// library, not assumed: `"ab **cd** ef"` gives the `Strong` node
    /// columns 4 → 10, i.e. bytes 3 to 8 inclusive, which is exactly the six
    /// bytes of `**cd**`. It therefore carries over as-is into a Cocoa
    /// range, without adding the width of the last code unit.
    func range(fromLine: Int, fromColumn: Int, toLine: Int, toColumn: Int) -> NSRange {
        let start = utf16Offset(line: fromLine, column: fromColumn)
        let end = max(start, utf16Offset(line: toLine, column: toColumn))
        return NSRange(location: start, length: end - start)
    }

    /// UTF-16 range of the line containing `location`, terminator **excluded**.
    /// Used by the line-scoped constructs of §2.2.
    func lineRange(containing location: Int) -> NSRange {
        let line = lines[lineIndex(containing: location)]
        return NSRange(location: line.utf16Start, length: line.utf16Length)
    }

    /// Binary search. Called on every caret movement, i.e. on the app's
    /// most sensitive path.
    private func lineIndex(containing location: Int) -> Int {
        var low = 0
        var high = lines.count - 1
        var found = 0
        while low <= high {
            let middle = (low + high) / 2
            if lines[middle].utf16Start <= location {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }
}
