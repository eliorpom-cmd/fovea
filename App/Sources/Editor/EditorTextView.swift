// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit
import UniformTypeIdentifiers

/// La vue d'édition.
///
/// Elle reste volontairement mince : tout ce qui touche au markdown vit dans
/// `EditorController`. Ce fichier ne s'occupe que de ce qu'une `NSTextView`
/// fait mal par défaut pour un éditeur de markdown.
final class EditorTextView: NSTextView {

    /// Appelé quand `⌫` doit supprimer une construction entière plutôt qu'un
    /// caractère de marqueur isolé (§2.5). Renvoie `true` si la suppression a
    /// été prise en charge.
    var handlesDeleteBackward: ((NSRange) -> Bool)?

    /// Les marques dessinées derrière le texte : puces, barres de citation,
    /// filets, fonds de blocs de code. Voir `EditorDecoration`.
    var decorations: [EditorDecoration] = [] {
        didSet { needsDisplay = true }
    }

    var typography: EditorTypography = .default
    var documentURL: URL?

    /// La plage laissée en pleine intensité par le mode focus (§4.5).
    /// `nil` quand le mode est éteint.
    var focusRange: NSRange? {
        didSet {
            guard focusRange != oldValue else { return }
            focusOverlay.isHidden = focusRange == nil
            focusOverlay.frame = bounds
            focusOverlay.needsDisplay = true
        }
    }

    /// Le voile du mode focus, **au-dessus** du texte.
    ///
    /// Il ne peut pas être peint dans `draw(_:)` : avec TextKit 2, les
    /// fragments de texte sont rendus dans des couches posées par-dessus le
    /// dessin de la vue, et le voile passait dessous — invisible. Une sous-vue,
    /// elle, se compose au-dessus.
    private lazy var focusOverlay: FocusOverlayView = {
        let overlay = FocusOverlayView(owner: self)
        overlay.isHidden = true
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        return overlay
    }()

    /// Rappels vers `EditorController` pour les touches dont le comportement
    /// dépend du markdown. Chacun renvoie `true` s'il a pris la main.
    var handlesNewline: (() -> Bool)?
    var handlesIndent: ((_ outdent: Bool) -> Bool)?

    /// Les touches que le menu slash intercepte quand il est ouvert (§4.5).
    enum MenuKey { case up, down, confirm, cancel }

    /// Renvoie `true` si le menu slash a pris la touche. Il ne devient jamais
    /// fenêtre clé — c'est ce qui permet de continuer à taper dans le texte
    /// pendant qu'il filtre — donc c'est la vue de texte qui reçoit les flèches
    /// et les lui transmet.
    var handlesMenuKey: ((MenuKey) -> Bool)?

    // MARK: - Construction

    static func make() -> EditorTextView {
        // TextKit 2 explicitement. La `NSTextView` par défaut peut encore
        // basculer en TextKit 1 dès qu'une API de compatibilité est touchée, et
        // toute l'app dépend de la mise en page par viewport.
        let view = EditorTextView(usingTextLayoutManager: true)
        view.configure()
        return view
    }

