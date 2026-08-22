// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// A list row, selected **in gray** rather than in blue.
///
/// # Why this file exists
///
/// `NSTableView` paints its selection with the system's accent color, that
/// is, blue. It was the last accent color left in the app, in the three
/// list the user sees: the slash menu.
/// §7 only allows colour on the user's own content — their
/// images, their code blocks colored on request — and `Theme` already
/// claimed to neutralize the system selection without any list actually
/// applying it.
///
/// There is no setting for this: `selectionHighlightStyle` only offers
/// `.regular` — blue — or `.none` — nothing. Gray therefore has to be drawn
/// by hand, which fits in one method.
///
/// The rounded corner is not decorative: without it, the gray band touches
/// the edges of the panel and reads as a divider rather than as a selection.
final class ListRowView: NSTableRowView {

    /// Horizontal margin left on each side of the band.
    private static let inset: CGFloat = 4
    private static let radius: CGFloat = 6

    private var isHovered = false

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        fill(with: Theme.NS.rowSelection)
    }

    /// Hover feedback, which was missing everywhere.
    ///
    /// The app's lists did not react
    /// to the pointer passing over them: there was no way to know what would
    /// be clicked before clicking it. `Theme.rowHover` existed, documented,
    /// and was used nowhere.
    ///
    /// It is painted into the **background**, not into the selection: a
    /// selected row being hovered must not stack two grays on top of each
    /// other.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected else { return }
        fill(with: Theme.NS.rowHover)
    }

    private func fill(with color: NSColor) {
        let box = bounds.insetBy(dx: Self.inset, dy: 1)
        color.setFill()
        NSBezierPath(roundedRect: box, xRadius: Self.radius, yRadius: Self.radius).fill()
    }

    /// `.activeAlways`: panels anchored to the caret never become the key
    /// window — that is their whole point — so tracking limited to the
    /// active window would never respond there.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    /// Rows are recycled: without this reset, a hover state left stuck would
    /// light back up on a different entry after scrolling.
    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    /// The text color does not change when the row is selected.
    ///
    /// `NSTableView` switches its labels to white on the blue selection,
    /// which would make them illegible on a light gray. It is therefore told
    /// that the row is never "emphasized" in the system's sense: it is, in
    /// its own way, through the background just painted.
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}
