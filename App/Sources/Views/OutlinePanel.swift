// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The document outline (§4.5).
///
/// A collapsible panel, closed by default. §7 asks that the app disappear:
/// a permanent sidebar would be exactly what that seeks to avoid. This one
/// opens on `⌘⌥0`, is used to navigate, and closes again.
@MainActor
final class OutlinePanel: NSView {

    /// An entry in the outline.
    ///
    /// `Equatable` so `update` can recognize an outline that has not moved:
    /// see the guard below that spares a `reloadData` on every keystroke.
    struct Item: Equatable {
        var title: String
        var level: Int
        var location: Int
    }

    /// Called when the user picks a heading.
    var onSelect: ((Int) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var items: [Item] = []

    /// What the panel says when it has nothing to list.
    ///
    /// An empty, silent panel reads as broken: it opens, shows nothing, and
    /// nothing tells whether the outline is broken or the document simply
    /// has no headings. The sentence answers the question and gives the
    /// gesture.
    private let emptyLabel = NSTextField(wrappingLabelWithString:
        "No headings in this document.\n\nHeadings appear here as you write "
        + "them — \"#\" at the start of a line, or ⌘⌃1.")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyLayerBackground(Theme.NS.window)

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

        let column = NSTableColumn(identifier: .init("heading"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        // The title bar is transparent and the tabs overlap it: without this
        // inset, the first headings would pass underneath.
        scrollView.contentInsets = NSEdgeInsets(top: Theme.Space.s64, left: 0, bottom: Theme.Space.s12, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // A dividing rule, not a border: the panel must stand apart from the
        // text column without becoming a separate object.
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

        emptyTop = emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Space.s64)
        NSLayoutConstraint.activate([
            emptyTop,
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
    required init?(coder: NSCoder) { fatalError("no view comes from a xib") }

    /// The background is **resolved at layout time**: a `CGColor` follows
    /// neither a light/dark switch, nor — the trickiest case — the simple
    /// birth of a view in an app whose theme differs from the system's. See
    /// `applyLayerBackground(_:)`.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerBackground(Theme.NS.window)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLayerBackground(Theme.NS.window)
    }

    /// The inset left for the title bar, dictated by the window rather than
    /// guessed: see `DocumentWindowController.applyTitleBarInset()`.
    var topInset: CGFloat = Theme.Space.s64 {
        didSet {
            guard topInset != oldValue else { return }
            scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0,
                                                    bottom: Theme.Space.s12, right: 0)
            emptyTop.constant = topInset
        }
    }

    private var emptyTop: NSLayoutConstraint!

    // MARK: - Content

    /// Rebuilds the outline from the document's constructs.
    ///
    /// Called on **every keystroke** — the price of an outline that follows
    /// what is being written — hence the two precautions below: the markers
    /// are computed once for all headings, and the table only reloads if
    /// the outline actually changed.
    func update(spans: [SyntaxSpan], text: NSString) {
        let markers = Self.inlineMarkers(of: spans)
        let next = spans
            .compactMap { span -> Item? in
                guard case .heading(let level) = span.kind,
                      span.content.upperBound <= text.length else { return nil }
                let title = Self.plainText(of: span.content, markers: markers, text: text)
                guard !title.isEmpty else { return nil }
                return Item(title: title, level: level, location: span.range.location)
            }
            .sorted { $0.location < $1.location }

        // Typing inside a paragraph changes no heading. Reloading anyway
        // used to make the list jump under the user's eyes on every
        // keystroke, and undid the highlighted row only to reset it at once.
        guard next != items else { return }
        items = next
        tableView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
    }

    /// All the document's inline markers, sorted.
    ///
    /// # Why they are pulled out of `plainText`
    ///
    /// The function used to re-filter the **entire** list of constructs for
    /// each heading: with two hundred headings in a twenty-thousand-construct
    /// document, that was four million tests — on every keystroke, for as
    /// long as the outline stayed open. The markers do not depend on any
    /// particular heading: they are computed once, and each heading only
    /// takes its own slice of them.
    static func inlineMarkers(of spans: [SyntaxSpan]) -> [NSRange] {
        spans
            .filter { $0.kind.revealScope == .innermostInline }
            .flatMap(\.markers)
            .sorted { $0.location < $1.location }
    }

    /// The heading as it reads in the document, markers removed.
    ///
    /// The outline used to show the **source**: `## 2. Tasks — in
    /// **2 — Notes**` would read there with its asterisks. It is the only
    /// list in the app that let them show, while everything else is built to
    /// keep them silent — and in a narrow panel, the two asterisks eat into
    /// the space of the text being searched for.
    static func plainText(of content: NSRange, spans: [SyntaxSpan], text: NSString) -> String {
        plainText(of: content, markers: inlineMarkers(of: spans), text: text)
    }

    /// Reference version, by scanning.
    ///
    /// Kept on the model of `RevealPolicy.revealedIndicesByScan`: it is the
    /// literal definition — "strip from this heading the markers that run
    /// through it" — and `OutlinePanelTests` uses it to verify that the fast
    /// version renders exactly the same text.
    static func plainTextByScan(of content: NSRange, spans: [SyntaxSpan], text: NSString) -> String {
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

    static func plainText(of content: NSRange, markers: [NSRange], text: NSString) -> String {
        // The first marker that can touch the content, by binary search: the
        // list is sorted, and a heading near the bottom of a long document
        // has no reason to scan all the ones before it.
        var low = 0
        var high = markers.count
        while low < high {
            let middle = (low + high) / 2
            if markers[middle].upperBound <= content.location { low = middle + 1 } else { high = middle }
        }

        var result = ""
        var index = content.location
        for cut in markers[low...] {
            guard cut.location < content.upperBound else { break }
            guard cut.location >= index else { continue }
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

    /// Highlights the heading the caret is currently within.
    func highlight(caret: Int) {
        guard let index = items.lastIndex(where: { $0.location <= caret }) else {
            tableView.deselectAll(nil)
            return
        }
        // Already in place: without this guard, every caret move would
        // request a scroll again, and the list would jitter while typing —
        // even while staying within the same section.
        guard tableView.selectedRow != index else { return }
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

    /// The selection is gray, not blue. See `ListRowView`.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ListRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let label = NSTextField(labelWithString: item.title)
        // The level reads through indentation and weight, not size: six
        // sizes in a 200-point panel would make deep headings illegible.
        label.font = .systemFont(ofSize: 12, weight: item.level <= 2 ? .medium : .regular)
        label.textColor = item.level <= 2 ? Theme.NS.label : Theme.NS.labelSecondary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        // §8: the level reads through indentation and weight, two things a
        // screen reader cannot see. It must therefore be spoken.
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.staticText)
        container.setAccessibilityLabel("Heading, level \(item.level), \(item.title)")
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