    private func configure() {
        isRichText = false
        allowsUndo = true
        isEditable = true
        isSelectable = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true

        registerForDraggedTypes([.fileURL, .png, .tiff])

        // §2.5 : aucune substitution typographique, y compris celles de macOS.
        // Dans un fichier destiné à git ou à un générateur de site, une
        // transformation invisible est un bug, pas un service.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        // La correction orthographique, elle, reste : elle souligne sans rien
        // réécrire, et c'est précisément ce qu'on attend dans un éditeur de prose.
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false

        // La sélection système est bleue. Dans un éditeur monochrome où seule
        // l'image de l'utilisateur a droit à la couleur, on la neutralise (§7).
        selectedTextAttributes = [.backgroundColor: Theme.NS.selection]

        drawsBackground = true
        backgroundColor = Theme.NS.window
        insertionPointColor = Theme.NS.label

        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 0, height: Theme.Space.s40)
    }

    /// Remet le voile à la taille de la vue.
    ///
    /// La vue de texte grandit à mesure que la mise en page progresse ; sans
    /// ce rappel, le voile garderait la hauteur qu'elle avait à l'ouverture et
    /// laisserait le bas du document en pleine intensité.
    func refreshFocusOverlay() {
        guard focusRange != nil else { return }
        focusOverlay.frame = bounds
        focusOverlay.needsDisplay = true
    }

    // MARK: - Décorations

    /// Les marques sont peintes dans la passe de fond, donc **derrière** le
    /// texte et derrière la surbrillance de sélection. Une puce dessinée
    /// par-dessus le texte barrerait le premier mot de l'item quand la ligne
    /// est sélectionnée.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !decorations.isEmpty else { return }
        DecorationPainter(typography: typography, documentURL: documentURL)
            .draw(decorations, in: self, dirtyRect: rect)
    }

    // MARK: - Suppression intelligente

    /// `⌫` juste après une construction masquée doit supprimer la construction
    /// **entière**, pas le seul caractère de marqueur qui la précède : sinon on
    /// obtient un `**` orphelin qui casse le rendu sans qu'on comprenne
    /// pourquoi (§2.5).
    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length == 0, let handler = handlesDeleteBackward, handler(selection) {
            return
        }
        super.deleteBackward(sender)
    }

    // MARK: - Menu slash

    /// Les touches de navigation sont détournées **avant** l'interprétation
    /// habituelle : `⏎` doit valider l'entrée choisie, pas insérer un saut de
    /// ligne, et `⎋` doit refermer le menu sans rien faire d'autre.
    override func keyDown(with event: NSEvent) {
        let key: MenuKey? = switch event.keyCode {
        case 126: .up
        case 125: .down
        case 36, 76: .confirm
        case 53: .cancel
        default: nil
        }
        if let key, handlesMenuKey?(key) == true { return }
        super.keyDown(with: event)
    }

    // MARK: - Listes

    /// `⏎` continue la liste, `⇥` et `⇧⇥` en changent le niveau (§2.5).
    ///
    /// Ces trois touches sont interceptées ici plutôt que dans `keyDown` :
    /// `insertNewline(_:)` et `insertTab(_:)` sont les actions que le système
    /// envoie, et les traiter à ce niveau conserve la saisie par dictée, les
    /// méthodes de saisie asiatiques et les claviers de remplacement.
    override func insertNewline(_ sender: Any?) {
        if handlesNewline?() == true { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if handlesIndent?(false) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if handlesIndent?(true) == true { return }
        super.insertBacktab(sender)
    }

    // MARK: - Glisser-déposer d'images

    /// Accepte les images déposées depuis le Finder ou d'autres apps (§4.4).
    ///
    /// `NSTextView` accepte déjà des dépôts, mais pour y insérer du texte
    /// riche — ce qu'un tampon `isRichText = false` refuse. On intercepte donc
    /// avant lui, et seulement pour ce qui est une image.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesImage(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesImage(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard carriesImage(sender),
              let result = ImageDrop.handle(sender.draggingPasteboard, document: documentURL)
        else { return super.performDragOperation(sender) }

        // L'insertion se fait là où le curseur *serait* si on cliquait : c'est
        // l'endroit visé par le geste, pas la sélection d'avant le dépôt.
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        setSelectedRange(NSRange(location: index, length: 0))
        insertText(surrounded(result.markdown, at: index), replacementRange: NSRange(location: index, length: 0))
        return true
    }

    private func carriesImage(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            return urls.contains { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: .image)
            }
        }
        return NSImage.canInit(with: pasteboard)
    }

    /// Une image est un bloc : elle a besoin d'une ligne vide de chaque côté,
    /// sans quoi markdown la colle au paragraphe voisin et elle se rend en
    /// pleine phrase.
    private func surrounded(_ markdown: String, at index: Int) -> String {
        guard let storage = textStorage else { return markdown }
        let text = storage.mutableString
        var prefix = "\n\n"
        var suffix = "\n\n"
        if index == 0 { prefix = "" }
        else if index >= 2, text.substring(with: NSRange(location: index - 2, length: 2)) == "\n\n" { prefix = "" }
        if index >= text.length { suffix = "\n" }
        else if text.character(at: index) == 10 { suffix = "\n" }
        return prefix + markdown + suffix
    }

    // MARK: - Collage

    /// `⌘V` convertit le texte riche en markdown (§2.5).
    ///
    /// `NSTextView` propose `paste(_:)` et `pasteAsPlainText(_:)`. Le premier
    /// collerait du texte riche dans un tampon qui n'en veut pas — la vue est
    /// en `isRichText = false`, les attributs seraient perdus sans rien laisser
    /// en échange. On intercepte donc, et on insère du markdown.
    override func paste(_ sender: Any?) {
        // Une image d'abord : elle doit devenir un fichier à côté du document,
        // pas un texte riche perdu (§2.5, étape 3).
        if NSImage.canInit(with: .general),
           let result = ImageDrop.handle(.general, document: documentURL) {
            let index = selectedRange().location
            insertText(surrounded(result.markdown, at: index), replacementRange: selectedRange())
            return
        }
        if let markdown = PasteConversion.markdown(from: .general) {
            insertText(markdown, replacementRange: selectedRange())
            return
        }
        super.pasteAsPlainText(sender)
    }

    /// `⌘⇧V` colle toujours en texte brut, sans aucune conversion (§2.5).
    @objc func pastePlainText(_ sender: Any?) {
        super.pasteAsPlainText(sender)
    }

    // MARK: - Liens

    /// `⌘`+clic ouvre l'URL. Un clic simple ne le fait pas : dans un éditeur,
    /// cliquer dans un lien sert d'abord à y placer le curseur.
    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let storage = textStorage, index < storage.length,
           let link = storage.attribute(.link, at: index, effectiveRange: nil) as? URL {
            NSWorkspace.shared.open(link)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: - Apparence

    /// Le fond et les couleurs sont des `NSColor` dynamiques, mais les
    /// attributs déjà posés dans le tampon, eux, sont figés : ils ont été
    /// résolus au moment de la pose. Un changement de thème système doit donc
    /// déclencher un nouveau rendu, que le contrôleur écoute.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        NotificationCenter.default.post(name: .foveaAppearanceChanged, object: self)
    }
}

