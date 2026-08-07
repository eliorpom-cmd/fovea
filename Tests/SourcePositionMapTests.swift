// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
@testable import Fovea

/// Le piège identifié au §3.3 : `swift-markdown` compte en octets UTF-8,
/// `NSTextStorage` en unités UTF-16.
///
/// Ces tests sont la contrepartie de la promesse. Ils ne vérifient pas que le
/// code « marche » : ils vérifient qu'il place les attributs **au caractère
/// près** sur du texte que Fovea rencontrera dès la première phrase écrite en
/// français.
final class SourcePositionMapTests: XCTestCase {

    // MARK: - Le cas nominal

    func testASCIIColumnsMapDirectly() {
        let map = SourcePositionMap(text: "ab **cd** ef")
        // Colonne 1 → offset 0 : cmark compte à partir de 1, Cocoa à partir de 0.
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 4), 3)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 10), 9)
    }

    // MARK: - Le cas qui casse une implémentation naïve

    func testAccentedCharactersShiftColumnsButNotOffsets() {
        // « é » vaut 2 octets UTF-8 et 1 unité UTF-16. Le `**` est donc à la
        // colonne 6 pour cmark, mais à l'offset 3 pour NSTextStorage.
        let text = "éé **cd** ef"
        let map = SourcePositionMap(text: text)
        XCTAssertEqual(text.utf8.count, 14)
        XCTAssertEqual(text.utf16.count, 12)

        XCTAssertEqual(map.utf16Offset(line: 1, column: 6), 3,
                       "Une lecture naïve de la colonne donnerait 5 et décalerait tout le rendu")
        XCTAssertEqual(map.utf16Offset(line: 1, column: 12), 9)
    }

    func testEmojiCountsFourBytesAndTwoUnits() {
        // « 🙂 » vaut 4 octets UTF-8 et 2 unités UTF-16 : les deux écarts jouent
        // en sens contraire, ce qu'un simple facteur constant ne rattraperait pas.
        let text = "🙂 **cd** ef"
        let map = SourcePositionMap(text: text)
        XCTAssertEqual(text.utf8.count, 14)
        XCTAssertEqual(text.utf16.count, 12)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 6), 3)
    }

    func testCJKCountsThreeBytesAndOneUnit() {
        let text = "日本語 **cd**"
        let map = SourcePositionMap(text: text)
        // 3 idéogrammes × 3 octets + espace + ** + cd + ** = 9 + 1 + 6 = 16.
        XCTAssertEqual(text.utf8.count, 16)
        // Les mêmes en UTF-16 : 3 + 1 + 6 = 10. L'écart avec les octets est de
        // 6 unités, uniquement dû aux idéogrammes.
        XCTAssertEqual(text.utf16.count, 10)
        // Le `**` ouvrant commence à l'octet 10, donc à la colonne 11 — mais à
        // l'offset UTF-16 4, juste après « 日本語 ».
        XCTAssertEqual(map.utf16Offset(line: 1, column: 11), 4)
    }

    func testCombiningMarksAreCountedAsWritten() {
        // « e » + U+0301 est un caractère à l'écran, deux scalaires, trois
        // octets. C'est ce que produit un copier-coller depuis certains PDF.
        let text = "e\u{0301}x"
        let map = SourcePositionMap(text: text)
        XCTAssertEqual(text.utf8.count, 4)
        XCTAssertEqual(text.utf16.count, 3)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 4), 2)
    }

    // MARK: - Lignes

    func testMultilineOffsetsAccumulateAcrossLines() {
        let map = SourcePositionMap(text: "été\nhiver\nprintemps")
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
        XCTAssertEqual(map.utf16Offset(line: 2, column: 1), 4)   // « été » = 3 unités + saut
        XCTAssertEqual(map.utf16Offset(line: 3, column: 1), 10)
    }

    func testLineRangeExcludesTheTerminator() {
        let map = SourcePositionMap(text: "un\ndeux\ntrois")
        XCTAssertEqual(map.lineRange(containing: 0), NSRange(location: 0, length: 2))
        XCTAssertEqual(map.lineRange(containing: 4), NSRange(location: 3, length: 4))
        XCTAssertEqual(map.lineRange(containing: 12), NSRange(location: 8, length: 5))
    }

    func testTrailingNewlineProducesAnEmptyLastLine() {
        // Sans cette ligne fantôme, un curseur posé après le dernier saut de
        // ligne n'aurait aucune ligne à laquelle appartenir.
        let map = SourcePositionMap(text: "un\n")
        XCTAssertEqual(map.lineCount, 2)
        XCTAssertEqual(map.lineRange(containing: 3), NSRange(location: 3, length: 0))
    }

    func testEmptyTextStillHasOneLine() {
        let map = SourcePositionMap(text: "")
        XCTAssertEqual(map.lineCount, 1)
        XCTAssertEqual(map.utf16Length, 0)
        XCTAssertEqual(map.utf16Offset(line: 1, column: 1), 0)
    }

    // MARK: - Bornes

    func testOutOfBoundsPositionsAreClampedRatherThanFatal() {
        // cmark place parfois la fin d'un nœud une colonne après le dernier
        // caractère. Ce n'est pas un défaut à signaler, c'est une convention à
        // absorber — sinon l'app plante sur un document valide.
        let map = SourcePositionMap(text: "abc")
        XCTAssertEqual(map.utf16Offset(line: 1, column: 99), 3)
        XCTAssertEqual(map.utf16Offset(line: 99, column: 1), 3)
        XCTAssertEqual(map.utf16Offset(line: 0, column: 1), 0)
    }

    func testRangeUsesExclusiveUpperBound() {
        // Vérifié sur `swift-markdown` : pour « ab **cd** ef », le `Strong`
        // couvre les colonnes 4 → 10, soit exactement les six octets de
        // « **cd** ». La borne haute est exclusive.
        let map = SourcePositionMap(text: "ab **cd** ef")
        let range = map.range(fromLine: 1, fromColumn: 4, toLine: 1, toColumn: 10)
        XCTAssertEqual(range, NSRange(location: 3, length: 6))
    }

    func testRangeAcrossLines() {
        let map = SourcePositionMap(text: "> une\n> deux")
        let range = map.range(fromLine: 1, fromColumn: 1, toLine: 2, toColumn: 7)
        XCTAssertEqual(range, NSRange(location: 0, length: 12))
    }
}
