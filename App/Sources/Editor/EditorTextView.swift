// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The editing view.
///
/// It stays deliberately thin: everything that touches markdown lives in
/// `EditorController`. This file only handles what an `NSTextView` gets
/// wrong by default for a markdown editor.
final class EditorTextView: NSTextView {

    /// Called when `⌫` must delete an entire construct rather than a single
    /// marker character (§2.5). Returns `true` if the deletion was handled.
    var handlesDeleteBackward: ((NSRange) -> Bool)?

    /// The marks drawn behind the text: bullets, blockquote bars, horizontal
    /// rules, code block backgrounds. See `EditorDecoration`.
    var decorations: [EditorDecoration] = [] {
        didSet {
            needsDisplay = true
            // Checkboxes set up pointer areas: they move as soon as the text
            // changes, so AppKit has to be asked to recompute them.
            //
            // But only checkboxes. The callback used to fire on every
            // keystroke, even in a document that doesn't contain a single
            // task, and `resetCursorRects` queries the layout for every
            // visible checkbox.
            if Self.hasCheckbox(oldValue) || Self.hasCheckbox(decorations) {
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    private static func hasCheckbox(_ decorations: [EditorDecoration]) -> Bool {
        decorations.contains {
            if case .checkbox = $0.kind { return true }
            return false
        }
    }

    /// Reassigned by `EditorController` on every render, hence the guard:
    /// only a genuine change is worth anything.
    var typography: EditorTypography = .default {
        didSet {
            guard typography != oldValue else { return }
            refreshTypingAttributes()
        }
    }

    /// Source mode (§4.2) lays the buffer out in the fixed-pitch font, on
    /// tighter lines. The empty line has to follow, or the caret would
    /// change size the moment the mode is switched.
    var showsSource = false {
        didSet {
            guard showsSource != oldValue else { return }
            refreshTypingAttributes()
        }
    }

    var documentURL: URL?

    /// Callbacks into `EditorController` for keys whose behavior depends on
    /// markdown. Each one returns `true` if it took over.
    var handlesNewline: (() -> Bool)?
    var handlesIndent: ((_ outdent: Bool) -> Bool)?

    /// Called for every character typed, before it is inserted. Used for
    /// auto-pairing. Returns `true` if the character was handled another way.
    var handlesTyping: ((Character) -> Bool)?

    /// Called for a character that was just written and that could **not**
    /// be intercepted beforehand: the output of a dead key. See `insertText`.
    var handlesTypedCharacter: ((Character) -> Void)?

    /// Called on `⌘`+click at a given position: a footnote responds to it by
    /// jumping to its other half.
    var handlesFootnoteJump: ((Int) -> Bool)?

    /// Called when a task's checkbox is clicked. Receives the range of the
    /// item's content, the one the decoration carries.
    var handlesTaskToggle: ((NSRange) -> Bool)?

    // MARK: - Setup

    static func make() -> EditorTextView {
        // TextKit 2 explicitly. The default `NSTextView` can still fall back
        // to TextKit 1 as soon as a compatibility API is touched, and the
        // whole app depends on viewport-based layout.
        let view = EditorTextView(usingTextLayoutManager: true)
        view.configure()
        return view
    }

    private func configure() {
        isRichText = false
        allowsUndo = true
        isEditable = true
        isSelectable = true
        usesFindBar = true
        // **Incremental search stays off.**
        //
        // It doesn't only add highlighting as you type: it also draws
        // `NSTextFinder`'s veil, which dims the **entire** document to opaque
        // gray and leaves only white holes over the results, and paints the
        // current result in system yellow. On a white page, the user's text
        // turns medium gray, the only screen in the app where it stops being
        // readable, and the only saturated color that has ever made it
        // through §7.
        //
        // `NSTextView` doesn't expose its `NSTextFinder`, so
        // `incrementalSearchingShouldDimContentView` isn't reachable either:
        // the only lever is the switch. It gets turned off. `⌘F`, `⌘G` and
        // the result indicator keep working, and the document stays readable
        // while searching through it.
        isIncrementalSearchingEnabled = false

        registerForDraggedTypes([.fileURL])

        // §2.5: no typographic substitution, including macOS's own. In a
        // file destined for git or a site generator, an invisible
        // transformation is a bug, not a service.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        // Spell checking, by contrast, stays on: it underlines without
        // rewriting anything, which is exactly what's expected in a prose
        // editor.
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false

        // The system selection is blue. In a monochrome editor where only
        // the user's own content earns color, it gets neutralized (§7).
        selectedTextAttributes = [.backgroundColor: Theme.NS.selection]

        // Same reason for links: as soon as a range carries a `.link`,
        // `NSTextView` applies **its own** attributes, system blue and
        // underline, on top of whatever the renderer already set. They're
        // replaced with nothing: the link is already underlined in gray by
        // `MarkdownRenderer`.
        linkTextAttributes = [:]

        drawsBackground = true
        backgroundColor = Theme.NS.window
        insertionPointColor = Theme.NS.label
        refreshTypingAttributes()

        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 0, height: Theme.Space.s40)
    }

    // MARK: - The caret

    /// The attributes an empty line is measured with.
    ///
    /// # Why a new line had a caret of its own size
    ///
    /// A view with `isRichText = false` does not take its typing attributes
    /// from the buffer: it rebuilds them from `font`, `textColor` and
    /// `defaultParagraphStyle` — none of which this editor had ever set,
    /// since every attribute it displays is applied to the storage by
    /// `MarkdownRenderer`. They therefore stayed at the `NSTextView`
    /// default, Helvetica 12, and that default is exactly what TextKit
    /// measures a **line with no characters** with. Pressing `⏎` opened a
    /// 12-point line fragment, so a 12-point caret, in a document set in
    /// 16-point type; the first character typed handed the line back to the
    /// render and the caret jumped to its real size.
    ///
    /// Set explicitly, they make the empty line exactly as tall as a full
    /// one, and the caret stops changing size under the fingers.
    private func refreshTypingAttributes() {
        typingAttributes = [
            .font: showsSource ? typography.codeBlock : typography.body,
            .foregroundColor: Theme.NS.label,
            .paragraphStyle: showsSource ? typography.sourceParagraphStyle()
                                         : typography.paragraphStyle(),
        ]
    }

    /// Since macOS 14 the caret is a view, not something drawn: the text
    /// view keeps exactly one, alongside the focus veil.
    private var insertionIndicator: NSTextInsertionIndicator? {
        subviews.lazy.compactMap { $0 as? NSTextInsertionIndicator }.first
    }

    /// The caret, brought back to the height of the text.
    ///
    /// # Why it stood taller than the letters
    ///
    /// Line spacing (§4.7, 1.5 by default) is a `lineHeightMultiple`, and
    /// TextKit spends it *above* the baseline: a 16-point line is laid out
    /// 27 points tall, 9 of which are empty sky over the capitals. The text
    /// view sizes the indicator to the **whole line fragment** — so the
    /// caret filled those 27 points and stood a third of its height above
    /// the tallest letter. It read as a bar placed next to the text rather
    /// than a caret inside it.
    ///
    /// Nothing exposes the caret's height, but the indicator is a public
    /// view, and the frame it is given can be brought back to the text's own
    /// metrics: ascender to descender, standing on the line's baseline.
    /// Everything else about it — blinking, color, the dictation glow — is
    /// left alone.
    private func fitCaretToText() {
        guard let indicator = insertionIndicator else { return }
        let box = indicator.frame
        let font = caretFont()
        let height = (font.ascender - font.descender).rounded()
        // The call comes in bursts — a layout pass, then the blink timer —
        // and lands on its own result: it must not shrink what it already
        // shrank, which is what this comparison rules out.
        guard height < box.height, let baseline = caretBaseline(in: box) else { return }
        indicator.frame = NSRect(x: box.minX, y: (baseline - font.ascender).rounded(),
                                 width: box.width, height: height)
    }

    /// The font the caret must match: the one of the character it stands on.
    ///
    /// Hidden markers are stepped over: they carry a 0.01-point font
    /// (`MarkerMask`), and a caret measured on that has no height at all. At
    /// the very end of the buffer there is no character left to ask, and the
    /// typing attributes are the right answer — they are what the empty line
    /// was measured with in the first place.
    private func caretFont() -> NSFont {
        let fallback = (typingAttributes[.font] as? NSFont) ?? typography.body
        guard let storage = textStorage, storage.length > 0 else { return fallback }
        let caret = selectedRange().location
        for index in [caret, caret - 1] where index >= 0 && index < storage.length {
            let attributes = storage.attributes(at: index, effectiveRange: nil)
            guard attributes[.foveaMasked] == nil,
                  let font = attributes[.font] as? NSFont else { continue }
            return font
        }
        return fallback
    }

    /// The baseline, in the view's coordinates, of the line the caret is on.
    private func caretBaseline(in box: NSRect) -> CGFloat? {
        guard let layout = textLayoutManager else { return nil }
        let origin = textContainerOrigin
        guard let fragment = layout.textLayoutFragment(
            for: NSPoint(x: box.midX - origin.x, y: box.midY - origin.y)) else { return nil }

        // A fragment can hold several lines — a wrapped paragraph is a
        // single fragment — so the one to measure is the line the caret sits
        // in, i.e. the last one that starts above it.
        let top = fragment.layoutFragmentFrame.minY + origin.y
        var line = fragment.textLineFragments.first
        for candidate in fragment.textLineFragments {
            guard top + candidate.typographicBounds.minY <= box.midY + 0.5 else { break }
            line = candidate
        }
        guard let line else { return nil }
        return top + line.typographicBounds.minY + line.glyphOrigin.y
    }

    /// The two moments the text view moves the indicator: a layout pass, and
    /// every caret move or keystroke.
    override func layout() {
        super.layout()
        fitCaretToText()
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        fitCaretToText()
    }

    // MARK: - Decorations

    /// Marks are painted in the background pass, so **behind** the text and
    /// behind the selection highlight. A bullet drawn over the text would
    /// strike through the item's first word when the line is selected.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawPlaceholder(in: rect)
        guard !decorations.isEmpty else { return }
        DecorationPainter(typography: typography, documentURL: documentURL)
            .draw(decorations, in: self, dirtyRect: rect)
    }

    /// What's shown in an empty document.
    ///
    /// A blank page without a single word is the only screen in the app
    /// where "making the app disappear" (§7) works against it: nothing on it
    /// says how a heading gets made, and the person opening an empty document
    /// is exactly the one who does not know. A line in pale gray, at the exact
    /// spot where the first word will land, that vanishes on the first
    /// character typed.
    ///
    /// It names the syntax rather than a menu. There is no insertion menu any
    /// more, so the markers **are** the interface: type them and they fold
    /// away, which is the one thing worth knowing before the first line.
    private func drawPlaceholder(in rect: NSRect) {
        guard textStorage?.length == 0 else { return }
        let hint = "Write. Type # for a heading, - for a list, ** around a word for bold."

        // **It wraps.** Measured on a single line and drawn in a box of that
        // width, the sentence used to get cut off flat as soon as the window
        // narrowed, on the one screen in the app whose only job is to be read.
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: typography.body,
            .foregroundColor: Theme.NS.labelTertiary,
            .paragraphStyle: style,
        ]
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let width = max(1, (textContainer?.size.width ?? bounds.width) - padding * 2)
        let size = (hint as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes).size
        // Nudged by a hair: placed exactly where the text will start, the
        // placeholder sits **under the caret**, which blinks at the same
        // spot. The `W` of "Write" used to read as struck through by a
        // vertical bar, which looks like a rendering glitch. A couple of
        // pixels go unnoticed; a bar through the letter doesn't.
        let box = NSRect(x: origin.x + padding + 2, y: origin.y,
                         width: width, height: size.height.rounded(.up))
        guard box.intersects(rect) else { return }
        (hint as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attributes)
    }

