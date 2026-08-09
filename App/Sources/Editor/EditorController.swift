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

    /// Le menu d'insertion de bloc (§4.5), et ce qui l'a déclenché.
    private let slashMenu = SlashMenu()
    private let languagePicker = LanguagePicker()
    private let tableSizePicker = TableSizePicker()
    /// La plage du mot de langage que le sélecteur remplacera.
    private var languageTrigger: CodeFence.LanguageTrigger?
    /// Le `/tab` que le damier remplacera quand il aura une réponse.
    private var pendingTableTrigger: TypingBehaviour.SlashTrigger?
    private var slashTrigger: TypingBehaviour.SlashTrigger?

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
            guard let self else { return false }
            return stepBackInsteadOfBreakingTheGrid(at: selection)
                || deletePair(at: selection)
                || deleteConstruct(at: selection)
        }
        textView.handlesTyping = { [weak self] character in
            guard let self, !isSourceMode, AppSettings.shared.automaticPairs else { return false }
            return apply(TypingBehaviour.autoPair(typing: character, in: text,
                                                  selection: textView.selectedRange(),
                                                  insideCode: isInsideCode(at: textView.selectedRange().location)))
        }
        textView.handlesNewline = { [weak self] in
            guard let self else { return false }
            // Le tableau d'abord : dedans, `⏎` descend d'une ligne au lieu
            // d'insérer un retour qui couperait la grille en deux.
            if moveToRowBelow() { return true }
            guard AppSettings.shared.markdownShortcutsWhileTyping else { return false }
            return apply(TypingBehaviour.newline(in: text, selection: textView.selectedRange()))
        }
        textView.handlesIndent = { [weak self] outdent in
            guard let self else { return false }
            // Sortir d'un format passe avant tout le reste : c'est le geste qui
            // ferme la boucle ouverte par les paires automatiques.
            if !outdent, escapeFormat() { return true }
            if moveBetweenCells(outdent: outdent) { return true }
            guard AppSettings.shared.markdownShortcutsWhileTyping else { return false }
            return apply(TypingBehaviour.indent(in: text, selection: textView.selectedRange(), outdent: outdent))
        }

        textView.handlesTaskToggle = { [weak self] content in
            self?.toggleTask(atContent: content) ?? false
        }
        textView.handlesFootnoteJump = { [weak self] index in
            self?.jumpBetweenFootnoteHalves(at: index) ?? false
        }
        textView.handlesMenuKey = { [weak self] key in
            self?.handleSlashMenuKey(key) ?? false
        }
        slashMenu.onChoose = { [weak self] command in
            // Le tableau est le seul bloc dont la forme se demande avant de
            // l'écrire : le damier prend le relais du menu.
            if command == .table {
                self?.presentTableSizePicker(replacing: self?.slashTrigger)
            } else {
                self?.insertBlock(command)
            }
        }
        languagePicker.onChoose = { [weak self] language in
            self?.applyLanguage(language)
        }
        tableSizePicker.onChoose = { [weak self] columns, rows in
            self?.insertTable(columns: columns, rows: rows)
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
        textView.decorations = EditorDecoration.build(from: spans, in: storage,
                                                      typography: typography,
                                                      revealed: revealed)
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

        // Un tableau dont une cellule vient de révéler ses `**` a changé de
        // largeur : ses colonnes doivent être reposées, sinon toutes celles de
        // droite glissent de la largeur des marqueurs réapparus. On ne repose
        // que les tableaux réellement concernés — il y en a rarement plus d'un.
        let touched = changed.compactMap { $0 < spans.count ? spans[$0].range : nil }
        var rebuiltDecorations = changed.contains {
            $0 < spans.count && EditorDecoration.hasRevealDependentMark(spans[$0].kind)
        }
        for (index, span) in spans.enumerated() where renderer.isTable(span) {
            guard changed.contains(index)
                    || touched.contains(where: { NSIntersectionRange($0, span.range).length > 0 })
            else { continue }
            renderer.applyTable(storage, span: span, revealed: next.contains(index))
            rebuiltDecorations = true
        }
        storage.endEditing()

        // Les marques dessinées suivent l'état de révélation : la puce, la case
        // à cocher, le filet et les cadres de tableau s'effacent quand leur
        // source réapparaît sous le curseur. On ne reconstruit la couche que
        // lorsque l'une d'elles est concernée — ce chemin est celui de chaque
        // flèche du clavier.
        if rebuiltDecorations {
            textView.decorations = EditorDecoration.build(from: spans, in: storage,
                                                          typography: typography,
                                                          revealed: next)
        }
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
            .map { $0.shifted(by: -selection.location) }
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

    // MARK: - Écrire dans un tableau (§2.6)

    /// La dernière position connue du curseur, pour savoir dans quel sens il
    /// allait quand il est tombé entre deux cellules.
    private var previousCaret = 0
    /// Empêche la correction de se rappeler elle-même : reposer la sélection
    /// renvoie `textViewDidChangeSelection`.
    private var isCorrectingCaret = false

    /// Le tableau qui contient cette position, s'il est rendu en grille.
    ///
    /// Un tableau resté en source — malformé, ou trop large — s'édite comme du
    /// texte ordinaire : ses `|` sont visibles, il n'y a donc rien à corriger.
    private func grid(at location: Int) -> MarkdownTable? {
        guard let storage = textView.textStorage else { return nil }
        for span in spans {
            guard case .table(let table?) = span.kind,
                  RevealPolicy.contains(span.range, location) else { continue }
            return MarkdownRenderer(typography: typography)
                .gridLayout(for: table, in: storage) != nil ? table : nil
        }
        return nil
    }

    /// Ramène le curseur dans une cellule quand il est tombé dans ce que la
    /// grille ne montre pas.
    ///
    /// Corriger **après** le déplacement plutôt qu'intercepter chaque commande :
    /// il y en a une trentaine avec leurs variantes, et il en manquerait une.
    /// Ici, tout ce qui bouge le curseur passe par le même point — flèches,
    /// clic, `⌘↓`, dictée, recherche.
    private func correctCaretInsideTable() {
        guard !isSourceMode, !isCorrectingCaret else { return }
        let selection = textView.selectedRange()
        // Une sélection est un geste en cours : on ne la déplace pas sous la
        // main de l'utilisateur.
        guard selection.length == 0, let table = grid(at: selection.location) else {
            previousCaret = selection.location
            return
        }

        let forward = selection.location >= previousCaret
        previousCaret = selection.location
        guard let corrected = TableEditing.correctedCaret(selection.location, in: table, forward: forward),
              corrected != selection.location
        else { return }

        isCorrectingCaret = true
        textView.setSelectedRange(NSRange(location: corrected, length: 0))
        previousCaret = corrected
        isCorrectingCaret = false
    }

    /// `⇥` passe à la cellule suivante et **sélectionne son contenu**, comme
    /// dans un tableur : on remplace en tapant. Au-delà de la dernière, une
    /// ligne est ajoutée.
    private func moveBetweenCells(outdent: Bool) -> Bool {
        let caret = textView.selectedRange().location
        guard !isSourceMode, let table = grid(at: caret) else { return false }

        if let cell = TableEditing.neighbouringCell(from: caret, in: table, forward: !outdent) {
            textView.setSelectedRange(cell)
            return true
        }
        // Reculer depuis la première cellule ne fait rien ; avancer depuis la
        // dernière ajoute une ligne, qui est ce qu'on voulait en arrivant là.
        guard !outdent else { return true }
        return appendRow(to: table)
    }

    /// `⏎` descend d'une ligne dans la même colonne, et **sort du tableau**
    /// quand on est sur la dernière.
    ///
    /// Sortir plutôt qu'ajouter une ligne : `⇥` ajoute déjà, et sans ça il n'y
    /// aurait littéralement aucun moyen de quitter un tableau au clavier par la
    /// touche qu'on essaie en premier — on en ajouterait une ligne à chaque
    /// tentative. C'est le choix de MarkText, et il est juste.
    private func moveToRowBelow() -> Bool {
        let caret = textView.selectedRange().location
        guard !isSourceMode, let table = grid(at: caret) else { return false }

        if let cell = TableEditing.cellBelow(caret, in: table) {
            textView.setSelectedRange(cell)
            return true
        }
        return leaveTable(table)
    }

    /// Pose le curseur sous le tableau, en créant la ligne vide qui manque.
    private func leaveTable(_ table: MarkdownTable) -> Bool {
        guard let storage = textView.textStorage, let last = table.rows.last else { return false }
        let end = min(last.line.upperBound, storage.length)

        // Un tableau en fin de document n'a pas de ligne où aller : on en écrit
        // une, sinon la touche ne ferait rien et l'utilisateur serait enfermé.
        guard end < storage.length else {
            return apply(TypingBehaviour.Edit(range: NSRange(location: end, length: 0),
                                              replacement: "\n\n",
                                              caret: end + 2,
                                              undoName: "Sortir du tableau"))
        }
        textView.setSelectedRange(NSRange(location: end + 1, length: 0))
        return true
    }

    private func appendRow(to table: MarkdownTable) -> Bool {
        guard let last = table.rows.last,
              let row = TableEditing.newRow(below: table.rows.count - 1, in: table)
        else { return false }
        return apply(TypingBehaviour.Edit(range: NSRange(location: last.line.upperBound, length: 0),
                                          replacement: row.text,
                                          caret: last.line.upperBound + row.caret,
                                          undoName: "Ajouter une ligne"))
    }

    /// `⌫` au début d'une cellule ne supprime rien : il recule d'une cellule.
    ///
    /// Le caractère qui précède est un `|` que personne ne voit ; l'effacer
    /// fusionnerait deux colonnes sans que rien ne l'ait demandé, et le tableau
    /// entier se réécrirait sous les yeux de l'utilisateur.
    private func stepBackInsteadOfBreakingTheGrid(at selection: NSRange) -> Bool {
        guard !isSourceMode, selection.length == 0,
              let table = grid(at: selection.location),
              TableEditing.isAtCellStart(selection.location, in: table)
        else { return false }

        if let previous = TableEditing.neighbouringCell(from: selection.location, in: table, forward: false) {
            textView.setSelectedRange(NSRange(location: previous.upperBound, length: 0))
        }
        return true
    }

    /// Le loquet de la portée ligne : voir `RevealPolicy`. On retient le début
    /// de la ligne et non ses spans, parce qu'une analyse incrémentale renumérote
    /// les constructions — le début de ligne, lui, ne bouge pas tant qu'on tape
    /// dedans.
    private var latchedLineStart: Int?

    private func currentRevealedIndices() -> Set<Int> {
        let selection = textView.selectedRange()
        let line = currentLineRange()
        if latchedLineStart != line.location { latchedLineStart = nil }

        let revealed = RevealPolicy.revealedIndices(index: spanIndex,
                                                    selection: selection,
                                                    lineRange: line,
                                                    linePrefixesLatched: latchedLineStart != nil)
        // Le loquet se pose dès qu'un préfixe est révélé, et se relève de
        // lui-même au prochain appel fait depuis une autre ligne.
        latchedLineStart = revealed.contains { index in
            index < spanIndex.spans.count && spanIndex.spans[index].kind.revealScope == .wholeLine
        } ? line.location : nil
        return revealed
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
        let selection = textView.selectedRange()
        isSourceMode.toggle()
        slashMenu.dismiss()
        rerenderEverything()

        // §6 : la sélection est conservée, mais **étendue aux marqueurs de ses
        // constructions**. Sélectionner un mot en gras ne sélectionne que le
        // mot — ses `**` étaient invisibles. Passer en source sans étendre
        // laisserait une sélection qui coupe la construction en deux, et un
        // `⌘X` produirait un `**` orphelin.
        if isSourceMode, selection.length > 0 {
            textView.setSelectedRange(extendedToConstructs(selection))
        }
    }

    /// La sélection élargie aux constructions inline qu'elle touche.
    ///
    /// Seules les constructions inline : élargir aux blocs ferait sauter la
    /// sélection d'un mot à un chapitre entier dès qu'on est sous un titre.
    private func extendedToConstructs(_ selection: NSRange) -> NSRange {
        var result = selection
        for span in spans where span.kind.revealScope == .innermostInline {
            guard NSIntersectionRange(span.range, selection).length > 0 else { continue }
            result = NSUnionRange(result, span.range)
        }
        let length = textView.textStorage?.length ?? 0
        return NSIntersectionRange(result, NSRange(location: 0, length: length))
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

    /// Pose un lien autour de la sélection, l'adresse venant du presse-papier
    /// s'il en contient une.
    func insertLink() {
        guard !isSourceMode else { return }
        let pasted = NSPasteboard.general.string(forType: .string)
        let url = pasted.flatMap { TypingBehaviour.looksLikeURL($0) ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        _ = apply(TypingBehaviour.link(in: text, selection: textView.selectedRange(), url: url))
    }

    /// Coche ou décoche la tâche de la ligne du curseur (`⌘⏎`).
    ///
    /// Le clic sur la case suffirait à un utilisateur voyant. Il ne suffit pas
    /// au §8 : une fonction qui n'existe qu'à la souris n'existe pas pour qui
    /// n'en tient pas.
    @discardableResult
    func toggleTaskAtCaret() -> Bool {
        let caret = textView.selectedRange().location
        guard let index = spans.firstIndex(where: { span in
            guard case .taskItem = span.kind else { return false }
            return RevealPolicy.contains(span.range, caret)
        }) else { return false }
        return toggle(spans[index])
    }

    /// Coche ou décoche la tâche dont le contenu est cette plage — c'est celle
    /// que porte la décoration cliquée.
    private func toggleTask(atContent range: NSRange) -> Bool {
        guard let index = spans.firstIndex(where: { span in
            guard case .taskItem = span.kind else { return false }
            return span.content == range
        }) else { return false }
        return toggle(spans[index])
    }

    private func toggle(_ span: SyntaxSpan) -> Bool {
        guard !isSourceMode, let marker = span.markers.first else { return false }
        return apply(TypingBehaviour.toggleTask(in: text,
                                                marker: marker,
                                                caret: textView.selectedRange().location))
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

        // Une édition qui ne change aucun caractère ne déplace que le curseur —
        // c'est le cas de la fermeture qu'on franchit. La faire passer par la
        // pile d'annulation y inscrirait une étape qui ne défait rien.
        let selection = { (caret: Int) in
            NSRange(location: min(caret, storage.length),
                    length: min(edit.selectionLength, storage.length - min(caret, storage.length)))
        }
        guard edit.range.length > 0 || !edit.replacement.isEmpty else {
            textView.setSelectedRange(selection(edit.caret))
            return true
        }

        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
            return false
        }
        if let name = edit.undoName {
            textView.undoManager?.setActionName(name)
        }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.didChangeText()
        textView.setSelectedRange(selection(edit.caret))
        return true
    }

    /// `⌫` entre les deux moitiés d'une paire les efface toutes les deux.
    private func deletePair(at selection: NSRange) -> Bool {
        guard !isSourceMode, AppSettings.shared.automaticPairs else { return false }
        return apply(TypingBehaviour.deletingPair(in: text, selection: selection))
    }

    /// Le curseur est-il dans du code, où les marqueurs markdown n'ont pas
    /// cours ? Passe par l'index plutôt que par la liste entière : la question
    /// est posée à chaque caractère tapé (§9).
    private func isInsideCode(at location: Int) -> Bool {
        spanIndex.candidates(near: location, line: currentLineRange()).contains { index in
            guard index < spanIndex.spans.count else { return false }
            let span = spanIndex.spans[index]
            switch span.kind {
            case .inlineCode, .codeBlock:
                return NSLocationInRange(location, span.range)
            default:
                return false
            }
        }
    }

    /// `⌘`+clic sur une note de bas de page mène à son autre moitié.
    ///
    /// Une note vit en deux endroits : le renvoi `[^1]` au fil du texte, et sa
    /// définition `[^1]: …` tout en bas. Les relier à la souris est ce qui les
    /// rend utilisables — sans ça, vérifier une note demande de faire défiler
    /// le document, de la lire, puis de retrouver où l'on en était.
    ///
    /// Le geste est le même dans les deux sens, et c'est celui des liens : rien
    /// de nouveau à apprendre.
    private func jumpBetweenFootnoteHalves(at index: Int) -> Bool {
        guard !isSourceMode else { return false }

        let identifier: String
        let goingToDefinition: Bool
        if let span = spans.first(where: { span in
            guard case .footnoteReference = span.kind else { return false }
            return NSLocationInRange(index, span.range)
        }), case .footnoteReference(let name) = span.kind {
            (identifier, goingToDefinition) = (name, true)
        } else if let span = spans.first(where: { span in
            guard case .footnoteDefinition = span.kind else { return false }
            // Seul le libellé répond, pas le texte de la note : autrement, tout
            // clic dans une note qu'on est en train d'écrire sauterait ailleurs.
            return span.markers.contains { NSLocationInRange(index, $0) }
                || NSLocationInRange(index, NSRange(location: span.range.location,
                                                    length: span.content.location - span.range.location))
        }), case .footnoteDefinition(let name) = span.kind {
            (identifier, goingToDefinition) = (name, false)
        } else {
            return false
        }

        let destination = spans.first { span in
            switch span.kind {
            case .footnoteDefinition(let name) where goingToDefinition: return name == identifier
            case .footnoteReference(let name) where !goingToDefinition: return name == identifier
            default: return false
            }
        }
        guard let destination else { return false }

        // Le curseur va sur le **contenu**, jamais sur un marqueur : arriver
        // dans un `[^` rouvrirait la syntaxe au moment précis où l'on vient
        // lire du texte.
        textView.setSelectedRange(NSRange(location: destination.content.location, length: 0))
        textView.scrollRangeToVisible(destination.range)
        textView.showFindIndicator(for: destination.range)
        return true
    }

    /// `⇥` collé devant la balise fermante saute par-dessus.
    ///
    /// C'est la sortie de `**gras|**` sans lever la main, et le pendant exact
    /// des paires automatiques : elles posent la fermeture, celle-ci la
    /// franchit. La condition est stricte — le curseur doit être **à la fin du
    /// contenu**, pas n'importe où dedans — sinon `⇥` cesserait d'indenter.
    private func escapeFormat() -> Bool {
        guard !isSourceMode else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }

        var innermost: NSRange?
        for index in spanIndex.candidates(near: selection.location, line: currentLineRange())
        where index < spanIndex.spans.count {
            let span = spanIndex.spans[index]
            guard span.kind.revealScope == .innermostInline,
                  span.content.upperBound == selection.location,
                  span.range.upperBound > selection.location else { continue }
            if innermost == nil || span.range.length < innermost!.length { innermost = span.range }
        }
        guard let innermost else { return false }
        textView.setSelectedRange(NSRange(location: innermost.upperBound, length: 0))
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
        //
        // Les blocs délimités en sont exclus, et c'est un garde-fou, pas une
        // simplification : leurs marqueurs sont les deux clôtures d'un bloc
        // entier. Un `⌫` en fin de ligne ` ```swift ` aurait effacé la clôture
        // de fermeture dix lignes plus bas, sans que rien ne le laisse voir —
        // et dans un tableau, il aurait retiré tous les `|` d'un coup.
        guard let index = spans.firstIndex(where: { span in
            span.kind.revealScope != .wholeBlock
                && span.markers.contains { NSLocationInRange(target, $0) }
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

    // MARK: - Menu slash (§4.5)

    /// Ouvre, met à jour ou referme le menu selon ce qui vient d'être tapé.
    ///
    /// Appelé après chaque frappe **et** chaque déplacement du curseur : sortir
    /// de la ligne doit refermer le menu aussi sûrement qu'effacer le `/`.
    private func refreshSlashMenu() {
        let selection = textView.selectedRange()
        guard !isSourceMode, selection.length == 0,
              textView.window?.isKeyWindow == true,
              let storage = textView.textStorage
        else {
            slashTrigger = nil
            slashMenu.dismiss()
            return
        }

        // `currentLineRange()` coûte la longueur d'une ligne, pas celle du
        // document : le menu peut donc être réévalué à chaque frappe sans
        // entamer le budget du §9.
        let line = currentLineRange()
        guard let trigger = TypingBehaviour.slashTrigger(
            inLine: storage.mutableString.substring(with: line),
            lineStart: line.location,
            caret: selection.location,
            scope: AppSettings.shared.slashMenuScope)
        else {
            slashTrigger = nil
            slashMenu.dismiss()
            return
        }
        slashTrigger = trigger
        // Le rectangle du curseur est demandé en coordonnées écran, que le
        // panneau attend telles quelles.
        let caretRect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        if !slashMenu.present(query: trigger.query, caretRect: caretRect, over: textView.window) {
            slashTrigger = nil
        }
    }

    /// Aiguille les touches de navigation vers le panneau ouvert.
    ///
    /// Un seul l'est à la fois — ils se ferment les uns les autres — donc
    /// l'ordre n'a pas à trancher de conflit ; il dit simplement lequel
    /// regarder en premier.
    private func handleSlashMenuKey(_ key: EditorTextView.MenuKey) -> Bool {
        if tableSizePicker.isOpen {
            switch key {
            case .up: tableSizePicker.move(columns: 0, rows: -1)
            case .down: tableSizePicker.move(columns: 0, rows: 1)
            case .left: tableSizePicker.move(columns: -1, rows: 0)
            case .right: tableSizePicker.move(columns: 1, rows: 0)
            case .confirm: tableSizePicker.confirmSelection()
            case .cancel: tableSizePicker.dismiss()
            }
            return true
        }
        if languagePicker.isOpen {
            switch key {
            case .up: languagePicker.moveSelection(by: -1)
            case .down: languagePicker.moveSelection(by: 1)
            case .confirm: languagePicker.confirmSelection()
            case .cancel:
                languageTrigger = nil
                languagePicker.dismiss()
            // Les flèches horizontales restent au texte : on est en train
            // d'écrire un mot, pas de naviguer dans une grille.
            case .left, .right: return false
            }
            return true
        }
        guard slashMenu.isOpen else { return false }
        switch key {
        case .up: slashMenu.moveSelection(by: -1)
        case .down: slashMenu.moveSelection(by: 1)
        case .confirm: slashMenu.confirmSelection()
        case .cancel:
            slashTrigger = nil
            slashMenu.dismiss()
        case .left, .right: return false
        }
        return true
    }

    // MARK: - Le langage d'un bloc de code

    /// Ouvre, met à jour ou referme le sélecteur de langage.
    ///
    /// Appelé au même endroit que le menu slash, et pour la même raison : la
    /// question « le curseur est-il quelque part où l'app peut aider ? » se
    /// repose à chaque frappe et à chaque déplacement.
    private func refreshLanguagePicker() {
        let selection = textView.selectedRange()
        guard !isSourceMode, selection.length == 0, !slashMenu.isOpen,
              textView.window?.isKeyWindow == true,
              let storage = textView.textStorage
        else {
            languageTrigger = nil
            languagePicker.dismiss()
            return
        }
        let line = currentLineRange()
        guard let trigger = CodeFence.languageTrigger(
            inLine: storage.mutableString.substring(with: line),
            lineStart: line.location,
            caret: selection.location)
        else {
            languageTrigger = nil
            languagePicker.dismiss()
            return
        }
        languageTrigger = trigger
        let caretRect = textView.firstRect(forCharacterRange: selection, actualRange: nil)
        if !languagePicker.present(query: trigger.query, caretRect: caretRect, over: textView.window) {
            languageTrigger = nil
        }
    }

    private func applyLanguage(_ language: String) {
        guard let trigger = languageTrigger else { return }
        languageTrigger = nil
        apply(TypingBehaviour.Edit(range: trigger.range,
                                   replacement: language,
                                   caret: trigger.range.location + language.utf16.count,
                                   undoName: "Choisir le langage"))
    }

    // MARK: - Le damier de tableau

    /// Ouvre le damier, en mémorisant ce qu'il devra remplacer.
    ///
    /// Le `/tab` tapé est retiré au moment de l'insertion, pas à l'ouverture :
    /// refermer le damier sans choisir doit laisser le texte exactement comme
    /// on l'a tapé.
    var isTableSizePickerOpen: Bool { tableSizePicker.isOpen }
    var isLanguagePickerOpen: Bool { languagePicker.isOpen }

    func presentTableSizePicker(replacing trigger: TypingBehaviour.SlashTrigger? = nil) {
        pendingTableTrigger = trigger
        slashTrigger = nil
        slashMenu.dismiss()
        // Un tour de boucle avant de montrer le panneau.
        //
        // Sans ça, l'entrée de menu « Tableau… » n'ouvrait rien : ouvrir un
        // menu de la barre désactive brièvement l'application, et un panneau
        // `hidesOnDeactivate` posé pendant ce suivi se refermait aussitôt.
        // Le chemin du menu slash, lui, marchait — ce qui rendait le défaut
        // parfaitement invisible aux tests comme à l'essai rapide.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let caretRect = textView.firstRect(forCharacterRange: textView.selectedRange(),
                                               actualRange: nil)
            tableSizePicker.present(caretRect: caretRect, over: textView.window)
        }
    }

    private func insertTable(columns: Int, rows: Int) {
        let (markdown, offset) = CodeFence.table(columns: columns, rows: rows)
        let target: NSRange
        if let trigger = pendingTableTrigger {
            target = trigger.range
        } else {
            target = textView.selectedRange()
        }
        pendingTableTrigger = nil
        // Une grille ne peut pas commencer au milieu d'une phrase : si la ligne
        // porte déjà du texte, le tableau s'écrit en dessous.
        let line = TypingBehaviour.lineRange(Array(text.utf16), containing: target.location)
        let needsBreak = target.location > line.location
        let prefix = needsBreak ? "\n\n" : ""
        apply(TypingBehaviour.Edit(range: target,
                                   replacement: prefix + markdown,
                                   caret: target.location + prefix.utf16.count + offset,
                                   undoName: "Insérer un tableau"))
    }

    private func insertBlock(_ command: SlashCommand) {
        guard let trigger = slashTrigger else { return }
        slashTrigger = nil
        apply(TypingBehaviour.insertion(of: command, replacing: trigger))
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
        refreshSlashMenu()
        refreshLanguagePicker()
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
        // Avant tout le reste : le curseur doit être quelque part où l'on peut
        // écrire, sans quoi le rendu se calculerait pour une position qui
        // n'existe pas à l'écran.
        correctCaretInsideTable()
        updateReveal()
        applyFocus()
        applyTypewriterScrolling()
        refreshSlashMenu()
        refreshLanguagePicker()
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
