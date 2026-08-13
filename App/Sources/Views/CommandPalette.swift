// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// La palette de commandes, `⌘K` (§4.5).
///
/// Elle sert deux choses à la fois, et c'est voulu : lancer une commande, et
/// **naviguer par titre**. Dans un document long, chercher « Architecture » et
/// y sauter est le geste le plus fréquent — plus fréquent que n'importe quelle
/// commande.
///
/// Le filtrage est **par sous-séquence**, comme partout ailleurs : taper
/// « mdf » doit trouver « Mode focus ». Un filtrage par préfixe obligerait à
/// se souvenir du premier mot exact, ce qui annule l'intérêt de la palette.
@MainActor
final class CommandPalette: NSPanel {

    struct Entry {
        var title: String
        /// Ce qui s'affiche à droite : le raccourci, ou la section d'un titre.
        var detail: String
        var action: () -> Void
    }

    private let field = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

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
        // Une palette qui survit à la perte du focus resterait en travers de
        // l'écran ; celle-ci se ferme dès qu'on regarde ailleurs.
        hidesOnDeactivate = true
        isFloatingPanel = true
        level = .modalPanel
        backgroundColor = .clear

        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 12
        visual.layer?.masksToBounds = true

        field.placeholderString = "Commande ou titre…"
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
        tableView.addTableColumn(NSTableColumn(identifier: .init("entrée")))

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        // La fenêtre est en `fullSizeContentView` : sans cela, AppKit réserve de
        // lui-même la hauteur d'une barre de titre — invisible ici — au-dessus
        // de la liste. La première entrée se décollait du filet, et la hauteur
        // ajustée aux résultats coupait la dernière en deux.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = Theme.NS.separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        visual.addSubview(field)
        visual.addSubview(divider)
        visual.addSubview(scrollView)
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
        ])
    }

    // MARK: - Présentation

    func present(entries: [Entry], relativeTo host: NSWindow?) {
        all = entries
        field.stringValue = ""
        filter(with: "")

        if let host {
            // Centrée horizontalement, au tiers supérieur : posée au milieu,
            // elle masquerait précisément la ligne qu'on vient de quitter.
            let frame = host.frame
            setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2,
                                   y: frame.maxY - self.frame.height - frame.height * 0.18))
        } else {
            center()
        }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    /// Un `NSPanel` refuse le focus par défaut ; sans cela, le champ de
    /// recherche ne recevrait pas la frappe.
    override var canBecomeKey: Bool { true }

    // MARK: - Filtrage

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
        resizeToFit()
    }

    /// Le nombre de lignes qu'on montre avant de laisser défiler.
    ///
    /// Au-delà, la palette occuperait la moitié de l'écran pour une liste qu'on
    /// ne lit pas jusqu'en bas : on cherche, on tape deux lettres de plus.
    private static let visibleRows = 11

    /// Ajuste la hauteur au nombre de résultats.
    ///
    /// La palette gardait ses 380 points quoi qu'il arrive : taper « machine »
    /// laissait un seul résultat et trois cents points de vide en dessous, ce
    /// qui se lit comme une fenêtre cassée plutôt que comme une recherche qui a
    /// trouvé. Elle se referme maintenant sur ce qu'elle montre.
    ///
    /// **Le haut reste où il est.** Un `NSWindow` a son origine en bas à
    /// gauche : redimensionner sans y penser ferait remonter le champ de
    /// recherche à chaque frappe, sous les doigts.
    private func resizeToFit() {
        guard let visual = contentView else { return }
        visual.layoutSubtreeIfNeeded()

        // Tout est **mesuré**, rien n'est recomposé à partir des constantes de
        // contraintes. Ni le chrome — un champ de recherche ne fait pas la
        // hauteur qu'on lui suppose —, ni les rangées : le style `.inset` d'un
        // `NSTableView` ajoute sa propre marge, et la calculer à
        // `rowHeight × n` coupait la dernière entrée en deux au ras de la
        // fenêtre. Une rangée tronquée est pire que le vide qu'on enlève.
        let chrome = visual.bounds.height - scrollView.frame.height
        let shown = min(filtered.count, Self.visibleRows)
        let rows = shown > 0
            ? tableView.rect(ofRow: shown - 1).maxY + tableView.rect(ofRow: 0).minY
            : 0
        let target = (chrome + rows).rounded()
        guard abs(frame.height - target) > 0.5 else { return }

        setFrame(NSRect(x: frame.minX, y: frame.maxY - target,
                        width: frame.width, height: target),
                 display: true)
    }

    /// Score d'une correspondance par sous-séquence, ou `nil` si le texte ne
    /// contient pas les lettres de la requête dans l'ordre.
    ///
    /// Les correspondances **en début de mot** valent plus : chercher « mf »
    /// doit remonter « Mode focus » avant « Rechercher un format ».
    /// `nonisolated` parce qu'elle est pure : elle ne touche ni à la vue ni à
    /// AppKit, et le menu slash s'en sert depuis la couche sans interface.
    nonisolated static func score(_ text: String, query: String) -> Int? {
        let haystack = Array(text.lowercased())
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
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
        close()
        entry.action()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: close()                                  // Échap
        case 36, 76: run(at: tableView.selectedRow)       // Entrée
        case 125: move(by: 1)                             // Flèche bas
        case 126: move(by: -1)                            // Flèche haut
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

// MARK: - Champ de recherche

extension CommandPalette: NSSearchFieldDelegate {

    func controlTextDidChange(_ notification: Notification) {
        filter(with: field.stringValue)
    }

    /// Les flèches et la touche Entrée doivent piloter la liste, pas le champ.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): move(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)): run(at: tableView.selectedRow); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }
}

// MARK: - Table

extension CommandPalette: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    /// La sélection est grise, pas bleue. Voir `ListRowView`.
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
        // Le raccourci en symboles — « ⌘⌥0 » — ne s'énonce pas ; le nom de la
        // commande, si.
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.staticText)
        stack.setAccessibilityLabel(entry.title)
        return stack
    }
}