    /// The pointer turns into a hand over a checkbox.
    ///
    /// Without this, the checkbox is clickable without anything saying so: in
    /// an editor, the rest of the surface is text where the pointer stays an
    /// I-beam, and an area that responds to a click without showing it is
    /// only discovered by accident.
    override func resetCursorRects() {
        super.resetCursorRects()
        for target in DecorationPainter(typography: typography, documentURL: documentURL)
            .checkboxTargets(among: decorations, in: self) {
            addCursorRect(target.box, cursor: .pointingHand)
        }
    }

    // MARK: - Smart deletion

    /// `⌫` right after a hidden construct must delete the **entire**
    /// construct, not just the marker character before it: otherwise you get
    /// an orphaned `**` that breaks the rendering without any obvious reason
    /// why (§2.5).
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, let handler = handlesDeleteBackward, handler(selection) {
            return
        }
        super.deleteBackward(sender)
    }

    // MARK: - Lists

    /// `⏎` continues the list; `⇥` and `⇧⇥` change its level (§2.5).
    ///
    /// These three keys are intercepted here rather than in `keyDown`:
    /// `insertNewline(_:)` and `insertTab(_:)` are the actions the system
    /// sends, and handling them at this level preserves dictation input,
    /// Asian input methods, and alternate keyboards.
    override func insertNewline(_ sender: Any?) {
        if handlesNewline?() == true { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if handlesIndent?(false) == true { return }
        super.insertTab(sender)
    }

    /// Auto-pairing goes through here, not through `keyDown`: this is the
    /// point where the character is already determined, regardless of how it
    /// was produced: keyboard, dictation, character palette.
    ///
    /// Text still being composed, dead-key accents, Asian input methods, is
    /// left untouched: inserting a closing character into it would split the
    /// composition in two.
    /// # The second door, for dead keys
    ///
    /// The two guards below protect an ongoing composition: a closing
    /// character cannot be slipped in the middle of an accent that's being
    /// formed. But on a **French keyboard**, the grave accent and the tilde
    /// *are* dead keys: `` ` `` and `~` never arrive raw, they conclude a
    /// composition, so the guards were turning them away silently.
    /// Auto-pairing never fired once for the two markdown markers that need
    /// it the most, and promotion to a code block didn't either.
    ///
    /// The composition still has to be committed first. So it's written,
    /// **then** the decision is replayed on the text as it now stands: that's
    /// `TypingBehaviour.autoPairAfterTyping`, which says the same thing from
    /// the other side of the keystroke.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        guard let typed, typed.count == 1, let character = typed.first else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        if !hasMarkedText(), replacementRange.location == NSNotFound {
            if handlesTyping?(character) == true { return }
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        super.insertText(string, replacementRange: replacementRange)
        handlesTypedCharacter?(character)
    }

    override func insertBacktab(_ sender: Any?) {
        if handlesIndent?(true) == true { return }
        super.insertBacktab(sender)
    }

    // MARK: - Dropping a document

    /// A dropped markdown file is **opened**, not inserted.
    ///
    /// `NSTextView` would do what it does by default with a URL: write its
    /// path into the document, which is not what anyone has ever wanted from
    /// this gesture, least of all in an editor that manages tabs. So the drop
    /// is intercepted before it gets there.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        documents(in: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        documents(in: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = documents(in: sender)
        if !files.isEmpty {
            for url in files {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
            return true
        }

        return super.performDragOperation(sender)
    }

    /// The dropped files the app knows how to open: its own document types,
    /// as declared in `Info.plist`.
    private func documents(in sender: NSDraggingInfo) -> [URL] {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return []
        }
        return urls.filter { AppConfig.readableExtensions.contains($0.pathExtension.lowercased()) }
    }

    // MARK: - Paste

    /// `⌘V` converts rich text into markdown (§2.5).
    ///
    /// `NSTextView` offers `paste(_:)` and `pasteAsPlainText(_:)`. The former
    /// would paste rich text into a buffer that doesn't want it: the view is
    /// `isRichText = false`, and the attributes would be lost without leaving
    /// anything in exchange. So it's intercepted, and markdown is inserted
    /// instead.
    override func paste(_ sender: Any?) {
        if let markdown = PasteConversion.markdown(from: .general) {
            insertText(markdown, replacementRange: selectedRange())
            return
        }
        super.pasteAsPlainText(sender)
    }

    /// `⌘⇧V` always pastes as plain text, with no conversion at all (§2.5).
    @objc func pastePlainText(_ sender: Any?) {
        super.pasteAsPlainText(sender)
    }

    // MARK: - Links

    /// `⌘`+click opens the URL. A plain click does not: in an editor,
    /// clicking inside a link is primarily meant to place the caret there.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // A checkbox gets checked on click. This is the mouse counterpart of
        // §2.5: the checkbox is drawn, so the only way to check it would
        // otherwise be to manually rewrite an `x` between two brackets that
        // were just hidden.
        if !event.modifierFlags.contains(.command),
           let range = DecorationPainter(typography: typography, documentURL: documentURL)
               .task(at: point, among: decorations, in: self),
           handlesTaskToggle?(range) == true {
            return
        }

        guard event.modifierFlags.contains(.command) else {
            super.mouseDown(with: event)
            return
        }
        let index = characterIndexForInsertion(at: point)
        if let storage = textStorage, index < storage.length,
           let link = storage.attribute(.link, at: index, effectiveRange: nil) as? URL {
            NSWorkspace.shared.open(link)
            return
        }
        // A footnote has no address to open, but it has another half
        // somewhere in the document: the same gesture leads there.
        if handlesFootnoteJump?(index) == true { return }
        super.mouseDown(with: event)
    }

    // MARK: - Appearance

    /// The background and colors are dynamic `NSColor`s, but the attributes
    /// already set in the buffer are frozen: they were resolved at the
    /// moment they were applied. A system theme change must therefore
    /// trigger a new render, which the controller listens for.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        NotificationCenter.default.post(name: .foveaAppearanceChanged, object: self)
    }
}

extension Notification.Name {
    static let foveaAppearanceChanged = Notification.Name("foveaAppearanceChanged")
}
