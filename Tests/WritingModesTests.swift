// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
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
}
