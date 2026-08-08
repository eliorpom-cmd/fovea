// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// La géométrie d'un tableau GFM, lue **directement dans la source**.
///
/// # Pourquoi ne pas prendre l'arbre de cmark
///
/// `swift-markdown` donne bien un `Table`, ses lignes et ses cellules, mais il
/// ne donne pas ce dont le rendu a besoin : la position de chaque `|`, celle
/// des blancs de remplissage, et la ligne de délimitation — que l'analyseur
/// consomme et fait disparaître. Or ce sont exactement les caractères à
/// masquer.
///
/// Le balayage est donc fait ici, à la main. Il est court, il n'a aucune
/// ambiguïté à lever, et il travaille dans les mêmes unités UTF-16 que tout le
/// reste de l'éditeur.
///
/// # La règle de découpe
///
/// GFM découpe les cellules sur les `|` **avant** toute autre analyse inline.
/// Un `|` dans un `code span` coupe donc quand même, et le seul moyen d'en
/// écrire un dans une cellule est `\|`. C'est cette règle qui est appliquée —
/// pas une plus intelligente, qui produirait un rendu différent de GitHub.
struct MarkdownTable: Equatable, Sendable {

    /// L'alignement d'une colonne, lu dans la ligne `|:--|--:|:-:|`.
    enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    struct Cell: Equatable, Sendable {
        /// Le contenu, blancs de remplissage exclus. C'est la seule partie qui
        /// reste visible quand la grille est affichée.
        var content: NSRange
        /// Les blancs entre les `|` et le contenu. Masqués avec les `|` : la
        /// grille place les colonnes elle-même, l'espacement de la source ne la
        /// regarde pas.
        var padding: [NSRange]
        /// Largeur d'affichage du contenu, en signes de chasse fixe.
        var width: Int
    }

    struct Row: Equatable, Sendable {
        var line: NSRange
        /// Les `|` de la ligne, dans l'ordre où ils apparaissent.
        var pipes: [NSRange]
        var cells: [Cell]
        /// Vrai si la ligne s'ouvre par un `|`, qui sert alors de bord gauche.
        var hasLeadingPipe: Bool
    }

    /// La ligne `|---|:--:|`. Elle ne porte aucun contenu : entièrement masquée
    /// en lecture, elle laisse la place au filet d'en-tête.
    var delimiter: NSRange
    /// L'en-tête puis le corps. La ligne de délimitation n'en fait pas partie.
    var rows: [Row]
    var alignments: [Alignment]
    /// Largeur de chaque colonne, en signes : le plus large de ses contenus.
    var columnWidths: [Int]

    var columnCount: Int { alignments.count }

    /// Largeur totale de la grille, gouttières comprises, en signes.
    ///
    /// Sert au garde-fou du rendu : un tableau plus large que la colonne de
    /// texte reviendrait à la ligne, et une grille qui se replie ne se lit plus
    /// du tout. Dans ce cas on renonce à la grille et on montre la source.
    func totalWidth(gutter: Int) -> Int {
        guard !columnWidths.isEmpty else { return 0 }
        return columnWidths.reduce(0, +) + gutter * (columnWidths.count - 1)
    }

    /// Tout ce qui doit disparaître en lecture : les `|`, les blancs de
    /// remplissage, et la ligne de délimitation entière.
    var markerRanges: [NSRange] {
        var result: [NSRange] = [delimiter]
        for row in rows {
            result.append(contentsOf: row.pipes)
            for cell in row.cells {
                result.append(contentsOf: cell.padding)
            }
        }
        return result.filter { $0.length > 0 }.sorted { $0.location < $1.location }
    }

    /// Décale toutes les positions — après une analyse par fragment (§3.3).
    func shifted(by delta: Int) -> MarkdownTable {
        guard delta != 0 else { return self }
        func move(_ range: NSRange) -> NSRange {
            NSRange(location: range.location + delta, length: range.length)
        }
        var copy = self
        copy.delimiter = move(delimiter)
        copy.rows = rows.map { row in
            var moved = row
            moved.line = move(row.line)
            moved.pipes = row.pipes.map(move)
            moved.cells = row.cells.map { cell in
                var movedCell = cell
                movedCell.content = move(cell.content)
                movedCell.padding = cell.padding.map(move)
                return movedCell
            }
            return moved
        }
        return copy
    }

