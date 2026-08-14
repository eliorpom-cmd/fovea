// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Les fonctions d'écriture du §4.5, testées comme des fonctions pures.
final class WritingModesTests: XCTestCase {

    // MARK: - Paragraphe

    func testParagraphIsDelimitedByBlankLinesNotByLineBreaks() {
        // Un document markdown est presque toujours coupé à la main autour de
        // 80 signes. Prendre la ligne pour le paragraphe atténuerait la moitié
        // de la phrase qu'on est en train d'écrire.
        let text = "Première ligne\nqui continue ici.\n\nAutre paragraphe.\n" as NSString
        let range = WritingModes.paragraphRange(in: text, containing: 5)
        XCTAssertEqual(text.substring(with: range), "Première ligne\nqui continue ici.\n")
    }

    func testParagraphAtTheEndOfTheDocument() {
        let text = "Un.\n\nDeux." as NSString
        let range = WritingModes.paragraphRange(in: text, containing: 8)
        XCTAssertEqual(text.substring(with: range), "Deux.")
    }

    // MARK: - Phrase

    func testSentenceStopsAtStrongPunctuation() {
        let text = "Première phrase. Deuxième phrase. Troisième." as NSString
        let range = WritingModes.sentenceRange(in: text, containing: 20)
        XCTAssertEqual(text.substring(with: range).trimmingCharacters(in: .whitespaces),
                       "Deuxième phrase.")
    }

    func testSentenceIgnoresAbbreviations() {
        // « M. Dupont » ne fait pas deux phrases, sinon l'atténuation
        // clignoterait au milieu d'un nom propre.
        let text = "Nous avons vu M. Dupont hier soir. Puis nous sommes partis." as NSString
        let range = WritingModes.sentenceRange(in: text, containing: 20)
        XCTAssertEqual(text.substring(with: range).trimmingCharacters(in: .whitespaces),
                       "Nous avons vu M. Dupont hier soir.")
    }

    func testSentenceNeverEscapesItsParagraph() {
        let text = "Une phrase sans point final\n\nUn autre paragraphe." as NSString
        let range = WritingModes.sentenceRange(in: text, containing: 5)
        XCTAssertLessThanOrEqual(range.upperBound, 28)
    }

    // MARK: - Statistiques

    func testMarkdownSyntaxIsNotCountedAsWords() {
        // Les `#` d'un titre et les `**` d'un mot gras ne sont pas des mots.
        // Compter la source donnerait un total qui gonfle à chaque formatage.
        let source = "# Titre\n\nUn mot **important** ici.\n"
        let stats = WritingModes.statistics(of: source, spans: MarkdownParser.parse(source).spans)
        XCTAssertEqual(stats.words, 5, "« Titre Un mot important ici »")
    }

    func testLinkURLsAreNotCountedButLabelsAre() {
        let source = "Voir [le site officiel](https://exemple.fr/une/page/longue) ici.\n"
        let stats = WritingModes.statistics(of: source, spans: MarkdownParser.parse(source).spans)
        XCTAssertEqual(stats.words, 5, "« Voir le site officiel ici »")
    }

    func testReadingTimeIsNeverZeroForNonEmptyText() {
        let short = WritingModes.statistics(of: "Trois petits mots.", spans: [])
        XCTAssertEqual(short.readingMinutes, 1)

        let empty = WritingModes.statistics(of: "", spans: [])
        XCTAssertEqual(empty.readingMinutes, 0)
        XCTAssertEqual(empty.words, 0)
    }

    func testAccentedWordsAreCountedAsOne() {
        let stats = WritingModes.statistics(of: "Été déjà vu œuvre 日本語", spans: [])
        XCTAssertEqual(stats.words, 5)
    }

