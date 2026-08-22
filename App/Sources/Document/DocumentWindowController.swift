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
    /// The inset left for the title bar, and for the tab bar when present.
    /// See `applyTitleBarInset()`.
    private var bannerTop: NSLayoutConstraint!
    /// The settings subscription, released on close.

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.naturalSize()),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        // The title is hidden but the bar stays: it carries the window
        // buttons and the document's drag handle. Making it transparent lets
        // the text scroll behind it, which is exactly the effect wanted.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.NS.window
        window.minSize = NSSize(width: 420, height: 320)
        window.isMovableByWindowBackground = false

        // **It appears, it does not animate in.** The default for a document
        // window is a short scale-and-fade. It costs a frame or two of an
        // opening that the whole app is built to make instant, and it is the
        // first thing anyone sees.
        window.animationBehavior = .none

        // **No tabs.** They are free — the system draws them — but a tab bar
        // says workspace, and this app opens a file. The capability stays for
        // anyone who goes looking: `⌘N` in a window still offers it through
        // the Window menu once this is `.disallowed` only by default.
        window.tabbingMode = .disallowed

        self.init(window: window)

        // The text column is centered, so its margin depends on the width
        // available. `windowDidResize` isn't enough: on first display it
        // hasn't been called yet and the scroll view doesn't have its final
        // size, which left the text stuck to the left. The recalculation is
        // therefore tied to the view's own layout pass.
        let content = LayoutObservingView()
        content.onLayout = { [weak self, weak editor] in
            self?.applyTitleBarInset()
            self?.refreshTitleTracking()
            editor?.applyColumnLayout()
            // The reading position needs a laid-out scroll view to land in,
            // and this is the first pass that has one.
            self?.restoreReadingPositionOnce()
        }
        content.addSubview(banner)
        content.addSubview(editor.scrollView)
        editor.scrollView.translatesAutoresizingMaskIntoConstraints = false
        banner.translatesAutoresizingMaskIntoConstraints = false
        bannerTop = banner.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Space.s64)

        NSLayoutConstraint.activate([
            // The banner sits **above** the column, not over it: it pushes
            // the text down instead of covering it, and gives it back in
            // full once it closes.
            //
            // The top inset exists because the title bar is transparent and
            // tabs overlap it. At 40, the banner passed underneath it: of its
            // 34 points of height, only the last ten showed, and its message
            // was unreadable at the exact moment it needed to be read.
            bannerTop,
            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            editor.scrollView.topAnchor.constraint(equalTo: banner.bottomAnchor),
            editor.scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            editor.scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content
        window.delegate = self


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


    /// The window is **as wide as the text it holds**, not an arbitrary
    /// rectangle the column then floats inside.
    ///
    /// 820 by 720 was a guess, and at the default font it left about a
    /// hundred points of empty page on either side of the column: the window
    /// read as a frame around a document rather than as the document. Here
    /// the width is the column plus its two margins, so the page has edges
    /// where the text has edges.
    ///
    /// The height keeps a proportion rather than a measurement — a document
    /// has no natural height — and is clamped to what the screen can show.
    private static func naturalSize() -> NSSize {
        let typography = AppSettings.shared.typography
        let width = typography.columnWidth + Theme.Space.s24 * 2
        let height = (width * 1.15).rounded()
        guard let visible = NSScreen.main?.visibleFrame else {
            return NSSize(width: width, height: height)
        }
        return NSSize(width: min(width, visible.width),
                      height: min(height, visible.height))
    }

    /// The filename, shown only while the pointer is on the title bar.
    ///
    /// It is the last piece of chrome left in the reading view, and it is
    /// information rather than a control: worth having, not worth looking at
    /// for the whole time a document is open. The same rule the statistics
    /// bar used to follow, applied to what outlived it.
    private var titleHover: NSTrackingArea?

    private func refreshTitleTracking() {
        guard let content = window?.contentView else { return }
        if let titleHover { content.removeTrackingArea(titleHover) }
        let height = Theme.Space.s40
        let area = NSTrackingArea(
            rect: NSRect(x: 0, y: content.bounds.height - height,
                         width: content.bounds.width, height: height),
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self)
        content.addTrackingArea(area)
        titleHover = area
    }

    override func mouseEntered(with event: NSEvent) {
        window?.titleVisibility = .visible
    }

    override func mouseExited(with event: NSEvent) {
        window?.titleVisibility = .hidden
    }

    /// Puts the document back where it was last read.
    ///
    /// Asking the layout manager for the fragment carrying that character is
    /// what lays the document out that far, and no further: coming back to
    /// page two of a long file costs page two. Coming back to the end costs
    /// the file, which is inherent — there is no way to know where the end is
    /// without laying it out.
    private var hasRestoredPosition = false

    /// Called by the document once the text and the URL are in, and again on
    /// every layout pass until it can be honoured: the content view lays out
    /// before `makeWindowControllers` has said which file this is, so the
    /// first pass has nothing to go on.
    func restoreReadingPositionOnce() {
        guard !hasRestoredPosition else { return }
        guard let index = ReadingPosition.character(for: editor.documentURL) else {
            // Nothing stored is still an answer: stop asking on every pass.
            hasRestoredPosition = editor.documentURL != nil
            return
        }
        let clip = editor.scrollView.contentView
        guard clip.bounds.height > 1,
              let layout = editor.textView.textLayoutManager,
              let content = editor.textView.textContentStorage,
              let location = content.location(content.documentRange.location, offsetBy: index),
              let fragment = layout.textLayoutFragment(for: location)
        else { return }

        hasRestoredPosition = true
        let target = fragment.layoutFragmentFrame.minY + editor.textView.textContainerOrigin.y

        // **`scrollRangeToVisible` first, and it is not redundant.**
        //
        // Setting the origin by hand is what puts the line at the *top* of
        // the viewport rather than merely on screen. But the origin is
        // clamped against `textView.frame.height`, and with TextKit 2 that
        // height is one screenful until the layout catches up: computing the
        // clamp straight away landed a document reopened at its end about a
        // third of the way down. Scrolling by range grows the frame first.
        editor.textView.scrollRangeToVisible(NSRange(location: index, length: 0))

        let maximum = max(0, editor.textView.frame.height - clip.bounds.height)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: min(target, maximum)))
        editor.scrollView.reflectScrolledClipView(clip)
    }

    /// The first character on screen, which is what "where I was" means.
    private func rememberReadingPosition() {
        let visible = editor.scrollView.documentVisibleRect
        let top = NSPoint(x: visible.minX + editor.textView.textContainerInset.width + 1,
                          y: visible.minY + 1)
        let index = editor.textView.characterIndexForInsertion(at: top)
        ReadingPosition.remember(character: index, for: editor.documentURL)
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
    /// The inset was hardcoded, for exactly this reason.
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
    @objc func toggleTaskAtCaret(_ sender: Any?) { editor.toggleTaskAtCaret() }

    @objc func setHeadingLevel(_ sender: Any?) {
        // The level travels in the menu item's `tag`: one action for all of
        // them, and the ⌘⌃n shortcut stays readable in the menu.
        guard let item = sender as? NSMenuItem else { return }
        editor.setHeadingLevel(item.tag)
    }

    @objc func pastePlainText(_ sender: Any?) {
        editor.textView.pastePlainText(sender)
    }

    /// `NSWindowController` doesn't inherit validation: without this
    /// conformance, the items would stay grayed out even though the actions
    /// exist. This is also where the checked states get updated.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSourceMode(_:)):
            menuItem.title = editor.isSourceMode ? "Hide Source" : "Show Source"

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
             #selector(insertLink(_:)), #selector(setHeadingLevel(_:)):
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

// MARK: - NSWindowDelegate

extension DocumentWindowController: NSWindowDelegate {

    /// The scroll offset is written on the way out rather than as it changes:
    /// a scroll is a continuous gesture, and `UserDefaults` is not the place
    /// to record every frame of one.
    func windowWillClose(_ notification: Notification) {
        rememberReadingPosition()
    }
}
