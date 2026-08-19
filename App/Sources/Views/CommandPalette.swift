// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The command palette, `⌘K` (§4.5).
///
/// It serves two purposes at once, deliberately: run a command, and
/// **navigate by title**. In a long document, searching for "Architecture"
/// and jumping to it is the most frequent gesture — more frequent than any
/// command.
///
/// Filtering is **by subsequence**, as everywhere else in the app: typing
/// "mdf" must find "Mode focus". Prefix filtering would force remembering
/// the exact first word, which defeats the purpose of the palette.
@MainActor
final class CommandPalette: NSPanel {

    struct Entry {
        var title: String
        /// What is shown on the right: the shortcut, or the section of a title.
        var detail: String
        var action: () -> Void
    }

    private let field = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No results.")

    private var all: [Entry] = []
    private var filtered: [Entry] = []

    // MARK: - Construction

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        // A palette that survives losing focus would stay stranded across
        // the screen; this one closes as soon as the user looks elsewhere.
        hidesOnDeactivate = true
        isFloatingPanel = true
        level = .modalPanel
        backgroundColor = .clear
        // **Without this, `close()` over-releases the window.** The default
        // for an `NSWindow` created in code is `true`: closing sends a
        // `release` on an object a strong property of the controller already
        // retains. A `⌘K`, an `⎋`, a second `⌘K`, and the app crashed on a
        // dead object. `SettingsWindowController` did set the flag; the
        // palette had been overlooked.
        isReleasedWhenClosed = false

        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 12
        visual.layer?.masksToBounds = true