    // MARK: - Les statistiques d'une sélection
    //
    // C'est ici que l'app s'arrêtait. La barre d'état compte la sélection, donc
    // l'éditeur ramène les constructions aux coordonnées du fragment en les
    // décalant de `-selection.location` — et une construction qui commence avant
    // la sélection se retrouve à une position négative. Le bornage d'origine,
    // `max(0, début)..<min(units, fin)`, s'inversait alors en `0..<-3`, ce que
    // Swift traite comme une erreur fatale. Sélectionner deux paragraphes
    // suffisait, et le plantage tombait pendant le glissement de la souris.

    /// Reproduit exactement ce que fait `EditorController.statistics`.
    private func statisticsOfSelection(_ selection: NSRange, in source: String) -> WritingModes.Statistics {
        let spans = MarkdownParser.parse(source).spans
        let fragment = (source as NSString).substring(with: selection)
        let local = spans
            .filter { NSIntersectionRange($0.range, selection).length > 0 }
            .map { $0.shifted(by: -selection.location) }
        return WritingModes.statistics(of: fragment, spans: local)
    }

    func testASelectionStartingInsideABoldWordDoesNotCrash() {
        // « Un mot **important** ici » : la sélection prend « portant** ici »,
        // donc le `**` ouvrant tombe à une position négative.
        let source = "Un mot **important** ici, et la suite du paragraphe.\n"
        let stats = statisticsOfSelection(NSRange(location: 13, length: 20), in: source)
        XCTAssertGreaterThan(stats.words, 0)
    }

    func testASelectionEndingInsideAConstructDoesNotCrash() {
        // Le symétrique : le `**` fermant et la fin du lien débordent après le
        // fragment.
        let source = "Un [lien](https://exemple.fr) et un **gras** à cheval.\n"
        let stats = statisticsOfSelection(NSRange(location: 0, length: 40), in: source)
        XCTAssertGreaterThan(stats.words, 0)
    }

    /// Le vrai geste de l'utilisateur : glisser d'un bloc à l'autre. Chaque
    /// position intermédiaire déclenche un calcul, donc chacune doit tenir.
    func testEveryPossibleSelectionOfARealDocumentIsSafe() {
        let source = """
        # Titre

        Un mot **important**, de l'*italique*, du `code` et un
        [lien](https://exemple.fr/page) dans la phrase.

        - Un item de liste
        - [x] Une tâche faite

        > Une citation qui traverse
        > deux lignes entières.
        """
        let length = (source as NSString).length
        for start in stride(from: 0, to: length, by: 3) {
            for end in stride(from: start + 1, through: length, by: 7) {
                let stats = statisticsOfSelection(NSRange(location: start, length: end - start), in: source)
                XCTAssertGreaterThanOrEqual(stats.characters, 0)
            }
        }
    }

    /// **Le voile se dessine dans le même sens que le texte.**
    ///
    /// `NSTextView` est retournée, une `NSView` ordinaire ne l'est pas. Tant
    /// que le voile ne l'était pas, les bornes de l'unité active — calculées
    /// par la mise en page, donc en coordonnées descendantes — se dessinaient
    /// dans un repère montant : la bande claire était le miroir vertical de la
    /// bonne, tombait sur un autre paragraphe, et ses bords coupaient les
    /// lignes en pleine hauteur. Mesuré sur le titre de « 1 — Article » : clair
    /// jusqu'au pixel 345, voilé de 346 à 366, en plein milieu des lettres.
    @MainActor
    func testTheFocusVeilUsesTheSameCoordinatesAsTheText() {
        let controller = EditorController(typography: .default)
        controller.textView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        controller.setText("Une phrase. Une autre.\n")
        controller.textView.focusRange = NSRange(location: 0, length: 11)

        let veil = controller.textView.subviews.first { String(describing: type(of: $0)).contains("FocusOverlay") }
        XCTAssertNotNil(veil, "le voile doit être une sous-vue")
        XCTAssertTrue(veil?.isFlipped ?? false,
                      "le voile doit être retourné comme la vue de texte qu'il recouvre")
        XCTAssertTrue(controller.textView.isFlipped, "la vue de texte est retournée")
    }

}
