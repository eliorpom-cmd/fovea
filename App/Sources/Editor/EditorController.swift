// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The orchestrator: buffer, parser, rendering, selection.
///
/// There is **only one buffer**, and it holds the markdown text (§3.1). Everything
/// this controller does is decide which attributes are applied to it, and when.
@MainActor
final class EditorController: NSObject {

    let textView: EditorTextView
    let scrollView: NSScrollView

    private(set) var spans: [SyntaxSpan] = []
    private var revealed: Set<Int> = []
    /// Rebuilt on every parse, consulted on every caret move.
    private var spanIndex = SpanIndex([])

    /// The last edit reported by `NSTextStorage`, so the typing cycle knows which
    /// block to re-parse.
    private var lastEditedRange: NSRange?
    private var lastChangeInLength = 0

    var typography: EditorTypography {
        didSet {
            rerenderEverything()
            applyColumnLayout()
        }
    }

    /// The document's location, to resolve relatively-pathed images (§4.4). `nil`
    /// until the document has been saved.
    var documentURL: URL? {
        didSet {
            guard documentURL != oldValue else { return }
            ImageStore.shared.invalidate()
            rerenderEverything()
        }
    }

    /// Source mode (§4.2): the same buffer, without the styling layer.
    private(set) var isSourceMode = false

    /// The block insertion menu (§4.5), and what triggered it.
    private let slashMenu = SlashMenu()
    /// The `/tab` the grid picker will replace once it has an answer.
    private var slashTrigger: TypingBehaviour.SlashTrigger?

    /// Called after every text modification, so the document knows it is dirty.
    var onTextChanged: (() -> Void)?

    // MARK: - Setup

    init(typography: EditorTypography? = nil) {
        self.typography = typography ?? AppSettings.shared.typography
        self.textView = EditorTextView.make()
        self.scrollView = NSScrollView()
        super.init()

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.NS.window
        // §7: the app must disappear. A permanent scroller is chrome.
        scrollView.scrollerStyle = .overlay

        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.handlesDeleteBackward = { [weak self] selection in
            guard let self else { return false }
            // **The construct before the pair.**
            //
            // The order used to be reversed, and it produced exactly the orphan
            // `deleteConstruct` exists to avoid: the caret can land *between the
            // two asterisks* of an opening marker — the marker is revealed there,
            // so the position is reachable — and `⌫` would see a `*|*` pair to
            // undo there. `**bold**` became `bold**`, a lone closing marker in
            // the middle of the sentence.
            //
            // Nothing is lost by the change: a freshly typed pair — `()`, an
            // empty `**` — is never a parsed construct, so `deleteConstruct` lets
            // it pass through.
            return deleteConstruct(at: selection)
                || deletePair(at: selection)
        }
        textView.handlesTyping = { [weak self] character in
            guard let self, !isSourceMode else { return false }
            // The third backtick first: without it, the auto-pairs double every
            // keystroke and ` ``` ` produces six.
            if apply(TypingBehaviour.codeFence(typing: character, in: text,
                                               selection: textView.selectedRange())) {
                return true
            }
            return apply(TypingBehaviour.autoPair(typing: character, in: text,
                                                  selection: textView.selectedRange(),
                                                  insideCode: isInsideCode(at: textView.selectedRange().location)))
        }
        // Catching up on dead keys: the same decision, made after the fact.
        // See `EditorTextView.insertText`.
        textView.handlesTypedCharacter = { [weak self] character in
            guard let self, !isSourceMode else { return }
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return }
            let caret = selection.location
            if apply(TypingBehaviour.codeFenceAfterTyping(character, in: text, caret: caret)) { return }
            _ = apply(TypingBehaviour.autoPairAfterTyping(character, in: text, caret: caret,
                                                          insideCode: isInsideCode(at: max(0, caret - 1))))
        }
        textView.handlesNewline = { [weak self] in
            guard let self else { return false }
            return apply(TypingBehaviour.newline(in: text, selection: textView.selectedRange()))
        }
        textView.handlesIndent = { [weak self] outdent in
            guard let self else { return false }
            // Escaping a format comes before everything else: it is the gesture
            // that closes the loop opened by the auto-pairs.
            if !outdent, escapeFormat() { return true }
            return apply(TypingBehaviour.indent(in: text, selection: textView.selectedRange(), outdent: outdent))
        }

