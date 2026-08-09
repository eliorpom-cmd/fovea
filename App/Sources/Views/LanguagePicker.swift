// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Le choix du langage d'un bloc de code.
///
/// Il s'ouvre tout seul dès que le curseur se pose après les accents graves
/// d'une ouverture, et se filtre à mesure qu'on tape — exactement comme le menu
/// slash, et pour la même raison : personne ne devrait avoir à connaître par
/// cœur le mot que l'app attend.
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
        tableView.addTableColumn(NSTableColumn(identifier: .init("langage")))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
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

    /// - Returns: `false` quand rien ne correspond ; le panneau se referme et
    ///   l'appelant sait que ce qui est tapé n'est pas un langage connu.
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
