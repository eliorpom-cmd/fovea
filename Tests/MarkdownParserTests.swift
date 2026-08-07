// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
@testable import Fovea

/// Le parseur ne produit que des positions. Ces tests vérifient qu'elles
/// désignent **exactement** les caractères de syntaxe, et rien d'autre : un
/// marqueur trop large mangerait une lettre du texte de l'auteur, un marqueur
/// trop court laisserait une étoile orpheline à l'écran.
final class MarkdownParserTests: XCTestCase {

    // MARK: - Inline

    func testStrongMarkersAreTheStarsAndOnlyTheStars() throws {
        let span = try firstSpan(in: "Un mot **important** ici") { if case .strong = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.range, NSRange(location: 7, length: 13))
        XCTAssertEqual(span.markers, [NSRange(location: 7, length: 2), NSRange(location: 18, length: 2)])
        XCTAssertEqual(span.content, NSRange(location: 9, length: 9))
    }

    func testEmphasisKeepsTheAuthorsMarkerCharacter() throws {
        // `_texte_` et `*texte*` veulent dire la même chose. Le rendu est
        // identique, mais le marqueur révélé doit être celui qui est écrit
        // dans le fichier — sinon la révélation mentirait sur le contenu.
        let underscore = try firstSpan(in: "un _mot_ ici") { if case .emphasis = $0.kind { return true } else { return false } }
        XCTAssertEqual(underscore.markers, [NSRange(location: 3, length: 1), NSRange(location: 7, length: 1)])
    }

    func testInlineCodeCountsItsBackticks() throws {
        // Un code inline peut être délimité par plusieurs backticks quand il en
        // contient lui-même : ``a `b` c``.
        let single = try firstSpan(in: "un `code` ici") { if case .inlineCode = $0.kind { return true } else { return false } }
        XCTAssertEqual(single.content, NSRange(location: 4, length: 4))

        let double = try firstSpan(in: "un ``a `b` c`` ici") { if case .inlineCode = $0.kind { return true } else { return false } }
        XCTAssertEqual(double.markers.first, NSRange(location: 3, length: 2))
        XCTAssertEqual(double.content, NSRange(location: 5, length: 7))
    }

    func testLinkSplitsBracketsFromDestination() throws {
        let span = try firstSpan(in: "voir [le site](https://x.fr) ici") { if case .link = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.content, NSRange(location: 6, length: 7), "Seul « le site » est du contenu")
        XCTAssertEqual(span.markers, [NSRange(location: 5, length: 1), NSRange(location: 13, length: 15)])
    }

    // MARK: - Blocs

    func testHeadingMarkerIncludesTheTrailingSpace() throws {
        // `## ` et non `##` : laisser l'espace visible décalerait le titre d'un
        // caractère par rapport au reste du texte.
        let span = try firstSpan(in: "## Titre à accents") { if case .heading = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers, [NSRange(location: 0, length: 3)])
        XCTAssertEqual(span.content, NSRange(location: 3, length: 15))
    }

    func testListItemProducesAMarkerAndABullet() throws {
        let spans = MarkdownParser.parse("- un\n- deux\n").spans
        let items = spans.filter { if case .listItem = $0.kind { return true } else { return false } }
        XCTAssertEqual(items.count, 2, "Chaque item porte son propre marqueur")
        XCTAssertEqual(items[0].markers, [NSRange(location: 0, length: 2)])
        XCTAssertEqual(items[1].markers, [NSRange(location: 5, length: 2)])
    }