        textView.handlesTaskToggle = { [weak self] content in
            self?.toggleTask(atContent: content) ?? false
        }
        textView.handlesFootnoteJump = { [weak self] index in
            self?.jumpBetweenFootnoteHalves(at: index) ?? false
        }
        textView.handlesMenuKey = { [weak self] key in
            self?.handleSlashMenuKey(key) ?? false
        }
        slashMenu.onChoose = { [weak self] command in
            self?.insertBlock(command)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceChanged),
            name: .foveaAppearanceChanged, object: textView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: AppSettings.didChange, object: nil)
    }

    // MARK: - Content

    var text: String {
        textView.string
    }

    /// Length parsed and styled **before** the first paint.
    ///
    /// Enough for several screens at any font size; the rest waits for the next
    /// runloop turn. See `setText(_:)`.
    private static let firstPaintLength = 40_000

    func setText(_ newText: String) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
        storage.endEditing()
        // The initial replacement is not a user edit: it must neither mark the
        // document dirty nor enter the undo stack.
        textView.undoManager?.removeAllActions()
        lastEditedRange = nil
        lastChangeInLength = 0

        guard storage.length > Self.firstPaintLength else {
            reparse()
            rerenderEverything()
            applyColumnLayout()
            return
        }

        // **Progressive opening.** Parsing and styling 600 pages before showing
        // anything cost more than a second, against a 500 ms budget (§9) — and
        // the user only needs the first screen.
        //
        // TextKit 2 already only lays out the viewport; what remained
        // proportional to the document was parsing and applying attributes. This
        // does just enough to paint, and the rest follows immediately after,
        // before the hand has even left the keyboard.
        let head = IncrementalParse.blockRange(
            in: storage.mutableString,
            around: NSRange(location: 0, length: Self.firstPaintLength))
        spans = MarkdownParser.parse(storage.mutableString.substring(with: head), offsetBy: head.location)
        spanIndex = SpanIndex(spans)
        render(in: head)
        applyColumnLayout()

        Task { @MainActor [weak self] in
            guard let self else { return }
            reparse()
            rerenderEverything()
        }
    }

    // MARK: - Parsing and rendering

    private func reparse() {
        spans = MarkdownParser.parse(textView.string).spans
            .sorted { $0.range.location < $1.range.location }
        spanIndex = SpanIndex(spans)
    }

    /// Re-parses **only the touched block**, and falls back to the whole document
    /// when its meaning depends on it (see `IncrementalParse`).
    ///
    /// - Returns: the range to re-style.
    private func reparseIncrementally(editedRange: NSRange, delta: Int) -> NSRange {
        guard let storage = textView.textStorage else { return NSRange(location: 0, length: 0) }
        let whole = NSRange(location: 0, length: storage.length)

        let inserted = editedRange.length > 0 && editedRange.upperBound <= storage.length
            ? storage.mutableString.substring(with: editedRange)
            : ""
        let codeBlocks = spans.compactMap { span -> NSRange? in
            if case .codeBlock = span.kind { return span.range } else { return nil }
        }

        guard let scope = IncrementalParse.scope(in: storage.mutableString,
                                                 editedRange: editedRange,
                                                 inserted: inserted,
                                                 existingCodeBlocks: codeBlocks) else {
            reparse()
            return whole
        }

        let fragment = storage.mutableString.substring(with: scope)
        let fresh = MarkdownParser.parse(fragment, offsetBy: scope.location)
        spans = MarkdownParser.splice(spans, replacing: scope, with: fresh, delta: delta)
        spanIndex = SpanIndex(spans)
        return scope
    }

    /// The width **actually** offered to the text: the container's width, which
    /// `applyColumnLayout` has bounded to the available space. It is this width
    /// that must decide a table's geometry, not the settings' width.
    private var renderedColumnWidth: CGFloat {
        let width = textView.textContainer?.size.width ?? 0
        return width > 0 ? width : typography.columnWidth
    }

    /// The width at the last render, to know when tables need to be repositioned.
    private var lastRenderedColumnWidth: CGFloat = 0

    /// Repositions **only the tables**, at the current width.
    ///
    /// A grid doesn't hold together through a constraint: it holds together
    /// through the kerning applied to its hidden `|` characters, which is to say
    /// through attributes frozen in the buffer. Changing the container's width
    /// therefore does not reposition it, and after a window resize the table used
    /// to keep the old width's geometry until the next keystroke that touched it.
    private func rerenderTables() {
        guard !isSourceMode, let storage = textView.textStorage, !spans.isEmpty else { return }
        let renderer = MarkdownRenderer(typography: typography, availableWidth: renderedColumnWidth)
        let tables = spans.enumerated().filter { renderer.isTable($0.element) }
        guard !tables.isEmpty else { return }

        storage.beginEditing()
        for (index, span) in tables {
            renderer.applyTable(storage, span: span, revealed: revealed.contains(index))
        }
        storage.endEditing()
        textView.decorations = EditorDecoration.build(from: spans, in: storage,
                                                      typography: typography,
                                                      availableWidth: renderedColumnWidth,
                                                      revealed: revealed)
    }

    private func rerenderEverything() {
        guard let storage = textView.textStorage else { return }
        render(in: NSRange(location: 0, length: storage.length))
    }

    /// Applies attributes to a range, and only that range.
    ///
    /// The decorations, meanwhile, are always rebuilt in full: their computation
    /// only walks the list of constructs without touching the buffer, and it is
    /// negligible next to applying attributes.
    private func render(in range: NSRange) {
        guard let storage = textView.textStorage else { return }
        textView.showsSource = isSourceMode
        guard !isSourceMode else {
            renderSourceMode(storage)
            return
        }
        revealed = currentRevealedIndices()
        let renderer = MarkdownRenderer(typography: typography,
                                        documentURL: documentURL,
                                        availableWidth: renderedColumnWidth)
        // Only the constructs that touch the range are re-passed; the range is
        // that of the edited block, not of the document.
        //
        // "Touch", boundaries included, rather than "intersect": an edit range
        // can be **empty** — deleting the document's last character leaves
        // one — and an empty intersection would then discard every construct.
        // The fallback that used to fix this case re-passed **all** of them,
        // whole document included: the worst possible moment to do it, since a
        // keystroke is what calls it.
        let touching = spans.enumerated().filter { Self.touches($0.element.range, range) }
        renderer.render(storage,
                        spans: touching.map(\.element),
                        revealed: Set(touching.indices.filter { revealed.contains(touching[$0].offset) }),
                        in: range)
        textView.typography = typography
        textView.documentURL = documentURL
        textView.decorations = EditorDecoration.build(from: spans, in: storage,
                                                      typography: typography,
                                                      availableWidth: renderedColumnWidth,
                                                      revealed: revealed)
    }

    /// Do the two ranges touch, boundaries included? An empty range touches
    /// another as soon as it is inside it or at its edge.
    static func touches(_ a: NSRange, _ b: NSRange) -> Bool {
        a.location <= b.upperBound && b.location <= a.upperBound
    }

    /// The safety net (§4.2): the text as it is in the file, in a fixed-pitch
    /// font, without a single rendering attribute.
    private func renderSourceMode(_ storage: NSTextStorage) {
        let style = typography.sourceParagraphStyle()
        storage.beginEditing()
        storage.setAttributes([
            .font: typography.codeBlock,
            .foregroundColor: Theme.NS.label,
            .paragraphStyle: style,
        ], range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        // Source mode shows the file, not an interpretation: no drawn mark
        // belongs there.
        textView.decorations = []
    }

    /// Recomputes only the constructs whose reveal state has changed. This is the
    /// app's most frequent operation — an arrow key triggers it — and the only
    /// one that must stay under a millisecond regardless of document size.
    private func updateReveal() {
        guard !isSourceMode, let storage = textView.textStorage else { return }
        let next = currentRevealedIndices()
        guard next != revealed else { return }

        let changed = next.symmetricDifference(revealed)
        revealed = next

        storage.beginEditing()
        let renderer = MarkdownRenderer(typography: typography, availableWidth: renderedColumnWidth)
        for index in changed where index < spans.count {
            renderer.applyMarkers(storage, span: spans[index], revealed: next.contains(index))
        }

        // A table whose cell just revealed its `**` has changed width: its
        // columns must be repositioned, or every column to the right shifts by
        // the width of the markers that reappeared. Only the tables actually
        // affected are repositioned — there are rarely more than one.
        let touched = changed.compactMap { $0 < spans.count ? spans[$0].range : nil }
        var rebuiltDecorations = changed.contains {
            $0 < spans.count && EditorDecoration.hasRevealDependentMark(spans[$0].kind)
        }
        for (index, span) in spans.enumerated() where renderer.isTable(span) {
            guard changed.contains(index)
                    || touched.contains(where: { NSIntersectionRange($0, span.range).length > 0 })
            else { continue }
            renderer.applyTable(storage, span: span, revealed: next.contains(index))
            rebuiltDecorations = true
        }
        storage.endEditing()

        // The drawn marks follow the reveal state: the bullet, the checkbox,
        // the rule and the table borders disappear when their source reappears
        // under the caret. The layer is only rebuilt when one of them is
        // affected — this path runs on every arrow key.
        if rebuiltDecorations {
            textView.decorations = EditorDecoration.build(from: spans, in: storage,
                                                          typography: typography,
                                                          availableWidth: renderedColumnWidth,
                                                          revealed: next)
        }
    }

    /// The line-scope latch: see `RevealPolicy`. The start of the line is
    /// retained rather than its spans, because incremental parsing renumbers
    /// the constructs — the start of the line, however, doesn't move while
    /// typing inside it.
    private var latchedLineStart: Int?

    private func currentRevealedIndices() -> Set<Int> {
        let selection = textView.selectedRange()
        let line = currentLineRange()
        if latchedLineStart != line.location { latchedLineStart = nil }

        let revealed = RevealPolicy.revealedIndices(index: spanIndex,
                                                    selection: selection,
                                                    lineRange: line,
                                                    linePrefixesLatched: latchedLineStart != nil)
        // The latch engages as soon as a prefix is revealed, and releases
        // itself on the next call made from a different line.
        latchedLineStart = revealed.contains { index in
            index < spanIndex.spans.count && spanIndex.spans[index].kind.revealScope == .wholeLine
        } ? line.location : nil
        return revealed
    }

    /// The range of the caret's line, terminator excluded.
    ///
    /// Computed directly on the buffer rather than read from a line table:
    /// `NSString.lineRange(for:)` costs the length of **one line**, where
    /// rebuilding the table cost the whole document — 1.7 ms per 10,000-word
    /// chunk, on every keystroke, for a single useful line.
    private func currentLineRange() -> NSRange {
        guard let storage = textView.textStorage else { return NSRange(location: 0, length: 0) }
        let caret = min(textView.selectedRange().location, storage.length)
        var line = storage.mutableString.lineRange(for: NSRange(location: caret, length: 0))
        // `lineRange(for:)` includes the terminator; §2.2 wants it excluded, or
        // a caret at the start of the next line would reveal the previous one.
        while line.length > 0 {
            let last = storage.mutableString.character(at: line.upperBound - 1)
            guard last == 10 || last == 13 else { break }
            line.length -= 1
        }
        return line
    }

    // MARK: - Column layout

    /// Centers the text column in the window (§7). The width is measured in
    /// characters on the actual font, not fixed in points, so it follows the
    /// choice of font and size.
    /// **Never call this from the typing cycle.**
    ///
    /// Rewriting `textContainerInset` and the container's size invalidates the
    /// layout of the *entire* document. Called on every keystroke, this single
    /// line used to cost more than parsing and rendering combined. It only
    /// needs to run when the available width or the typography changes: that
    /// is, on resize and in settings.
    func applyColumnLayout() {
        guard let container = textView.textContainer else { return }
        let available = scrollView.contentSize.width
        // **No measured space, no decision.**
        //
        // The scroll view has no size yet until it is inside a laid-out
        // window. The calculation that follows used to answer that with a
        // one-point-wide column — the old 240 floor masked it, giving a wrong
        // width rather than none. The next pass is waited for, since it is
        // coming anyway.
        guard available > 1 else { return }

        // **The column never exceeds the available space.**
        //
        // The calculation used to set a fixed 240-point floor and a fixed
        // 24-point margin. At the minimum window size,
        // only 200 points of width remain: the column overflowed, and since
        // the view isn't horizontally resizable, the text was cut off
        // outright.
        //
        // The margin yields before the column, and the column before
        // everything.
        let margin = min(Theme.Space.s24, available / 8)
        let column = max(1, min(typography.columnWidth, available - margin * 2))
        let inset = max(0, (available - column) / 2)
        textView.textContainerInset = NSSize(width: inset, height: Theme.Space.s64)
        container.size = NSSize(width: column, height: .greatestFiniteMagnitude)
        container.widthTracksTextView = false

        // Tables don't follow on their own: see `rerenderTables()`. The cost
        // is only paid when the width has actually changed — this method is
        // called on every layout pass.
        guard abs(column - lastRenderedColumnWidth) > 0.5 else { return }
        lastRenderedColumnWidth = column
        rerenderTables()
    }

    // MARK: - Commands

    func toggleSourceMode() {
        let selection = textView.selectedRange()
        isSourceMode.toggle()
        slashMenu.dismiss()
        rerenderEverything()

        // §6: the selection is kept, but **extended to the markers of its
        // constructs**. Selecting a bold word only selects the word — its `**`
        // were invisible. Switching to source without extending would leave a
        // selection that cuts a construct in two, and a `⌘X` would produce an
        // orphaned `**`.
        if isSourceMode, selection.length > 0 {
            textView.setSelectedRange(extendedToConstructs(selection))
        }
    }

    /// The selection widened to the inline constructs it touches.
    ///
    /// Inline constructs only: widening to blocks would jump the selection
    /// from a word to an entire chapter as soon as it is under a heading.
    private func extendedToConstructs(_ selection: NSRange) -> NSRange {
        var result = selection
        for span in spans where span.kind.revealScope == .innermostInline {
            guard NSIntersectionRange(span.range, selection).length > 0 else { continue }
            result = NSUnionRange(result, span.range)
        }
        let length = textView.textStorage?.length ?? 0
        return NSIntersectionRange(result, NSRange(location: 0, length: length))
    }

    /// Wraps the selection, or removes the formatting if it is already there
    /// (§2.5).
    func wrapSelection(with marker: String) {
        guard !isSourceMode else { return }
        _ = apply(TypingBehaviour.wrap(text, selection: textView.selectedRange(), with: marker))
    }

    func setHeadingLevel(_ level: Int) {
        guard !isSourceMode else { return }
        _ = apply(TypingBehaviour.setHeadingLevel(level, in: text, selection: textView.selectedRange()))
    }

    /// Places a link around the selection, the address coming from the
    /// pasteboard if it contains one.
    func insertLink() {
        guard !isSourceMode else { return }
        let pasted = NSPasteboard.general.string(forType: .string)
        let url = pasted.flatMap { TypingBehaviour.looksLikeURL($0) ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        _ = apply(TypingBehaviour.link(in: text, selection: textView.selectedRange(), url: url))
    }

    /// Checks or unchecks the task on the caret's line (`⌘⏎`).
    ///
    /// Clicking the checkbox would be enough for a sighted user. It is not
    /// enough for §8: a function that only exists with a mouse doesn't exist
    /// for anyone without one.
    @discardableResult
    func toggleTaskAtCaret() -> Bool {
        let caret = textView.selectedRange().location
        guard let index = spans.firstIndex(where: { span in
            guard case .taskItem = span.kind else { return false }
            return RevealPolicy.contains(span.range, caret)
        }) else { return false }
        return toggle(spans[index])
    }

    /// Checks or unchecks the task whose content is this range — the one the
    /// clicked decoration carries.
    private func toggleTask(atContent range: NSRange) -> Bool {
        guard let index = spans.firstIndex(where: { span in
            guard case .taskItem = span.kind else { return false }
            return span.content == range
        }) else { return false }
        return toggle(spans[index])
    }

    private func toggle(_ span: SyntaxSpan) -> Bool {
        guard !isSourceMode, let marker = span.markers.first else { return false }
        return apply(TypingBehaviour.toggleTask(in: text,
                                                marker: marker,
                                                caret: textView.selectedRange().location))
    }

    /// Applies an edit computed by `TypingBehaviour`.
    ///
    /// It goes through `shouldChangeText(in:replacementString:)`, which is
    /// what registers the undo in the view's `NSUndoManager` rather than in a
    /// parallel stack: a `⌘Z` undoes list continuation the same way it undoes
    /// a keystroke, without anything having been written for it.
    @discardableResult
    private func apply(_ edit: TypingBehaviour.Edit?) -> Bool {
        guard let edit, let storage = textView.textStorage,
              edit.range.upperBound <= storage.length else { return false }

        // An edit that changes no character only moves the caret — this is
        // the case of the closing marker being crossed. Sending it through
        // the undo stack would register a step that undoes nothing.
        let selection = { (caret: Int) in
            NSRange(location: min(caret, storage.length),
                    length: min(edit.selectionLength, storage.length - min(caret, storage.length)))
        }
        guard edit.range.length > 0 || !edit.replacement.isEmpty else {
            textView.setSelectedRange(selection(edit.caret))
            return true
        }

        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
            return false
        }
        if let name = edit.undoName {
            textView.undoManager?.setActionName(name)
        }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.didChangeText()
        textView.setSelectedRange(selection(edit.caret))
        return true
    }

    /// `⌫` between the two halves of a pair deletes both of them.
    private func deletePair(at selection: NSRange) -> Bool {
        guard !isSourceMode else { return false }
        return apply(TypingBehaviour.deletingPair(in: text, selection: selection))
    }

    /// Is the caret inside code, where markdown markers don't apply? Goes
    /// through the index rather than the full list: the question is asked on
    /// every character typed (§9).
    private func isInsideCode(at location: Int) -> Bool {
        spanIndex.candidates(near: location, line: currentLineRange()).contains { index in
            guard index < spanIndex.spans.count else { return false }
            let span = spanIndex.spans[index]
            switch span.kind {
            case .inlineCode, .codeBlock:
                return NSLocationInRange(location, span.range)
            default:
                return false
            }
        }
    }

    /// `⌘`+click on a footnote reference jumps to its other half.
    ///
    /// A footnote lives in two places: the `[^1]` reference in the flow of the
    /// text, and its `[^1]: …` definition down at the bottom. Linking them by
    /// mouse is what makes them usable: without it, checking a footnote
    /// requires scrolling the document, reading it, and then finding where one
    /// left off.
    ///
    /// The gesture is the same in both directions, and it is the one used for
    /// links: nothing new to learn.
    private func jumpBetweenFootnoteHalves(at index: Int) -> Bool {
        guard !isSourceMode else { return false }

        let identifier: String
        let goingToDefinition: Bool
        if let span = spans.first(where: { span in
            guard case .footnoteReference = span.kind else { return false }
            return NSLocationInRange(index, span.range)
        }), case .footnoteReference(let name) = span.kind {
            (identifier, goingToDefinition) = (name, true)
        } else if let span = spans.first(where: { span in
            guard case .footnoteDefinition = span.kind else { return false }
            // Only the label answers, not the note's text: otherwise, every
            // click inside a note being written would jump elsewhere.
            return span.markers.contains { NSLocationInRange(index, $0) }
                || NSLocationInRange(index, NSRange(location: span.range.location,
                                                    length: span.content.location - span.range.location))
        }), case .footnoteDefinition(let name) = span.kind {
            (identifier, goingToDefinition) = (name, false)
        } else {
            return false
        }

        let destination = spans.first { span in
            switch span.kind {
            case .footnoteDefinition(let name) where goingToDefinition: return name == identifier
            case .footnoteReference(let name) where !goingToDefinition: return name == identifier
            default: return false
            }
        }
        guard let destination else { return false }

        // The caret goes to the **content**, never to a marker: landing inside
        // a `[^` would reopen the syntax at the exact moment text is being
        // read.
        textView.setSelectedRange(NSRange(location: destination.content.location, length: 0))
        textView.scrollRangeToVisible(destination.range)
        textView.showFindIndicator(for: destination.range)
        return true
    }

    /// `⇥` placed right before the closing tag jumps over it.
    ///
    /// This is the exit from `**bold|**` without lifting the hand, and the
    /// exact counterpart of the auto-pairs: they place the closing marker,
    /// this crosses it. The condition is strict — the caret must be **at the
    /// end of the content**, not anywhere inside it — or `⇥` would stop
    /// indenting.
    private func escapeFormat() -> Bool {
        guard !isSourceMode else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }

        var innermost: NSRange?
        for index in spanIndex.candidates(near: selection.location, line: currentLineRange())
        where index < spanIndex.spans.count {
            let span = spanIndex.spans[index]
            guard span.kind.revealScope == .innermostInline,
                  span.content.upperBound == selection.location,
                  span.range.upperBound > selection.location else { continue }
            if innermost == nil || span.range.length < innermost!.length { innermost = span.range }
        }
        guard let innermost else { return false }
        textView.setSelectedRange(NSRange(location: innermost.upperBound, length: 0))
        return true
    }

    /// Deletes the entire construct when `⌫` would land on a marker (§2.5).
    /// Returns `false` to let `NSTextView` do its usual work in every other
    /// case.
    private func deleteConstruct(at selection: NSRange) -> Bool {
        guard !isSourceMode, selection.location > 0, let storage = textView.textStorage else { return false }
        let target = selection.location - 1

        // The targeted construct is the one whose marker contains the
        // position about to be deleted.
        //
        // Delimited blocks are excluded from this, and it is a safeguard, not
        // a simplification: their markers are the two fences of an entire
        // block. A `⌫` at the end of a  ```swift  line would have erased the
        // closing fence ten lines below, without anything showing it — and in
        // a table, it would have removed every `|` at once.
        guard let index = spans.firstIndex(where: { span in
            span.kind.revealScope != .wholeBlock
                && span.markers.contains { NSLocationInRange(target, $0) }
        }) else { return false }

        let span = spans[index]
        guard span.range.upperBound <= storage.length else { return false }

        // **A single edit, and it goes through `shouldChangeText`.**
        //
        // The previous version removed the markers one by one, directly in
        // the `NSTextStorage`, between a `beginUndoGrouping` and an
        // `endUndoGrouping`. But it isn't the group that registers an undo,
        // it's `shouldChangeText(in:replacementString:)`: the group was
        // therefore empty, and `⌘Z` did not restore the erased `**`. The
        // stack still said `canUndo`, though — the undo existed, it just
        // undid nothing, which is the worst of the two forms.
        //
        // Replacing the entire construct with just its content does the same
        // work in one edit, which the view can undo like a keystroke.
        let kept = withoutMarkers(span, in: storage)
        guard textView.shouldChangeText(in: span.range, replacementString: kept) else { return false }
        textView.undoManager?.setActionName("Remove Formatting")
        storage.replaceCharacters(in: span.range, with: kept)
        textView.didChangeText()

        // **The caret stays where it was**, minus what just disappeared in
        // front of it.
        //
        // It used to go to the start of the content. On `**word**`, `⌫` did
        // remove the bold, but sent the caret three characters back, in front
        // of the word: the next keystroke was written to the left of what had
        // just been unformatted. This was the app's most frequent bug, since
        // it triggered on every format removal.
        let removed = span.markers.reduce(0) { total, marker in
            total + max(0, min(marker.upperBound, selection.location) - marker.location)
        }
        let end = span.range.location + kept.utf16.count
        textView.setSelectedRange(NSRange(
            location: min(max(span.range.location, selection.location - removed), end),
            length: 0))
        return true
    }

    /// A construct's text, with its markers removed.
    private func withoutMarkers(_ span: SyntaxSpan, in storage: NSTextStorage) -> String {
        let text = storage.mutableString
        var kept = ""
        var cursor = span.range.location
        for marker in span.markers.sorted(by: { $0.location < $1.location }) {
            guard marker.location >= cursor, marker.upperBound <= span.range.upperBound else { continue }
            kept += text.substring(with: NSRange(location: cursor, length: marker.location - cursor))
            cursor = marker.upperBound
        }
        return kept + text.substring(with: NSRange(location: cursor,
                                                   length: span.range.upperBound - cursor))
    }

    // MARK: - Slash menu (§4.5)

    /// Opens, updates or closes the menu depending on what was just typed.
    ///
    /// Called after every keystroke **and** every caret move: leaving the line
    /// must close the menu just as reliably as deleting the `/`.
    ///
    /// - Parameter mayOpen: true only when the call follows a **keystroke**. A
    ///   panel that captures arrow keys and `⏎` must never open on its own:
    ///   placing the caret at the end of a line ending in `/` used to leave an
    ///   unrequested menu open and a keyboard that no longer responded to the
    ///   text. A caret move can therefore **close** the menu or follow it when
    ///   already open, never open it.
    private func refreshSlashMenu(mayOpen: Bool) {
        let selection = textView.selectedRange()
        guard !isSourceMode, selection.length == 0,
              textView.window?.isKeyWindow == true,
              let storage = textView.textStorage
        else {
            slashTrigger = nil
            slashMenu.dismiss()
            return
        }

        // `currentLineRange()` costs the length of one line, not of the
        // document: the menu can therefore be re-evaluated on every keystroke
        // without eating into the §9 budget.
        let line = currentLineRange()
        guard let trigger = TypingBehaviour.slashTrigger(
            inLine: storage.mutableString.substring(with: line),
            lineStart: line.location,
            caret: selection.location)
        else {
            slashTrigger = nil
            slashMenu.dismiss()
            return
        }
        guard mayOpen || slashMenu.isOpen else {
            slashTrigger = nil
            return
        }
        slashTrigger = trigger
        // The caret's rectangle is requested in screen coordinates, which the
        // panel expects as is.
        let caretRect = caretRectOnScreen()
        if !slashMenu.present(query: trigger.query, caretRect: caretRect, over: textView.window) {
            slashTrigger = nil
        }
    }

    /// Routes navigation keys to the open panel.
    ///
    private func handleSlashMenuKey(_ key: EditorTextView.MenuKey) -> Bool {
        guard slashMenu.isOpen else { return false }
        switch key {
        case .up: slashMenu.moveSelection(by: -1)
        case .down: slashMenu.moveSelection(by: 1)
        case .confirm: slashMenu.confirmSelection()
        case .cancel:
            slashTrigger = nil
            slashMenu.dismiss()
        case .left, .right: return false
        }
        return true
    }

    // MARK: - A code block's language

    /// The caret's rectangle **in screen coordinates**, to anchor the floating
    /// panels — or `.zero` when there isn't one.
    ///
    /// `firstRect(forCharacterRange:actualRange:)` belongs to
    /// `NSTextInputClient`: it answers for a **session of input in
    /// progress**, and returns a null rectangle when there isn't one. This is
    /// the case as soon as the command comes from the menu bar rather than
    /// from typing — `/tab` opened the grid picker under the caret, ⌥⌘T
    /// opened it in the bottom-left corner of the screen, half under the
    /// Dock, with nothing in the code showing it.
    ///
    /// No fallback position is improvised here: `.zero` is passed through as
    /// is, and `FloatingPanel` — the only one that knows its own size —
    /// decides where to sit when there is no caret.
    private func caretRectOnScreen() -> NSRect {
        textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
    }

    private func insertBlock(_ command: SlashCommand) {
        guard let trigger = slashTrigger else { return }
        slashTrigger = nil
        apply(TypingBehaviour.insertion(of: command, replacing: trigger))
    }

    // MARK: - Reactions

    private func handleTextChange() {
        let edited = lastEditedRange ?? NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        let delta = lastChangeInLength
        lastEditedRange = nil
        lastChangeInLength = 0

        let scope = reparseIncrementally(editedRange: edited, delta: delta)
        render(in: scope)
        // Only now: the parse finally matches the buffer.
        refreshSlashMenu(mayOpen: true)
        onTextChanged?()
    }

    @objc private func appearanceChanged() {
        // Colors already applied in the buffer were resolved at the moment
        // they were applied: a light/dark switch doesn't update them on its
        // own.
        rerenderEverything()
    }

    @objc private func settingsChanged() {
        // Fonts are cached by (family, size) pair: changing the font would
        // leave the old one in the cache.
        FontCache.shared.clear()

        // **Only re-render if the rendering actually changed.**
        //
        // A single notification warns of *any* settings change, and the
        // response used to be reassigning `typography`, whose `didSet`
        // re-applies attributes across the entire document. Toggling focus
        // mode, which is only a veil laid over the rendering, or changing the
        // word-count goal, which touches nothing at all, therefore cost a
        // full render: several hundred milliseconds on a long document, for
        // nothing.
        let settings = AppSettings.shared
        if typography != settings.typography {
            typography = settings.typography
        }
    }
}

// MARK: - NSTextViewDelegate

extension EditorController: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        handleTextChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Before everything else: the caret must be somewhere writable, or
        // the rendering would be computed for a position that doesn't exist
        // on screen.
        updateReveal()
        // A caret move closes or follows, but never opens: see
        // `refreshSlashMenu(mayOpen:)`.
        refreshSlashMenu(mayOpen: false)
    }
}


// MARK: - NSTextStorageDelegate

extension EditorController: NSTextStorageDelegate {

    /// **Records** the modified range, without parsing anything here.
    ///
    /// This is the only place that knows precisely what changed —
    /// `textDidChange(_:)` doesn't say. But re-parsing from this callback
    /// would mean re-entering an edit that is still being processed, which is
    /// the surest way to corrupt `NSTextStorage`'s ranges. It is recorded, and
    /// the work happens on the next turn.
    nonisolated func textStorage(_ textStorage: NSTextStorage,
                                 didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange,
                                 changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            lastEditedRange = editedRange
            lastChangeInLength = delta
        }
    }
}
