// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// La ligne d'une liste, sélectionnée **en gris** et non en bleu.
///
/// # Pourquoi ce fichier existe
///
/// `NSTableView` peint sa sélection avec la couleur d'accent du système, c'est-
/// à-dire du bleu. C'était la seule couleur d'accent restée dans l'app, dans
/// les trois listes que l'utilisateur voit le plus : le menu slash, la palette
/// de commandes et le plan du document. Le §7 ne l'autorise que sur le contenu
/// de l'utilisateur — ses images, ses blocs de code coloriés sur demande — et
/// `Theme` annonçait déjà neutraliser la sélection système sans qu'aucune liste
/// ne l'applique.
///
/// Il n'y a pas de réglage pour cela : `selectionHighlightStyle` propose
/// `.regular` — bleu — ou `.none` — rien. Le gris demande donc de dessiner
/// soi-même, ce qui tient en une méthode.
///
/// Le coin arrondi n'est pas décoratif : sans lui, la bande grise touche les
/// bords du panneau et se lit comme un séparateur plutôt que comme une
/// sélection.
final class ListRowView: NSTableRowView {

    /// Marge horizontale laissée de chaque côté de la bande.
    private static let inset: CGFloat = 4
    private static let radius: CGFloat = 6

    private var isHovered = false

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        fill(with: Theme.NS.rowSelection)
    }

    /// Le survol, qui manquait partout.
    ///
    /// Les trois listes de l'app — menu slash, palette, plan — ne réagissaient
    /// pas au passage du pointeur : on ne savait pas ce qu'on allait cliquer
    /// avant de l'avoir cliqué. `Theme.rowHover` existait, documenté, et
    /// n'était utilisé nulle part.
    ///
    /// Il est peint dans le **fond** et non dans la sélection : une ligne
    /// sélectionnée qu'on survole ne doit pas empiler deux gris.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected else { return }
        fill(with: Theme.NS.rowHover)
    }

    private func fill(with color: NSColor) {
        let box = bounds.insetBy(dx: Self.inset, dy: 1)
        color.setFill()
        NSBezierPath(roundedRect: box, xRadius: Self.radius, yRadius: Self.radius).fill()
    }

    /// `.activeAlways` : les panneaux ancrés au curseur ne deviennent jamais
    /// fenêtre clé — c'est tout leur principe — et un suivi limité à la fenêtre
    /// active n'y répondrait donc jamais.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    /// Les rangées sont recyclées : sans cette remise à zéro, un survol resté
    /// collé se rallumerait sur une autre entrée après un défilement.
    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    /// La couleur du texte ne change pas quand la ligne est sélectionnée.
    ///
    /// `NSTableView` bascule ses libellés en blanc sur la sélection bleue, ce
    /// qui les rendrait illisibles sur un gris clair. On lui dit donc que la
    /// ligne n'est jamais « en évidence » au sens du système : elle l'est à sa
    /// façon, par le fond qu'on vient de peindre.
    override var isEmphasized: Bool {
        get { false }
        set { }
    }
}