    func testOrderedListKeepsTheAuthorsNumbering() throws {
        // Un document où l'auteur a écrit « 1. » sur chaque ligne doit se lire
        // tel qu'il l'a écrit : l'éditeur ne renumérote pas à l'affichage.
        let spans = MarkdownParser.parse("1. un\n1. deux\n").spans
        let items = spans.compactMap { span -> SyntaxSpan.ListMarker? in
            if case .listItem(let marker) = span.kind { return marker } else { return nil }
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0], .ordered(number: 1, delimiter: "."))
        XCTAssertEqual(items[1], .ordered(number: 1, delimiter: "."))
    }

    func testTaskItemMarkerCoversTheWholeCheckbox() throws {
        let span = try firstSpan(in: "- [x] fait") { if case .taskItem = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers, [NSRange(location: 0, length: 6)], "« - [x] » d'un seul tenant")
        if case .taskItem(_, let checked) = span.kind {
            XCTAssertTrue(checked)
        } else {
            XCTFail("Attendu une tâche")
        }
    }

    func testBlockQuoteMarksEveryLine() throws {
        // Le `>` se répète : un seul marqueur en tête de bloc laisserait les
        // chevrons des lignes suivantes visibles.
        let span = try firstSpan(in: "> une\n> deux\n") { if case .blockQuote = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers.count, 2)
        XCTAssertEqual(span.markers[0], NSRange(location: 0, length: 2))
        XCTAssertEqual(span.markers[1], NSRange(location: 6, length: 2))
    }

    func testFencedCodeBlockMarksBothFences() throws {
        let span = try firstSpan(in: "```swift\nlet x = 1\n```\n") { if case .codeBlock = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers.count, 2, "L'ouverture avec son langage, et la fermeture")
        XCTAssertEqual(span.markers[0], NSRange(location: 0, length: 8))
        if case .codeBlock(let language) = span.kind {
            XCTAssertEqual(language, "swift")
        }
    }

    func testThematicBreakIsEntirelyAMarker() throws {
        let span = try firstSpan(in: "avant\n\n---\n\naprès") { if case .thematicBreak = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers, [span.range], "Rien de la ligne n'est du contenu")
        XCTAssertEqual(span.content.length, 0)
    }

    // MARK: - Front matter

    func testFrontMatterIsRecognizedAndSwallowsTheDelimiters() throws {
        let source = "---\ntitle: Démo\n---\n\n# Titre\n"
        let span = try firstSpan(in: source) { if case .frontMatter = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.range.location, 0)
        XCTAssertEqual(span.markers.count, 2)
    }

    /// Le défaut trouvé à l'écran : `cmark` ignore le front matter et lit son
    /// `---` de fermeture comme le soulignement d'un titre `setext`. Sans
    /// filtre, « title: Démo » s'affichait en gros titre au-dessus du document.
    func testFrontMatterIsNotParsedAsASetextHeading() throws {
        let spans = MarkdownParser.parse("---\ntitle: Démo\ndate: 2026-08-07\n---\n\n# Vrai titre\n").spans
        let headings = spans.filter { if case .heading = $0.kind { return true } else { return false } }
        XCTAssertEqual(headings.count, 1, "Un seul titre : celui du corps")
        XCTAssertGreaterThan(headings[0].range.location, 36)
    }

    func testAThematicBreakLowerInTheDocumentIsNotFrontMatter() throws {
        // Le bloc doit commencer à la toute première ligne. Un `---` plus bas
        // est un filet, et le confondre couperait le rendu en deux.
        let spans = MarkdownParser.parse("Du texte\n\n---\n\nDe la suite\n").spans
        XCTAssertFalse(spans.contains { if case .frontMatter = $0.kind { return true } else { return false } })
        XCTAssertTrue(spans.contains { if case .thematicBreak = $0.kind { return true } else { return false } })
    }

    // MARK: - Notes de bas de page

    func testFootnoteReferencesAreFoundByTheHomeMadePass() throws {
        // `swift-markdown` ne les parse pas : `[^1]` en ressort comme du texte
        // brut. C'est le repli annoncé au §4.1 qui les repère.
        let span = try firstSpan(in: "Un renvoi[^1] ici") {
            if case .footnoteReference = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(span.range, NSRange(location: 9, length: 4))
        // Les crochets sont la syntaxe, l'identifiant est le contenu : masquer
        // tout ferait disparaître le renvoi de l'écran.
        XCTAssertEqual(span.markers, [NSRange(location: 9, length: 2), NSRange(location: 12, length: 1)])
        XCTAssertEqual(span.content, NSRange(location: 11, length: 1))
        if case .footnoteReference(let identifier) = span.kind {
            XCTAssertEqual(identifier, "1")
        }
    }

    func testFootnoteDefinitionStaysPlainText() throws {
        // `[^1]: la note` en début de ligne est la **définition**. Lui appliquer
        // le rendu d'un renvoi masquerait les crochets et ne laisserait qu'un
        // « : la note » incompréhensible — c'est ce qui s'affichait au premier
        // essai.
        let spans = MarkdownParser.parse("Un renvoi[^1]\n\n[^1]: la note\n").spans
        let references = spans.filter { if case .footnoteReference = $0.kind { return true } else { return false } }
        XCTAssertEqual(references.count, 1, "Seul le renvoi, pas la définition")
        XCTAssertEqual(references[0].range.location, 9)
    }

    func testFootnotePatternIsIgnoredInsideCode() throws {
        // Sans cette garde, un `[^1]` dans un bloc de code deviendrait un
        // renvoi — et disparaîtrait de l'écran, puisque tout y est marqueur.
        let spans = MarkdownParser.parse("```\nregex = \"[^1]\"\n```\n").spans
        XCTAssertFalse(spans.contains { if case .footnoteReference = $0.kind { return true } else { return false } })
    }

    // MARK: - Ce qui ne doit jamais être avalé

    func testRawHTMLIsNeverTurnedIntoAMarker() throws {
        // §6 : un élément non compris n'est jamais masqué. Masquer du texte
        // qu'on n'a pas su lire, c'est le faire disparaître.
        let spans = MarkdownParser.parse("un <b>gras</b> html\n").spans
        for span in spans {
            for marker in span.markers {
                XCTAssertFalse(NSLocationInRange(3, marker), "Le « < » de <b> ne doit jamais être masqué")
            }
        }
    }

    func testAccentsDoNotShiftMarkerPositions() throws {
        // Le croisement des deux pièges du §3.3 et du §2 : si la conversion de
        // plages était fausse, ce sont des lettres accentuées qui deviendraient
        // invisibles.
        let span = try firstSpan(in: "Été **crucial** ici") { if case .strong = $0.kind { return true } else { return false } }
        XCTAssertEqual(span.markers, [NSRange(location: 4, length: 2), NSRange(location: 13, length: 2)])
        XCTAssertEqual(span.content, NSRange(location: 6, length: 7))
    }

    // MARK: - Outils

    private func firstSpan(in source: String,
                           where predicate: (SyntaxSpan) -> Bool,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> SyntaxSpan {
        let spans = MarkdownParser.parse(source).spans
        return try XCTUnwrap(spans.first(where: predicate),
                             "Aucune construction correspondante dans \(source.debugDescription)",
                             file: file, line: line)
    }
}
