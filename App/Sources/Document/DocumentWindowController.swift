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
