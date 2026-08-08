// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Où tombe chaque colonne d'un tableau, en points.
///
/// # Pourquoi une structure à part
///
/// La géométrie a **deux lecteurs** : le rendu, qui la traduit en crénage sur
/// les `|` masqués, et la couche de décoration, qui y trace les filets. Tant
/// qu'il n'y avait que trois filets — en haut, sous l'en-tête, en bas — la
/// décoration n'avait besoin de rien savoir. Une vraie grille, elle, doit
/// dessiner **entre** les colonnes, donc connaître leurs abscisses au point
/// près, et deux calculs séparés auraient divergé au premier changement de
/// police.
///
/// # Ce qu'elle mesure, et pourquoi ce n'est pas ce qu'on croit
///
/// Les largeurs sont **mesurées sur le rendu**, pas comptées en signes :
/// `**Titre**` rend six signes de moins que sa source, et une colonne calculée
/// sur les signes serait large de six de trop. C'est aussi ce qui permet à un
/// tableau d'être rendu dans la police du corps plutôt qu'en chasse fixe — la
/// chasse fixe garantissait l'alignement gratuitement, mais faisait ressembler
/// chaque tableau à un bloc de code.
@MainActor
struct TableLayout {

    /// Abscisse du bord gauche de chaque colonne, depuis le début de la ligne.
    var columnOrigins: [CGFloat]
    /// Largeur du contenu le plus large de chaque colonne.
    var columnWidths: [CGFloat]
    /// Gouttière entre deux colonnes — l'air de part et d'autre d'un filet.
    var gutter: CGFloat
    /// Largeur totale de la grille, bords compris.
    var width: CGFloat

    /// Abscisse du filet qui sépare la colonne `index` de la précédente.
    ///
    /// Au **milieu** de la gouttière : posé contre le texte, il ferait un cadre
    /// serré au lieu d'une grille aérée.
    func separatorX(before index: Int) -> CGFloat? {
        guard index > 0, index < columnOrigins.count else { return nil }
        return (columnOrigins[index] - gutter / 2).rounded()
    }

    /// La géométrie d'un tableau, ou `nil` s'il ne tient pas dans la colonne.
    ///
    /// Renvoyer `nil` est un cas normal et non une erreur : c'est le §6. Une
    /// grille plus large que la colonne se replierait rangée par rangée et ne se
    /// lirait plus du tout ; on affiche alors la source, qui reste lisible.
    ///
    /// La décision se prend sur les largeurs **mesurées**, donc sur ce qui sera
    /// réellement dessiné. L'ancienne estimation comptait les signes de la
    /// source en chasse fixe, ce qui la rendait fausse dans les deux sens dès
    /// qu'on quittait cette police.
    static func measure(_ table: MarkdownTable,
                        in storage: NSTextStorage,
                        typography: EditorTypography,
                        available: CGFloat) -> TableLayout? {
        guard !table.alignments.isEmpty else { return nil }

        // La gouttière suit le corps du texte : c'est elle qui donne l'air, et
        // elle doit grandir avec la police comme tout le reste.
        let gutter = (typography.bodySize * 1.6).rounded()

        var widths = [CGFloat](repeating: 0, count: table.columnCount)
        for row in table.rows {
            for (column, cell) in row.cells.enumerated() where column < widths.count {
                widths[column] = max(widths[column], measure(storage, cell.content))
            }
        }
        // Une colonne vide garde une largeur minimale, sinon deux filets se
        // toucheraient et la cellule ne serait plus cliquable.
        let minimum = (typography.bodySize * 1.5).rounded()
        widths = widths.map { max($0, minimum) }

        var origins: [CGFloat] = []
        var cursor = gutter / 2
        for width in widths {
            origins.append(cursor)
            cursor += width + gutter
        }
        let total = cursor - gutter / 2

        guard total <= available else { return nil }
        return TableLayout(columnOrigins: origins, columnWidths: widths,
                           gutter: gutter, width: total)
    }

    /// Largeur réellement rendue d'une plage, attributs compris.
    private static func measure(_ storage: NSTextStorage, _ range: NSRange) -> CGFloat {
        guard range.length > 0, range.upperBound <= storage.length else { return 0 }
        return storage.attributedSubstring(from: range).size().width
    }
}
