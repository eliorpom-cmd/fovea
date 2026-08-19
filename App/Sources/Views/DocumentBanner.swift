// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// A **non-blocking** banner, at the top of the text column (§6).
///
/// # Why a banner and not an alert
///
/// Three states from §6 must be communicated without interrupting: a large
/// document, an encoding that will be converted, a read-only file. None of
/// the three calls for an immediate decision — they are facts to know, not
/// questions. A modal alert would force a click before writing, for
/// information the user simply wants to have seen.
///
/// It closes with one click and does not come back for the same document.
/// §7 wants the app to disappear: a permanent banner would be exactly the
/// chrome this seeks to avoid.
@MainActor
final class DocumentBanner: NSView {

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    /// Height constraint: zero when there is nothing to say.
    private var heightConstraint: NSLayoutConstraint!

    private static let visibleHeight: CGFloat = 34

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyLayerBackground(Theme.NS.fillQuaternary)

        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.NS.labelSecondary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.contentTintColor = Theme.NS.labelTertiary
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setAccessibilityLabel("Close banner")

        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = Theme.NS.separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(closeButton)
        addSubview(separator)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor,
                                            constant: -Theme.Space.s12),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.s12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no view comes from a xib") }

    /// Same reason as in the outline: see `applyLayerBackground(_:)`.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerBackground(Theme.NS.fillQuaternary)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLayerBackground(Theme.NS.fillQuaternary)
    }

    var isShowing: Bool { !isHidden }

    /// Shows the messages, joined. Nothing to say closes the banner.
    func show(_ messages: [String]) {
        let text = messages.filter { !$0.isEmpty }.joined(separator: "  ·  ")
        guard !text.isEmpty else {
            dismiss()
            return
        }
        label.stringValue = text
        setAccessibilityLabel(text)
        isHidden = false
        heightConstraint.constant = Self.visibleHeight
        // §8: the banner still appears if animations are reduced, it simply
        // does not slide in.
        Accessibility.animate(0.18) { superview?.layoutSubtreeIfNeeded() }
    }

    @objc func dismiss() {
        guard !isHidden else { return }
        heightConstraint.constant = 0
        // `isHidden` is set **at the end**, not before: applied right away,
        // it made the banner disappear all at once and the animation that
        // follows collapsed a view already invisible. The banner jumped
        // instead of closing, and the slide written just above never showed.
        Accessibility.animate(0.18) { superview?.layoutSubtreeIfNeeded() } completion: {
            MainActor.assumeIsolated { [weak self] in
                // A `show` may have happened in the meantime: only what
                // actually stayed collapsed gets hidden.
                guard let self, heightConstraint.constant == 0 else { return }
                isHidden = true
            }
        }
    }
}

// MARK: - The §6 messages

extension DocumentBanner {

    /// What there is to say about a document when it opens, or nothing.
    ///
    /// The function is pure and made public so it can be tested: these are
    /// sentences the user will read, and their accuracy matters as much as
    /// that of the code that triggers them.
    nonisolated static func messages(byteCount: Int,
                                     encoding: String.Encoding,
                                     isWritable: Bool) -> [String] {
        var result: [String] = []

        if !isWritable {
            // §6: the document opens and stays editable in memory. What will
            // not work is saving — and it is better to learn that before
            // writing three pages.
            result.append("Read-only file. Use \"Save As…\" "
                          + "to keep your changes.")
        }
        if byteCount > 1_000_000 {
            // The app never switches on its own (§6): it informs.
            result.append("Large document. Source mode (⌥⌘S) will be smoother.")
        }
        if encoding != .utf8 {
            result.append("File read as \(name(of: encoding)). It will be converted "
                          + "to UTF-8 when saved.")
        }
        return result
    }

    private nonisolated static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        case .windowsCP1252: "Windows-1252"
        case .isoLatin1: "ISO-8859-1"
        case .utf16LittleEndian, .utf16BigEndian, .utf16: "UTF-16"
        case .macOSRoman: "Mac OS Roman"
        default: "another encoding"
        }
    }
}
