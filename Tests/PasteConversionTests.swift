// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Le collage de texte riche (§2.5).
///
/// Coller depuis un navigateur est l'un des gestes les plus fréquents dans un
/// éditeur de notes. Perdre les liens et le gras à cette occasion serait aussi
/// visible qu'un rendu faux.
@MainActor
final class PasteConversionTests: XCTestCase {

    // MARK: - Reconnaissance du markdown

    func testStructuredMarkdownIsRecognizedAndLeftAlone() {
        // Le convertir depuis sa version HTML lui ferait faire un aller-retour
        // qui remplacerait `_` par `*` — ce que le §5 interdit.
        XCTAssertTrue(PasteConversion.looksLikeMarkdown("# Un titre\n\nDu texte."))
        XCTAssertTrue(PasteConversion.looksLikeMarkdown("- un item\n- un autre"))
        XCTAssertTrue(PasteConversion.looksLikeMarkdown("Du **gras** dans une phrase."))
        XCTAssertTrue(PasteConversion.looksLikeMarkdown("Voir [le site](https://x.fr)."))
        XCTAssertTrue(PasteConversion.looksLikeMarkdown("```swift\nlet x = 1\n```"))
    }

    func testOrdinaryProseIsNotMistakenForMarkdown() {
        // Le doute profite au texte brut, qui est sans risque.
        XCTAssertFalse(PasteConversion.looksLikeMarkdown("Une phrase ordinaire, sans rien de particulier."))
        XCTAssertFalse(PasteConversion.looksLikeMarkdown("2 * 3 * 4 = 24"))
        XCTAssertFalse(PasteConversion.looksLikeMarkdown("#sansespace n'est pas un titre"))
    }

    // MARK: - Conversion des attributs

    func testBoldBecomesStars() {
        let rich = NSMutableAttributedString(string: "un mot ici")
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 3, length: 3))
        XCTAssertEqual(PasteConversion.convert(rich), "un **mot** ici")
    }

    func testItalicBecomesOneStar() {
        let rich = NSMutableAttributedString(string: "un mot ici")
        let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
        rich.addAttribute(.font, value: italic, range: NSRange(location: 3, length: 3))
        XCTAssertEqual(PasteConversion.convert(rich), "un *mot* ici")
    }

    func testLinksKeepTheirDestination() {
        let rich = NSMutableAttributedString(string: "voir le site ici")
        rich.addAttribute(.link, value: URL(string: "https://x.fr")!, range: NSRange(location: 5, length: 7))
        XCTAssertEqual(PasteConversion.convert(rich), "voir [le site](https://x.fr) ici")
    }

    func testMonospacedTextBecomesInlineCode() {
        let rich = NSMutableAttributedString(string: "appeler foo() ici")
        rich.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                          range: NSRange(location: 8, length: 5))
        XCTAssertEqual(PasteConversion.convert(rich), "appeler `foo()` ici")
    }

    func testWhitespaceStaysOutsideTheMarkers() {
        // `** gras **` n'est pas du gras pour cmark : le blanc doit rester
        // dehors, sinon le collage produit des étoiles littérales.
        let rich = NSMutableAttributedString(string: "un mot ici")
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 2, length: 5))
        // `un **mot** ici` contient bien la suite « ** » suivie d'un espace :
        // ce qui compte est qu'aucun blanc ne soit **à l'intérieur** de la
        // paire, c'est-à-dire juste après l'ouvrante ou juste avant la
        // fermante.
        let result = PasteConversion.convert(rich)
        XCTAssertEqual(result, "un **mot** ici")
        XCTAssertFalse(result.contains("** m"), "Blanc après le marqueur ouvrant : \(result)")
        XCTAssertFalse(result.contains("t **"), "Blanc avant le marqueur fermant : \(result)")
    }

    func testMarkdownCharactersAreEscaped() {
        // Coller « 2 * 3 * 4 » depuis une page web ne doit pas produire de
        // l'italique là où il n'y avait qu'une multiplication.
        let rich = NSAttributedString(string: "2 * 3 * 4")
        XCTAssertEqual(PasteConversion.convert(rich), "2 \\* 3 \\* 4")
    }

    func testCodeIsNotEscaped() {
        // Ce qui est entre backticks est littéral : y ajouter des barres
        // obliques changerait le code collé.
        let rich = NSMutableAttributedString(string: "arr[0] * 2")
        rich.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                          range: NSRange(location: 0, length: 10))
        XCTAssertEqual(PasteConversion.convert(rich), "`arr[0] * 2`")
    }

    // MARK: - Depuis du vrai HTML

    func testRealHTMLFromABrowser() throws {
        let html = """
        <p>Un paragraphe avec du <b>gras</b>, de l'<i>italique</i> \
        et un <a href="https://exemple.fr">lien</a>.</p>
        """
        let rich = try XCTUnwrap(NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil))

        let markdown = PasteConversion.convert(rich)
        XCTAssertTrue(markdown.contains("**gras**"), markdown)
        XCTAssertTrue(markdown.contains("*italique*"), markdown)
        // L'importateur HTML de `NSAttributedString` normalise l'URL et lui
        // ajoute sa barre finale. C'est son droit, et le lien reste juste.
        XCTAssertTrue(markdown.contains("](https://exemple.fr"), markdown)
    }

    func testTheResultIsValidMarkdownThatParsesBack() throws {
        // Le vrai critère : ce qui est collé doit se relire. Un collage qui
        // produit du markdown que le parseur ne reconnaît pas est pire qu'un
        // collage en texte brut.
        let rich = NSMutableAttributedString(string: "un mot et un lien")
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 3, length: 3))
        rich.addAttribute(.link, value: URL(string: "https://x.fr")!, range: NSRange(location: 14, length: 3))

        let markdown = PasteConversion.convert(rich)
        let spans = MarkdownParser.parse(markdown).spans
        XCTAssertTrue(spans.contains { if case .strong = $0.kind { return true } else { return false } },
                      "Le gras collé doit se relire : \(markdown)")
        XCTAssertTrue(spans.contains { if case .link = $0.kind { return true } else { return false } },
                      "Le lien collé doit se relire : \(markdown)")
    }
}
