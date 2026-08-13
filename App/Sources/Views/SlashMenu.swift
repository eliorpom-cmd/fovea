// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Le menu d'insertion de bloc, ouvert par `/` (§4.5).
///
/// Le comportement de panneau — jamais fenêtre clé, ancré au curseur, piloté
/// par la vue de texte — vit dans `FloatingPanel`. Ne reste ici que la liste
/// des blocs et son filtrage.
///
/// L'alternative — un panneau qui prend le focus, comme `⌘K` — obligerait à
/// retirer le `/` du tampon puis à le remettre, et le curseur clignoterait
/// ailleurs pendant qu'on tape. Ce serait un mode ; ici il n'y en a pas.
@MainActor
final class SlashMenu: FloatingPanel {

    /// Appelé quand une entrée est validée.
    var onChoose: ((SlashCommand) -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var entries: [SlashCommand] = []

    private static let rowHeight: CGFloat = 28
    private static let width: CGFloat = 260
    private static let maximumVisibleRows = 7

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
        tableView.addTableColumn(NSTableColumn(identifier: .init("bloc")))

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

    // MARK: - Ouverture et filtrage

    /// Ouvre — ou met à jour — le menu sous le curseur.
    ///
    /// - Parameter caretRect: la position du curseur **en coordonnées écran**.
    /// - Returns: `false` si aucune entrée ne correspond ; le menu est alors
    ///   fermé, et l'appelant sait que la frappe est du texte ordinaire.
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

    // MARK: - Navigation, pilotée depuis la vue de texte

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

    /// La sélection est grise, pas bleue. Voir `ListRowView`.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ListRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = entries[row]
        let title = NSTextField(labelWithString: command.title)
        title.font = .systemFont(ofSize: 13)

        // La syntaxe posée, en chasse fixe : le menu montre ce qu'il écrit.
        let hint = NSTextField(labelWithString: command.hint)
        hint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        hint.textColor = Theme.NS.labelTertiary
        hint.alignment = .right
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [title, hint])
        stack.orientation = .horizontal
        stack.spacing = Theme.Space.s12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: Theme.Space.s12, bottom: 0, right: Theme.Space.s12)
        // La syntaxe affichée à droite ne s'énonce pas : « dièse dièse » n'aide
        // personne à l'oral. Seul le nom du bloc est lu.
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.staticText)
        stack.setAccessibilityLabel(command.title)
        return stack
    }
}
