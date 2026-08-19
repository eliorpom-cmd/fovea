// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The status bar: words, characters, reading time (§4.5).
///
/// It sits in the bottom-right corner and **fades out when the mouse is not
/// over it**. §7 asks that the app disappear; a permanent counter in the
/// field of view is exactly the kind of chrome that keeps reminding the
/// user they are writing inside a piece of software.
final class StatusBar: NSView {

    private let label = NSTextField(labelWithString: "")
    private var isHovered = false
    private var goalProgress: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // **The page's background, not a capsule.** The bar floats above the
        // column: in a narrow window, a long line used to pass underneath
        // and the two pieces of text overlapped, illegible. Painting the
        // page's background makes the bar opaque wherever it covers
        // something, and perfectly invisible everywhere else — which is
        // almost always.
        applyLayerBackground(Theme.NS.window)
        layer?.cornerRadius = Theme.Radius.control

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = Theme.NS.labelTertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.s10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
        alphaValue = 0.55
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used: no view comes from a xib") }

    /// **Transparent to events.**
    ///
    /// The bar floats above the column, and it is added after the scroll
    /// view: it used to receive clicks and scroll-wheel events before the
    /// text did. In the default window — 820 points, a 612-point column —
    /// it covers the right part of the column: clicking at the bottom right
    /// of the document did not place the caret, and the scroll wheel did
    /// nothing there.
    ///
    /// A counter is decorative: it has no reason to intercept anything.
    /// Tracking areas, by contrast, are geometric and keep reporting the
    /// pointer's entry and exit.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Content

    func update(_ statistics: WritingModes.Statistics, goal: Int, isSelection: Bool) {
        let words = statistics.words
        var parts: [String] = []

        if goal > 0 {
            parts.append("\(words) / \(goal) words")
            goalProgress = min(1, Double(words) / Double(goal))
        } else {
            parts.append(words == 1 ? "1 word" : "\(words) words")
            goalProgress = 0
        }
        parts.append(statistics.characters == 1 ? "1 character" : "\(statistics.characters) characters")
        if statistics.readingMinutes > 0 {
            parts.append("\(statistics.readingMinutes) min read")
        }
        // A selection changes the meaning of the numbers: saying so avoids
        // making it look like the document shrank.
        if isSelection { parts.append("selection") }

        label.stringValue = parts.joined(separator: "  ·  ")
        needsDisplay = true
    }

    // MARK: - Appearance

    /// The background is resolved at layout time: see
    /// `applyLayerBackground(_:)`. A window opened while the app's theme
    /// differs from the system's used to produce a **dark gray capsule**
    /// sitting on a white page here.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerBackground(Theme.NS.window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLayerBackground(Theme.NS.window)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard goalProgress > 0 else { return }
        // The session goal is rendered as a simple rule under the text.
        // No celebration, no confetti (§4.5): the user is writing, not
        // playing.
        let width = bounds.width * goalProgress
        let rule = NSRect(x: 0, y: 0, width: width, height: 1.5)
        Theme.NS.labelTertiary.setFill()
        rule.fill()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        animateAlpha()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        animateAlpha()
    }

    private func animateAlpha() {
        let target = isHovered ? 1.0 : 0.55
        // "Reduce motion" is a need, not a preference (§8): the state
        // changes, only the motion disappears.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = target
        }
    }
}
