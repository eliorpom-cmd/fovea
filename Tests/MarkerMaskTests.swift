// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// **Le jalon 0 : le pari technique du §3.4.**
///
/// Ces tests ne vérifient pas une intention, ils **mesurent la mise en page
/// réelle de TextKit 2**. Un marqueur masqué doit occuper une largeur nulle à
/// l'écran, sinon toute l'app est fausse — un `**` large d'un demi-point
/// suffirait à faire vibrer chaque mot gras d'un texte.
///
/// La mesure est prise là où elle compte : la position du curseur. Si le
/// curseur placé avant `**important**` et celui placé avant `important` sont
/// au même endroit, c'est que les deux étoiles ne prennent pas de place.
@MainActor
final class MarkerMaskTests: XCTestCase {

    /// Tolérance en points. Elle n'est pas nulle parce que TextKit arrondit ses
    /// positions au sous-pixel ; elle est très en dessous de ce qu'un œil peut
    /// distinguer, et très en dessous de la largeur du plus fin des caractères.
    private let tolerance: CGFloat = 0.1

    // MARK: - La mesure décisive

    func testHiddenMarkersOccupyNoHorizontalSpace() throws {
        let withMarkers = try measureCaretX(in: "Un mot **important** ici", atUTF16: 9)
        let withoutMarkers = try measureCaretX(in: "Un mot important ici", atUTF16: 7)

        XCTAssertEqual(withMarkers, withoutMarkers, accuracy: tolerance,
                       """
                       Le curseur devant « important » n'est pas au même endroit selon que \
                       les ** sont là ou non : le masquage ne rend pas la plage de largeur nulle.
                       """)
    }

    func testCaretPositionsCollapseAcrossAHiddenMarker() throws {
        // Les positions 7, 8 et 9 encadrent les deux étoiles. Masquées, elles
        // doivent toutes trois se rendre au même x.
        let text = "Un mot **important** ici"
        let seven = try measureCaretX(in: text, atUTF16: 7, revealing: false)
        let eight = try measureCaretX(in: text, atUTF16: 8, revealing: false)
        let nine = try measureCaretX(in: text, atUTF16: 9, revealing: false)

        XCTAssertEqual(seven, eight, accuracy: tolerance)
        XCTAssertEqual(eight, nine, accuracy: tolerance)
    }

    func testRevealedMarkersDoTakeSpaceAgain() throws {
        // Le pendant du test précédent : une fois révélés, les marqueurs
        // doivent redevenir de vrais caractères. Sans ça, on ne pourrait pas
        // les sélectionner ni les modifier.
        let text = "Un mot **important** ici"
        let hidden = try measureCaretX(in: text, atUTF16: 9, revealing: false)
        let shown = try measureCaretX(in: text, atUTF16: 9, revealing: true)

        XCTAssertGreaterThan(shown - hidden, 1.0,
                             "Un marqueur révélé doit occuper une largeur visible")
    }

    // MARK: - Ce que le masquage ne doit pas casser

    func testMaskingDoesNotChangeLineHeight() throws {
        // Une fonte à 0,01 pt pourrait faire s'effondrer la hauteur de ligne.
        // Elle ne le fait pas tant qu'un autre caractère de la ligne porte la
        // fonte normale — mais il fallait le vérifier, pas le supposer.
        let plain = try measureLineHeight(in: "Un mot important ici")
        let masked = try measureLineHeight(in: "Un mot **important** ici")
        XCTAssertEqual(plain, masked, accuracy: 0.5)
    }

    func testMaskingLeavesTheBufferUntouched() throws {
        // La promesse du §3.1 : le rendu n'est qu'une couche d'attributs. Le
        // texte doit ressortir identique au caractère près.
        let source = "# Titre\n\nUn mot **important** et `du code`.\n"
        let view = try renderedView(source)
        XCTAssertEqual(view.string, source)
    }

    func testFindStillMatchesAcrossHiddenMarkers() throws {
        // `NSTextFinder` cherche dans le tampon, pas dans ce qui est affiché.
        // Chercher « important » doit donc trouver, et c'est justement le
        // bénéfice du mécanisme A sur le mécanisme B du §3.4 : aucune
        // correspondance de plages à maintenir.
        let view = try renderedView("Un mot **important** ici")
        let found = (view.string as NSString).range(of: "important")
        XCTAssertEqual(found, NSRange(location: 9, length: 9))
    }

