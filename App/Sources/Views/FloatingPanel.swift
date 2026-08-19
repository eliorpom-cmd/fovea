// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The common base of panels anchored to the caret.
///
/// # Why a base class
///
/// The slash menu came first; the language picker and the table grid are
/// next, and there will be others — a selection bar, a link bubble, table
/// tools. Writing the same panel four times means guaranteeing four
/// slightly different behaviors for the keyboard and for closing. Everything
/// below is therefore decided **once**.
///
/// # The contract, in three rules
///
/// 1. **It never takes focus.** `nonactivatingPanel`, `canBecomeKey` set to
///    `false`: the caret stays in the text, keystrokes keep going into the
///    buffer, and the panel just follows along. This is what makes it
///    possible to type `/tab` and watch the list narrow down without ever
///    switching modes.
/// 2. **Keystrokes reach it through the text view.** Since it is never the
///    key window, it receives nothing from the system: `EditorTextView.keyDown`
///    forwards the arrow keys, `⏎` and `⎋` to it.
/// 3. **It anchors to a rectangle in screen coordinates** — the caret's,
///    obtained from `firstRect(forCharacterRange:)` — and flips above the
///    line once there is no more room below.
@MainActor
class FloatingPanel: NSPanel {

    /// The blurred view that carries the content. Subclasses add their own to it.
    let container = NSVisualEffectView()

    init(width: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isMovable = false
        hidesOnDeactivate = true
        // Without this, a tracking area set up with `.mouseMoved` receives
        // nothing: AppKit only *produces* move events for windows that
        // accept them, and the default is `false`. The grid's whole premise
        // is "hover, watch the grid fill in, click" — hovering used to fill
        // in nothing.
        acceptsMouseMovedEvents = true

        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        contentView = container
    }

    /// It never becomes key: that is the whole point. Without this `false`,
    /// the caret would leave the text as soon as it opens.
    override var canBecomeKey: Bool { false }

    var isOpen: Bool { isVisible }

    /// Places the panel below the caret, or above it if it would overflow
    /// the screen.
    ///
    /// - Parameter caretRect: the caret's position **in screen coordinates**.
    func present(size: NSSize, caretRect: NSRect, over host: NSWindow?) {
        // Below the current line, nudged by a hair: placed right on top of
        // it, the panel would hide the word currently being typed.
        // **A zero rectangle is not a position, it is the absence of an
        // answer.** `firstRect(forCharacterRange:)` returns one when no
        // input session is active — which is the case when the command
        // comes from the menu bar. The calculation below used to take that
        // literally: the origin landed at zero, the fallback to flip upward
        // pulled it right to the edge, and the panel ended up in the bottom
        // left corner of the screen, half under the Dock. Technically
        // displayed, unfindable in practice.
        //
        // The position is not guessed in its place: the upper third of the
        // window is used instead, where the eye already is.
        let anchor = caretRect == .zero ? fallbackAnchor(size: size, in: host) : caretRect

        // **It shrinks before it flips.**
        //
        // The rule used to be "no room below, switch to above." The panel
        // then landed **on top of the lines just written**: in a window 520
        // points tall, opening the menu near the bottom of the page hid the
        // previous eight lines — that is, the list currently being continued.
        //
        // A menu anchored to the caret reads below the caret. When space
        // runs out, what should shrink is its height — it scrolls — not the
        // text it covers. It only flips once there is not even room left to
        // show three entries.
        var height = size.height
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - height - 6)

        if let screen = host?.screen ?? NSScreen.main {
            let floor = screen.visibleFrame.minY + 8
            let roomBelow = anchor.minY - 6 - floor
            let roomAbove = screen.visibleFrame.maxY - 8 - (anchor.maxY + 6)

            if origin.y < floor {
                if roomBelow >= Self.minimumShrunkHeight {
                    height = min(height, roomBelow)
                    origin.y = anchor.minY - height - 6
                } else {
                    height = min(height, max(Self.minimumShrunkHeight, roomAbove))
                    origin.y = anchor.maxY + 6
                }
            }
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8),
                           screen.visibleFrame.maxX - size.width - 8)
        }
        setFrame(NSRect(origin: origin, size: NSSize(width: size.width, height: max(1, height))),
                 display: true)

        if !isVisible {
            host?.addChildWindow(self, ordered: .above)
            orderFront(nil)
        }
    }

    /// Below this, shrinking further serves no purpose: three entries.
    private static let minimumShrunkHeight: CGFloat = 90

    /// Where to place a panel with no caret to latch onto: the upper third
    /// of the window, centered. Not the caret's position, but it is in view
    /// and within the document — which a corner of the screen is not.
    private func fallbackAnchor(size: NSSize, in host: NSWindow?) -> NSRect {
        guard let frame = host?.frame else {
            let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            return NSRect(x: screen.midX - size.width / 2, y: screen.midY, width: 1, height: 1)
        }
        return NSRect(x: frame.midX - size.width / 2,
                      y: frame.minY + frame.height * 2 / 3,
                      width: 1, height: 1)
    }

    func dismiss() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
