// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// Écrire **dans** un tableau, sans jamais voir ses `|`.
///
/// # Ce que ce fichier remplace
///
/// La première version repliait la grille dès que le curseur entrait : on
/// voyait réapparaître `| une | deux |`, on éditait la source, on ressortait.
/// C'était le repli armé par le §2.6, et il était honnête — mais il demande de
/// connaître la syntaxe d'un tableau markdown, c'est-à-dire exactement ce que
/// l'app promet de ne plus imposer. Personne n'écrit un tableau à la main.
///
/// La grille reste donc affichée en permanence, et c'est ici que se règle le
/// prix à payer : **les positions de curseur qui ne correspondent à rien
/// d'affiché**.
///
/// # Le problème, précisément
///
/// Les `|`, les blancs de remplissage et la ligne `|---|` sont masqués. Le §2.3
/// montre que le curseur ne peut jamais tomber dans un marqueur masqué —
/// mais cette démonstration repose sur le fait qu'une construction se révèle
/// quand le curseur la touche. Une grille qui ne se replie **jamais** sort de
/// ce raisonnement : le tampon contient des caractères que rien ne montrera, et
/// une flèche droite peut poser le curseur au milieu d'eux.
///
/// La réponse n'est pas d'intercepter les commandes de déplacement une à une —
/// il y en a une trentaine avec leurs variantes de sélection, et un jour l'une
/// manquerait. C'est de **corriger le curseur après coup** : quel que soit le
/// geste — flèche, clic, `⌘↓`, dictée —, s'il atterrit hors d'une cellule, il
/// est ramené dans la plus proche, dans le sens où il allait.
///
/// Tout est pur et sans AppKit : c'est ce qui permet de vérifier au test que
/// **aucune position d'un tableau réel ne laisse le curseur en dehors d'une
/// cellule**, ce qu'aucune interception ne saurait démontrer.
enum TableEditing {

    /// Les plages de contenu des cellules, dans l'ordre du document.
    ///
    /// La ligne de délimitation n'en fait pas partie : elle ne se rend pas, on
    /// n'y écrit donc jamais.
    static func cellContents(of table: MarkdownTable) -> [NSRange] {
        table.rows.flatMap { $0.cells.map(\.content) }
    }

    /// Ce point est-il un endroit où l'on peut écrire ?
    ///
    /// Bornes comprises : le début et la fin d'une cellule sont dans la cellule.
    /// Une cellule vide est une plage de longueur nulle, et sa seule position
    /// est valide — sans quoi on ne pourrait jamais remplir un tableau neuf.
    static func isEditable(_ location: Int, in table: MarkdownTable) -> Bool {
        cellContents(of: table).contains { RevealPolicy.contains($0, location) }
    }

    /// Ramène le curseur dans une cellule.
    ///
    /// - Parameter forward: le sens du déplacement qui vient d'avoir lieu. En
    ///   avançant on prend la première position valide **après**, en reculant la
    ///   dernière **avant** : c'est ce qui fait qu'une flèche droite continue
    ///   d'avancer au lieu de rebondir sur la cellule qu'on vient de quitter.
    /// - Returns: `nil` quand la position est déjà bonne, ou qu'aucune ne l'est.
    static func correctedCaret(_ location: Int, in table: MarkdownTable, forward: Bool) -> Int? {
        guard !isEditable(location, in: table) else { return nil }

        // Sur la ligne de délimitation, la colonne est connue : on ressort donc
        // dans la **même colonne**, une ligne plus loin. Sans ça, une flèche
        // vers le bas depuis l'en-tête renverrait au début du tableau, et la
        // colonne qu'on suivait des yeux serait perdue à chaque traversée.
        if RevealPolicy.contains(table.delimiter, location),
           let column = table.delimiterCells.firstIndex(where: { RevealPolicy.contains($0, location) })
               ?? nearestColumn(to: location, among: table.delimiterCells),
           let target = cell(row: forward ? 1 : 0, column: column, in: table) {
            return target.location
        }

        let contents = cellContents(of: table)
        if forward, let next = contents.first(where: { $0.location >= location }) {
            return next.location
        }
        if !forward, let previous = contents.last(where: { $0.upperBound <= location }) {
            return previous.upperBound
        }
        // Bord du tableau : on retombe sur l'autre extrémité plutôt que de
        // laisser le curseur dans les `|`.
        return forward ? contents.last?.upperBound : contents.first?.location
    }

