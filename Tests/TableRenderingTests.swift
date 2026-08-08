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

    func testATrailingAlignedColumnEndsFlush() throws {
        let source = """
        | n |
        |---:|
        | 1 |
        | 1234 |
        """
        let view = try render(source)
        let shortEnd = try caretX(at: (source as NSString).range(of: "| 1 |").location + 3, view: view)
        let longEnd = try caretX(at: (source as NSString).range(of: "| 1234 |").location + 6, view: view)

        XCTAssertEqual(shortEnd, longEnd, accuracy: tolerance,
                       "Une colonne alignée à droite doit finir au même x sur toutes ses rangées")
    }

    func testACenteredColumnIsIndentedByHalfTheSlack() throws {
        let source = """
        | n |
        |:-:|
        | 1 |
        | 1234 |
        """
        let view = try render(source)
        let shortStart = try caretX(at: (source as NSString).range(of: "| 1 |").location + 2, view: view)
        let longStart = try caretX(at: (source as NSString).range(of: "| 1234 |").location + 2, view: view)
        let one = try width(of: "1234", in: source, view: view) / 4

        // « 1 » est plus court de trois signes ; centré, il commence donc une
        // signe et demi plus loin que « 1234 ».
        XCTAssertEqual(shortStart - longStart, one * 1.5, accuracy: one * 0.6)
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

    func testTheSourceComesBackWhenTheCaretEntersTheTable() throws {
        // Le repli du §2.6 : sous le curseur, on retombe sur du markdown à
        // pipes. C'est ce qui rend le tableau modifiable sans éditeur imbriqué.
        let source = "| a | b |\n|---|---|\n| c | d |"
        let view = try render(source, caret: 2)
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertFalse(MarkerMask.isMasked(storage, at: 0), "Le `|` doit réapparaître")
        XCTAssertNotNil(storage.attribute(.foveaRevealed, at: 0, effectiveRange: nil))
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
