// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Le plan du document (§4.5).
///
/// Un panneau repliable, fermé par défaut. Le §7 demande que l'app disparaisse :
/// une barre latérale permanente serait exactement ce qu'on cherche à éviter.
/// Celle-ci s'ouvre sur `⌘⌥0`, sert à naviguer, et se referme.
@MainActor
final class OutlinePanel: NSView {

    /// Une entrée du plan.
    struct Item {
        var title: String
        var level: Int
        var location: Int
    }

    /// Appelé quand l'utilisateur choisit un titre.
    var onSelect: ((Int) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var items: [Item] = []

    /// Ce que dit le panneau quand il n'a rien à lister.
    ///
    /// Un panneau vide et muet se lit comme une panne : on l'ouvre, il ne
    /// montre rien, et rien ne dit si le plan est cassé ou si le document n'a
    /// pas de titre. La phrase répond à la question et donne le geste.
    private let emptyLabel = NSTextField(wrappingLabelWithString:
        "Aucun titre dans ce document.\n\nLes titres apparaissent ici à mesure "
        + "que vous les écrivez — « # » en début de ligne, ou ⌘⌃1.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.NS.window.cgColor

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight = 24
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        let column = NSTableColumn(identifier: .init("titre"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        // La barre de titre est transparente et les onglets s'y superposent :
        // sans ce retrait, les premiers titres passeraient dessous.
        scrollView.contentInsets = NSEdgeInsets(top: Theme.Space.s64, left: 0, bottom: Theme.Space.s12, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Un filet de séparation, pas une bordure : le panneau doit se
        // distinguer de la colonne de texte sans devenir un objet à part.
        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = Theme.NS.separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.textColor = Theme.NS.labelTertiary
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.s64),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s16),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.s16),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),

            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("aucune vue ne vient d'un xib") }

    // MARK: - Contenu

    /// Reconstruit le plan depuis les constructions du document.
    func update(spans: [SyntaxSpan], text: NSString) {
        items = spans
            .compactMap { span -> Item? in
                guard case .heading(let level) = span.kind,
                      span.content.upperBound <= text.length else { return nil }
                let title = Self.plainText(of: span.content, spans: spans, text: text)
                guard !title.isEmpty else { return nil }
                return Item(title: title, level: level, location: span.range.location)
            }
            .sorted { $0.location < $1.location }
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
    }

    /// Le titre tel qu'on le lit dans le document, marqueurs retirés.
    ///
    /// Le plan montrait la **source** : `## 2. Les tâches — dans **2 — Notes**`
    /// s'y lisait avec ses étoiles. C'est la seule liste de l'app qui les
    /// laissait voir, alors que tout le reste est bâti pour les taire — et
    /// dans un panneau étroit, les deux étoiles mangent la place du texte
    /// qu'on cherche.
    static func plainText(of content: NSRange, spans: [SyntaxSpan], text: NSString) -> String {
        let cuts = spans
            .filter { $0.kind.revealScope == .innermostInline
                      && NSIntersectionRange($0.range, content).length > 0 }
            .flatMap(\.markers)
            .filter { NSIntersectionRange($0, content).length > 0 }
            .sorted { $0.location < $1.location }

        var result = ""
        var index = content.location
        for cut in cuts where cut.location >= index {
            if cut.location > index {
                result += text.substring(with: NSRange(location: index, length: cut.location - index))
            }
            index = max(index, cut.upperBound)
        }
        if index < content.upperBound {
            result += text.substring(with: NSRange(location: index, length: content.upperBound - index))
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Met en évidence le titre dans lequel se trouve le curseur.
    func highlight(caret: Int) {
        guard let index = items.lastIndex(where: { $0.location <= caret }) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes([index], byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    var isEmpty: Bool { items.isEmpty }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard items.indices.contains(row) else { return }
        onSelect?(items[row].location)
    }
}

// MARK: - Table

extension OutlinePanel: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    /// La sélection est grise, pas bleue. Voir `ListRowView`.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ListRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let label = NSTextField(labelWithString: item.title)
        // Le niveau se lit au retrait et à la graisse, pas à la taille : six
        // tailles dans un panneau de 200 points rendraient les titres profonds
        // illisibles.
        label.font = .systemFont(ofSize: 12, weight: item.level <= 2 ? .medium : .regular)
        label.textColor = item.level <= 2 ? Theme.NS.label : Theme.NS.labelSecondary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        // §8 : le niveau se lit au retrait et à la graisse, deux choses qu'un
        // lecteur d'écran ne voit pas. Il faut donc le dire.
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.staticText)
        container.setAccessibilityLabel("Titre, niveau \(item.level), \(item.title)")
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                           constant: 8 + CGFloat(item.level - 1) * 11),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }
}
