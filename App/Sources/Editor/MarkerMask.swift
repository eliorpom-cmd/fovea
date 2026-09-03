// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import AppKit

extension NSAttributedString.Key {
    /// Marks a range as a **currently hidden markdown marker**.
    ///
    /// The attribute has no visual effect by itself: it is a flag set
    /// alongside the attributes that actually make the range invisible. It
    /// lets the rest of the editor — smart delete (§2.5), accessibility
    /// (§8), export — know what is syntax and what is content, without
    /// having to re-parse.
    static let foveaMasked = NSAttributedString.Key("foveaMasked")

    /// Marks a range as a **revealed markdown marker**: it belongs to the
    /// construct the caret is currently touching (§2.2).
    static let foveaRevealed = NSAttributedString.Key("foveaRevealed")
}

/// The mechanism that makes markers disappear.
///
/// # The milestone-0 bet
///
/// §3.4 lays out two possible mechanisms without settling on
/// either. The one chosen is **A — zero-width rendering**: markers stay in
/// the buffer *and* in the display string, but receive an infinitesimal
/// font size and a transparent color.
///
/// The decisive advantage is that **the buffer's ranges and the display's
/// ranges stay identical**. Selection, `NSTextFinder`, `NSUndoManager`,
/// accessibility and export keep working without any mapping, whereas
/// mechanism B — returning a shorter `NSTextParagraph` from
/// `NSTextContentStorageDelegate` — would have made `NSTextLocation` and the
/// storage offsets diverge across all of those subsystems at once.
///
/// # What the prototype corrected
///
/// §2.3 announced "invisible caret positions" to work around by
/// intercepting every `NSTextView` movement command. **That fear was
/// unfounded**, and it is the reveal rule that cancels it: a construct
/// reveals as soon as the caret touches `[start, end]`, bounds included.
/// Any position inside a marker is, by construction, within that interval.
/// So **when a marker is hidden, the caret cannot be inside it**, and there
/// is nothing to intercept.
///
/// See `RevealPolicy` for the proof, and `MarkerMaskTests` for the
/// exhaustive check on a real document.
///
/// `@MainActor` because masking resolves `NSFont` and reads the system's
/// accessibility settings: AppKit is not thread-safe, and this layer is in
/// any case only called from rendering, itself on the main thread.
@MainActor
enum MarkerMask {

    /// Not zero: `NSFont` accepts 0, but TextKit then produces degenerate
    /// metrics, and a `NaN` width propagates all the way to the caret rect.
    /// An infinitesimal size gives an advance under a tenth of a point,
    /// invisible at any screen scale.
    static let hiddenFontSize: CGFloat = 0.01

    /// Makes a range invisible and zero-width.
    ///
    /// The substitute font is deliberately the system font, not the
    /// surrounding text's font: at 0.01 pt nothing gets drawn, and loading
    /// the real font at an absurd size would cost a cache entry per
    /// (font, size) pair for nothing.
    static func hide(in storage: NSTextStorage, range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttributes([
            .font: NSFont.systemFont(ofSize: hiddenFontSize),
            .foregroundColor: NSColor.clear,
            // Without this explicit reset, kerning inherited from the
            // surrounding text would survive and make the range a few
            // tenths of a point wide — enough for a `**` to visibly shift a
            // heading line.
            .kern: 0,
            .foveaMasked: true,
        ], range: range)
        storage.removeAttribute(.foveaRevealed, range: range)
    }

    /// Makes a range invisible while imposing **a chosen width** on it.
    ///
    /// This is what lets the table grid exist without a single character
    /// being added to the file (§3.1): the `|` that separates two cells no
    /// longer draws, but its advance is computed to place the next column
    /// exactly where it must land. The kerning carries that advance; the
    /// infinitesimal font cancels the glyph's own.
    static func hide(in storage: NSTextStorage, range: NSRange, advance: CGFloat) {
        guard range.length > 0 else { return }
        storage.addAttributes([
            .font: NSFont.systemFont(ofSize: hiddenFontSize),
            .foregroundColor: NSColor.clear,
            .kern: max(0, advance),
            .foveaMasked: true,
        ], range: range)
        storage.removeAttribute(.foveaRevealed, range: range)
    }

    /// Makes a range invisible **without shrinking its width or its
    /// height**.
    ///
    /// For a line whose *entire* content is a marker — the `---` of a
    /// horizontal rule — ordinary masking would collapse the line height,
    /// since no character would carry the normal font anymore. The rule
    /// would then have nowhere to draw itself.
    ///
    /// Here the font stays the body font and only the color becomes
    /// transparent: the line keeps its place, and `DecorationPainter` draws
    /// the line there.
    static func hideKeepingMetrics(in storage: NSTextStorage, range: NSRange, font: NSFont) {
        guard range.length > 0 else { return }
        storage.addAttributes([
            .font: font,
            .foregroundColor: NSColor.clear,
            .foveaMasked: true,
        ], range: range)
        storage.removeAttribute(.foveaRevealed, range: range)
    }

    /// Displays a range of markers, understated: present, never loud.
    ///
    /// The surrounding text does not change style — the word stays bold
    /// while its `**` reappear (§2.1).
    static func reveal(in storage: NSTextStorage, range: NSRange, font: NSFont) {
        guard range.length > 0 else { return }
        storage.addAttributes([
            .font: font,
            // §8: below the AA threshold, and deliberately so — these are
            // cues, not content. When "Increase contrast" is active, the
            // user has said they do not want this trade-off.
            .foregroundColor: Accessibility.markerColor,
            .kern: 0,
            .foveaRevealed: true,
        ], range: range)
        storage.removeAttribute(.foveaMasked, range: range)
    }

    static func isMasked(_ storage: NSTextStorage, at location: Int) -> Bool {
        guard location >= 0, location < storage.length else { return false }
        return storage.attribute(.foveaMasked, at: location, effectiveRange: nil) != nil
    }

    /// The hidden range containing `location`, if there is one.
    ///
    /// Useful to smart delete (§2.5) and to tests, which need to assert
    /// that a given position is *not* inside something hidden.
    static func maskedRange(in storage: NSTextStorage, at location: Int) -> NSRange? {
        guard location >= 0, location < storage.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard storage.attribute(.foveaMasked, at: location, effectiveRange: &range) != nil else { return nil }
        return range
    }
}
