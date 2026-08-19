// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The editing window.
///
/// It is as empty as possible: no toolbar, no sidebar, a transparent title.
/// This is the direct application of §7: the app must disappear, leaving
/// only the text column.
final class DocumentWindowController: NSWindowController {

    let editor = EditorController()
    /// The §6 states, communicated without interrupting.
    let banner = DocumentBanner()
    private let statusBar = StatusBar()
    private let outline = OutlinePanel()
    private let palette = CommandPalette()
    /// Outline width when open. Zero closes it.
    private var outlineWidth: NSLayoutConstraint!
    /// The inset left for the title bar, and for the tab bar when present.
    /// See `applyTitleBarInset()`.
    private var bannerTop: NSLayoutConstraint!
    /// The settings subscription, released on close.
    private var settingsObserver: (any NSObjectProtocol)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        // The title is hidden but the bar stays: it carries the window
        // buttons and the document's drag handle. Making it transparent lets
        // the text scroll behind it, which is exactly the effect wanted.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.NS.window
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 420, height: 320)
        window.isMovableByWindowBackground = false

        self.init(window: window)
        window.delegate = self

        // The text column is centered, so its margin depends on the width
        // available. `windowDidResize` isn't enough: on first display it
        // hasn't been called yet and the scroll view doesn't have its final
        // size, which left the text stuck to the left. The recalculation is
        // therefore tied to the view's own layout pass.
        let content = LayoutObservingView()
        content.onLayout = { [weak self, weak editor] in
            self?.applyTitleBarInset()
            editor?.applyColumnLayout()
        }
        content.addSubview(outline)
        content.addSubview(banner)
        content.addSubview(editor.scrollView)
        content.addSubview(statusBar)
        editor.scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        outline.translatesAutoresizingMaskIntoConstraints = false
        banner.translatesAutoresizingMaskIntoConstraints = false
        outlineWidth = outline.widthAnchor.constraint(equalToConstant: 0)
        bannerTop = banner.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Space.s64)

        NSLayoutConstraint.activate([
            outline.topAnchor.constraint(equalTo: content.topAnchor),
            outline.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            outline.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outlineWidth,

            // The banner sits **above** the column, not over it: it pushes
            // the text down instead of covering it, and gives it back in
            // full once it closes.
            //
            // The inset matches the outline's, for the same reason: the
            // title bar is transparent and tabs overlap it. At 40, the
            // banner passed underneath it: of its 34 points of height, only
            // the last ten showed, and its message was unreadable at the
            // exact moment it needed to be read.
            bannerTop,
            banner.leadingAnchor.constraint(equalTo: outline.trailingAnchor),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            editor.scrollView.topAnchor.constraint(equalTo: banner.bottomAnchor),
            editor.scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            editor.scrollView.leadingAnchor.constraint(equalTo: outline.trailingAnchor),
            editor.scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            // Floating above the text, in the bottom-right corner: it
            // doesn't steal space from the column, and fades out when the
            // pointer is elsewhere.
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.Space.s16),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Theme.Space.s12),
            statusBar.heightAnchor.constraint(equalToConstant: 20),
        ])
        window.contentView = content

        editor.onSelectionChanged = { [weak self] in
            self?.refreshStatistics()
            self?.refreshOutlineHighlight()
        }
        editor.onSpansChanged = { [weak self] in self?.refreshOutline() }
        outline.onSelect = { [weak self] location in self?.goTo(location) }
        refreshStatistics()

        // The status bar is the only piece of chrome whose visibility is a
        // setting. Without this subscription, unchecking "Show statistics"
        // did nothing visible: the bar only went away on the next
        // keystroke, when some other path called `refreshStatistics`. The
        // setting looked broken when it was only late.
        // The token is retained and released in `deinit`: the block-based
        // variant does **not** remove its observer by itself, unlike the
        // one that takes a target. The block stayed registered after the
        // window closed, and every document opened in the session left one
        // more behind.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatistics() }
            }

        // The first responder must be the text view as soon as the window
        // opens: in a writing app, the caret should be blinking before the
        // hand leaves the keyboard.
        window.makeFirstResponder(editor.textView)

        // **The size is remembered, the position shifts.**
        //
        // A frame autosave name disables AppKit's window cascading: windows
        // for two documents opened side by side landed pixel-for-pixel on
        // top of each other, and the second looked like it hadn't opened at
        // all. The saved frame is kept, since it restores the chosen size,
        // and the window is shifted by hand whenever another window already
        // occupies that spot.
        windowFrameAutosaveName = "FoveaDocumentWindow"
        if let taken = NSApp.windows.first(where: {
            $0 !== window && $0.isVisible && $0.frame.origin == window.frame.origin
        }) {
            window.cascadeTopLeft(from: NSPoint(x: taken.frame.minX, y: taken.frame.maxY))
        }
    }


    override func windowDidLoad() {
        super.windowDidLoad()
        editor.applyColumnLayout()
    }

    /// Gives the text back exactly the height the title bar **actually**
    /// takes.
    ///
    /// # What the hardcoded 64 points missed
    ///
    /// The window is `fullSizeContentView`: the content extends under the
    /// title bar, and that's intentional: the text scrolls behind it. It
    /// still shouldn't *start* underneath it.
    ///
    /// 64 points was enough for a title bar alone. As soon as a second tab
    /// opens, macOS adds a tab bar on top of it: the first visible line was
    /// then **cut in half** by its bottom edge for the whole scroll. The
    /// outline already had an inset for exactly this reason, but that one
    /// was hardcoded too.
    ///
    /// `contentLayoutRect` is the only measurement that's accurate: it's
    /// AppKit reporting what it actually took.
    private func applyTitleBarInset() {
        guard let window, let content = window.contentView else { return }
        // 64 remains the **floor**: it's the breathing room wanted above
        // the first word, not an estimate of the title bar. What the
        // measurement adds is whatever comes on top of that: the tab bar,
        // which takes close to forty points and under which the first
        // visible line was cut in half.
        let taken = max(Theme.Space.s64, content.bounds.height - window.contentLayoutRect.height)
        guard abs(bannerTop.constant - taken) > 0.5 else { return }
        bannerTop.constant = taken
        outline.topInset = taken
    }

    /// The pending recount. See `refreshStatistics`.
    private var pendingStatistics: DispatchWorkItem?

    /// Refreshes the status bar.
    ///
    /// Called on every selection change **and** on every keystroke. Since
    /// the bar can be hidden, nothing is paid at all when it is.
    func refreshStatistics() {
        guard AppSettings.shared.showStatistics else {
            statusBar.isHidden = true
            return
        }
        statusBar.isHidden = false

        // **The count is debounced, not redone on every keystroke.**
        //
        // It excludes markdown syntax, so it walks the whole document and
        // allocates a flag per character along the way: 26 ms for 50,000
        // words, measured. Called on every key *and* every caret move, it
        // had become the most expensive step of the typing cycle, well
        // above the 16 ms budget from §9, for a number nobody reads while
        // typing.
        //
        // A quarter second of silence is enough: the counter updates as
        // soon as the fingers lift, and typing never pays for it again.
        pendingStatistics?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            statusBar.update(editor.statistics,
                             goal: AppSettings.shared.sessionWordGoal,
                             isSelection: editor.textView.selectedRange().length > 0)
        }
        pendingStatistics = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

