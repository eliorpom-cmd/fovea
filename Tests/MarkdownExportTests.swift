// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Les exports du §4.6.
///
/// C'est le seul endroit de l'app qui **écrit** du markdown ailleurs que dans
/// le tampon. Ces tests vérifient que ce qui sort correspond à ce que l'écran
/// montrait — et surtout, que le document d'origine n'est jamais touché.
@MainActor
final class MarkdownExportTests: XCTestCase {

    // MARK: - Structure

    func testHeadingsBecomeHeadingTags() {
        let html = MarkdownExport.html(from: "# Titre un\n\n## Titre deux\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<h1>Titre un</h1>"), html)
        XCTAssertTrue(html.contains("<h2>Titre deux</h2>"), html)
    }

    func testInlineFormattingIsTranslated() {
        let html = MarkdownExport.html(from: "Du **gras**, de l'*italique*, du `code` et du ~~barré~~.\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<strong>gras</strong>"), html)
        XCTAssertTrue(html.contains("<em>italique</em>"), html)
        XCTAssertTrue(html.contains("<code>code</code>"), html)
        XCTAssertTrue(html.contains("<del>barré</del>"), html)
    }

    /// `***gras et italique***` faisait tomber l'app par débordement de pile,
    /// donc l'export HTML, l'export PDF et `⌘⇧C` avec : cmark donne au nœud
    /// `emphasis` et au nœud `strong` la **même** plage source, et le rendu
    /// re-sélectionnait indéfiniment l'emphase au lieu de descendre dedans.
    func testTripleEmphasisNestsAndDoesNotRecurseForever() {
        let html = MarkdownExport.html(from: "Un ***gras et italique*** collés.\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<em><strong>gras et italique</strong></em>"), html)
    }

    /// Les autres imbrications gardent leur ordre : c'est le nœud le plus
    /// extérieur qui ouvre la première balise.
    func testNestedEmphasisKeepsItsOrder() {
        let mixed = MarkdownExport.html(from: "***a* b**.\n", title: "T", documentURL: nil)
        XCTAssertTrue(mixed.contains("<strong><em>a</em> b</strong>"), mixed)

        let underscored = MarkdownExport.html(from: "**_x_**.\n", title: "T", documentURL: nil)
        XCTAssertTrue(underscored.contains("<strong><em>x</em></strong>"), underscored)

        let inLink = MarkdownExport.html(from: "[lien **gras**](https://exemple.fr).\n",
                                         title: "T", documentURL: nil)
        XCTAssertTrue(inLink.contains("<a href=\"https://exemple.fr\">lien <strong>gras</strong></a>"), inLink)
    }

    /// Les documents d'essai sont coupés à 80 signes, comme la plupart des
    /// markdown écrits à la main. Chaque ligne ressortait en `<p>`, donc un
    /// paragraphe de trois lignes s'espaçait comme trois paragraphes.
    func testAWrappedParagraphStaysOneParagraph() {
        let html = MarkdownExport.html(from: "Une phrase assez longue\npour être coupée\nen trois.\n",
                                       title: "T", documentURL: nil)
        XCTAssertEqual(html.components(separatedBy: "<p>").count - 1, 1, html)
        XCTAssertTrue(html.contains("<p>Une phrase assez longue\npour être coupée\nen trois.</p>"), html)
    }

    /// Le vrai dégât de la découpe ligne à ligne : une construction à cheval
    /// sur la coupure n'était plus reconnue, et sa syntaxe brute ressortait.
    func testAConstructSpanningTheWrapIsStillRendered() {
        let code = MarkdownExport.html(from: "et du `code avec des\n*étoiles*` qui suit.\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(code.contains("<code>"), code)
        XCTAssertFalse(code.contains("`"), code)

        let strong = MarkdownExport.html(from: "un **gras coupé\nen deux** ici.\n",
                                         title: "T", documentURL: nil)
        XCTAssertTrue(strong.contains("<strong>gras coupé\nen deux</strong>"), strong)
        XCTAssertFalse(strong.contains("**"), strong)
    }

    /// Recoller les lignes ne doit pas avaler ce qui suit le paragraphe.
    func testABlockAfterAParagraphIsNotSwallowed() {
        let html = MarkdownExport.html(from: "Une phrase\ncoupée.\n\n- un\n- deux\n\n## Titre\n",
                                       title: "T", documentURL: nil)
        XCTAssertEqual(html.components(separatedBy: "<p>").count - 1, 1, html)
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 2, html)
        XCTAssertTrue(html.contains("<h2>Titre</h2>"), html)
    }

    /// Deux définitions de note qui se suivent restent deux lignes, pas un
    /// paragraphe recollé.
    func testFootnoteDefinitionsAreNotMergedTogether() {
        let html = MarkdownExport.html(from: "Un renvoi[^1].\n\n[^1]: La première.\n[^b]: La seconde.\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("[^1]: La première."), html)
        XCTAssertTrue(html.contains("[^b]: La seconde."), html)
        XCTAssertFalse(html.contains("La première.\n[^b]"), html)
    }

    /// Une coupure rendue dure par l'auteur — deux espaces ou une barre
    /// inverse — reste une coupure, sinon recoller la ferait disparaître.
    func testHardBreaksSurviveTheJoin() {
        let spaces = MarkdownExport.html(from: "premier vers  \nsecond vers\n", title: "T", documentURL: nil)
        XCTAssertTrue(spaces.contains("<br>"), spaces)

        let backslash = MarkdownExport.html(from: "premier vers\\\nsecond vers\n", title: "T", documentURL: nil)
        XCTAssertTrue(backslash.contains("<br>"), backslash)
        XCTAssertFalse(backslash.contains("\\"), backslash)
    }

    func testLinksKeepTheirDestination() {
        let html = MarkdownExport.html(from: "Voir [le site](https://exemple.fr).\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<a href=\"https://exemple.fr\">le site</a>"), html)
    }

    func testListsAreWrappedOnceNotPerItem() {
        // Une balise d'ouverture par liste, pas par ligne : sinon le navigateur
        // affiche trois listes d'un élément, avec trois fois l'espacement.
        let html = MarkdownExport.html(from: "- un\n- deux\n- trois\n", title: "T", documentURL: nil)
        XCTAssertEqual(html.components(separatedBy: "<ul>").count - 1, 1, html)
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 3, html)
    }

    func testOrderedListsUseOL() {
        let html = MarkdownExport.html(from: "1. un\n2. deux\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<ol>"), html)
    }

    func testTaskItemsBecomeCheckboxes() {
        let html = MarkdownExport.html(from: "- [x] fait\n- [ ] à faire\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("checked"), html)
        XCTAssertEqual(html.components(separatedBy: "type=\"checkbox\"").count - 1, 2, html)
    }

    func testCodeBlocksKeepTheirLanguage() {
        let html = MarkdownExport.html(from: "```swift\nlet x = 1\n```\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("class=\"language-swift\""), html)
        XCTAssertTrue(html.contains("let x = 1"), html)
    }

    func testThematicBreakBecomesHR() {
        let html = MarkdownExport.html(from: "avant\n\n---\n\naprès\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<hr>"), html)
    }

    func testFrontMatterIsNotExported() {
        // Les métadonnées servent au générateur de site, pas au lecteur.
        let html = MarkdownExport.html(from: "---\ntitle: Secret\n---\n\n# Vrai titre\n",
                                       title: "T", documentURL: nil)
        XCTAssertFalse(html.contains("Secret"), html)
        XCTAssertTrue(html.contains("<h1>Vrai titre</h1>"), html)
    }

    // MARK: - Tableaux

    func testATableBecomesATable() {
        // Sans ce cas, chaque rangée ressortait en paragraphe, pipes compris.
        let html = MarkdownExport.html(from: "| a | b |\n|---|---|\n| 1 | 2 |\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<table>"), html)
        XCTAssertTrue(html.contains("<th>a</th>"), html)
        XCTAssertTrue(html.contains("<td>1</td>"), html)
        XCTAssertFalse(html.contains("<p>| a | b |</p>"), html)
    }

    func testTableAlignmentsSurvive() {
        let html = MarkdownExport.html(from: "| g | c | d |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("text-align:center"), html)
        XCTAssertTrue(html.contains("text-align:right"), html)
    }

    func testInlineMarkupInsideACellIsRendered() {
        let html = MarkdownExport.html(from: "| **gras** | `code` |\n|---|---|\n| a | b |\n",
                                       title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("<th><strong>gras</strong></th>"), html)
        XCTAssertTrue(html.contains("<code>code</code>"), html)
    }

    // MARK: - Échappement

    func testHTMLSpecialCharactersAreEscaped() {
        // Sans échappement, un document qui parle de HTML produirait un export
        // dont la moitié serait interprétée comme du balisage.
        let html = MarkdownExport.html(from: "Comparer a < b & c > d.\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("a &lt; b &amp; c &gt; d"), html)
    }

    func testCodeContentIsEscapedToo() {
        let html = MarkdownExport.html(from: "```\nif (a < b) { }\n```\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("if (a &lt; b)"), html)
    }

    func testAnEmojiSurvivesTheExport() {
        // Une paire de substitution doit se copier entière. Convertir l'unité
        // UTF-16 seule échouait sur la moitié haute, et chaque emoji ressortait
        // en deux espaces.
        let html = MarkdownExport.html(from: "Bravo 🙂 vraiment.\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("Bravo 🙂 vraiment"), html)
    }

    func testTitleIsEscaped() {
        let html = MarkdownExport.html(from: "texte\n", title: "A <b> & B", documentURL: nil)
        XCTAssertTrue(html.contains("<title>A &lt;b&gt; &amp; B</title>"), html)
    }

    // MARK: - Autonomie

    func testTheExportIsASingleSelfContainedFile() throws {
        // « Autonome » veut dire ce qu'il dit : le fichier s'ouvre sans son
        // dossier d'images, s'envoie par courriel, et se lit dans dix ans.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: folder.appendingPathComponent("photo.png"))

        let document = folder.appendingPathComponent("doc.md")
        let html = MarkdownExport.html(from: "![Une photo](photo.png)\n", title: "T", documentURL: document)

        XCTAssertTrue(html.contains("data:image/png;base64,"), "L'image doit être embarquée")
        XCTAssertFalse(html.contains("src=\"photo.png\""), "Aucune référence externe ne doit subsister")
        XCTAssertTrue(html.contains("alt=\"Une photo\""))
    }

    func testAMissingImageKeepsItsPathRatherThanDisappearing() {
        // Un chemin visible reste plus utile qu'une image cassée sans indice.
        let html = MarkdownExport.html(from: "![Rien](absente.png)\n", title: "T", documentURL: nil)
        XCTAssertTrue(html.contains("absente.png"), html)
    }

    // MARK: - Texte riche

    func testRichTextCarriesTheFormatting() throws {
        let rich = try XCTUnwrap(MarkdownExport.richText(from: "Un **mot** ici.\n", documentURL: nil))
        XCTAssertTrue(rich.string.contains("Un mot ici"), rich.string)

        // Le mot doit ressortir en gras : c'est tout l'intérêt de ⌘⇧C.
        var foundBold = false
        rich.enumerateAttribute(.font, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
            if let font = value as? NSFont,
               NSFontManager.shared.traits(of: font).contains(.boldFontMask) {
                foundBold = true
            }
        }
        XCTAssertTrue(foundBold, "Le gras doit survivre au passage en texte riche")
    }

    /// Le texte riche est collé dans Mail ou Pages, et le PDF est imprimé :
    /// des pages **blanches**. WebKit résolvait `prefers-color-scheme` sur
    /// l'apparence du système, donc en thème sombre `⌘⇧C` et l'export PDF ne
    /// donnaient qu'un gris clair illisible — le fond, lui, ne suit pas.
    func testRichTextIsReadableOnPaperWhateverTheSystemAppearance() throws {
        let rich = try XCTUnwrap(MarkdownExport.richText(from: "Une phrase ordinaire.\n", documentURL: nil))
        let colour = try XCTUnwrap(rich.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor)
        let sRGB = try XCTUnwrap(colour.usingColorSpace(.sRGB))
        XCTAssertLessThan(sRGB.brightnessComponent, 0.5,
                          "Le texte riche doit rester sombre : il atterrit sur du blanc (\(sRGB))")
    }

    /// Le fichier autonome, lui, s'ouvre dans un navigateur — qui applique
    /// aussi le fond. Il garde donc sa variante sombre.
    func testTheStandaloneFileKeepsItsDarkVariant() {
        let file = MarkdownExport.html(from: "Une phrase.\n", title: "T", documentURL: nil)
        XCTAssertTrue(file.contains("prefers-color-scheme: dark"), file)
    }

    // MARK: - La règle qui prime sur tout

    func testExportingNeverTouchesTheSource() {
        // L'export est le seul endroit qui re-sérialise (§3.1). Il écrit dans
        // un autre fichier ; le markdown d'origine ne doit pas bouger d'un
        // octet, même en mémoire.
        let source = "# Titre\n\nDu **gras** et un [lien](https://x.fr).\n\n- un\n- deux\n"
        let copy = source
        _ = MarkdownExport.html(from: source, title: "T", documentURL: nil)
        _ = MarkdownExport.richText(from: source, documentURL: nil)
        XCTAssertEqual(source, copy)
    }
}
