// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import Foundation

/// Locates footnotes, which `swift-markdown` does not parse.
///
/// §4.1 raises the question; the answer is no: `cmark-gfm` does
/// have the extension, but `swift-markdown` does not expose it, and `[^1]`
/// comes out as plain `Text`. The pattern being entirely unambiguous, a
/// homemade pass is enough — this is the fallback that was planned.
///
/// Two constructs come out of it: the **reference** `[^1]` in the body of the
/// text, and the **definition** `[^1]: …` at the start of a line. The second
/// is revealed at the line — placing the caret on it makes `[^1]: ` visible
/// and editable — which lets it be formatted without locking the author out
/// of their own text.
enum Footnotes {

    static func scan(utf16: [UInt16], skippingCodeIn verbatim: [NSRange]) -> [SyntaxSpan] {
        let openBracket = UInt16(UnicodeScalar("[").value)
        let caret = UInt16(UnicodeScalar("^").value)
        let closeBracket = UInt16(UnicodeScalar("]").value)
        let backslash = UInt16(UnicodeScalar("\\").value)

        var spans: [SyntaxSpan] = []
        var index = 0
        while index + 3 < utf16.count {
            guard utf16[index] == openBracket, utf16[index + 1] == caret else {
                index += 1
                continue
            }
            // An escaped `[` opens nothing.
            if index > 0, utf16[index - 1] == backslash {
                index += 1
                continue
            }

            var end = index + 2
            var identifier = ""
            while end < utf16.count, utf16[end] != closeBracket {
                // An identifier does not cross a line ending: without this
                // bound, a stray `[` would swallow half the document.
                guard let scalar = UnicodeScalar(utf16[end]), scalar != "\n" else { break }
                identifier.unicodeScalars.append(scalar)
                end += 1
            }
            guard end < utf16.count, utf16[end] == closeBracket, !identifier.isEmpty else {
                index += 1
                continue
            }

            let range = NSRange(location: index, length: end - index + 1)
            if verbatim.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                index = end + 1
                continue
            }
            // The **definition** `[^1]: …` at the start of a line is a
            // different construct: `[^` and `]:` are its markers, the rest
            // of the line is the note's text.
            //
            // It is revealed at the line, like a heading or a bullet:
            // placing the caret on it makes `[^1]:` visible, hence editable.
            // This is what lets it be formatted without ever locking the
            // author out of their own text.
            if isDefinition(utf16: utf16, referenceStart: index, referenceEnd: end) {
                // The space that follows the `:` is **not** a marker: hidden
                // along with it, the superscript would stick to the note's
                // first word. It is the only blank that separates the
                // number from its text.
                let contentStart = end + 2
                var lineEnd = contentStart
                while lineEnd < utf16.count, utf16[lineEnd] != UInt16(UnicodeScalar("\n").value) {
                    lineEnd += 1
                }
                spans.append(SyntaxSpan(
                    kind: .footnoteDefinition(identifier: identifier),
                    range: NSRange(location: index, length: lineEnd - index),
                    markers: [NSRange(location: index, length: 2),
                              NSRange(location: end, length: contentStart - end)],
                    content: NSRange(location: contentStart, length: lineEnd - contentStart)))
                index = end + 1
                continue
            }

            // The brackets are the syntax, the identifier is the content: it
            // renders as a superscript. Hiding everything would make the
            // reference disappear from the screen, leaving the author with
            // no way to find their way back to the note.
            spans.append(SyntaxSpan(
                kind: .footnoteReference(identifier: identifier),
                range: range,
                markers: [NSRange(location: index, length: 2),
                          NSRange(location: end, length: 1)],
                content: NSRange(location: index + 2, length: end - index - 2)))
            index = end + 1
        }
        return spans
    }

    /// True if the pattern is a **definition** and not a reference: only
    /// whitespace precedes it on its line, and a `:` follows it immediately.
    private static func isDefinition(utf16: [UInt16], referenceStart: Int, referenceEnd: Int) -> Bool {
        let colon = UInt16(UnicodeScalar(":").value)
        guard referenceEnd + 1 < utf16.count, utf16[referenceEnd + 1] == colon else { return false }

        let newline = UInt16(UnicodeScalar("\n").value)
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        var cursor = referenceStart - 1
        while cursor >= 0 {
            let unit = utf16[cursor]
            if unit == newline { return true }
            guard unit == space || unit == tab else { return false }
            cursor -= 1
        }
        return true
    }
}
