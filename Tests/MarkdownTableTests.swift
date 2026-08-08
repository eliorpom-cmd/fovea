// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
@testable import Fovea

/// La lecture de la grille (§2.6).
///
/// C'est la couche qui décide **quels caractères disparaissent** dans un
/// tableau. Une erreur d'un signe ici et une colonne entière glisse, ou un `|`
/// reste à l'écran au milieu d'une grille.
final class MarkdownTableTests: XCTestCase {

    private func scan(_ source: String) -> MarkdownTable? {
        let utf16 = Array(source.utf16)
        return MarkdownTable.scan(utf16: utf16, in: NSRange(location: 0, length: utf16.count))
    }

    private func text(_ source: String, _ range: NSRange) -> String {
        (source as NSString).substring(with: range)
    }

    // MARK: - Forme générale

    func testAPlainTableIsRead() throws {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        let table = try XCTUnwrap(scan(source))

        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.rows.count, 2, "L'en-tête et le corps, sans la ligne de délimitation")
        XCTAssertEqual(text(source, table.delimiter), "|---|---|")
        XCTAssertEqual(table.rows.map { $0.cells.map { text(source, $0.content) } },
                       [["a", "b"], ["1", "2"]])
    }

    func testATableWithoutOuterPipesIsRead() {
        // GFM les autorise, et beaucoup de gens écrivent comme ça.
        let source = "a | b\n--|--\n1 | 2"
        guard let table = scan(source) else { return XCTFail("Le tableau devrait être lu") }
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertFalse(table.rows[0].hasLeadingPipe)
        XCTAssertEqual(table.rows[0].cells.map { text(source, $0.content) }, ["a", "b"])
    }

    func testAlignmentsAreRead() throws {
        let table = try XCTUnwrap(scan("| a | b | c | d |\n|:--|--:|:-:|---|\n| 1 | 2 | 3 | 4 |"))
        XCTAssertEqual(table.alignments, [.leading, .trailing, .center, .leading])
    }

    // MARK: - Ce qui disparaît

    func testEveryPipeAndEveryPadIsAMarker() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        guard let table = scan(source) else { return XCTFail("Le tableau devrait être lu") }

        // Tout sauf le contenu des cellules doit être couvert : ce qui n'est pas
        // masqué reste à l'écran, et un seul `|` oublié saute aux yeux.
        var covered = Set<Int>()
        for marker in table.markerRanges {
            for offset in marker.location..<marker.upperBound { covered.insert(offset) }
        }
        var expected = Set(0..<(source as NSString).length)
        for row in table.rows {
            for cell in row.cells {
                for offset in cell.content.location..<cell.content.upperBound { expected.remove(offset) }
            }
        }
        // Les sauts de ligne ne sont ni contenu ni marqueur.
        for (offset, unit) in Array(source.utf16).enumerated() where unit == 10 { expected.remove(offset) }
        XCTAssertEqual(covered, expected)
    }

    func testTheDelimiterLineIsEntirelyAMarker() throws {
        let source = "| a |\n|:--|\n| 1 |"
        let table = try XCTUnwrap(scan(source))
        XCTAssertTrue(table.markerRanges.contains(table.delimiter))
    }

    // MARK: - Le cas qui casserait tout

    func testAnEscapedPipeDoesNotSplitACell() throws {
        // `\|` est le seul moyen d'écrire un `|` dans une cellule. Le traiter
        // comme un séparateur couperait la cellule en deux et décalerait toutes
        // les colonnes suivantes.
        let source = "| a \\| b | c |\n|---|---|\n| 1 | 2 |"
        let table = try XCTUnwrap(scan(source))
        XCTAssertEqual(table.rows[0].cells.map { text(source, $0.content) }, ["a \\| b", "c"])
    }

    func testAPipeInsideACodeSpanStillSplits() throws {
        // C'est la règle de GFM, aussi surprenante soit-elle : la découpe en
        // cellules a lieu avant l'analyse inline. Rendre autrement donnerait un
        // tableau différent de celui de GitHub.
        let source = "| `a|b` | c |\n|---|---|\n| 1 | 2 |"
        let table = try XCTUnwrap(scan(source))
        XCTAssertEqual(table.rows[0].cells.count, 3)
    }

    func testAnEmptyCellSurvives() throws {
        let source = "| a || c |\n|---|---|---|\n| 1 | 2 | 3 |"
        let table = try XCTUnwrap(scan(source))
        XCTAssertEqual(table.rows[0].cells.map { text(source, $0.content) }, ["a", "", "c"])
    }

    // MARK: - Ce qui n'est pas un tableau (§6)

    func testAMalformedDelimiterYieldsNoGrid() {
        // §6 : aucune grille, la source reste affichée. On ne devine jamais.
        XCTAssertNil(scan("| a | b |\n| x | y |\n| 1 | 2 |"))
        XCTAssertNil(scan("| a | b |\n|--x|---|\n| 1 | 2 |"))
        XCTAssertNil(scan("| a | b |"))
    }

    // MARK: - Largeur d'affichage

    func testColumnWidthIsTheWidestContent() throws {
        let table = try XCTUnwrap(scan("| a | bbbb |\n|---|---|\n| ccccc | d |"))
        XCTAssertEqual(table.columnWidths, [5, 4])
    }

    func testAnIdeographTakesTwoCells() {
        // Dans toute police à chasse fixe, un idéogramme occupe deux cellules.
        // Compter les unités UTF-16 désalignerait la colonne d'un signe par
        // caractère.
        let source = "漢字"
        let width = MarkdownTable.displayWidth(utf16: Array(source.utf16),
                                               in: NSRange(location: 0, length: 2))
        XCTAssertEqual(width, 4)
    }

    func testACombiningAccentTakesNone() {
        // « e » suivi d'un accent combinant : un signe à l'écran, deux unités.
        let source = "e\u{0301}"
        let utf16 = Array(source.utf16)
        XCTAssertEqual(MarkdownTable.displayWidth(utf16: utf16,
                                                  in: NSRange(location: 0, length: utf16.count)), 1)
    }

    func testAnEmojiTakesTwoCells() {
        let source = "🙂"
        let utf16 = Array(source.utf16)
        XCTAssertEqual(MarkdownTable.displayWidth(utf16: utf16,
                                                  in: NSRange(location: 0, length: utf16.count)), 2)
    }

    // MARK: - Positions

    func testShiftingMovesEveryPosition() throws {
        let source = "| a |\n|---|\n| 1 |"
        let table = try XCTUnwrap(scan(source))
        let moved = table.shifted(by: 100)

        XCTAssertEqual(moved.delimiter.location, table.delimiter.location + 100)
        XCTAssertEqual(moved.rows[0].pipes[0].location, table.rows[0].pipes[0].location + 100)
        XCTAssertEqual(moved.rows[0].cells[0].content.location,
                       table.rows[0].cells[0].content.location + 100)
        XCTAssertEqual(moved.columnWidths, table.columnWidths)
    }

    // MARK: - Intégration avec le parseur

    func testTheParserAttachesTheGridToTheSpan() throws {
        let source = "Avant.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nAprès.\n"
        let spans = MarkdownParser.parse(source).spans
        let table = try XCTUnwrap(spans.first { if case .table = $0.kind { return true } else { return false } })

        guard case .table(let grid?) = table.kind else { return XCTFail("La grille doit être attachée") }
        XCTAssertEqual(grid.columnCount, 2)
        // Les positions sont celles du document entier, pas celles du bloc.
        XCTAssertEqual(text(source, grid.rows[0].cells[0].content), "a")
    }

    func testAnAccentedTableStaysAligned() throws {
        // Le piège du §3.3 : cmark compte en octets, le tampon en unités UTF-16.
        // Un tableau plein d'accents est le meilleur révélateur d'un décalage.
        let source = "| Élément | Réglé |\n|---|---|\n| Été | Oui |\n"
        let spans = MarkdownParser.parse(source).spans
        let table = try XCTUnwrap(spans.first { if case .table = $0.kind { return true } else { return false } })
        guard case .table(let grid?) = table.kind else { return XCTFail("La grille doit être attachée") }

        XCTAssertEqual(text(source, grid.rows[0].cells[0].content), "Élément")
        XCTAssertEqual(text(source, grid.rows[1].cells[0].content), "Été")
    }
}
