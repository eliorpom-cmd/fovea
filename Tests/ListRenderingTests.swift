// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Les items de liste qui tiennent sur **plusieurs lignes de source**.
///
/// Un `.md` écrit à la main est presque toujours replié autour de 80 signes :
/// un item de trois phrases occupe donc trois lignes, dont deux ne portent pas
/// de puce. Ces lignes-là n'avaient aucun style de bloc — la plage du span
/// s'arrête à la première ligne, pour que la puce ne réapparaisse pas quand le
/// curseur est trois lignes plus bas — et retombaient au retrait zéro : elles se
/// dessinaient **à gauche de leur propre puce**, avec leur indentation de source
/// en blanc devant. Sur le document d'accueil du dossier `essais/`, c'était le
/// premier défaut qu'on voyait.
///
/// Comme pour les tableaux, on ne vérifie pas une intention mais des abscisses.
@MainActor
final class ListRenderingTests: XCTestCase {

    private let tolerance: CGFloat = 0.6

    func testAContinuationLineSitsUnderTheItemText() throws {
        let source = """
        - Une première phrase.
          Sa continuation.
        """
        let view = try render(source)
        let first = try caretX(atFirstOccurrenceOf: "Une", in: source, view: view)
        let next = try caretX(atFirstOccurrenceOf: "Sa", in: source, view: view)
        XCTAssertEqual(next, first, accuracy: tolerance,
                       "La continuation tombe sous le texte de l'item, pas sous la marge")
    }

    func testAContinuationLineIsIndentedPastTheBullet() throws {
        // L'assertion complémentaire : avant le correctif, la continuation était
        // non seulement désalignée mais **plus à gauche que la puce**.
        let source = """
        - Une première phrase.
          Sa continuation.
        """
        let view = try render(source)
        let bullet = try caretX(at: 0, view: view)
        let next = try caretX(atFirstOccurrenceOf: "Sa", in: source, view: view)
        XCTAssertGreaterThan(next, bullet, "La continuation reste à droite de la puce")
    }

    func testTheSourceIndentOfAContinuationIsMasked() throws {
        // Les deux blancs sont de la syntaxe : ce sont eux qui gardent la phrase
        // dans la puce. Visibles, ils s'ajoutaient au retrait et décalaient la
        // continuation d'un cran de trop.
        let source = "- Un item.\n  Sa suite.\n"
        let view = try render(source)
        let storage = try XCTUnwrap(view.textStorage)
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 11), "Le premier blanc de continuation")
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 12), "Le second blanc de continuation")
        XCTAssertFalse(MarkerMask.isMasked(storage, at: 13), "Le « S » de « Sa » est du contenu")
    }

    func testABlankLineInsideAnItemKeepsItsHeight() throws {
        // Un item en deux paragraphes. La ligne vide ne porte que des blancs :
        // la masquer effondrerait sa hauteur et souderait les deux blocs.
        let source = "- Premier paragraphe.\n\n  Second paragraphe.\n"
        let view = try render(source)
        let heights = try lineHeights(in: view)
        XCTAssertFalse(heights.contains { $0 < 1 },
                       "Aucune ligne ne doit tomber à une hauteur nulle : \(heights)")
    }

    func testANestedItemKeepsItsOwnDeeperIndent() throws {
        // La plage de mise en page du parent couvre l'enfant. Le style de
        // l'enfant est posé après — sinon un item imbriqué remonterait au
        // retrait de son parent.
        let source = """
        - Parent.
          - Enfant.
        """
        let view = try render(source)
        let parent = try caretX(atFirstOccurrenceOf: "Parent", in: source, view: view)
        let child = try caretX(atFirstOccurrenceOf: "Enfant", in: source, view: view)
        XCTAssertGreaterThan(child, parent, "L'enfant reste plus à droite que son parent")
    }

    // MARK: - Outils

    private func render(_ source: String) throws -> EditorTextView {
        let view = EditorTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false

        let storage = try XCTUnwrap(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)

        let parsed = MarkdownParser.parse(source)
        MarkdownRenderer(typography: .default)
            .render(storage, spans: parsed.spans, revealed: [],
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
