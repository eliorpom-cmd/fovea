// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// La grille des tableaux, **mesurée sur la mise en page réelle** (§2.6).
///
/// Comme pour le jalon 0, on ne vérifie pas une intention mais des abscisses :
/// une colonne est alignée si le curseur placé au début de chaque cellule tombe
/// exactement au même x. C'est la seule assertion qui ait du sens ici — la
/// grille n'existe que dans le crénage des `|`, et rien dans le tampon ne dirait
/// qu'elle est droite.
@MainActor
final class TableRenderingTests: XCTestCase {

    /// TextKit arrondit au sous-pixel ; la tolérance reste très en dessous de
    /// la largeur du plus fin des caractères.
    private let tolerance: CGFloat = 0.6

    // MARK: - L'assertion qui compte

    func testColumnsLineUpAcrossRows() throws {
        // Les contenus n'ont pas la même longueur d'une ligne à l'autre : sans
        // grille, la deuxième colonne serait à trois abscisses différentes.
        let source = """
        | a | x |
        |---|---|
        | bbbb | y |
        | cc | z |
        """
        let view = try render(source)
        let xs = try ["x", "y", "z"].map { try caretX(atFirstOccurrenceOf: $0, in: source, view: view) }

        XCTAssertEqual(xs[0], xs[1], accuracy: tolerance, "L'en-tête et la première rangée doivent s'aligner")
        XCTAssertEqual(xs[1], xs[2], accuracy: tolerance, "Les rangées doivent s'aligner entre elles")
    }

    func testTheSecondColumnStartsAfterTheWidestCellOfTheFirst() throws {
        let source = """
        | a | x |
        |---|---|
        | bbbbbbbb | y |
        """
        let view = try render(source)
        let firstColumn = try caretX(atFirstOccurrenceOf: "a", in: source, view: view)
        let secondColumn = try caretX(atFirstOccurrenceOf: "x", in: source, view: view)
        let widest = try width(of: "bbbbbbbb", in: source, view: view)

        // Huit signes plus la gouttière : la colonne suivante ne peut pas
        // commencer avant, sinon « bbbbbbbb » déborderait dessus.
        XCTAssertGreaterThan(secondColumn - firstColumn, widest)
    }

    // MARK: - Alignements

    /// **Toutes les cellules partent du même bord.**
    ///
    /// L'alignement de la ligne `|:---:|---:|` reste dans le fichier — il n'est
    /// simplement plus rendu. Une grille dont chaque colonne commence à un bord
    /// différent se parcourt moins bien qu'une grille dont toutes les entrées
    /// tombent au même point, et c'est le rendu qui a été tranché.
    func testEveryCellIsLeftAlignedWhateverTheDelimiterSays() throws {
        let source = """
        | g | c | d |
        |---|:-:|--:|
        | 1 | 1 | 1 |
        | 1234 | 1234 | 1234 |
        """
        let view = try render(source)
        for column in 0..<3 {
            let short = try cellStart(row: "| 1 | 1 | 1 |", column: column, in: source, view: view)
            let long = try cellStart(row: "| 1234 | 1234 | 1234 |", column: column, in: source, view: view)
            XCTAssertEqual(short, long, accuracy: tolerance,
                           "La colonne \(column) doit partir du même x sur les deux rangées")
        }
    }

    func testACellIsNotGluedToItsRule() throws {
        // Un peu d'air entre le filet et la première lettre : sans lui, la
        // grille se lit comme un tableau de chiffres.
        let source = "| a | b |\n|---|---|\n| c | d |"
        let view = try render(source)
        let left = try caretX(at: 0, view: view)
        let text = try caretX(atFirstOccurrenceOf: "a", in: source, view: view)
        XCTAssertGreaterThan(text - left, 2, "Le contenu garde un retrait par rapport au bord")
    }

    // MARK: - Hauteur des rangées

    /// **Un tableau vide reste un tableau.**
    ///
    /// Les `|` masqués mesurent un centième de point : une rangée dont toutes
    /// les cellules sont vides n'avait donc aucune hauteur naturelle, et le
    /// multiplicateur d'interlignage multipliait ce néant. Le tableau à remplir
    /// de « 6 — Tableaux » se réduisait à trois filets empilés, sans une rangée
    /// où poser le curseur.
    func testAnEmptyTableKeepsClickableRows() throws {
        let full = try lineHeights(in: try render("| a | b |\n|---|---|\n| c | d |"))
        let empty = try lineHeights(in: try render("|  |  |\n|---|---|\n|  |  |"))

        XCTAssertEqual(empty.count, full.count)
        for (index, height) in empty.enumerated() {
            XCTAssertEqual(height, full[index], accuracy: tolerance,
                           "La rangée \(index) vide doit faire la hauteur d'une rangée pleine")
        }
    }

