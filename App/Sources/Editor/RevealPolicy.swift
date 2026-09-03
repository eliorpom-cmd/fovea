// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import Foundation

/// Decides which markers are visible, based on where the caret is.
///
/// This is the app's key function reduced to its simplest form: a pure
/// function, without AppKit, fully testable.
///
/// # The rule and its unexpected consequence
///
/// A construct reveals when the caret touches `[start, end]`, **bounds
/// included**. The choice of bounds is not cosmetic: it makes navigation
/// reversible:
///
/// ```
/// A word **important** here
/// 0123456789...
///        ^7        ^18,19   the construct occupies [7, 20]
/// ```
///
/// Moving forward, the caret reaches 7: `7 ∈ [7, 20]`, and the `**` appear.
/// At 20 they are still there; at 21 they disappear. Moving backward from
/// 21, the caret passes through 20 again and they reappear at the same
/// spot. **A right arrow followed by a left arrow always returns to the
/// starting state** — which would be false with an open interval, where
/// entry and exit would not happen at the same position.
///
/// The consequence matters even more, and it corrected §2.3:
/// **any position inside a marker belongs to the interval of its own
/// construct**, so that construct is revealed, so its markers are visible.
/// In other words, the caret can never sit inside a hidden marker. The
/// "invisible positions" the original design promised to work around by intercepting
/// every `NSTextView` movement command **do not exist**.
///
/// # What real-world use corrected: line-scoped constructs moved too much
///
/// The first version revealed a line-scoped construct — `#`, `>`, `-` — as
/// soon as the caret was **anywhere on its line**. The rule is easy to
/// state, and it is what made the app unpleasant to use: moving down
/// through a document made the text jump right, then back, on *every*
/// heading, list and blockquote line crossed. The `## ` of a heading spans
/// about forty points at heading-2 size: the text shifted by three
/// characters on every down arrow.
///
/// The rule is now **the same as for inline, applied to markers**: a
/// line-scoped construct reveals when the caret touches one of its markers,
/// bounds included. Two properties follow:
///
/// - The invariant from §2.3 still holds, and for the same reason as
///   before: any position *inside* a marker touches that marker.
/// - Navigating vertically through the middle of lines no longer reveals
///   anything, so nothing moves. The `##` only shows up when going to fetch
///   it, at the start of the line — which is where editing it takes place
///   anyway.
///
/// # The latch: not closing back up under the fingers
///
/// The rule above, on its own, reopened a symmetrical bug: after a `⏎` that
/// continues a list, the caret sits right after the freshly inserted `- `,
/// so the marker is revealed — and it would hide again **at the first
/// letter typed**, shifting the line at the worst possible moment.
///
/// Hence `linePrefixesLatched`: once a line's prefixes are revealed, they
/// stay revealed as long as the caret does not leave that line. The state
/// is therefore no longer a pure function of position; it depends on the
/// path taken — but only in the one sense that matters, the one that
/// **removes** movement: the latch never reveals anything that would not
/// already be revealed.
enum RevealPolicy {

    /// The indices, in `spans`, of the constructs whose markers must be
    /// visible.
    ///
    /// - Parameters:
    ///   - spans: every construct in the document, in any order.
    ///   - selection: the current selection; a zero length is a caret.
    ///   - lineRange: the range of the line the caret is on, terminator
    ///     excluded. Used for the latch on line-scoped constructs.
    ///   - linePrefixesLatched: true when `lineRange`'s prefixes are
    ///     already revealed and the caret has not left that line since.
    static func revealedIndices(spans: [SyntaxSpan],
                                selection: NSRange,
                                lineRange: NSRange,
                                linePrefixesLatched: Bool = false) -> Set<Int> {
        revealedIndices(index: SpanIndex(spans), selection: selection, lineRange: lineRange,
                        linePrefixesLatched: linePrefixesLatched)
    }

