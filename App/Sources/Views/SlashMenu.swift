// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The block insertion menu, opened by `/` (§4.5).
///
/// The panel behavior — never a key window, anchored to the caret, driven
/// by the text view — lives in `FloatingPanel`. Only the list of blocks and
/// its filtering remain here.
///
/// The alternative — a panel that takes focus — would force
/// removing the `/` from the buffer and putting it back, and the caret would
/// blink elsewhere while typing. That would be a mode; there is none here.
@MainActor
final class SlashMenu: FloatingPanel {

    /// Called when an entry is confirmed.
    var onChoose: ((SlashCommand) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var entries: [SlashCommand] = []

    private static let rowHeight: CGFloat = 28
    private static let width: CGFloat = 260
    /// Ten — that is, **all of them**.
    ///
    /// Seven used to be shown, with no scroller and no hint that there were
    /// more: "Code Block", "Table" and "Horizontal Rule" were invisible.
    /// Including "Table", which is the whole reason the menu exists — it is
    /// the block nobody knows how to write by hand, hence the one the menu
    /// gets opened for.
    private static let maximumVisibleRows = SlashCommand.allCases.count

    // MARK: - Construction

    init() {
        super.init(width: Self.width)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.addTableColumn(NSTableColumn(identifier: .init("block")))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        // The panel can shrink for lack of room under the caret (see
        // `FloatingPanel.present`): it then needs a way to say it continues.
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    // MARK: - Opening and filtering

    /// Opens — or updates — the menu under the caret.
    ///
    /// - Parameter caretRect: the caret's position **in screen coordinates**.
    /// - Returns: `false` if no entry matches; the menu is then closed, and
    ///   the caller knows the keystroke is ordinary text.
    @discardableResult
    func present(query: String, caretRect: NSRect, over host: NSWindow?) -> Bool {
        entries = SlashCommand.matching(query)
        guard !entries.isEmpty else {
            dismiss()
            return false
        }

        tableView.reloadData()
        tableView.selectRowIndexes([0], byExtendingSelection: false)

        let rows = min(entries.count, Self.maximumVisibleRows)
        present(size: NSSize(width: Self.width, height: CGFloat(rows) * Self.rowHeight + 8),
                caretRect: caretRect, over: host)
        return true
    }

    // MARK: - Navigation, driven from the text view

    func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        let next = min(max(0, tableView.selectedRow + delta), entries.count - 1)
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func confirmSelection() {
        run(at: tableView.selectedRow)
    }

    @objc private func rowClicked() { run(at: tableView.clickedRow) }

    private func run(at row: Int) {
        guard entries.indices.contains(row) else { return }
        let command = entries[row]
        dismiss()
        onChoose?(command)
    }
}

// MARK: - Table

extension SlashMenu: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    /// The selection is gray, not blue. See `ListRowView`.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ListRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = entries[row]
        let title = NSTextField(labelWithString: command.title)
        title.font = .systemFont(ofSize: 13)

        // The syntax it inserts, in monospace: the menu shows what it writes.
        let hint = NSTextField(labelWithString: command.hint)
        hint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hint.textColor = Theme.NS.labelTertiary
        hint.alignment = .right
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [title, hint])
        stack.orientation = .horizontal
        stack.spacing = Theme.Space.s12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Theme.Space.s12, bottom: 0, right: Theme.Space.s12)
        // The syntax shown on the right is not spoken: "hash hash" helps no
        // one aloud. Only the block's name is read.
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.staticText)
        stack.setAccessibilityLabel(command.title)
        return stack
    }
}
