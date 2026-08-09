// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Le damier de création d'un tableau.
///
/// Insérer un tableau demandait jusqu'ici d'accepter un 3 × 3 puis de le
/// corriger. Le damier pose la question au moment où l'on sait y répondre, et
/// il la pose **sans mots** : on survole, on voit la grille se remplir, on
/// clique. C'est trois fois rien à écrire et ça évite de compter des colonnes.
@MainActor
final class TableSizePicker: FloatingPanel {

    /// Appelé avec le nombre de colonnes et de lignes de corps choisi.
    var onChoose: ((_ columns: Int, _ rows: Int) -> Void)?

    private let grid = GridView()

    private static let maximumColumns = 8
    private static let maximumRows = 6
    private static let cell: CGFloat = 20
    private static let gap: CGFloat = 3
    private static let padding: CGFloat = 10
    private static let caption: CGFloat = 22

    private static var gridWidth: CGFloat {
        CGFloat(maximumColumns) * cell + CGFloat(maximumColumns - 1) * gap
    }
    private static var gridHeight: CGFloat {
        CGFloat(maximumRows) * cell + CGFloat(maximumRows - 1) * gap
    }

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(width: Self.gridWidth + Self.padding * 2)

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.onHover = { [weak self] columns, rows in self?.refreshCaption(columns, rows) }
        grid.onClick = { [weak self] columns, rows in self?.choose(columns, rows) }

        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.NS.labelSecondary
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(grid)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            grid.widthAnchor.constraint(equalToConstant: Self.gridWidth),
            grid.heightAnchor.constraint(equalToConstant: Self.gridHeight),
            label.topAnchor.constraint(equalTo: grid.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        refreshCaption(3, 2)
    }

    func present(caretRect: NSRect, over host: NSWindow?) {
        grid.selection = (3, 2)
        refreshCaption(3, 2)
        present(size: NSSize(width: Self.gridWidth + Self.padding * 2,
                             height: Self.gridHeight + Self.padding + Self.caption),
                caretRect: caretRect, over: host)
    }

    /// Les flèches déplacent le coin choisi. Le damier se pilote donc
    /// entièrement au clavier, comme tout le reste.
    func move(columns: Int, rows: Int) {
        let next = (min(max(1, grid.selection.columns + columns), Self.maximumColumns),
                    min(max(1, grid.selection.rows + rows), Self.maximumRows))
        grid.selection = next
        refreshCaption(next.0, next.1)
    }

    func confirmSelection() {
        choose(grid.selection.columns, grid.selection.rows)
    }

    private func choose(_ columns: Int, _ rows: Int) {
        dismiss()
        onChoose?(columns, rows)
    }

    private func refreshCaption(_ columns: Int, _ rows: Int) {
        grid.selection = (columns, rows)
        // « 3 colonnes × 2 lignes » se lit ; « 3 × 2 » se devine mal quand on ne
        // sait pas lequel vient en premier.
        label.stringValue = "\(columns) colonne\(columns > 1 ? "s" : "") × \(rows) ligne\(rows > 1 ? "s" : "")"
    }

    // MARK: - La grille elle-même

    private final class GridView: NSView {
        var selection: (columns: Int, rows: Int) = (3, 2) { didSet { needsDisplay = true } }
        var onHover: ((Int, Int) -> Void)?
        var onClick: ((Int, Int) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        private func cellAt(_ point: NSPoint) -> (Int, Int)? {
            let step = TableSizePicker.cell + TableSizePicker.gap
            let column = Int(point.x / step) + 1
            // L'origine d'une vue AppKit est en bas : la première ligne du
            // tableau est donc la **dernière** rangée dessinée.
            let row = TableSizePicker.maximumRows - Int(point.y / step)
            guard (1...TableSizePicker.maximumColumns).contains(column),
                  (1...TableSizePicker.maximumRows).contains(row) else { return nil }
            return (column, row)
        }

        override func mouseMoved(with event: NSEvent) {
            guard let (column, row) = cellAt(convert(event.locationInWindow, from: nil)) else { return }
            onHover?(column, row)
        }

        override func mouseDown(with event: NSEvent) {
            guard let (column, row) = cellAt(convert(event.locationInWindow, from: nil)) else { return }
            onClick?(column, row)
        }

        override func draw(_ dirtyRect: NSRect) {
            let step = TableSizePicker.cell + TableSizePicker.gap
            for column in 1...TableSizePicker.maximumColumns {
                for row in 1...TableSizePicker.maximumRows {
                    let frame = NSRect(x: CGFloat(column - 1) * step,
                                       y: CGFloat(TableSizePicker.maximumRows - row) * step,
                                       width: TableSizePicker.cell,
                                       height: TableSizePicker.cell)
                    let chosen = column <= selection.columns && row <= selection.rows
                    let path = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
                    (chosen ? Theme.NS.label : Theme.NS.fillTertiary).setFill()
                    path.fill()
                    // La première rangée est l'en-tête : un liseré la distingue,
                    // pour qu'on sache ce qu'on crée avant de l'avoir créé.
                    if row == 1 {
                        Theme.NS.labelSecondary.setStroke()
                        path.lineWidth = 1
                        path.stroke()
                    }
                }
            }
        }
    }
}
