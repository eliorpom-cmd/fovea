// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

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

    // MARK: - Décorations

    /// Les marques sont peintes dans la passe de fond, donc **derrière** le
    /// texte et derrière la surbrillance de sélection. Une puce dessinée
    /// par-dessus le texte barrerait le premier mot de l'item quand la ligne
    /// est sélectionnée.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard !decorations.isEmpty else { return }
        DecorationPainter(typography: typography).draw(decorations, in: self, dirtyRect: rect)
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

extension Notification.Name {
    static let foveaAppearanceChanged = Notification.Name("foveaAppearanceChanged")
}