    /// La cellule voisine, pour `⇥` et `⇧⇥`.
    ///
    /// Elle est rendue **entière** : la tabulation sélectionne le contenu de la
    /// cellule d'arrivée, ce qui permet de le remplacer en tapant. C'est le
    /// geste d'un tableur, et celui d'Apple Notes.
    ///
    /// - Returns: `nil` au-delà de la dernière cellule — l'appelant crée alors
    ///   une ligne.
    static func neighbouringCell(from location: Int, in table: MarkdownTable, forward: Bool) -> NSRange? {
        let contents = cellContents(of: table)
        guard let index = contents.firstIndex(where: { RevealPolicy.contains($0, location) })
            ?? contents.firstIndex(where: { $0.location >= location })
        else { return nil }

        let target = forward ? index + 1 : index - 1
        return contents.indices.contains(target) ? contents[target] : nil
    }

    /// La cellule de même colonne dans la ligne suivante, pour `⏎`.
    static func cellBelow(_ location: Int, in table: MarkdownTable) -> NSRange? {
        guard let position = position(of: location, in: table) else { return nil }
        return cell(row: position.row + 1, column: position.column, in: table)
    }

    /// Où se trouve ce curseur, en (ligne, colonne).
    static func position(of location: Int, in table: MarkdownTable) -> (row: Int, column: Int)? {
        for (row, line) in table.rows.enumerated() {
            for (column, cell) in line.cells.enumerated()
            where RevealPolicy.contains(cell.content, location) {
                return (row, column)
            }
        }
        return nil
    }

    /// Le curseur est-il dans la première position d'une cellule ?
    ///
    /// Sert à `⌫` : effacer là reviendrait à manger le `|` qui précède, donc à
    /// fusionner deux colonnes sans que rien ne l'ait demandé.
    static func isAtCellStart(_ location: Int, in table: MarkdownTable) -> Bool {
        cellContents(of: table).contains { $0.location == location }
    }

    // MARK: - Ajouter une ligne

    /// La ligne vide à insérer sous `row`, et où poser le curseur dedans.
    ///
    /// Le style suit celui de la ligne au-dessus — bord gauche ou non — parce
    /// que le §5 vaut ici aussi : un tableau écrit sans `|` de bord ne doit pas
    /// en gagner un parce qu'on lui a ajouté une ligne.
    static func newRow(below row: Int, in table: MarkdownTable) -> (text: String, caret: Int)? {
        guard table.rows.indices.contains(row) else { return nil }
        let model = table.rows[row]
        let columns = max(1, table.columnCount)

        var line = model.hasLeadingPipe ? "|" : ""
        // Une cellule vide et non un blanc : `|  |` se relit comme une cellule
        // vide, et le curseur s'y pose sans avoir à traverser des espaces.
        for _ in 0..<columns { line += "  |" }
        if !model.hasLeadingPipe { line.removeLast() }

        let caret = (model.hasLeadingPipe ? 1 : 0) + 1
        return ("\n" + line, caret + 1)
    }

    // MARK: - Détails

    private static func cell(row: Int, column: Int, in table: MarkdownTable) -> NSRange? {
        guard table.rows.indices.contains(row) else { return nil }
        let cells = table.rows[row].cells
        guard !cells.isEmpty else { return nil }
        return cells[min(column, cells.count - 1)].content
    }

    /// La colonne dont la plage est la plus proche — pour une position tombée
    /// entre deux `---` de la ligne de délimitation.
    private static func nearestColumn(to location: Int, among cells: [NSRange]) -> Int? {
        cells.indices.min { left, right in
            distance(from: location, to: cells[left]) < distance(from: location, to: cells[right])
        }
    }

    private static func distance(from location: Int, to range: NSRange) -> Int {
        if location < range.location { return range.location - location }
        if location > range.upperBound { return location - range.upperBound }
        return 0
    }
}
