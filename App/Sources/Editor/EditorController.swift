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
    private var revealed: Set<Int> = []
    /// Reconstruit à chaque analyse, consulté à chaque déplacement du curseur.
    private var spanIndex = SpanIndex([])

    /// La dernière édition signalée par `NSTextStorage`, pour que le cycle de
    /// frappe sache quel bloc ré-analyser.
    private var lastEditedRange: NSRange?
    private var lastChangeInLength = 0

    var typography: EditorTypography {
        didSet {
            rerenderEverything()
            applyColumnLayout()
        }
    }

    /// L'emplacement du document, pour résoudre les images en chemin relatif
    /// (§4.4). `nil` tant que le document n'a pas été enregistré.
    var documentURL: URL? {
        didSet {
            guard documentURL != oldValue else { return }
            ImageStore.shared.invalidate()
            rerenderEverything()
        }
    }

    /// Mode source (§4.2) : le même tampon, sans la couche de style.
    private(set) var isSourceMode = false

    /// Appelé après chaque modification du texte, pour que le document sache
    /// qu'il est sale et que la barre d'état se rafraîchisse.
    var onTextChanged: (() -> Void)?

    /// Appelé quand la sélection bouge, pour rafraîchir les statistiques.
    var onSelectionChanged: (() -> Void)?

    /// Appelé quand les constructions ont changé, pour que le plan suive.
    var onSpansChanged: (() -> Void)?

    // MARK: - Construction

    init(typography: EditorTypography? = nil) {
        self.typography = typography ?? AppSettings.shared.typography
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
        textView.textStorage?.delegate = self
        textView.handlesDeleteBackward = { [weak self] selection in
            self?.deleteConstruct(at: selection) ?? false
        }
        textView.handlesNewline = { [weak self] in
            guard let self, AppSettings.shared.markdownShortcutsWhileTyping else { return false }
            return apply(TypingBehaviour.newline(in: text, selection: textView.selectedRange()))
        }
        textView.handlesIndent = { [weak self] outdent in
            guard let self, AppSettings.shared.markdownShortcutsWhileTyping else { return false }
            return apply(TypingBehaviour.indent(in: text, selection: textView.selectedRange(), outdent: outdent))
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceChanged),
            name: .foveaAppearanceChanged, object: textView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: AppSettings.didChange, object: nil)
    }

    // MARK: - Contenu

    var text: String {
        textView.string
    }

    /// Longueur analysée et stylée **avant** le premier affichage.
    ///
    /// Assez pour plusieurs écrans à n'importe quelle taille de police ; le
    /// reste attend le tour de boucle suivant. Voir `setText(_:)`.
    private static let firstPaintLength = 40_000

    func setText(_ newText: String) {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: newText)
        storage.endEditing()
        // Le remplacement initial n'est pas une modification de l'utilisateur :
        // il ne doit ni salir le document ni entrer dans la pile d'annulation.
        textView.undoManager?.removeAllActions()
        lastEditedRange = nil
        lastChangeInLength = 0

        guard storage.length > Self.firstPaintLength else {
            reparse()
            rerenderEverything()
            applyColumnLayout()
            return
        }

        // **Ouverture progressive.** Analyser et styler 600 pages avant de
        // montrer quoi que ce soit coûtait plus d'une seconde, pour un budget
        // de 500 ms (§9) — et l'utilisateur n'a besoin que du premier écran.
        //
        // TextKit 2 ne met déjà en page que le viewport ; ce qui restait
        // proportionnel au document, c'était l'analyse et la pose d'attributs.
        // On en fait juste assez pour peindre, le reste suit immédiatement
        // après, avant même que la main n'ait quitté le clavier.
        let head = IncrementalParse.blockRange(
            in: storage.mutableString,
            around: NSRange(location: 0, length: Self.firstPaintLength))
        spans = MarkdownParser.parse(storage.mutableString.substring(with: head), offsetBy: head.location)
        spanIndex = SpanIndex(spans)
        render(in: head)
        applyColumnLayout()

        Task { @MainActor [weak self] in
            guard let self else { return }
            reparse()
            rerenderEverything()
        }
    }

    // MARK: - Analyse et rendu

    private func reparse() {
        spans = MarkdownParser.parse(textView.string).spans
            .sorted { $0.range.location < $1.range.location }
        spanIndex = SpanIndex(spans)
        onSpansChanged?()
    }

    /// Ré-analyse **le seul bloc touché**, et retombe sur le document entier
    /// quand son sens en dépend (voir `IncrementalParse`).
    ///
    /// - Returns: la plage à re-styler.
    private func reparseIncrementally(editedRange: NSRange, delta: Int) -> NSRange {
        guard let storage = textView.textStorage else { return NSRange(location: 0, length: 0) }
        let whole = NSRange(location: 0, length: storage.length)

        let inserted = editedRange.length > 0 && editedRange.upperBound <= storage.length
            ? storage.mutableString.substring(with: editedRange)
            : ""
        let codeBlocks = spans.compactMap { span -> NSRange? in
            if case .codeBlock = span.kind { return span.range } else { return nil }
        }

        guard let scope = IncrementalParse.scope(in: storage.mutableString,
                                                 editedRange: editedRange,
                                                 inserted: inserted,
                                                 existingCodeBlocks: codeBlocks) else {
            reparse()
            return whole
        }

        let fragment = storage.mutableString.substring(with: scope)
        let fresh = MarkdownParser.parse(fragment, offsetBy: scope.location)
        spans = MarkdownParser.splice(spans, replacing: scope, with: fresh, delta: delta)
        spanIndex = SpanIndex(spans)
        onSpansChanged?()
        return scope
    }

    private func rerenderEverything() {
        guard let storage = textView.textStorage else { return }
        render(in: NSRange(location: 0, length: storage.length))
    }

    /// Pose les attributs sur une portée, et rien qu'elle.
    ///
    /// Les décorations, elles, sont toujours reconstruites en entier : leur
    /// calcul ne fait que parcourir la liste des constructions, sans toucher au
    /// tampon, et il est négligeable face à la pose d'attributs.
    private func render(in range: NSRange) {
        guard let storage = textView.textStorage else { return }
        guard !isSourceMode else {
            renderSourceMode(storage)
            return
        }
        revealed = currentRevealedIndices()
        let renderer = MarkdownRenderer(typography: typography,
                                        colorfulCode: AppSettings.shared.colorfulCodeBlocks,
                                        documentURL: documentURL)
        // Seules les constructions qui touchent la portée sont repassées ; la
        // portée est celle du bloc édité, pas celle du document.
        let touching = spans.enumerated().filter {
            NSIntersectionRange($0.element.range, range).length > 0 || range.length == 0
        }
        renderer.render(storage,
                        spans: touching.map(\.element),
                        revealed: Set(touching.indices.filter { revealed.contains(touching[$0].offset) }),
                        in: range)
        textView.typography = typography
        textView.documentURL = documentURL
        textView.decorations = EditorDecoration.build(from: spans, typography: typography)
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

    // MARK: - Fonctions d'écriture (§4.5)

    /// Statistiques du document, ou de la sélection quand il y en a une.
    var statistics: WritingModes.Statistics {
        guard let storage = textView.textStorage else {
            return WritingModes.Statistics(words: 0, characters: 0, readingMinutes: 0)
        }
        let selection = textView.selectedRange()
        guard selection.length > 0 else {
            return WritingModes.statistics(of: storage.string, spans: spans)
        }
        // Sur une sélection, on compte la sélection — et les constructions
        // ramenées à ses coordonnées, sinon la syntaxe ne serait plus exclue.
        let fragment = storage.mutableString.substring(with: selection)
        let local = spans
            .filter { NSIntersectionRange($0.range, selection).length > 0 }
            .map { span -> SyntaxSpan in
                var moved = span
                moved.range.location -= selection.location
                moved.content.location -= selection.location
                moved.markers = span.markers.map {
                    NSRange(location: $0.location - selection.location, length: $0.length)
                }
                return moved
            }
        return WritingModes.statistics(of: fragment, spans: local)
    }

    /// Atténue tout sauf l'unité courante (§4.5).
    ///
    /// L'atténuation est une couche d'opacité posée par-dessus le rendu, et
    /// **jamais** un changement de couleur : les attributs de couleur portent
    /// déjà le sens — code, citation, marqueur révélé — et les écraser
    /// obligerait à tout recalculer pour revenir en arrière.
    private func applyFocus() {
        guard let storage = textView.textStorage, !isSourceMode else { return }
        let settings = AppSettings.shared
        guard settings.focusMode else {
            textView.focusRange = nil
            return
        }
        textView.focusRange = WritingModes.focusRange(in: storage.mutableString,
                                                      caret: textView.selectedRange().location,
                                                      unit: settings.focusUnit)
    }

    /// Maintient la ligne active à une hauteur fixe (§4.5).
    ///
    /// **Désactivé par défaut** : le défilement normal est le défaut, et ce
    /// mode déroute plus qu'il n'aide tant qu'on ne l'a pas demandé.
    private func applyTypewriterScrolling() {
        guard AppSettings.shared.typewriterMode,
              let layout = textView.textLayoutManager,
              let content = textView.textContentStorage,
              let caretLocation = content.location(content.documentRange.location,
                                                   offsetBy: textView.selectedRange().location)
        else { return }

        var caretFrame: NSRect?
        layout.enumerateTextSegments(in: NSTextRange(location: caretLocation),
                                     type: .selection, options: []) { _, frame, _, _ in
            caretFrame = frame
            return false
        }
        guard let caretFrame else { return }

        let visible = scrollView.contentView.bounds
        // Un tiers de la hauteur, pas la moitié : on écrit vers le bas, et
        // laisser deux tiers de contexte au-dessus se lit mieux qu'un partage
        // égal.
        let target = caretFrame.midY + textView.textContainerOrigin.y - visible.height / 3
        scrollView.contentView.setBoundsOrigin(NSPoint(x: visible.origin.x,
                                                       y: max(0, target)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func currentRevealedIndices() -> Set<Int> {
        let selection = textView.selectedRange()
        return RevealPolicy.revealedIndices(index: spanIndex, selection: selection, lineRange: currentLineRange())
    }

    /// La plage de la ligne du curseur, terminateur exclu.
    ///
    /// Calculée directement sur le tampon plutôt que lue dans une table des
    /// lignes : `NSString.lineRange(for:)` coûte la longueur d'**une ligne**,
    /// là où reconstruire la table coûtait le document entier — 1,7 ms par
    /// tranche de 10 000 mots, à chaque frappe, pour une seule ligne utile.
    private func currentLineRange() -> NSRange {
        guard let storage = textView.textStorage else { return NSRange(location: 0, length: 0) }
        let caret = min(textView.selectedRange().location, storage.length)
        var line = storage.mutableString.lineRange(for: NSRange(location: caret, length: 0))
        // `lineRange(for:)` inclut le terminateur ; le §2.2 le veut exclu, sans
        // quoi un curseur en début de ligne suivante révélerait la précédente.
        while line.length > 0 {
            let last = storage.mutableString.character(at: line.upperBound - 1)
            guard last == 10 || last == 13 else { break }
            line.length -= 1
        }
        return line
    }

    // MARK: - Mise en page de la colonne

    /// Centre la colonne de texte dans la fenêtre (§7). La largeur est mesurée
    /// en signes sur la fonte réelle, pas fixée en points, pour qu'elle suive
    /// le choix de police et de taille.
    /// **À ne jamais appeler depuis le cycle de frappe.**
    ///
    /// Réécrire `textContainerInset` et la taille du conteneur invalide la mise
    /// en page de *tout* le document. Appelée à chaque touche, cette seule
    /// ligne coûtait plus cher que l'analyse et le rendu réunis. Elle n'a de
    /// raison de tourner que lorsque la largeur disponible ou la typographie
    /// change — c'est-à-dire au redimensionnement et dans les réglages.
    func applyColumnLayout() {
        textView.refreshFocusOverlay()
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

    /// Encadre la sélection, ou retire le formatage s'il est déjà là (§2.5).
    func wrapSelection(with marker: String) {
        guard !isSourceMode else { return }
        _ = apply(TypingBehaviour.wrap(text, selection: textView.selectedRange(), with: marker))
    }

    func setHeadingLevel(_ level: Int) {
        guard !isSourceMode else { return }
        _ = apply(TypingBehaviour.setHeadingLevel(level, in: text, selection: textView.selectedRange()))
    }

    /// Applique une édition calculée par `TypingBehaviour`.
    ///
    /// Elle passe par `shouldChangeText(in:replacementString:)`, ce qui est ce
    /// qui inscrit l'annulation dans le `NSUndoManager` de la vue plutôt que
    /// dans une pile parallèle : un `⌘Z` défait la continuation de liste comme
    /// il défait une frappe, sans que rien n'ait été écrit pour ça.
    @discardableResult
    private func apply(_ edit: TypingBehaviour.Edit?) -> Bool {
        guard let edit, let storage = textView.textStorage,
              edit.range.upperBound <= storage.length else { return false }

        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
            return false
        }
        if let name = edit.undoName {
            textView.undoManager?.setActionName(name)
        }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: min(edit.caret, storage.length), length: 0))
        return true
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
        let edited = lastEditedRange ?? NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        let delta = lastChangeInLength
        lastEditedRange = nil
        lastChangeInLength = 0

        let scope = reparseIncrementally(editedRange: edited, delta: delta)
        render(in: scope)
        applyFocus()
        applyTypewriterScrolling()
        onTextChanged?()
    }

    @objc private func appearanceChanged() {
        // Les couleurs déjà posées dans le tampon ont été résolues au moment de
        // la pose : un changement clair/sombre ne les met pas à jour tout seul.
        rerenderEverything()
    }

    @objc private func settingsChanged() {
        // Les fontes sont mises en cache par couple (famille, taille) : changer
        // de police laisserait l'ancienne dans le cache.
        FontCache.shared.clear()
        typography = AppSettings.shared.typography
        applyFocus()
        applyTypewriterScrolling()
    }
}

// MARK: - NSTextViewDelegate

extension EditorController: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        handleTextChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateReveal()
        applyFocus()
        applyTypewriterScrolling()
        onSelectionChanged?()
    }
}


// MARK: - NSTextStorageDelegate

extension EditorController: NSTextStorageDelegate {

    /// **Enregistre** la plage modifiée, sans rien analyser ici.
    ///
    /// C'est le seul endroit qui connaisse précisément ce qui a changé —
    /// `textDidChange(_:)` ne le dit pas. Mais ré-analyser depuis ce rappel
    /// reviendrait à rentrer dans une édition en cours de traitement, ce qui
    /// est le meilleur moyen de corrompre les plages de `NSTextStorage`. On
    /// note, et on travaille au tour suivant.
    nonisolated func textStorage(_ textStorage: NSTextStorage,
                                 didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange,
                                 changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            lastEditedRange = editedRange
            lastChangeInLength = delta
        }
    }
}
