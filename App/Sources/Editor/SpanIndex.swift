// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import Foundation

/// Quickly finds the constructs near a position.
///
/// # Why
///
/// On every arrow key press, `RevealPolicy` needs to know which constructs
/// touch the caret. Scanning all of them turned the app's most frequent
/// operation into its most expensive: **3.3 ms on a 100,000-word document**,
/// against a one-millisecond budget (§9). A document of that size holds tens
/// of thousands of constructs, of which the caret never touches more than
/// three.
///
/// # How
///
/// Constructs are split into two families, because they're searched for
/// differently:
///
/// - **The short ones** — inline and line-scoped. Numerous but brief: a
///   `**bold**` run is fifteen characters, a list item one line. Sorted by
///   position, they're found by binary search, then by a backward step
///   bounded by the longest one among them.
/// - **The long ones** — code blocks, tables, front matter. They can span
///   half the document, which would make the bound useless; but there are
///   only a handful of them, and scanning them costs nothing.
struct SpanIndex {

    let spans: [SyntaxSpan]

    /// Indices of the short constructs, sorted by start position.
    private let shortOrder: [Int]
    /// The longest of the short constructs: the maximum distance to walk
    /// back from the caret.
    private let longestShort: Int
    /// Indices of the long constructs, scanned as-is.
    private let longIndices: [Int]

    init(_ spans: [SyntaxSpan]) {
        self.spans = spans

        var short: [Int] = []
        var long: [Int] = []
        var longest = 0
        short.reserveCapacity(spans.count)

        for (index, span) in spans.enumerated() {
            switch span.kind.revealScope {
            case .wholeBlock:
                long.append(index)
            case .innermostInline, .wholeLine:
                short.append(index)
                longest = max(longest, span.range.length)
            }
        }
        // `sorted` on an already-sorted list still costs a full sort — on
        // every keystroke, over tens of thousands of constructs. But
        // `MarkdownParser.splice` maintains the order by position: the
        // common case is therefore to have nothing to sort, and that has to
        // be recognized.
        self.shortOrder = SpanIndex.isSorted(short, in: spans)
            ? short
            : short.sorted { spans[$0].range.location < spans[$1].range.location }
        self.longestShort = longest
        self.longIndices = long
    }

    /// The constructs that might be relevant to this position.
    ///
    /// The final filtering — inclusive bounds, nesting — is left to
    /// `RevealPolicy`: this index prunes, it doesn't decide.
    func candidates(near location: Int, line: NSRange) -> [Int] {
        var result = longIndices

        // The useful zone runs from the start of the line (for line-scoped
        // constructs) to the caret, extended backward by the longest short
        // construct — beyond that, none can still reach the caret.
        let lowerBound = min(line.location, location) - longestShort
        let upperBound = max(line.upperBound, location)

        var position = firstIndex(withLocationAtLeast: lowerBound)
        while position < shortOrder.count {
            let candidate = shortOrder[position]
            guard spans[candidate].range.location <= upperBound else { break }
            result.append(candidate)
            position += 1
        }
        return result
    }

    private static func isSorted(_ order: [Int], in spans: [SyntaxSpan]) -> Bool {
        for position in 1..<max(1, order.count)
        where spans[order[position]].range.location < spans[order[position - 1]].range.location {
            return false
        }
        return true
    }

    /// Binary search over `shortOrder`.
    private func firstIndex(withLocationAtLeast target: Int) -> Int {
        var low = 0
        var high = shortOrder.count
        while low < high {
            let middle = (low + high) / 2
            if spans[shortOrder[middle]].range.location < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
