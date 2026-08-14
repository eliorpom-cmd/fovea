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

    // MARK: - Structure de bloc

    /// Une chaîne attribuée depuis du vrai HTML, comme le presse-papier en
    /// livre quand on copie une page web.
    private func fromHTML(_ html: String) throws -> NSAttributedString {
        try XCTUnwrap(NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil))
    }

    /// **Les titres et les listes survivent au collage.**
    ///
    /// L'en-tête de `PasteConversion` promet de ne pas perdre « les titres, les
    /// listes et les liens ». Les liens passaient ; les deux autres non — seul
    /// l'inline était traité, et un article collé arrivait en une suite de
    /// paragraphes plats. C'est justement la perte que la conversion existe
    /// pour éviter.
    func testHeadingsAndListsSurviveAPaste() throws {
        let html = """
        <h1>Le grand titre</h1>
        <p>Un paragraphe avec du <strong>gras</strong> et un <a href="https://x.fr">lien</a>.</p>
        <h2>Un sous-titre</h2>
        <ul><li>Premier item</li><li>Deuxième avec du <em>relief</em></li></ul>
        <ol><li>Un</li><li>Deux</li></ol>
        """
        let converted = PasteConversion.convert(try fromHTML(html))

        XCTAssertTrue(converted.contains("# Le grand titre"), converted)
        XCTAssertTrue(converted.contains("## Un sous-titre"), converted)
        XCTAssertTrue(converted.contains("- Premier item"), converted)
        XCTAssertTrue(converted.contains("- Deuxième avec du *relief*"), converted)
        XCTAssertTrue(converted.contains("1. Un"), converted)
        XCTAssertTrue(converted.contains("**gras**"), converted)

        // Un titre est déjà gras : `# **Le titre**` dirait deux fois la même
        // chose, et laisserait des étoiles dans le fichier.
        XCTAssertFalse(converted.contains("# **"), converted)
        // La puce que l'importateur écrit dans le texte ne doit pas doubler
        // celle de markdown.
        XCTAssertFalse(converted.contains("- •"), converted)
        XCTAssertFalse(converted.contains("1. 1"), converted)
    }

    func testNestedListsKeepTheirDepth() throws {
        let html = "<ul><li>Un<ul><li>Un-un</li></ul></li><li>Deux</li></ul>"
        let converted = PasteConversion.convert(try fromHTML(html))
        XCTAssertTrue(converted.contains("\n  - Un-un"), converted)
    }

    /// Le revers : de la prose reste de la prose. Un paragraphe ordinaire ne
    /// doit gagner ni dièse ni tiret.
    func testPlainProseGainsNoStructure() throws {
        let html = "<p>Une phrase ordinaire, sans structure particulière.</p>"
        XCTAssertEqual(PasteConversion.convert(try fromHTML(html)),
                       "Une phrase ordinaire, sans structure particulière.")
    }

    // MARK: - Les blocs que le collage perdait

    /// Une citation collée devenait un paragraphe ordinaire : rien ne disait
    /// plus que c'en était une. L'importateur HTML n'a pas d'attribut pour
    /// `<blockquote>` — ce qu'il pose est un retrait.
    func testABlockquoteKeepsItsMarker() throws {
        let html = "<p>Avant.</p><blockquote>Une citation.</blockquote><p>Après.</p>"
        let rich = try XCTUnwrap(NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil))
        let markdown = PasteConversion.convert(rich)
        XCTAssertTrue(markdown.contains("> Une citation."), markdown)
    }

    /// Un `<pre>` de plusieurs lignes arrivait sur une seule, entouré de
    /// backticks simples : le bloc perdait ses retours et sa clôture.
    func testAPreBecomesAFencedBlock() throws {
        let html = "<pre><code>let x = 1\nlet y = 2\nprint(x + y)</code></pre>"
        let rich = try XCTUnwrap(NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil))
        let markdown = PasteConversion.convert(rich)
        XCTAssertTrue(markdown.hasPrefix("```"), markdown)
        XCTAssertTrue(markdown.hasSuffix("```"), markdown)
        XCTAssertTrue(markdown.contains("let x = 1"), markdown)
        XCTAssertTrue(markdown.contains("print(x + y)"), markdown)
        // Les lignes du bloc ne doivent pas être entourées une par une.
        XCTAssertFalse(markdown.contains("`let x = 1`"), markdown)
    }

    /// Mais un mot de code au fil d'une phrase arrive lui aussi tout en chasse
    /// fixe : une seule ligne doit rester du code en ligne, pas un bloc.
    func testASingleMonospacedLineStaysInline() {
        let rich = NSMutableAttributedString(string: "arr[0] * 2")
        rich.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                          range: NSRange(location: 0, length: 10))
        XCTAssertEqual(PasteConversion.convert(rich), "`arr[0] * 2`")
    }

}