    /// The same decision, but by consulting an index instead of scanning.
    ///
    /// This is the path taken on every arrow key press. Linear scanning
    /// cost 3.3 ms on a 100,000-word document — for a one-millisecond
    /// budget, on the app's most frequent operation.
    static func revealedIndices(index: SpanIndex,
                                selection: NSRange,
                                lineRange: NSRange,
                                linePrefixesLatched: Bool = false) -> Set<Int> {
        let caret = selection.location
        var revealed = Set<Int>()
        var innermost: (index: Int, length: Int)?

        for candidate in index.candidates(near: caret, line: lineRange) {
            let span = index.spans[candidate]
            switch span.kind.revealScope {
            case .innermostInline:
                if selection.length == 0, holdsCaretInAMarker(span, caret: caret) {
                    revealed.insert(candidate)
                }
                guard !span.markers.isEmpty, encloses(span.range, selection) else { continue }
                if innermost == nil || span.range.length < innermost!.length {
                    innermost = (candidate, span.range.length)
                }
            case .wholeLine:
                if revealsLinePrefix(span, caret: caret, line: lineRange, latched: linePrefixesLatched) {
                    revealed.insert(candidate)
                }
            case .wholeBlock:
                // A delimited block does not reveal under a selection: its
                // two fences are whole lines, and making them reappear in
                // the middle of a mouse drag would vertically shift what the
                // user is aiming at.
                if selection.length == 0, contains(span.range, caret) {
                    revealed.insert(candidate)
                }
            }
        }
        if let innermost { revealed.insert(innermost.index) }
        return revealed
    }

    /// Is the caret **inside** one of this construct's markers?
    ///
    /// # The gap this test closes
    ///
    /// "The innermost wins" was enough as long as two inline constructs did
    /// not contend for the same range. Two real cases do:
    ///
    /// - `***bold and italic***`. cmark renders an emphasis whose content is
    ///   *exactly* the bold it wraps. The emphasis therefore has **no
    ///   marker** — the complement is empty — but the same length as the
    ///   bold. At equal length it came first, won the contest, and the
    ///   bold's three asterisks stayed hidden **with the caret inside
    ///   them**.
    /// - `[link **bold**](https://example.com)`. At the position right
    ///   after `**bold**`, the caret touches both the end of the bold —
    ///   bounds included — and the start of the link's `](…)`. The shorter
    ///   bold won; the link's marker stayed hidden with the caret inside it.
    ///
    /// Both were exactly what §2.3 declared impossible. The rule therefore
    /// becomes: **a marker that contains the caret is revealed, no matter
    /// what**, and the innermost-wins contest only decides the rest. This is
    /// the only priority order that makes the invariant true by
    /// construction, and `FidelityTests` verifies it at every position of
    /// every document in the corpus.
    ///
    /// `NSLocationInRange`, not `contains`: a marker's upper bound is the
    /// position right after it, not a position *inside* it.
    private static func holdsCaretInAMarker(_ span: SyntaxSpan, caret: Int) -> Bool {
        span.markers.contains { NSLocationInRange(caret, $0) }
    }

    /// Does a line-scoped construct show its markers?
    ///
    /// The test looks at the **markers**, not the range: a ten-line
    /// blockquote sets one marker per line, and it is the one on the
    /// caret's line that decides. Without this restriction, being on the
    /// first line of a long block would be enough to reveal the other nine.
    private static func revealsLinePrefix(_ span: SyntaxSpan,
                                          caret: Int,
                                          line: NSRange,
                                          latched: Bool) -> Bool {
        for marker in span.markers {
            guard contains(line, marker.location) else { continue }
            // Bounds included, exactly as for inline: this guarantees that
            // no position of a hidden marker is reachable.
            if contains(marker, caret) { return true }
        }
        // The latch only applies to the line where it was set, and only to
        // the constructs on it — otherwise a heading would keep its hashes
        // while typing three lines further down.
        return latched && intersects(span.range, line) && contains(line, caret)
    }

    /// Membership **bounds included** — that is the whole point of the
    /// rule. `NSLocationInRange` excludes the upper bound and is therefore
    /// unsuitable.
    static func contains(_ range: NSRange, _ location: Int) -> Bool {
        location >= range.location && location <= range.location + range.length
    }

    /// Does the construct cover **all** of the selection, bounds included?
    ///
    /// On a caret — zero length — this is exactly `contains`. On a
    /// selection, this replaces the old "a selection reveals nothing" rule:
    /// keeping the markers of a construct that contains the whole selection
    /// does not make any syntax *appear*, since the caret was already
    /// showing them before the selection extended. What disappears is the
    /// line jump on every `⇧→` inside a bold word. A selection that extends
    /// past the construct, on the other hand, still reveals nothing: that
    /// is the case of a mouse drag, where the text must not move under the
    /// pointer.
    static func encloses(_ range: NSRange, _ selection: NSRange) -> Bool {
        selection.location >= range.location && selection.upperBound <= range.upperBound
    }

    private static func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        let start = max(a.location, b.location)
        let end = min(a.location + a.length, b.location + b.length)
        return start <= end
    }
}
