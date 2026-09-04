// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import Foundation

/// Finds the URLs written bare, without any markdown around them.
///
/// # Why a homemade pass, again
///
/// `cmark-gfm` has the autolink extension. `swift-markdown` does not expose
/// it: verified, `https://example.com` in the middle of a paragraph comes out
/// as plain `Text`, exactly like `[^1]` does (see `Footnotes`). Everywhere
/// else the same file is read — GitHub first of all — that address is a
/// working link, so the app was showing *less* than the plainest possible
/// renderer of the same text.
///
/// # Where it stops
///
/// GFM's rule, kept to its useful part: the address runs to the first space
/// or angle bracket, then trailing punctuation is given back to the sentence.
/// `See https://example.com.` links `https://example.com` and leaves the full
/// stop where it belongs; a closing parenthesis is only kept when the address
/// opened one, which is what makes a Wikipedia URL survive being written
/// inside brackets.
enum Autolinks {

    /// - Parameter claimed: the ranges that already belong to somebody —
    ///   every construct the parser produced, plus code. A URL inside
    ///   `[text](url)`, inside `<https://…>` or inside a fenced block is
    ///   already spoken for, and a second span over it would fight the first
    ///   one for the same characters.
    static func scan(utf16: [UInt16], skipping claimed: [NSRange]) -> [SyntaxSpan] {
        var spans: [SyntaxSpan] = []
        var index = 0

        while index < utf16.count {
            guard startsAnAddress(utf16: utf16, at: index) else {
                index += 1
                continue
            }

            var end = index
            while end < utf16.count, !isBoundary(utf16[end]) { end += 1 }
            end = trimmingTrailingPunctuation(utf16: utf16, from: index, to: end)

            let range = NSRange(location: index, length: end - index)
            guard isAddress(utf16: utf16, in: range) else {
                index += 1
                continue
            }
            if claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                index = max(end, index + 1)
                continue
            }

            // No markers: there is no syntax to hide, the address *is* the
            // text. It renders underlined and opens on `⌘`-click like any
            // other link, and the reveal rule has nothing to reveal.
            let destination = String(decoding: utf16[range.location..<range.upperBound], as: UTF16.self)
            spans.append(SyntaxSpan(kind: .link(destination: destination),
                                    range: range, markers: [], content: range))
            index = max(end, index + 1)
        }
        return spans
    }

    // MARK: - Where an address begins

    private static let schemes = ["http://", "https://", "www."]

    /// An address starts at a **word boundary**: without this test, the
    /// `https://` inside `xhttps://example.com` — or, more to the point,
    /// inside an address already found — would open a second one.
    private static func startsAnAddress(utf16: [UInt16], at index: Int) -> Bool {
        guard schemes.contains(where: { matches($0, utf16: utf16, at: index) }) else { return false }
        guard index > 0 else { return true }
        guard let previous = UnicodeScalar(utf16[index - 1]) else { return true }
        return !CharacterSet.alphanumerics.contains(previous)
            && !"/:@.-".unicodeScalars.contains(previous)
    }

    private static func matches(_ prefix: String, utf16: [UInt16], at index: Int) -> Bool {
        let units = Array(prefix.utf16)
        guard index + units.count <= utf16.count else { return false }
        for (offset, unit) in units.enumerated() {
            // The scheme is case-insensitive: `HTTPS://` is an address too.
            guard lowercased(utf16[index + offset]) == unit else { return false }
        }
        return true
    }

    private static func lowercased(_ unit: UInt16) -> UInt16 {
        (unit >= 65 && unit <= 90) ? unit + 32 : unit
    }

    // MARK: - Where it ends

    /// A space, a tab, a line ending or an angle bracket closes an address.
    private static func isBoundary(_ unit: UInt16) -> Bool {
        unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 60 || unit == 62
    }

    /// Gives back to the sentence the punctuation that ends it.
    private static func trimmingTrailingPunctuation(utf16: [UInt16], from start: Int, to end: Int) -> Int {
        var end = end
        let closing = UInt16(UnicodeScalar(")").value)
        let opening = UInt16(UnicodeScalar("(").value)
        let trailing = Set("?!.,:;*_~'\"]".unicodeScalars.map { UInt16($0.value) })

        while end > start {
            let last = utf16[end - 1]
            if trailing.contains(last) {
                end -= 1
            } else if last == closing {
                // Kept only if the address opened it: `(https://example.com)`
                // gives the parenthesis back, `https://en.wikipedia.org/wiki/A_(b)`
                // keeps it.
                let opens = utf16[start..<end].filter { $0 == opening }.count
                let closes = utf16[start..<end].filter { $0 == closing }.count
                if closes > opens { end -= 1 } else { break }
            } else {
                break
            }
        }
        return end
    }

    /// Is what was found long enough to be an address at all?
    ///
    /// `https://` on its own is not one, and neither is `www.` — an address
    /// needs a host, and a `www.` one needs the dot that follows it to be
    /// followed by something.
    private static func isAddress(utf16: [UInt16], in range: NSRange) -> Bool {
        let text = String(decoding: utf16[range.location..<range.upperBound], as: UTF16.self).lowercased()
        if text.hasPrefix("www.") { return text.dropFirst(4).contains(".") }
        guard let host = text.components(separatedBy: "://").last else { return false }
        return host.contains(".")
    }
}