    // MARK: - Balayage

    /// Lit un tableau dans `range`, ou renvoie `nil` si ce n'en est pas un.
    ///
    /// Renvoyer `nil` n'est pas un échec : c'est le comportement du §6 pour un
    /// tableau malformé. Aucune grille n'est dessinée, la source reste affichée
    /// telle quelle, et on ne devine jamais l'intention.
    static func scan(utf16: [UInt16], in range: NSRange) -> MarkdownTable? {
        let lines = lineRanges(utf16: utf16, in: range)
        guard lines.count >= 2 else { return nil }

        let parsed = lines.map { row(utf16: utf16, line: $0) }
        guard let alignments = delimiterAlignments(parsed[1], utf16: utf16) else { return nil }
        guard !alignments.isEmpty else { return nil }

        let content = Array(parsed[..<1] + parsed[2...])
        var widths = [Int](repeating: 1, count: alignments.count)
        for row in content {
            for (column, cell) in row.cells.enumerated() where column < widths.count {
                widths[column] = max(widths[column], cell.width)
            }
        }

        return MarkdownTable(delimiter: lines[1],
                             rows: content,
                             alignments: alignments,
                             columnWidths: widths)
    }

    // MARK: - Découpe d'une ligne

    private static let pipe = UInt16(UnicodeScalar("|").value)
    private static let backslash = UInt16(UnicodeScalar("\\").value)

    private static func row(utf16: [UInt16], line: NSRange) -> Row {
        var pipes: [NSRange] = []
        var offset = line.location
        while offset < line.upperBound {
            if utf16[offset] == pipe, !isEscaped(utf16: utf16, at: offset, from: line.location) {
                pipes.append(NSRange(location: offset, length: 1))
            }
            offset += 1
        }

        // Les segments entre les `|`, bords compris.
        var segments: [NSRange] = []
        var start = line.location
        for pipeRange in pipes {
            segments.append(NSRange(location: start, length: pipeRange.location - start))
            start = pipeRange.upperBound
        }
        segments.append(NSRange(location: start, length: line.upperBound - start))

        // Un `|` de bord n'ouvre pas de cellule : le segment qui le précède,
        // vide ou blanc, n'en est pas une. Même chose à droite.
        var hasLeadingPipe = false
        if !pipes.isEmpty, let first = segments.first, isBlank(utf16: utf16, in: first) {
            hasLeadingPipe = true
            segments.removeFirst()
        }
        if !pipes.isEmpty, let last = segments.last, isBlank(utf16: utf16, in: last), segments.count > 1 {
            segments.removeLast()
        }

        let cells = segments.map { cell(utf16: utf16, in: $0) }
        return Row(line: line, pipes: pipes, cells: cells, hasLeadingPipe: hasLeadingPipe)
    }

    private static func cell(utf16: [UInt16], in segment: NSRange) -> Cell {
        var start = segment.location
        var end = segment.upperBound
        while start < end, isSpace(utf16[start]) { start += 1 }
        while end > start, isSpace(utf16[end - 1]) { end -= 1 }

        let content = NSRange(location: start, length: end - start)
        var padding: [NSRange] = []
        if start > segment.location {
            padding.append(NSRange(location: segment.location, length: start - segment.location))
        }
        if segment.upperBound > end {
            padding.append(NSRange(location: end, length: segment.upperBound - end))
        }
        return Cell(content: content, padding: padding,
                    width: displayWidth(utf16: utf16, in: content))
    }

