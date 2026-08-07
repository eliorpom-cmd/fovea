// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Le chef d'orchestre : tampon, parseur, rendu, sélection.
///
/// Il n'y a **qu'un seul tampon**, et c'est le texte markdown (§3.1). Tout ce
/// que fait ce contrôleur, c'est décider quels attributs y sont posés et quand.
@MainActor
final class EditorController: NSObject {

    let textView: EditorTextView
    let scrollView: NSScrollView

    private(set) var spans: [SyntaxSpan] = []
    private(set) var positions = SourcePositionMap(text: "")
    private var revealed: Set<Int> = []

    var typography: EditorTypography {
        didSet { rerenderEverything() }
    }

    /// Mode source (§4.2) : le même tampon, sans la couche de style.
    private(set) var isSourceMode = false

    /// Appelé après chaque modification du texte, pour que le document sache
    /// qu'il est sale et que la barre d'état se rafraîchisse.
    var onTextChanged: (() -> Void)?

    // MARK: - Construction

    init(typography: EditorTypography = .default) {
        self.typography = typography
        self.textView = EditorTextView.make()
        self.scrollView = NSScrollView()
        super.init()

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.NS.window
        // §7 : l'app doit disparaître. Un ascenseur permanent est du chrome.
        scrollView.scrollerStyle = .overlay

        textView.delegate = self
        textView.handlesDeleteBackward = { [weak self] selection in
            self?.deleteConstruct(at: selection) ?? false
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceChanged),
            name: .foveaAppearanceChanged, object: textView)
    }

    // MARK: - Contenu

    var text: String {
        textView.string
    }

    func setText(_ newText: String) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
        storage.endEditing()
        // Le remplacement initial n'est pas une modification de l'utilisateur :
        // il ne doit ni salir le document ni entrer dans la pile d'annulation.
        textView.undoManager?.removeAllActions()
        reparse()
        rerenderEverything()
    }

    // MARK: - Analyse et rendu

    private func reparse() {
        let result = MarkdownParser.parse(textView.string)
        spans = result.spans
        positions = result.positions
    }

    private func rerenderEverything() {
        guard let storage = textView.textStorage else { return }
        guard !isSourceMode else {
            renderSourceMode(storage)
            return
        }
        revealed = currentRevealedIndices()
        let renderer = MarkdownRenderer(typography: typography)
        renderer.render(storage, spans: spans, revealed: revealed,
                        in: NSRange(location: 0, length: storage.length))
        textView.typography = typography
        textView.decorations = EditorDecoration.build(from: spans, typography: typography)
        applyColumnLayout()
    }

    /// Le filet de sécurité (§4.2) : le texte tel qu'il est dans le fichier,
    /// en chasse fixe, sans un seul attribut de rendu.
    private func renderSourceMode(_ storage: NSTextStorage) {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        storage.beginEditing()
        storage.setAttributes([
            .font: typography.codeBlock,
            .foregroundColor: Theme.NS.label,
            .paragraphStyle: style,
        ], range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        // Le mode source montre le fichier, pas une interprétation : aucune
        // marque dessinée n'y a sa place.
        textView.decorations = []
        applyColumnLayout()
    }

    /// Recalcule uniquement les constructions dont l'état de révélation a
    /// changé. C'est l'opération la plus fréquente de l'app — une flèche du
    /// clavier la déclenche — et la seule qui doive rester en dessous de la
    /// milliseconde quelle que soit la taille du document.
    private func updateReveal() {
        guard !isSourceMode, let storage = textView.textStorage else { return }
        let next = currentRevealedIndices()
        guard next != revealed else { return }

        let changed = next.symmetricDifference(revealed)
        revealed = next

        storage.beginEditing()
        let renderer = MarkdownRenderer(typography: typography)
        for index in changed where index < spans.count {
            renderer.applyMarkers(storage, span: spans[index], revealed: next.contains(index))
        }
        storage.endEditing()
    }

    private func currentRevealedIndices() -> Set<Int> {
        let selection = textView.selectedRange()
        let line = positions.lineRange(containing: min(selection.location, max(0, positions.utf16Length)))
        return RevealPolicy.revealedIndices(spans: spans, selection: selection, lineRange: line)
    }

    // MARK: - Mise en page de la colonne

    /// Centre la colonne de texte dans la fenêtre (§7). La largeur est mesurée
    /// en signes sur la fonte réelle, pas fixée en points, pour qu'elle suive
    /// le choix de police et de taille.
    func applyColumnLayout() {
        guard let container = textView.textContainer else { return }
        let available = scrollView.contentSize.width
        let column = min(typography.columnWidth, max(240, available - Theme.Space.s40 * 2))
        let inset = max(Theme.Space.s24, (available - column) / 2)
        textView.textContainerInset = NSSize(width: inset, height: Theme.Space.s64)
        container.size = NSSize(width: column, height: .greatestFiniteMagnitude)
        container.widthTracksTextView = false
    }

    // MARK: - Commandes

    func toggleSourceMode() {
        isSourceMode.toggle()
        rerenderEverything()
    }

    /// Supprime la construction entière quand `⌫` tomberait sur un marqueur
    /// (§2.5). Renvoie `false` pour laisser `NSTextView` faire son travail
    /// habituel dans tous les autres cas.
    private func deleteConstruct(at selection: NSRange) -> Bool {
        guard !isSourceMode, selection.location > 0, let storage = textView.textStorage else { return false }
        let target = selection.location - 1

        // La construction visée est celle dont un marqueur contient la position
        // qui allait être supprimée.
        guard let index = spans.firstIndex(where: { span in
            span.markers.contains { NSLocationInRange(target, $0) }
        }) else { return false }

        let span = spans[index]
        // Supprimer les marqueurs de la fin vers le début : chaque suppression
        // décale ce qui suit, et remonter évite d'avoir à recalculer les offsets.
        let ordered = span.markers.sorted { $0.location > $1.location }
        guard let undo = textView.undoManager else { return false }

        undo.beginUndoGrouping()
        storage.beginEditing()
        for marker in ordered where marker.upperBound <= storage.length {
            storage.replaceCharacters(in: marker, with: "")
        }
        storage.endEditing()
        undo.endUndoGrouping()

        textView.setSelectedRange(NSRange(location: max(0, span.content.location - lengthBefore(span)), length: 0))
        handleTextChange()
        return true
    }

    private func lengthBefore(_ span: SyntaxSpan) -> Int {
        span.markers.filter { $0.location < span.content.location }.reduce(0) { $0 + $1.length }
    }

    // MARK: - Réactions

    private func handleTextChange() {
        reparse()
        rerenderEverything()
        onTextChanged?()
    }

    @objc private func appearanceChanged() {
        // Les couleurs déjà posées dans le tampon ont été résolues au moment de
        // la pose : un changement clair/sombre ne les met pas à jour tout seul.
        rerenderEverything()
    }
}

// MARK: - NSTextViewDelegate

extension EditorController: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        handleTextChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateReveal()
    }
}

