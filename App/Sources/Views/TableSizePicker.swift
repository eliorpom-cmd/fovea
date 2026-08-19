// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The checkerboard grid for creating a table.
///
/// Inserting a table used to mean accepting a 3 × 3 and then fixing it. The
/// grid asks the question at the moment the answer is known, and it asks
/// **without words**: the user hovers, watches the grid fill in, and
/// clicks. It is next to nothing to write, and it avoids counting columns.
@MainActor
final class TableSizePicker: FloatingPanel {

    /// Called with the chosen number of columns and body rows.
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

    /// The arrow keys move the chosen corner. The grid is therefore fully
    /// keyboard-driven, like everything else.
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
        // "3 columns × 2 rows" reads clearly; "3 × 2" is hard to guess when
        // it is unclear which one comes first.
        label.stringValue = "\(columns) column\(columns > 1 ? "s" : "") × \(rows) row\(rows > 1 ? "s" : "")"
    }

    // MARK: - The grid itself

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
            // An AppKit view's origin is at the bottom: the table's first
            // row is therefore the **last** row drawn.
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
                    // The first row is the header: an outline sets it apart,
                    // so the user knows what is being created before it exists.
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
