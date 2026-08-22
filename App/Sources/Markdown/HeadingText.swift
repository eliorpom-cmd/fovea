// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import Foundation

/// A heading as it **reads**, rather than as it is written.
///
/// The command palette lists every heading in the document alongside its
/// commands. It used to list the **source**: `## 2. Tasks — see **2 — Notes**`
/// appeared there with its asterisks, the one place in the app that let them
/// show, while everything else is built to keep them silent.
///
/// These functions lived on `OutlinePanel` while the outline panel existed.
/// They belong to the Markdown layer: they are pure functions of spans and
/// text, with no interface, and that is the layer tested without one.
enum HeadingText {

    /// Every inline marker in the document, sorted, computed **once**.
    ///
    /// Filtering the constructs per heading was quadratic: with two thousand
    /// headings and two thousand constructs, that was four million tests, on
    /// every keystroke. The markers do not depend on any particular heading —
    /// each one only takes its own slice of them.
    static func inlineMarkers(of spans: [SyntaxSpan]) -> [NSRange] {
        spans
            .filter { $0.kind.revealScope == .innermostInline }
            .flatMap(\.markers)
            .sorted { $0.location < $1.location }
    }

    static func plainText(of content: NSRange, spans: [SyntaxSpan], text: NSString) -> String {
        plainText(of: content, markers: inlineMarkers(of: spans), text: text)
    }

    /// Reference version, by scanning.
    ///
    /// Kept on the model of `RevealPolicy.revealedIndicesByScan`: it is the
    /// literal definition — "strip from this heading the markers that run
    /// through it" — and the tests use it to verify that the fast version
    /// renders exactly the same text.
    static func plainTextByScan(of content: NSRange, spans: [SyntaxSpan], text: NSString) -> String {
        let cuts = spans
            .filter { $0.kind.revealScope == .innermostInline
                      && NSIntersectionRange($0.range, content).length > 0 }
            .flatMap(\.markers)
            .filter { NSIntersectionRange($0, content).length > 0 }
            .sorted { $0.location < $1.location }

        var result = ""
        var index = content.location
        for cut in cuts where cut.location >= index {
            if cut.location > index {
                result += text.substring(with: NSRange(location: index, length: cut.location - index))
            }
            index = max(index, cut.upperBound)
        }
        if index < content.upperBound {
            result += text.substring(with: NSRange(location: index, length: content.upperBound - index))
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func plainText(of content: NSRange, markers: [NSRange], text: NSString) -> String {
        // The first marker that can touch the content, by binary search: the
        // list is sorted, and a heading near the bottom of a long document
        // has no reason to scan all the ones before it.
        var low = 0
        var high = markers.count
        while low < high {
            let middle = (low + high) / 2
            if markers[middle].upperBound <= content.location { low = middle + 1 } else { high = middle }
        }

        var result = ""
        var index = content.location
        for cut in markers[low...] {
            guard cut.location < content.upperBound else { break }
            guard cut.location >= index else { continue }
            if cut.location > index {
                result += text.substring(with: NSRange(location: index, length: cut.location - index))
            }
            index = max(index, cut.upperBound)
        }
        if index < content.upperBound {
            result += text.substring(with: NSRange(location: index, length: content.upperBound - index))
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