/// A view that notifies when it has just been laid out.
///
/// `NSViewController.viewDidLayout` would do the same job, but would
/// require a whole view controller for a single callback line.
private final class LayoutObservingView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - NSWindowDelegate

extension DocumentWindowController: NSWindowDelegate {

    /// The settings subscription is released here rather than in `deinit`:
    /// the latter is `nonisolated`, and an observer token doesn't cross
    /// isolation domains. The window closing is, in any case, the exact
    /// moment the subscription stops having an object.
    func windowWillClose(_ notification: Notification) {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        // The palette is a separate window: without this, it would outlive
        // the document it operates on.
        palette.dismiss()
        pendingStatistics?.cancel()
    }
}

// MARK: - Menu bar commands

extension DocumentWindowController: NSMenuItemValidation {

    @objc func toggleSourceMode(_ sender: Any?) {
        editor.toggleSourceMode()
    }

    @objc func toggleBold(_ sender: Any?) { editor.wrapSelection(with: "**") }
    @objc func toggleItalic(_ sender: Any?) { editor.wrapSelection(with: "*") }
    @objc func toggleStrikethrough(_ sender: Any?) { editor.wrapSelection(with: "~~") }
    @objc func toggleInlineCode(_ sender: Any?) { editor.wrapSelection(with: "`") }
    @objc func insertLink(_ sender: Any?) { editor.insertLink() }
    @objc func insertMarkdownTable(_ sender: Any?) { editor.presentTableSizePicker() }
    @objc func toggleTaskAtCaret(_ sender: Any?) { editor.toggleTaskAtCaret() }