    /// Le tableau occupe **toute la colonne de texte**.
    ///
    /// À la taille de son contenu, un tableau qu'on venait d'insérer — toutes
    /// cellules vides — se réduisait à un filet de 168 points au milieu d'une
    /// colonne trois fois plus large : on ne voyait pas où cliquer.
    func testATableFillsTheTextColumn() throws {
        let typography = EditorTypography.default
        for source in ["|  |  |  |\n|---|---|---|\n|  |  |  |",
                       "| a | b |\n|---|---|\n| c | d |",
                       "| Piège | Symptôme | Correctif |\n|---|---|---|\n| a | b | c |"] {
            let view = try render(source)
            let storage = try XCTUnwrap(view.textStorage)
            let table = try XCTUnwrap(firstTable(in: source))
            let layout = try XCTUnwrap(TableLayout.measure(table, in: storage,
                                                          typography: typography,
                                                          available: typography.columnWidth))
            XCTAssertEqual(layout.width, typography.columnWidth, accuracy: 3,
                           "Le tableau doit tenir toute la colonne : \(source)")
        }
    }

    /// L'étirement ne doit pas rattraper un tableau trop large : celui-là reste
    /// en source, et le test se fait sur sa largeur **naturelle**.
    func testAnOversizedTableIsStillRefusedBeforeStretching() throws {
        let source = """
        | Une colonne au titre interminable | Une deuxième tout aussi longue | Une troisième pour finir | Et une quatrième |
        |---|---|---|---|
        | a | b | c | d |
        """
        let view = try render(source)
        let storage = try XCTUnwrap(view.textStorage)
        let table = try XCTUnwrap(firstTable(in: source))
        XCTAssertNil(TableLayout.measure(table, in: storage,
                                         typography: .default,
                                         available: EditorTypography.default.columnWidth))
    }

    private func firstTable(in source: String) -> MarkdownTable? {
        for span in MarkdownParser.parse(source).spans {
            if case .table(let table?) = span.kind { return table }
        }
        return nil
    }

    // MARK: - Les deux états du §2.1