/// Le voile qui atténue tout sauf l'unité active.
///
/// Il est peint dans la couleur du fond à faible opacité, plutôt qu'en
/// changeant la couleur des caractères. Les attributs de couleur portent déjà
/// du sens — code, citation, marqueur révélé — et les écraser obligerait à tout
/// recalculer pour revenir en arrière, à chaque déplacement du curseur.
private final class FocusOverlayView: NSView {

    private weak var owner: EditorTextView?

    init(owner: EditorTextView) {
        self.owner = owner
        super.init(frame: owner.bounds)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("aucune vue ne vient d'un xib") }

    /// Transparente aux clics : le voile est décoratif, on écrit à travers.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let focusRange = owner.focusRange,
              let layout = owner.textLayoutManager,
              let content = owner.textContentStorage,
              let start = content.location(content.documentRange.location, offsetBy: focusRange.location),
              let end = content.location(start, offsetBy: focusRange.length),
              let range = NSTextRange(location: start, end: end) else { return }

        // Les bornes verticales de l'unité active suffisent : découper par
        // segments laisserait des trous entre les lignes.
        var union: NSRect?
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        guard let union else { return }
        let active = union.offsetBy(dx: owner.textContainerOrigin.x, dy: owner.textContainerOrigin.y)

        Theme.NS.window.withAlphaComponent(0.74).setFill()
        NSRect(x: bounds.minX, y: bounds.minY,
               width: bounds.width, height: max(0, active.minY - bounds.minY))
            .intersection(dirtyRect).fill()
        NSRect(x: bounds.minX, y: active.maxY,
               width: bounds.width, height: max(0, bounds.maxY - active.maxY))
            .intersection(dirtyRect).fill()
    }
}

extension Notification.Name {
    static let foveaAppearanceChanged = Notification.Name("foveaAppearanceChanged")
}