    func testMaskedRangesAreQueryable() throws {
        let view = try renderedView("Un mot **important** ici")
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertTrue(MarkerMask.isMasked(storage, at: 7), "L'étoile ouvrante doit être marquée masquée")
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 18))
        XCTAssertFalse(MarkerMask.isMasked(storage, at: 9), "Le contenu n'est jamais masqué")
        XCTAssertEqual(MarkerMask.maskedRange(in: storage, at: 7), NSRange(location: 7, length: 2))
    }

    func testAccentedTextKeepsMarkersAligned() throws {
        // Le croisement des deux pièges : un accent avant le gras décale les
        // colonnes cmark, et une erreur de conversion masquerait le mauvais
        // caractère — ici, un « é » deviendrait invisible.
        let view = try renderedView("Été **crucial** ici")
        let storage = try XCTUnwrap(view.textStorage)

        XCTAssertFalse(MarkerMask.isMasked(storage, at: 0), "Le « É » ne doit pas être masqué")
        XCTAssertFalse(MarkerMask.isMasked(storage, at: 1))
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 4), "Les ** sont aux offsets 4 et 5")
        XCTAssertTrue(MarkerMask.isMasked(storage, at: 5))
        XCTAssertFalse(MarkerMask.isMasked(storage, at: 6), "« crucial » commence à l'offset 6")
    }

    // MARK: - Une marque dessinée remplace une source masquée

    /// Le défaut le plus visible de l'éditeur : sous le curseur, un item de
    /// liste affichait `• - Un item` — la puce dessinée par l'éditeur **et** le
    /// tiret du fichier, l'un à côté de l'autre.
    ///
    /// La puce n'existe que parce que le tiret est caché. Dès que le tiret
    /// revient, elle doit partir.
    func testTheDrawnBulletDisappearsWhenItsDashComesBack() throws {
        let source = "- Un item de liste"
        let parsed = MarkdownParser.parse(source)
        let line = NSRange(location: 0, length: (source as NSString).length)

        let atPrefix = RevealPolicy.revealedIndices(spans: parsed.spans,
                                                    selection: NSRange(location: 1, length: 0),
                                                    lineRange: line)
        XCTAssertFalse(atPrefix.isEmpty, "Le curseur est dans le `- ` : il doit se montrer")
        XCTAssertTrue(marks(parsed.spans, source, revealed: atPrefix).isEmpty,
                      "La puce dessinée doit s'effacer pendant que le tiret est visible")

        let inTheText = RevealPolicy.revealedIndices(spans: parsed.spans,
                                                     selection: NSRange(location: 8, length: 0),
                                                     lineRange: line)
        XCTAssertTrue(inTheText.isEmpty, "Au milieu du texte, le tiret reste caché")
        XCTAssertEqual(marks(parsed.spans, source, revealed: inTheText).count, 1,
                       "…et c'est la puce qui le remplace")
    }

    /// Le pendant pour un filet horizontal, dont le trait barrait ses `---`
    /// revenus, et pour une case à cocher.
    func testDrawnMarksYieldToTheirSourceEverywhere() throws {
        for source in ["---", "- [x] Une tâche faite"] {
            let parsed = MarkdownParser.parse(source)
            let line = NSRange(location: 0, length: (source as NSString).length)
            let revealed = RevealPolicy.revealedIndices(spans: parsed.spans,
                                                        selection: NSRange(location: 1, length: 0),
                                                        lineRange: line)
            XCTAssertTrue(marks(parsed.spans, source, revealed: revealed).isEmpty,
                          "« \(source) » : la marque dessinée doublonne avec sa source")
            XCTAssertFalse(marks(parsed.spans, source, revealed: []).isEmpty,
                           "« \(source) » : sans curseur, la marque doit être là")
        }
    }

    /// Une image au fil d'une phrase n'est pas un bloc : lui réserver une
    /// hauteur écartait la ligne, et le dessin passait **par-dessus les mots**
    /// qui l'entouraient.
    func testAnImageInsideASentenceIsNotDrawnAsABlock() throws {
        let inline = "Du texte ![une image](a.png) et la suite."
        let alone = "![une image](a.png)"

        for (source, expected) in [(inline, 0), (alone, 1)] {
            let parsed = MarkdownParser.parse(source)
            let images = marks(parsed.spans, source, revealed: []).filter {
                if case .image = $0.kind { return true } else { return false }
            }
            XCTAssertEqual(images.count, expected, "« \(source) »")
        }
    }

    private func marks(_ spans: [SyntaxSpan], _ text: String, revealed: Set<Int>) -> [EditorDecoration] {
        // La barre de citation et le fond des blocs de code ne remplacent rien :
        // ils cadrent un bloc, et ce bloc existe aussi sous le curseur.
        EditorDecoration.build(from: spans, text: text as NSString,
                               typography: .default, revealed: revealed)
            .filter { $0.kind != .quoteBar && $0.kind != .codeBackground }
    }

    // MARK: - Instruments de mesure

    /// Construit une vue rendue, hors écran mais avec une vraie mise en page.
    private func renderedView(_ source: String,
                              caret: Int? = nil,
                              revealing: Bool = false) throws -> EditorTextView {
        let view = EditorTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false

        let storage = try XCTUnwrap(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)

        let parsed = MarkdownParser.parse(source)
        let renderer = MarkdownRenderer(typography: .default)
        let revealed: Set<Int>
        if revealing, let caret {
            revealed = RevealPolicy.revealedIndices(
                spans: parsed.spans,
                selection: NSRange(location: caret, length: 0),
                lineRange: parsed.positions.lineRange(containing: caret))
        } else {
            revealed = []
        }
        renderer.render(storage, spans: parsed.spans, revealed: revealed,
                        in: NSRange(location: 0, length: storage.length))

        let layout = try XCTUnwrap(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        return view
    }

    /// Abscisse du curseur à un offset UTF-16 donné, en coordonnées du conteneur.
    private func measureCaretX(in source: String, atUTF16 offset: Int, revealing: Bool = false) throws -> CGFloat {
        let view = try renderedView(source, caret: offset, revealing: revealing)
        let layout = try XCTUnwrap(view.textLayoutManager)
        let content = try XCTUnwrap(view.textContentStorage)
        let location = try XCTUnwrap(content.location(content.documentRange.location, offsetBy: offset))
        let range = NSTextRange(location: location)

        var x: CGFloat?
        layout.enumerateTextSegments(in: range, type: .selection, options: []) { _, frame, _, _ in
            x = frame.origin.x
            return false
        }
        return try XCTUnwrap(x, "Aucun segment de texte à l'offset \(offset)")
    }

    private func measureLineHeight(in source: String) throws -> CGFloat {
        let view = try renderedView(source)
        let layout = try XCTUnwrap(view.textLayoutManager)
        var height: CGFloat?
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            height = fragment.layoutFragmentFrame.height
            return false
        }
        return try XCTUnwrap(height)
    }
}