        field.placeholderString = "Command or title…"
        field.font = .systemFont(ofSize: 15)
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.rowHeight = 30
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.addTableColumn(NSTableColumn(identifier: .init("entry")))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        // The window is `fullSizeContentView`: without this, AppKit reserves
        // the height of a title bar on its own — invisible here — above the
        // list. The first entry would pull away from the divider, and the
        // height fitted to the results would cut the last one in half.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = Theme.NS.separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // **A search with no results must say so.** The list used to empty
        // out and the window would close in on its field: a gray band
        // without a word, which reads as a broken palette rather than a
        // search that found nothing.
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = Theme.NS.labelTertiary
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        visual.addSubview(field)
        visual.addSubview(divider)
        visual.addSubview(scrollView)
        visual.addSubview(emptyLabel)
        contentView = visual

        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: visual.topAnchor, constant: Theme.Space.s12),
            field.leadingAnchor.constraint(equalTo: visual.leadingAnchor, constant: Theme.Space.s12),
            field.trailingAnchor.constraint(equalTo: visual.trailingAnchor, constant: -Theme.Space.s12),

            divider.topAnchor.constraint(equalTo: field.bottomAnchor, constant: Theme.Space.s12),
            divider.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: visual.bottomAnchor),

            emptyLabel.topAnchor.constraint(equalTo: divider.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            emptyLabel.heightAnchor.constraint(equalToConstant: Self.emptyHeight),
        ])
    }

    /// The height left for "No results" — that of two rows, enough for the
    /// sentence to breathe without the window looking empty.
    private static let emptyHeight: CGFloat = 60

    // MARK: - Presentation

    func present(entries: [Entry], relativeTo host: NSWindow?) {
        all = entries
        field.stringValue = ""
        filter(with: "")

        if let host {
            // Centered horizontally, at the upper third: placed in the
            // middle, it would hide precisely the line just left behind.
            let frame = host.frame
            setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2,
                                   y: frame.maxY - self.frame.height - frame.height * 0.18))
        } else {
            center()
        }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        // A system field's insertion point is **blue**, and it was the last
        // accent color left in the app outside of Settings. The editor sets
        // its own; the search field lives in a shared field editor, which
        // can only be colored once it exists — that is, here.
        (currentEditor(for: field) as? NSTextView)?.insertionPointColor = Theme.NS.label
    }

    private func currentEditor(for control: NSControl) -> NSText? {
        control.currentEditor() ?? fieldEditor(true, for: control)
    }

    /// An `NSPanel` refuses key status by default; without this, the search
    /// field would not receive keystrokes.
    override var canBecomeKey: Bool { true }

    /// **Clicking elsewhere closes it.**
    ///
    /// `hidesOnDeactivate` only fires when the *application* loses focus.
    /// Clicking in the editing window does not deactivate it: the palette,
    /// at `.modalPanel` level, would stay stranded across the screen until
    /// the user thought of `⎋`. A search palette closes as soon as the user
    /// looks elsewhere, like Spotlight's.
    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    /// Closes, once only.
    ///
    /// The guard is not gratuitous caution: `close()` makes the window lose
    /// key status, which calls `resignKey`, which would call `dismiss` again.
    func dismiss() {
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        close()
        isDismissing = false
    }

    private var isDismissing = false

    // MARK: - Filtering

    private func filter(with query: String) {
        filtered = query.isEmpty
            ? all
            : all
                .compactMap { entry -> (Entry, Int)? in
                    guard let score = Self.score(entry.title, query: query) else { return nil }
                    return (entry, score)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes([0], byExtendingSelection: false)
        }
        emptyLabel.isHidden = !filtered.isEmpty
        scrollView.isHidden = filtered.isEmpty
        resizeToFit()
    }

    /// The number of rows shown before scrolling kicks in.
    ///
    /// Beyond that, the palette would take up half the screen for a list
    /// that is not read to the bottom: the user searches, then types two
    /// more letters.
    private static let visibleRows = 11


    /// Fits the height to the number of results.
    ///
    /// The palette used to keep its 380 points no matter what: typing
    /// "typewriter" would leave a single result and three hundred points of
    /// empty space below it, which reads as a broken window rather than a
    /// search that found something. It now closes in on what it shows.
    ///
    /// **The top stays where it is.** An `NSWindow` has its origin at the
    /// bottom left: resizing without accounting for that would make the
    /// search field jump up on every keystroke, out from under the fingers.
    private func resizeToFit() {
        guard let visual = contentView else { return }
        visual.layoutSubtreeIfNeeded()

        // Everything is **measured**, nothing is recomputed from constraint
        // constants. Not the chrome — a search field is not as tall as one
        // would assume — nor the rows: the `.inset` style of an
        // `NSTableView` adds its own margin, and computing it as
        // `rowHeight × n` used to cut the last entry in half at the edge of
        // the window. A truncated row is worse than the empty space removed
        // to avoid it.
        let chrome = visual.bounds.height - scrollView.frame.height
        let shown = min(filtered.count, Self.visibleRows)
        let rows = shown > 0
            ? tableView.rect(ofRow: shown - 1).maxY + tableView.rect(ofRow: 0).minY
            : Self.emptyHeight
        let target = (chrome + rows).rounded()
        guard abs(frame.height - target) > 0.5 else { return }

        setFrame(NSRect(x: frame.minX, y: frame.maxY - target,
                        width: frame.width, height: target),
                 display: true)
    }

    /// Score of a subsequence match, or `nil` if the text does not contain
    /// the letters of the query in order.
    ///
    /// Matches **at the start of a word** are worth more: searching for "mf"
    /// must rank "Mode focus" above "Search for a format". `nonisolated`
    /// because it is pure: it touches neither the view nor AppKit, and the
    /// slash menu uses it from the interface-free layer. Case- **and
    /// accent-**insensitive.
    ///
    /// The comparison used to be a plain `lowercased()`: "cafe" would not
    /// find "café", "resume" would not find "résumé". In an app whose titles
    /// are accented as often as not, searching by title would require typing
    /// the exact accent — that is, already knowing what is being searched
    /// for.
    ///
    /// The fallback runs without a locale, so it is identical everywhere:
    /// the result should not depend on the system's language.
    nonisolated static func folded(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    nonisolated static func score(_ text: String, query: String) -> Int? {
        let haystack = Array(Self.folded(text))
        let needle = Array(Self.folded(query).filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }

        var score = 0
        var index = 0
        var previousWasSeparator = true
        for character in needle {
            var found = false
            while index < haystack.count {
                let candidate = haystack[index]
                let isSeparator = candidate == " " || candidate == "-" || candidate == "'"
                index += 1
                if candidate == character {
                    score += previousWasSeparator ? 10 : 1
                    previousWasSeparator = false
                    found = true
                    break
                }
                previousWasSeparator = isSeparator
            }
            guard found else { return nil }
        }
        return score
    }

    // MARK: - Actions

    @objc private func rowClicked() {
        run(at: tableView.clickedRow)
    }

    private func run(at row: Int) {
        guard filtered.indices.contains(row) else { return }
        let entry = filtered[row]
        dismiss()
        entry.action()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: dismiss()                                // Escape
        case 36, 76: run(at: tableView.selectedRow)       // Return
        case 125: move(by: 1)                             // Down arrow
        case 126: move(by: -1)                            // Up arrow
        default: super.keyDown(with: event)
        }
    }

    private func move(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let next = min(max(0, tableView.selectedRow + delta), filtered.count - 1)
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

// MARK: - Search field

extension CommandPalette: NSSearchFieldDelegate {

    func controlTextDidChange(_ notification: Notification) {
        filter(with: field.stringValue)
    }

    /// The arrow keys and the Return key must drive the list, not the field.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): move(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)): run(at: tableView.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }
}

// MARK: - Table

extension CommandPalette: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    /// The selection is gray, not blue. See `ListRowView`.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ListRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row]
        let title = NSTextField(labelWithString: entry.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(labelWithString: entry.detail)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Theme.NS.labelTertiary
        detail.alignment = .right
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .horizontal
        stack.spacing = Theme.Space.s12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Theme.Space.s12, bottom: 0, right: Theme.Space.s12)
        // The shortcut in symbols — "⌘⌥0" — is not spoken; the command name
        // is.
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.staticText)
        stack.setAccessibilityLabel(entry.title)
        return stack
    }
}
