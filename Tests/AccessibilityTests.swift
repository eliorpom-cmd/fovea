// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// L'accessibilité du §8.
///
/// Ce qui est vérifié ici est ce qui **peut** l'être sans lecteur d'écran : les
/// libellés produits, l'adaptation au contraste, le point d'entrée unique des
/// animations, et la tenue de la mise en page de 11 à 32 points. Le
/// comportement réel de VoiceOver, lui, demande une machine et une oreille.
@MainActor
final class AccessibilityTests: XCTestCase {

    // MARK: - Ce que VoiceOver doit entendre

    func testEveryConstructHasASpokenRole() {
        let kinds: [SyntaxSpan.Kind] = [
            .heading(level: 2), .strong, .emphasis, .strikethrough, .inlineCode,
            .link(destination: "https://x.fr"), .image(source: "a.png", alt: "Un chat"),
            .blockQuote(depth: 1), .listItem(marker: .bullet("-")),
            .taskItem(marker: .bullet("-"), checked: true), .thematicBreak,
            .codeBlock(language: "swift"), .frontMatter, .table(nil),
            .footnoteReference(identifier: "1"),
        ]
        for kind in kinds {
            XCTAssertNotNil(Accessibility.roleDescription(of: kind),
                            "Aucun rôle énoncé pour \(kind)")
        }
    }

    func testARoleNeverSpeaksMarkdownSyntax() {
        // Le problème que le §8 pose : « dièse dièse espace Architecture » n'a
        // aucun sens à l'oral. Un rôle qui contiendrait la syntaxe le
        // reproduirait.
        let syntax: Set<Character> = ["#", "*", "`", "~", "|", ">", "[", "]"]
        let kinds: [SyntaxSpan.Kind] = [
            .heading(level: 1), .strong, .emphasis, .inlineCode, .strikethrough,
            .blockQuote(depth: 1), .table(nil), .thematicBreak,
        ]
        for kind in kinds {
            let role = Accessibility.roleDescription(of: kind) ?? ""
            XCTAssertFalse(role.contains(where: syntax.contains),
                           "« \(role) » contient de la syntaxe markdown")
        }
    }

    func testAHeadingAnnouncesItsLevel() {
        XCTAssertEqual(Accessibility.roleDescription(of: .heading(level: 3)), "Titre, niveau 3")
    }

    func testATaskAnnouncesWhetherItIsDone() {
        // L'état d'une case à cocher est **dessiné** : c'est exactement le genre
        // d'information qu'un lecteur d'écran ne peut pas deviner.
        XCTAssertEqual(Accessibility.roleDescription(of: .taskItem(marker: .bullet("-"), checked: true)),
                       "Tâche faite")
        XCTAssertEqual(Accessibility.roleDescription(of: .taskItem(marker: .bullet("-"), checked: false)),
                       "Tâche à faire")
    }

    func testAnImageIsDescribedByItsAlternativeText() {
        XCTAssertEqual(Accessibility.roleDescription(of: .image(source: "chat.png", alt: "Un chat roux")),
                       "Image, Un chat roux")
        // Sans texte alternatif, on annonce au moins qu'il y a une image plutôt
        // que de laisser un silence.
        XCTAssertEqual(Accessibility.roleDescription(of: .image(source: "x.png", alt: "")), "Image")
    }

    func testALinkAnnouncesItsDestination() {
        XCTAssertEqual(Accessibility.roleDescription(of: .link(destination: "https://exemple.fr")),
                       "Lien vers https://exemple.fr")
    }

    // MARK: - Contraste

    func testTheMarkerColourFollowsTheContrastSetting() {
        // On ne peut pas changer le réglage système depuis un test ; on vérifie
        // que la couleur rendue est bien l'une des deux prévues, et jamais une
        // troisième posée en dur ailleurs.
        let expected = [Theme.NS.labelTertiary, Theme.NS.labelSecondary]
        XCTAssertTrue(expected.contains(Accessibility.markerColor))
        XCTAssertEqual(Accessibility.markerColor,
                       Accessibility.prefersIncreasedContrast
                           ? Theme.NS.labelSecondary : Theme.NS.labelTertiary)
    }

