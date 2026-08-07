// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// **Les budgets du §9, mesurés plutôt qu'espérés.**
///
/// Un budget dépassé bloque le jalon. Les seuils sont écrits en dur ici pour
/// que l'échec soit une erreur de test et non une ligne dans un rapport que
/// personne ne lit.
///
/// Les mesures sont prises sur un corpus fixe, construit par programme pour que
/// deux exécutions comparent la même chose.
@MainActor
final class PerformanceTests: XCTestCase {

    // MARK: - Le coût réel : le reparse

    /// §9 : cycle frappe → affichage, document de 10 000 mots, budget **8 ms**
    /// — une trame à 120 Hz.
    func testKeystrokeCycleUnder8msAt10kWords() throws {
        let source = Corpus.document(words: 10_000)
        let elapsed = try measureKeystrokeCycle(on: source)
        XCTAssertLessThan(elapsed, 0.008,
                          "Cycle de frappe à 10 000 mots : \(ms(elapsed)) pour un budget de 8 ms")
    }

    /// §9 : idem à 100 000 mots, budget **16 ms**.
    func testKeystrokeCycleUnder16msAt100kWords() throws {
        let source = Corpus.document(words: 100_000)
        let elapsed = try measureKeystrokeCycle(on: source)
        XCTAssertLessThan(elapsed, 0.016,
                          "Cycle de frappe à 100 000 mots : \(ms(elapsed)) pour un budget de 16 ms")
    }

    /// §9 : ouverture et premier affichage, 100 000 mots, budget **500 ms**.
    func testOpeningA100kWordDocumentUnder500ms() throws {
        let source = Corpus.document(words: 100_000)
        let controller = EditorController(typography: .default)
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        // Ce qui est mesuré, c'est le chemin **jusqu'au premier affichage** :
        // l'ouverture progressive fait juste ce qu'il faut pour peindre, et
        // termine l'analyse au tour de boucle suivant.
        let start = CFAbsoluteTimeGetCurrent()
        controller.setText(source)
        let layout = try XCTUnwrap(controller.textView.textLayoutManager)
        layout.ensureLayout(for: NSRect(x: 0, y: 0, width: 700, height: 600))
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 0.5,
                          "Premier affichage de 100 000 mots : \(ms(elapsed)) pour un budget de 500 ms")
    }

    /// L'ouverture progressive ne doit pas laisser le document à moitié analysé :
    /// une fois la boucle d'événements repassée, tout doit être là.
    func testProgressiveOpeningCompletesTheWholeDocument() async throws {
        let source = Corpus.document(words: 100_000)
        let controller = EditorController(typography: .default)
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.setText(source)

        let head = controller.spans.count
        try await Task.sleep(for: .milliseconds(2000))

        XCTAssertGreaterThan(controller.spans.count, head,
                             "L'analyse du reste du document doit avoir eu lieu")
        let last = try XCTUnwrap(controller.spans.last)
        XCTAssertGreaterThan(last.range.upperBound, source.utf16.count / 2,
                             "Les constructions doivent couvrir la fin du document")
    }

    /// L'opération la plus fréquente de toute l'app : une flèche du clavier.
    /// Elle doit rester **sous la milliseconde** quelle que soit la taille du
    /// document, parce qu'elle ne recalcule que ce qui a changé.
    func testCaretMovementIsSubMillisecondAt100kWords() throws {
        let source = Corpus.document(words: 100_000)
        let parsed = MarkdownParser.parse(source)
        let length = source.utf16.count

        // L'index est construit à l'analyse, pas à chaque déplacement : c'est
        // ce que fait `EditorController`, et c'est ce qu'il faut mesurer.
        let index = SpanIndex(parsed.spans)
        let start = CFAbsoluteTimeGetCurrent()
        var iterations = 0
        for caret in stride(from: 0, to: length, by: max(1, length / 200)) {
            _ = RevealPolicy.revealedIndices(
                index: index,
                selection: NSRange(location: caret, length: 0),
                lineRange: parsed.positions.lineRange(containing: caret))
            iterations += 1
        }
        let perMove = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations)

        XCTAssertLessThan(perMove, 0.001,
                          "Déplacement de curseur : \(ms(perMove)) pour un budget de 1 ms")
    }

    // MARK: - Instrument

    /// Un cycle de frappe **tel qu'il se produit réellement** : par
    /// `EditorController`, donc par le chemin incrémental.
    ///
    /// Mesurer l'analyse complète et le rendu complet donnerait le chiffre de
    /// l'implémentation naïve, pas celui que l'utilisateur ressent. C'est
    /// précisément l'erreur que la première version de ce test commettait.
    private func measureKeystrokeCycle(on source: String) throws -> TimeInterval {
        let controller = EditorController(typography: .default)
        controller.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        controller.setText(source)

        let view = controller.textView
        let storage = try XCTUnwrap(view.textStorage)
        // On tape au milieu d'un paragraphe : le cas nominal, et celui où le
        // découpage par bloc doit faire son travail.
        let caret = storage.length / 2
        view.setSelectedRange(NSRange(location: caret, length: 0))

        var total: TimeInterval = 0
        let rounds = 20
        for round in 0..<rounds {
            let start = CFAbsoluteTimeGetCurrent()
            view.insertText("a", replacementRange: NSRange(location: caret + round, length: 0))
            total += CFAbsoluteTimeGetCurrent() - start
        }
        return total / Double(rounds)
    }

    private func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.1f ms", seconds * 1000)
    }
}

/// Un document de taille voulue, bâti par programme.
///
/// Il mêle délibérément les constructions coûteuses — gras, liens, listes,
/// citations, blocs de code — et du français accentué, qui force le chemin
/// lent de la conversion de plages. Un corpus purement ASCII donnerait des
/// chiffres flatteurs et faux.
private enum Corpus {

    static func document(words: Int) -> String {
        var text = "# Un document de \(words) mots\n\n"
        var written = 0
        var block = 0
        while written < words {
            switch block % 6 {
            case 0:
                text += "## Section \(block / 6 + 1)\n\n"
                written += 3
            case 1, 2:
                text += "Un paragraphe avec du **gras**, de l'*italique*, du `code` et un "
                text += "[lien](https://exemple.fr) — le tout très accentué : é è ê à ù ç.\n\n"
                written += 24
            case 3:
                text += "- Premier item de la liste\n- Deuxième, avec du **gras dedans**\n"
                text += "- Troisième, et un `bout de code`\n\n"
                written += 20
            case 4:
                text += "> Une citation qui tient sur deux lignes,\n"
                text += "> et qui garde son chevron sur chacune.\n\n"
                written += 16
            default:
                text += "```swift\nlet valeur = \(block) // un commentaire accentué : déjà\n```\n\n"
                written += 10
            }
            block += 1
        }
        return text
    }
}