    @objc func setHeadingLevel(_ sender: Any?) {
        // The level travels in the menu item's `tag`: six entries, one
        // action, and the ⌘⌃n shortcut stays readable in the menu.
        guard let item = sender as? NSMenuItem else { return }
        editor.setHeadingLevel(item.tag)
    }

    @objc func toggleFocusMode(_ sender: Any?) {
        AppSettings.shared.focusMode.toggle()
    }

    @objc func toggleTypewriterMode(_ sender: Any?) {
        AppSettings.shared.typewriterMode.toggle()
    }

    // MARK: - Exports (§4.6)

    @objc func copyAsRichText(_ sender: Any?) {
        guard let rich = MarkdownExport.richText(from: editor.text, documentURL: editor.documentURL),
              let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // RTF **and** plain text: an app that can't read the former should
        // find the latter instead of pasting an empty pasteboard.
        pasteboard.declareTypes([.rtf, .string], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString(rich.string, forType: .string)
    }

    @objc func pastePlainText(_ sender: Any?) {
        editor.textView.pastePlainText(sender)
    }

    @objc func exportHTML(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (documentName as NSString).deletingPathExtension + ".html"
        panel.message = "A single file, images included."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let html = MarkdownExport.html(from: editor.text,
                                       title: (documentName as NSString).deletingPathExtension,
                                       documentURL: editor.documentURL)
        try? Data(html.utf8).write(to: url)
    }

    /// Opens the system share sheet on the file itself.
    ///
    /// It's the `.md` that gets shared, not a render: sharing a markdown
    /// document means sending a file the recipient can reopen and edit.
    /// Anyone who wants a PDF has the Export menu right above.
    ///
    /// A document that has never been saved has nothing to share; the item
    /// is disabled instead, rather than opening an empty sheet.
    @objc func shareDocument(_ sender: Any?) {
        guard let url: URL = document?.fileURL else { return }
        let picker = NSSharingServicePicker(items: [url])
        guard let anchor = window?.contentView else { return }
        picker.show(relativeTo: NSRect(x: anchor.bounds.midX, y: anchor.bounds.maxY - 1, width: 1, height: 1),
                    of: anchor, preferredEdge: .maxY)
    }

    @objc func exportPDF(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (documentName as NSString).deletingPathExtension + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportPDF(to: url)
    }

    /// Produces the PDF from a **disposable** rendering view, without the
    /// editor's chrome and with every marker hidden (§4.6).
    ///
    /// Printing the editing view itself would carry over its column width,
    /// its background color and its caret. Pagination is left to
    /// `NSPrintOperation`: splitting by hand would produce paragraphs cut in
    /// half at the bottom of pages.
    private func exportPDF(to url: URL) {
        guard let rich = MarkdownExport.richText(from: editor.text, documentURL: editor.documentURL) else {
            return
        }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)   // A4 at 72 dpi
        info.topMargin = 64; info.bottomMargin = 64
        info.leftMargin = 64; info.rightMargin = 64
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let printable = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: printable, height: 100))
        view.textStorage?.setAttributedString(rich)
        view.isEditable = false
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
    }

    private var documentName: String {
        (document as? NSDocument)?.displayName ?? "Document"
    }

    // MARK: - Outline and palette (§4.5)

    @objc func toggleOutline(_ sender: Any?) {
        let opening = outlineWidth.constant == 0
        // The width **before** the fill: `refreshOutline` guards against
        // acting on a closed panel, and calling it first left it empty.
        //
        // **220 points, but never more than a third of the window.** The
        // width used to be fixed: in a 430-point window (above the allowed
        // minimum), the outline took up more than half the space and the
        // text column dropped to about fifteen characters per line. The
        // outline is there to navigate a document; it shouldn't get in the
        // way of reading it.
        let available = window?.frame.width ?? 820
        outlineWidth.constant = opening ? min(220, max(140, available / 3)) : 0
        if opening {
            refreshOutline()
            refreshOutlineHighlight()
        }

        // "Reduce motion" is a need, not a preference (§8): the panel still
        // opens, it just doesn't slide. The setting is read by
        // `Accessibility`, the sole entry point.
        Accessibility.animate(0.2) {
            window?.contentView?.layoutSubtreeIfNeeded()
        } completion: {
            // The completion block is called by AppKit with no declared
            // isolation, but always on the main thread: it's the one
            // animating.
            MainActor.assumeIsolated { [weak self] in self?.editor.applyColumnLayout() }
        }
    }

    @objc func showCommandPalette(_ sender: Any?) {
        // The shortcut that opens also closes: `⌘K` on a palette that was
        // already showing used to reset it, which looked like a key with no
        // effect.
        guard !palette.isVisible else {
            palette.dismiss()
            return
        }
        palette.present(entries: paletteEntries(), relativeTo: window)
    }

    /// Commands **and** the document's headings, in the same list.
    ///
    /// In a long document, searching for a heading and jumping to it is
    /// more frequent than any command; separating them would force a choice
    /// of mode before even knowing what's being searched for.
    private func paletteEntries() -> [CommandPalette.Entry] {
        // Shortcuts are **read from the menu bar**, never written here:
        // macOS remaps them based on the keyboard layout, and the palette
        // was the only place in the app that displayed them, so the only
        // place that got them wrong. See `MainMenu.shortcut(for:tag:)`.
        let key = MainMenu.shortcut
        var entries: [CommandPalette.Entry] = [
            .init(title: editor.isSourceMode ? "Hide Source" : "Show Source",
                  detail: key(#selector(toggleSourceMode(_:)), nil)) { [weak self] in
                      self?.editor.toggleSourceMode()
                  },
            .init(title: outlineWidth.constant == 0 ? "Document Outline" : "Hide Outline",
                  detail: key(#selector(toggleOutline(_:)), nil)) { [weak self] in self?.toggleOutline(nil) },
            .init(title: AppSettings.shared.focusMode ? "Turn Off Focus Mode" : "Focus Mode",
                  detail: key(#selector(toggleFocusMode(_:)), nil)) { AppSettings.shared.focusMode.toggle() },
            .init(title: AppSettings.shared.typewriterMode ? "Turn Off Typewriter Mode" : "Typewriter Mode",
                  detail: key(#selector(toggleTypewriterMode(_:)), nil)) { AppSettings.shared.typewriterMode.toggle() },
            .init(title: "Bold", detail: key(#selector(toggleBold(_:)), nil)) { [weak self] in
                self?.editor.wrapSelection(with: "**")
            },
            .init(title: "Italic", detail: key(#selector(toggleItalic(_:)), nil)) { [weak self] in
                self?.editor.wrapSelection(with: "*")
            },
            .init(title: "Code", detail: key(#selector(toggleInlineCode(_:)), nil)) { [weak self] in
                self?.editor.wrapSelection(with: "`")
            },
            .init(title: "Strikethrough", detail: key(#selector(toggleStrikethrough(_:)), nil)) { [weak self] in
                self?.editor.wrapSelection(with: "~~")
            },
            .init(title: "Table…", detail: key(#selector(insertMarkdownTable(_:)), nil)) { [weak self] in
                self?.editor.presentTableSizePicker()
            },
            .init(title: "Link…", detail: key(#selector(insertLink(_:)), nil)) { [weak self] in
                self?.editor.insertLink()
            },
            .init(title: "Export as Standalone HTML",
                  detail: key(#selector(exportHTML(_:)), nil)) { [weak self] in self?.exportHTML(nil) },
            .init(title: "Export as PDF",
                  detail: key(#selector(exportPDF(_:)), nil)) { [weak self] in self?.exportPDF(nil) },
            .init(title: "Copy as Rich Text",
                  detail: key(#selector(copyAsRichText(_:)), nil)) { [weak self] in self?.copyAsRichText(nil) },
            .init(title: "Settings",
                  detail: key(#selector(AppDelegate.showSettings(_:)), nil)) {
                      SettingsWindowController.shared.present()
                  },
        ]
        for level in 1...3 {
            entries.append(.init(title: "Heading \(level)",
                                 detail: key(#selector(setHeadingLevel(_:)), level)) { [weak self] in
                self?.editor.setHeadingLevel(level)
            })
        }

        let text = editor.textView.textStorage?.mutableString ?? NSMutableString()
        // The markers only once for all headings, like in the outline:
        // recomputing them per heading would be quadratic.
        let markers = OutlinePanel.inlineMarkers(of: editor.spans)
        for span in editor.spans {
            guard case .heading(let level) = span.kind,
                  span.content.upperBound <= text.length else { continue }
            // The same text as the outline: the document's, not its source.
            // A heading containing bold text used to list with its asterisks.
            let title = OutlinePanel.plainText(of: span.content, markers: markers, text: text)
            guard !title.isEmpty else { continue }
            entries.append(.init(title: title,
                                 detail: "Heading \(level)") { [weak self] in
                self?.goTo(span.range.location)
            })
        }
        return entries
    }

    private func goTo(_ location: Int) {
        let length = editor.textView.textStorage?.length ?? 0
        editor.textView.setSelectedRange(NSRange(location: min(location, length), length: 0))
        editor.textView.scrollRangeToVisible(NSRange(location: min(location, length), length: 0))
        window?.makeFirstResponder(editor.textView)
    }

    private func refreshOutline() {
        guard outlineWidth?.constant != 0 else { return }
        outline.update(spans: editor.spans,
                       text: editor.textView.textStorage?.mutableString ?? NSMutableString())
        // A reload clears the highlighted line: it's restored here. The
        // outline already guards itself against reloading for nothing, so
        // this is free in the common case.
        refreshOutlineHighlight()
    }

    private func refreshOutlineHighlight() {
        guard outlineWidth?.constant != 0 else { return }
        outline.highlight(caret: editor.textView.selectedRange().location)
    }

    /// `NSWindowController` doesn't inherit validation: without this
    /// conformance, the items would stay grayed out even though the actions
    /// exist. This is also where the checked states get updated.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSourceMode(_:)):
            menuItem.title = editor.isSourceMode ? "Hide Source" : "Show Source"

        case #selector(toggleFocusMode(_:)):
            menuItem.state = AppSettings.shared.focusMode ? .on : .off

        case #selector(toggleTypewriterMode(_:)):
            menuItem.state = AppSettings.shared.typewriterMode ? .on : .off

        case #selector(toggleOutline(_:)):
            menuItem.state = outlineWidth?.constant != 0 ? .on : .off

        case #selector(shareDocument(_:)):
            return document?.fileURL != nil

        case #selector(toggleTaskAtCaret(_:)):
            // The item says what it will do, and grays out outside a task
            // rather than doing nothing when chosen.
            let caret = editor.textView.selectedRange().location
            let task = editor.spans.first { span in
                guard case .taskItem(_, let checked) = span.kind,
                      RevealPolicy.contains(span.range, caret) else { return false }
                menuItem.title = checked ? "Uncheck Task" : "Check Task"
                return true
            }
            if task == nil { menuItem.title = "Check Task" }
            return task != nil && !editor.isSourceMode

        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)),
             #selector(toggleStrikethrough(_:)), #selector(toggleInlineCode(_:)),
             #selector(insertLink(_:)), #selector(insertMarkdownTable(_:)), #selector(setHeadingLevel(_:)):
            // Source mode shows the file exactly as it is: applying
            // formatting through a shortcut there would mean writing
            // asterisks blindly into plain text.
            return !editor.isSourceMode

        default:
            break
        }
        return true
    }
}
