// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The language picker for a code block.
///
/// It opens on its own as soon as the caret lands right after the backticks
/// of an opening fence, and filters as the user types — exactly like the
/// slash menu, and for the same reason: no one should have to know by heart
/// the word the app expects.
@MainActor
final class LanguagePicker: FloatingPanel {

    var onChoose: ((String) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var entries: [String] = []

    private static let rowHeight: CGFloat = 24
    private static let width: CGFloat = 170
    private static let maximumVisibleRows = 6

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
        tableView.addTableColumn(NSTableColumn(identifier: .init("language")))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
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

    /// - Returns: `false` when nothing matches; the panel closes and the
    ///   caller knows what was typed is not a known language.
    @discardableResult
    func present(query: String, caretRect: NSRect, over host: NSWindow?) -> Bool {
        entries = CodeFence.matching(query)
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

    func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        let next = min(max(0, tableView.selectedRow + delta), entries.count - 1)
        tableView.selectRowIndexes([next], byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func confirmSelection() { run(at: tableView.selectedRow) }

    @objc private func rowClicked() { run(at: tableView.clickedRow) }

    private func run(at row: Int) {
        guard entries.indices.contains(row) else { return }
        let language = entries[row]
        dismiss()
        onChoose?(language)
    }
}

extension LanguagePicker: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    /// The selection is gray, not blue. See `ListRowView`.
    ///
    /// This picker had been overlooked: it was the only list in the app
    /// where the chosen row stayed painted in the system's accent color,
    /// which §7 reserves for the user's content.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ListRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: entries[row])
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Theme.Space.s12, bottom: 0, right: Theme.Space.s12)
        stack.alignment = .centerY
        return stack
    }
}