    /// Lit les alignements dans la ligne de délimitation, ou `nil` si elle n'en
    /// est pas une.
    private static func delimiterAlignments(_ row: Row, utf16: [UInt16]) -> [Alignment]? {
        var result: [Alignment] = []
        for cell in row.cells {
            guard cell.content.length > 0 else { return nil }
            let colon = UInt16(UnicodeScalar(":").value)
            let dash = UInt16(UnicodeScalar("-").value)

            var offset = cell.content.location
            let end = cell.content.upperBound
            let opens = utf16[offset] == colon
            if opens { offset += 1 }
            var dashes = 0
            while offset < end, utf16[offset] == dash { offset += 1; dashes += 1 }
            let closes = offset < end && utf16[offset] == colon
            if closes { offset += 1 }

            // Rien d'autre n'est toléré : `|--x--|` n'est pas une délimitation,
            // et le bloc n'est alors pas un tableau.
            guard dashes >= 1, offset == end else { return nil }

            switch (opens, closes) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Outils

    /// Les lignes d'une plage, terminateur exclu.
    private static func lineRanges(utf16: [UInt16], in range: NSRange) -> [NSRange] {
        let newline = UInt16(10)
        var result: [NSRange] = []
        var start = range.location
        var offset = range.location
        while offset < min(range.upperBound, utf16.count) {
            if utf16[offset] == newline {
                result.append(NSRange(location: start, length: offset - start))
                start = offset + 1
            }
            offset += 1
        }
        if start < min(range.upperBound, utf16.count) {
            result.append(NSRange(location: start, length: min(range.upperBound, utf16.count) - start))
        }
        return result
    }

    /// Un `|` précédé d'un nombre **impair** de contre-obliques est échappé.
    private static func isEscaped(utf16: [UInt16], at location: Int, from start: Int) -> Bool {
        var count = 0
        var offset = location - 1
        while offset >= start, utf16[offset] == backslash {
            count += 1
            offset -= 1
        }
        return count % 2 == 1
    }

    private static func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 }

    private static func isBlank(utf16: [UInt16], in range: NSRange) -> Bool {
        for offset in range.location..<range.upperBound where !isSpace(utf16[offset]) {
            return false
        }
        return true
    }

    /// Largeur d'affichage en chasse fixe.
    ///
    /// Ce n'est **pas** le nombre d'unités UTF-16 : un idéogramme occupe deux
    /// cellules dans toutes les polices à chasse fixe, un accent combinant n'en
    /// occupe aucune, et un emoji en occupe deux pour deux unités. Compter les
    /// unités désalignerait toute colonne contenant du CJK.
    static func displayWidth(utf16: [UInt16], in range: NSRange) -> Int {
        var width = 0
        var offset = range.location
        while offset < min(range.upperBound, utf16.count) {
            let unit = utf16[offset]
            var scalarValue = UInt32(unit)
            if unit >= 0xD800, unit <= 0xDBFF, offset + 1 < range.upperBound {
                let low = utf16[offset + 1]
                if low >= 0xDC00, low <= 0xDFFF {
                    scalarValue = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(low - 0xDC00)
                    offset += 1
                }
            }
            offset += 1
            guard let scalar = Unicode.Scalar(scalarValue) else { width += 1; continue }
            width += cellWidth(of: scalar)
        }
        return width
    }

    private static func cellWidth(of scalar: Unicode.Scalar) -> Int {
        // Marques combinantes : posées sur le signe précédent, sans avance.
        if scalar.properties.canonicalCombiningClass != .notReordered { return 0 }
        switch scalar.value {
        case 0x1100...0x115F,      // jamo hangul initiaux
             0x2E80...0xA4CF,      // radicaux, kana, idéogrammes
             0xAC00...0xD7A3,      // syllabes hangul
             0xF900...0xFAFF,      // idéogrammes de compatibilité
             0xFE30...0xFE6F,      // formes de ponctuation verticale
             0xFF00...0xFF60,      // formes pleine chasse
             0xFFE0...0xFFE6,
             0x1F300...0x1F9FF,    // emoji
             0x20000...0x3FFFD:    // plans idéographiques supplémentaires
            return 2
        default:
            return 1
        }
    }
}