    func testPipesTakeNoWidthWhenTheCaretIsElsewhere() throws {
        let source = "| a | b |\n|---|---|\n| c | d |"
        let view = try render(source)
        let storage = try XCTUnwrap(view.textStorage)

        // Le `|` de bord gauche de la première rangée.
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 0))
        // Les blancs de remplissage aussi : c'est la grille qui espace.
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 1))
        XCTAssertFalse(MarkerMask.isMasked(storage, at: 2), "« a » est du contenu")
    }

    /// **La grille ne se replie plus sous le curseur.**
    ///
    /// C'était le repli du §2.6 : le curseur entrait, `| a | b |` réapparaissait,
    /// on éditait la source. Honnête, mais cela revient à demander de connaître
    /// la syntaxe d'un tableau markdown pour changer une cellule — c'est-à-dire
    /// exactement ce que l'app promet d'éviter, et ce que personne ne fait à la
    /// main. On écrit maintenant dans la grille ; `TableEditing` s'occupe des
    /// positions de curseur que plus rien n'affiche.
    func testTheGridStaysWhenTheCaretEntersTheTable() throws {
        let source = "| a | b |\n|---|---|\n| c | d |"
        let view = try render(source, caret: 2)
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertTrue(MarkerMask.isMasked(storage, at: 0), "Le `|` doit rester masqué")
        XCTAssertNil(storage.attribute(.foveaRevealed, at: 0, effectiveRange: nil))
        XCTAssertFalse(MarkerMask.isMasked(storage, at: 2), "…et « a » rester du contenu")
    }

    func testTheDelimiterLineIsShorterThanARow() throws {
        // Elle ne montre rien : sa hauteur est celle du filet qu'elle porte.
        let source = "| a |\n|---|\n| c |"
        let view = try render(source)
        let heights = try lineHeights(in: view)
        XCTAssertEqual(heights.count, 3)
        XCTAssertLessThan(heights[1], heights[0] * 0.9,
                          "La ligne |---| doit être réduite, pas rendue comme une rangée")
    }

    // MARK: - Quand il n'y a pas de grille (§6)

    func testAMalformedTableKeepsItsSourceIntact() throws {
        // Aucune grille, aucun masquage : on ne devine jamais l'intention.
        let source = "| a | b |\n| x | y |\n| 1 | 2 |"
        let view = try render(source)
        let storage = try XCTUnwrap(view.textStorage)
        for offset in 0..<storage.length {
            XCTAssertFalse(MarkerMask.isMasked(storage, at: offset),
                           "Rien ne doit être masqué à l'offset \(offset)")
        }
    }

    func testATableTooWideForTheColumnStaysInSource() throws {
        // Une grille plus large que la colonne se replierait rangée par rangée
        // et ne se lirait plus. Mieux vaut la source, lisible.
        let wide = String(repeating: "x", count: 60)
        let source = "| \(wide) | \(wide) |\n|---|---|\n| a | b |"
        let view = try render(source)
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertFalse(MarkerMask.isMasked(storage, at: 0))
        XCTAssertNotNil(storage.attribute(.foveaRevealed, at: 0, effectiveRange: nil))
    }

    // MARK: - Le tampon n'est jamais touché (§3.1)

    func testRenderingATableAddsNoCharacter() throws {
        let source = "| a | b |\n|---|---|\n| c | d |"
        let view = try render(source)
        XCTAssertEqual(view.string, source,
                       "La grille est faite d'attributs seuls : pas un signe ajouté")
    }

    // MARK: - Instruments

    private func render(_ source: String, caret: Int? = nil) throws -> EditorTextView {
        let view = EditorTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false

        let storage = try XCTUnwrap(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)

        let parsed = MarkdownParser.parse(source)
        let revealed: Set<Int> = caret.map {
            RevealPolicy.revealedIndices(spans: parsed.spans,
                                         selection: NSRange(location: $0, length: 0),
                                         lineRange: parsed.positions.lineRange(containing: $0))
        } ?? []

        MarkdownRenderer(typography: .default)
            .render(storage, spans: parsed.spans, revealed: revealed,
                    in: NSRange(location: 0, length: storage.length))

        let layout = try XCTUnwrap(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        return view
    }

    private func caretX(at offset: Int, view: EditorTextView) throws -> CGFloat {
        let layout = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(view.textContentStorage)
        let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: offset))

        var x: CGFloat?
        layout.enumerateTextSegments(in: NSTextRange(location: location),
                                     type: .selection, options: []) { _, frame, _, _ in
            x = frame.origin.x
            return false
        }
        return try XCTUnwrap(x, "Aucun segment à l'offset \(offset)")
    }

    private func caretX(atFirstOccurrenceOf needle: String, in source: String,
                        view: EditorTextView) throws -> CGFloat {
        let range = (source as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "« \(needle) » introuvable")
        return try caretX(at: range.location, view: view)
    }

    /// Abscisse du premier signe d'une cellule, repérée par sa rangée source.
    private func cellStart(row: String, column: Int, in source: String,
                           view: EditorTextView) throws -> CGFloat {
        let line = (source as NSString).range(of: row)
        XCTAssertNotEqual(line.location, NSNotFound, "Rangée « \(row) » introuvable")
        // `| a | b |` : le contenu de la colonne n commence après le n+1-ième
        // `|` et son blanc.
        var offset = line.location
        var seen = 0
        while seen <= column, offset < line.upperBound {
            if (source as NSString).character(at: offset) == UInt16(UnicodeScalar("|").value) { seen += 1 }
            offset += 1
        }
        return try caretX(at: offset + 1, view: view)
    }

    /// Largeur rendue d'un fragment, mesurée entre ses deux extrémités.
    private func width(of needle: String, in source: String, view: EditorTextView) throws -> CGFloat {
        let range = (source as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, "« \(needle) » introuvable")
        return try caretX(at: range.upperBound, view: view) - caretX(at: range.location, view: view)
    }

    private func lineHeights(in view: EditorTextView) throws -> [CGFloat] {
        let layout = try XCTUnwrap(view.textLayoutManager)
        var heights: [CGFloat] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            heights.append(fragment.layoutFragmentFrame.height)
            return true
        }
        return heights
    }
}
