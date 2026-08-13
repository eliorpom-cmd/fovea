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

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let box = bounds.insetBy(dx: Self.inset, dy: 1)
        Theme.NS.rowSelection.setFill()
        NSBezierPath(roundedRect: box, xRadius: Self.radius, yRadius: Self.radius).fill()
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
