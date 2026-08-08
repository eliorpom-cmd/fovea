// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Le menu d'insertion de bloc, ouvert par `/` en début de ligne vide (§4.5).
///
/// # Il ne prend jamais le focus
///
/// C'est la seule décision d'architecture qui compte ici. Le panneau est
/// `nonactivatingPanel` et ne devient jamais fenêtre clé : le curseur reste
/// dans le texte, la frappe continue d'aller dans le tampon, et le menu se
/// contente de filtrer à mesure. On tape `/tab`, on voit la liste se réduire,
/// on valide.
///
/// L'alternative — un panneau qui prend le focus, comme `⌘K` — obligerait à
/// retirer le `/` du tampon puis à le remettre, et le curseur clignoterait
/// ailleurs pendant qu'on tape. Ce serait un mode ; ici il n'y en a pas.
///
/// Les touches de navigation sont donc reçues par la vue de texte, qui les
/// renvoie ici. Voir `EditorTextView.keyDown`.
@MainActor
final class SlashMenu: NSPanel {

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
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isMovable = false
        hidesOnDeactivate = true

        let visual = NSVisualEffectView()
        visual.material = .menu
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 10
        visual.layer?.masksToBounds = true

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

        visual.addSubview(scrollView)
        contentView = visual
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: visual.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
        ])
    }

    /// Il ne devient jamais clé : c'est tout le principe. Sans ce `false`, le
    /// curseur quitterait le texte à l'ouverture.
    override var canBecomeKey: Bool { false }

    var isOpen: Bool { isVisible }

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
        let height = CGFloat(rows) * Self.rowHeight + 8
        // Sous la ligne courante, décalé d'un cheveu : posé dessus, le menu
        // masquerait le mot qu'on est en train de taper.
        var origin = NSPoint(x: caretRect.minX, y: caretRect.minY - height - 6)
        if let screen = host?.screen ?? NSScreen.main {
            // Trop bas pour tenir : il repasse au-dessus du curseur.
            if origin.y < screen.visibleFrame.minY {
                origin.y = caretRect.maxY + 6
            }
            origin.x = min(origin.x, screen.visibleFrame.maxX - Self.width - 8)
        }
        setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)

        if !isVisible {
            host?.addChildWindow(self, ordered: .above)
            orderFront(nil)
        }
        return true
    }

    func dismiss() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
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
        return stack
    }
}
