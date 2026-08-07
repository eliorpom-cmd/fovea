// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
@testable import Fovea

/// L'analyse incrémentale existe pour la vitesse. Elle ne vaut rien si elle ne
/// donne pas **exactement** le même résultat que l'analyse complète : un
/// éditeur qui rend juste au repos mais faux pendant la frappe est pire qu'un
/// éditeur lent.
///
/// Ces tests sont donc écrits comme une propriété : pour une édition donnée,
/// `incrémental == complet`.
final class IncrementalParseTests: XCTestCase {

    // MARK: - La propriété

    func testIncrementalMatchesFullParseOnOrdinaryEdits() {
        let base = """
        # Titre

        Un paragraphe avec du **gras** et de l'*italique*.

        - un item
        - un autre

        > une citation

        Un dernier paragraphe.
        """
        // Une insertion dans chaque bloc, pour couvrir chaque cas de portée.
        for insertionPoint in [10, 30, 60, 78, 95] where insertionPoint < base.utf16.count {
            assertIncrementalMatchesFull(base: base, insert: "texte ", at: insertionPoint)
        }
    }

    func testIncrementalMatchesFullParseWithAccents() {
        // Le croisement des deux risques : découpage par bloc et conversion de
        // plages UTF-8 → UTF-16.
        let base = "Été **crucial**.\n\nDéjà vu : é à ù ç.\n\n- Un élément accentué\n"
        for insertionPoint in stride(from: 0, to: base.utf16.count, by: 5) {
            assertIncrementalMatchesFull(base: base, insert: "é", at: insertionPoint)
        }
    }

    // MARK: - Les cas où le découpage ne suffit pas

    func testTypingAFenceForcesAFullReparse() {
        // Taper ``` change l'interprétation de **tout ce qui suit** : le reste
        // du document devient du code, ou cesse de l'être. C'est le cas du §6,
        // et le seul que le découpage par bloc ne peut pas voir.
        let text = "Un paragraphe.\n\n```\n" as NSString
        let scope = IncrementalParse.scope(in: text,
                                           editedRange: NSRange(location: 16, length: 3),
                                           inserted: "```",
                                           existingCodeBlocks: [])
        XCTAssertNil(scope, "Une clôture de bloc de code doit forcer l'analyse complète")
    }

    func testEditingInsideACodeBlockForcesAFullReparse() {
        // Dans un bloc de code, les lignes vides ne délimitent plus rien : la
        // portée par bloc n'a pas de sens.
        let text = "```\nligne un\n\nligne deux\n```\n" as NSString
        let scope = IncrementalParse.scope(in: text,
                                           editedRange: NSRange(location: 15, length: 1),
                                           inserted: "x",
                                           existingCodeBlocks: [NSRange(location: 0, length: 28)])
        XCTAssertNil(scope)
    }

    func testAnOrdinaryEditStaysLocal() throws {
        // Un document assez long pour que l'incrémental ait un sens. Sur un
        // document de trois lignes, `scope` renvoie délibérément `nil` : tout
        // reprendre y coûte moins cher que découper, et c'est exactement ce que
        // dit la règle de la moitié.
        let blocks = (1...60).map { "Bloc numéro \($0), avec du texte pour lui donner du corps.\n" }
        let text = blocks.joined(separator: "\n") as NSString

        let scope = try XCTUnwrap(IncrementalParse.scope(in: text,
                                                         editedRange: NSRange(location: text.length / 2, length: 1),
                                                         inserted: "x",
                                                         existingCodeBlocks: []))
        XCTAssertLessThan(scope.length, text.length / 4,
                          "Une frappe ordinaire ne doit ré-analyser qu'un voisinage")
    }

    func testAShortDocumentIsReparsedWhole() {
        // La règle de la moitié : découper un document de trois lignes coûte
        // plus que le reprendre en entier.
        let text = "Bloc un.\n\nBloc deux.\n\nBloc trois.\n" as NSString
        XCTAssertNil(IncrementalParse.scope(in: text,
                                            editedRange: NSRange(location: 12, length: 1),
                                            inserted: "x",
                                            existingCodeBlocks: []))
    }

    // MARK: - La marge de voisinage

    func testScopeIncludesTheNeighbouringBlocks() {
        // Un titre `setext` est souligné par la ligne d'après ; une liste dont
        // on retire la ligne vide fusionne avec la suivante. Un bloc de marge
        // de chaque côté couvre ces cas.
        let text = "Un.\n\nDeux.\n\nTrois.\n\nQuatre.\n\nCinq.\n" as NSString
        let scope = IncrementalParse.blockRange(in: text, around: NSRange(location: 13, length: 0))
        XCTAssertLessThan(scope.location, 12, "La portée doit remonter avant le bloc édité")
        XCTAssertGreaterThan(scope.upperBound, 18, "Et descendre après lui")
    }

    // MARK: - Le raccord

    func testSpliceShiftsWhatComesAfterTheScope() {
        let previous = [
            span(at: NSRange(location: 0, length: 5)),
            span(at: NSRange(location: 10, length: 5)),
            span(at: NSRange(location: 30, length: 5)),
        ]
        let fresh = [span(at: NSRange(location: 10, length: 8))]
        let result = MarkdownParser.splice(previous,
                                           replacing: NSRange(location: 8, length: 14),
                                           with: fresh,
                                           delta: 3)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].range, NSRange(location: 0, length: 5), "Avant la portée : inchangé")
        XCTAssertEqual(result[1].range, NSRange(location: 10, length: 8), "Dans la portée : remplacé")
        XCTAssertEqual(result[2].range, NSRange(location: 33, length: 5), "Après la portée : décalé de delta")
    }

    // MARK: - Outils

    private func assertIncrementalMatchesFull(base: String, insert: String, at location: Int,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let edited = (base as NSString).replacingCharacters(in: NSRange(location: location, length: 0),
                                                            with: insert)
        let editedRange = NSRange(location: location, length: insert.utf16.count)
        let delta = insert.utf16.count

        let full = MarkdownParser.parse(edited).spans
        let before = MarkdownParser.parse(base).spans
        let codeBlocks = before.compactMap { span -> NSRange? in
            if case .codeBlock = span.kind { return span.range } else { return nil }
        }

        guard let scope = IncrementalParse.scope(in: edited as NSString,
                                                 editedRange: editedRange,
                                                 inserted: insert,
                                                 existingCodeBlocks: codeBlocks) else {
            return // Analyse complète demandée : rien à comparer.
        }
        let fragment = (edited as NSString).substring(with: scope)
        let fresh = MarkdownParser.parse(fragment, offsetBy: scope.location)
        let incremental = MarkdownParser.splice(before, replacing: scope, with: fresh, delta: delta)

        XCTAssertEqual(normalise(incremental), normalise(full),
                       "Insertion de \(insert.debugDescription) en \(location)",
                       file: file, line: line)
    }

    /// Compare ce qui compte pour le rendu : le type et les plages. L'ordre de
    /// la liste, lui, dépend du parcours de l'AST et n'a pas de sens propre.
    private func normalise(_ spans: [SyntaxSpan]) -> [String] {
        spans
            .map { "\($0.kind) \($0.range) \($0.markers) \($0.content)" }
            .sorted()
    }

    private func span(at range: NSRange) -> SyntaxSpan {
        SyntaxSpan(kind: .strong, range: range, markers: [range], content: range)
    }
}