    func testTheFocusVeilLightensAtHigherContrast() {
        // Atténuer aide à se concentrer ; ça ne doit pas rendre le reste du
        // document illisible pour qui a demandé plus de contraste.
        XCTAssertEqual(Accessibility.focusVeilOpacity,
                       Accessibility.prefersIncreasedContrast ? 0.55 : 0.74)
    }

    // MARK: - Mouvement

    func testReducedMotionRemovesTheDurationNotTheChange() {
        // La distinction qui compte : une animation coupée ne doit jamais
        // devenir une fonction coupée.
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        XCTAssertEqual(Accessibility.duration(0.2), reduced ? nil : 0.2)

        var applied = false
        Accessibility.animate(0.2) { applied = true }
        XCTAssertTrue(applied, "Le changement s'applique quel que soit le réglage")
    }

    // MARK: - Taille de texte, de 11 à 32 (§8)

    func testTheLayoutHoldsAcrossTheWholeSizeRange() throws {
        // macOS n'a pas de Dynamic Type : le réglage de taille de l'app en tient
        // lieu, et la mise en page doit tenir sur toute son étendue.
        var previousHeight: CGFloat = 0
        for size in stride(from: 11.0, through: 32.0, by: 3.0) {
            let typography = EditorTypography(bodyFontName: nil, monoFontName: nil,
                                              bodySize: size, lineHeightMultiple: 1.5,
                                              columnWidthInCharacters: 68)
            XCTAssertGreaterThan(typography.columnWidth, 0)
            // Le retrait d'une puce doit rester plus large que la puce elle-même,
            // sinon elle se dessine à une abscisse négative — donc hors de la vue.
            XCTAssertGreaterThan(typography.listIndent(level: 0), typography.listMarkerGap)

            let height = try lineHeight(of: "# Titre\n\nDu texte.\n", typography: typography)
            XCTAssertGreaterThan(height, previousHeight,
                                 "La hauteur de ligne doit croître avec la taille")
            previousHeight = height
        }
    }

    func testATableStaysReadableAtTheLargestSize() throws {
        // À 32 points, une grille de trois colonnes ne tient plus dans 68
        // signes : elle doit repasser en source, pas se replier de travers.
        let typography = EditorTypography(bodyFontName: nil, monoFontName: nil,
                                          bodySize: 32, lineHeightMultiple: 1.5,
                                          columnWidthInCharacters: 68)
        let source = "| une colonne | une deuxième | une troisième |\n|---|---|---|\n| a | b | c |"
        let utf16 = Array(source.utf16)
        let table = try XCTUnwrap(MarkdownTable.scan(utf16: utf16,
                                                     in: NSRange(location: 0, length: utf16.count)))
        // Le garde-fou décide, et il décide la même chose partout : rendu et
        // décorations lisent `fitsAsGrid`.
        let renderer = MarkdownRenderer(typography: typography)
        XCTAssertEqual(renderer.fitsAsGrid(table),
                       EditorDecoration.build(from: [SyntaxSpan(kind: .table(table),
                                                                range: NSRange(location: 0, length: utf16.count),
                                                                markers: table.markerRanges,
                                                                content: NSRange(location: 0, length: utf16.count))],
                                              text: source as NSString,
                                              typography: typography).isEmpty == false)
    }

    // MARK: - Outil

    private func lineHeight(of source: String, typography: EditorTypography) throws -> CGFloat {
        let view = EditorTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false

        let storage = try XCTUnwrap(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)

        let parsed = MarkdownParser.parse(source)
        MarkdownRenderer(typography: typography)
            .render(storage, spans: parsed.spans, revealed: [],
                    in: NSRange(location: 0, length: storage.length))

        let layout = try XCTUnwrap(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)

        var height: CGFloat?
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            height = fragment.layoutFragmentFrame.height
            return false
        }
        return try XCTUnwrap(height)
    }
}
