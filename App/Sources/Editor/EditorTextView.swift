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
        didSet {
            needsDisplay = true
            // Les cases à cocher posent des zones de pointeur : elles bougent
            // dès que le texte change, donc AppKit doit les redemander.
            //
            // Mais elles seules. Le rappel partait à chaque frappe, y compris
            // dans un document qui ne contient pas une seule tâche — et
            // `resetCursorRects` interroge la mise en page pour chaque case
            // visible.
            if Self.hasCheckbox(oldValue) || Self.hasCheckbox(decorations) {
                window?.invalidateCursorRects(for: self)
            }
        }
    }

    private static func hasCheckbox(_ decorations: [EditorDecoration]) -> Bool {
        decorations.contains {
            if case .checkbox = $0.kind { return true }
            return false
        }
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

    /// Appelé pour chaque caractère tapé, avant son insertion. Sert aux paires
    /// automatiques. Renvoie `true` si le caractère a été traité autrement.
    var handlesTyping: ((Character) -> Bool)?

    /// Appelé pour un caractère qui vient d'être écrit et qu'on **n'a pas pu**
    /// intercepter avant — la sortie d'une touche morte. Voir `insertText`.
    var handlesTypedCharacter: ((Character) -> Void)?

    /// Appelé sur `⌘`+clic à une position donnée : une note de bas de page y
    /// répond en sautant vers son autre moitié.
    var handlesFootnoteJump: ((Int) -> Bool)?

    /// Appelé quand on clique la case à cocher d'une tâche. Reçoit la plage du
    /// contenu de l'item, celle que porte la décoration.
    var handlesTaskToggle: ((NSRange) -> Bool)?

    /// Les touches que le menu slash intercepte quand il est ouvert (§4.5).
    enum MenuKey { case up, down, left, right, confirm, cancel }

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
        // **La recherche incrémentale reste éteinte.**
        //
        // Elle n'apporte pas que le surlignage au fil de la frappe : elle pose
        // aussi le voile de `NSTextFinder`, qui assombrit **tout** le document
        // en gris opaque pour n'y laisser que des trous blancs sur les
        // résultats, et peint le résultat courant en jaune système. Sur une
        // page blanche, le texte de l'utilisateur devient gris moyen — le seul
        // écran de l'app où il cesse d'être lisible — et c'est la seule couleur
        // saturée qui ait jamais traversé le §7.
        //
        // `NSTextView` ne donne pas accès à son `NSTextFinder`, donc pas à
        // `incrementalSearchingShouldDimContentView` : la seule prise est
        // l'interrupteur. On la coupe. `⌘F`, `⌘G` et l'indicateur de résultat
        // continuent de marcher, et le document reste lisible pendant qu'on
        // cherche dedans.
        isIncrementalSearchingEnabled = false

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

        // Même raison pour les liens : dès qu'une plage porte un `.link`,
        // `NSTextView` lui applique **ses** attributs — bleu système et
        // soulignement — par-dessus ceux que le rendu a posés. On les remplace
        // par rien : le lien est déjà souligné en gris par `MarkdownRenderer`.
        linkTextAttributes = [:]

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
        drawPlaceholder(in: rect)
        guard !decorations.isEmpty else { return }
        DecorationPainter(typography: typography, documentURL: documentURL)
            .draw(decorations, in: self, dirtyRect: rect)
    }

    /// Ce qui s'affiche dans un document vide.
    ///
    /// Une page blanche sans un mot est le seul écran de l'app où « faire
    /// disparaître l'app » (§7) se retourne contre elle : rien n'y indique que
    /// la touche `/` ouvre les blocs, et c'est précisément la personne qui ne
    /// connaît pas la syntaxe qu'on vient de lui masquer qui ouvre un document
    /// vide. Une ligne en gris pâle, à l'endroit exact où le premier mot
    /// s'écrira, et qui part au premier signe tapé.
    private func drawPlaceholder(in rect: NSRect) {
        guard textStorage?.length == 0 else { return }
        let hint = AppSettings.shared.slashMenuScope == .off
            ? "Écrivez."
            : "Écrivez. Tapez « / » pour insérer un titre, une liste, un tableau."

        // **Il revient à la ligne.** Mesurée sur une seule ligne et dessinée
        // dans une boîte de cette largeur, la phrase était coupée net dès que
        // la fenêtre se resserrait — sur l'unique écran de l'app dont le seul
        // rôle est de se faire lire.
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: typography.body,
            .foregroundColor: Theme.NS.labelTertiary,
            .paragraphStyle: style,
        ]
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        let width = max(1, (textContainer?.size.width ?? bounds.width) - padding * 2)
        let size = (hint as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes).size
        // Décalé d'un cheveu : posé pile où le texte commencera, le substitut
        // passe **sous le curseur**, qui clignote au même endroit. Le « É »
        // d'« Écrivez » s'y lisait barré d'un trait vertical, ce qui ressemble
        // à un défaut d'affichage. Deux points ne se remarquent pas ; le trait
        // dans la lettre, si.
        let box = NSRect(x: origin.x + padding + 2, y: origin.y,
                         width: width, height: size.height.rounded(.up))
        guard box.intersects(rect) else { return }
        (hint as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attributes)
    }

    /// Le pointeur devient une main au-dessus d'une case à cocher.
    ///
    /// Sans ça, la case est cliquable sans que rien ne le dise : dans un
    /// éditeur, tout le reste de la surface est du texte où le pointeur reste
    /// en I, et une zone qui répond au clic sans le montrer ne se découvre que
    /// par accident.
    override func resetCursorRects() {
        super.resetCursorRects()
        for target in DecorationPainter(typography: typography, documentURL: documentURL)
            .checkboxTargets(among: decorations, in: self) {
            addCursorRect(target.box, cursor: .pointingHand)
        }
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
        case 123: .left
        case 124: .right
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

    /// Les paires automatiques passent par ici, et non par `keyDown` : c'est le
    /// point où le caractère est déjà déterminé, quelle que soit la façon dont
    /// il a été produit — clavier, dictée, palette de caractères.
    ///
    /// La saisie en cours de composition — accents morts, méthodes asiatiques —
    /// est laissée intacte : y intercaler une fermeture couperait la
    /// composition en deux.
    /// # La seconde porte, pour les touches mortes
    ///
    /// Les deux gardes ci-dessous protègent une composition en cours : on ne
    /// peut pas glisser une fermeture au milieu d'un accent qu'on est en train
    /// de former. Mais sur un **clavier français**, l'accent grave et le tilde
    /// *sont* des touches mortes : `` ` `` et `~` n'arrivent jamais bruts, ils
    /// concluent une composition — et les gardes les écartaient donc en
    /// silence. Les paires automatiques ne se déclenchaient pas une seule fois
    /// sur les deux marqueurs markdown qui en ont le plus besoin, et la
    /// promotion en bloc de code non plus.
    ///
    /// La composition doit bien être validée d'abord. On écrit donc, **puis**
    /// on rejoue la décision sur le texte tel qu'il est — c'est
    /// `TypingBehaviour.autoPairAfterTyping`, qui dit la même chose depuis
    /// l'autre côté de la frappe.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        guard let typed, typed.count == 1, let character = typed.first else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        if !hasMarkedText(), replacementRange.location == NSNotFound {
            if handlesTyping?(character) == true { return }
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        super.insertText(string, replacementRange: replacementRange)
        handlesTypedCharacter?(character)
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
        carriesImage(sender) || !documents(in: sender).isEmpty ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        carriesImage(sender) || !documents(in: sender).isEmpty ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Un fichier texte déposé s'**ouvre**. Sans ce cas, `NSTextView` faisait
        // ce qu'il fait par défaut d'une URL : il en insérait le chemin dans le
        // document, ce qui n'est ce que personne n'a jamais voulu en faisant ce
        // geste — surtout dans un éditeur qui gère les onglets.
        let files = documents(in: sender)
        if !files.isEmpty {
            for url in files {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
            return true
        }

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

    /// Les fichiers déposés que l'app sait ouvrir : ses propres types de
    /// document, tels que l'`Info.plist` les déclare.
    private func documents(in sender: NSDraggingInfo) -> [URL] {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return []
        }
        return urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return !type.conforms(to: .image)
                && AppConfig.readableExtensions.contains(url.pathExtension.lowercased())
        }
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
        let point = convert(event.locationInWindow, from: nil)

        // Une case à cocher se coche au clic. C'est le pendant du §2.5 pour la
        // souris : la case est dessinée, donc le seul moyen de la cocher serait
        // sinon d'aller réécrire à la main un `x` entre deux crochets qu'on a
        // justement masqués.
        if !event.modifierFlags.contains(.command),
           let range = DecorationPainter(typography: typography, documentURL: documentURL)
               .task(at: point, among: decorations, in: self),
           handlesTaskToggle?(range) == true {
            return
        }

        guard event.modifierFlags.contains(.command) else {
            super.mouseDown(with: event)
            return
        }
        let index = characterIndexForInsertion(at: point)
        if let storage = textStorage, index < storage.length,
           let link = storage.attribute(.link, at: index, effectiveRange: nil) as? URL {
            NSWorkspace.shared.open(link)
            return
        }
        // Une note de bas de page n'a pas d'adresse à ouvrir, mais elle a une
        // autre moitié quelque part dans le document : le même geste y mène.
        if handlesFootnoteJump?(index) == true { return }
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

    /// **Retournée, comme la vue de texte qu'elle recouvre.**
    ///
    /// `NSTextView` est retournée, une `NSView` ordinaire ne l'est pas. Les
    /// bornes de l'unité active venaient donc de la mise en page en
    /// coordonnées descendantes, et se dessinaient dans un repère montant :
    /// la bande claire était le **miroir vertical** de la bonne. Elle tombait
    /// sur un autre paragraphe, et ses bords coupaient les lignes en pleine
    /// hauteur au lieu de se poser entre elles.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let focusRange = owner.focusRange,
              let layout = owner.textLayoutManager,
              let content = owner.textContentStorage,
              let start = content.location(content.documentRange.location, offsetBy: focusRange.location),
              let end = content.location(start, offsetBy: focusRange.length),
              let range = NSTextRange(location: start, end: end) else { return }

        // **Les fragments de mise en page, pas les segments de texte.**
        //
        // Un segment épouse la hauteur typographique des caractères qu'il
        // couvre, laquelle est plus courte que la ligne : la frontière du voile
        // tombait alors *dans* les lettres. Sur le titre du document, mesuré au
        // pixel, la moitié haute restait claire et la moitié basse s'assombrissait
        // au milieu des jambages — une ligne coupée en deux dans sa hauteur.
        //
        // Les fragments, eux, pavent le document sans trou ni recouvrement :
        // leur bord est toujours *entre* deux lignes, jamais dedans.
        var union: NSRect?
        layout.enumerateTextLayoutFragments(from: range.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            union = union.map { $0.union(frame) } ?? frame
            // On s'arrête au fragment qui contient la fin de l'unité — celui-là
            // compris, sinon la dernière ligne resterait sous le voile.
            return fragment.rangeInElement.endLocation.compare(range.endLocation) == .orderedAscending
        }
        guard let union else { return }
        let active = union.offsetBy(dx: owner.textContainerOrigin.x, dy: owner.textContainerOrigin.y)

        Theme.NS.window.withAlphaComponent(Accessibility.focusVeilOpacity).setFill()
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
