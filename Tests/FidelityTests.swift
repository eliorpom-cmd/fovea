// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// **Le test qui valide la promesse du §5 de bout en bout.**
///
/// Les autres tests de fidélité travaillent sur des chaînes construites pour
/// l'occasion. Celui-ci prend de **vrais documents** — ceux du dépôt, plus un
/// corpus taillé pour les cas tordus — les fait passer par toute la chaîne
/// (lecture, analyse, rendu complet, écriture) et vérifie que les octets
/// ressortent identiques.
///
/// C'est l'équivalent automatisé du `git diff` vide après ouverture et
/// enregistrement sans rien toucher.
@MainActor
final class FidelityTests: XCTestCase {

    func testRealDocumentsSurviveTheWholePipeline() throws {
        for (name, source) in Corpus.documents {
            let original = Data(source.utf8)

            // 1. Lecture, comme `MarkdownDocument.read(from:)`.
            let contents = try TextFile.read(original)

            // 2. Analyse et rendu complet, comme à l'ouverture d'une fenêtre.
            let view = EditorTextView.make()
            let storage = try XCTUnwrap(view.textStorage)
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length),
                                      with: contents.text)
            let parsed = MarkdownParser.parse(contents.text)
            MarkdownRenderer(typography: .default)
                .render(storage, spans: parsed.spans, revealed: [],
                        in: NSRange(location: 0, length: storage.length))

            // 3. Écriture, comme `MarkdownDocument.data(ofType:)`.
            let written = TextFile.write(text: view.string, lineEnding: contents.lineEnding)

            XCTAssertEqual(written, original,
                           "\(name) est ressorti différent de ce qui est entré")
        }
    }


    /// Le rendu ne doit pas dépendre de la position du curseur pour laisser le
    /// texte intact : quel que soit l'endroit où l'on se place, les caractères
    /// sont les mêmes.
    func testRevealingMarkersNeverAltersTheText() throws {
        let source = Corpus.documents["torture"]!
        let view = EditorTextView.make()
        let storage = try XCTUnwrap(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)
        let parsed = MarkdownParser.parse(source)
        let renderer = MarkdownRenderer(typography: .default)

        for caret in stride(from: 0, to: source.utf16.count, by: 7) {
            let revealed = RevealPolicy.revealedIndices(
                spans: parsed.spans,
                selection: NSRange(location: caret, length: 0),
                lineRange: parsed.positions.lineRange(containing: caret))
            renderer.render(storage, spans: parsed.spans, revealed: revealed,
                            in: NSRange(location: 0, length: storage.length))
            XCTAssertEqual(view.string, source, "Curseur en \(caret)")
        }
    }

    /// **L'invariant du §2.3, vérifié sur de vrais documents.**
    ///
    /// Il n'y a pas de « position de curseur invisible » : quand un marqueur est
    /// masqué, le curseur ne peut pas s'y trouver. Ce test est ici et pas dans
    /// `RevealPolicyTests` parce que c'est sur du markdown réel qu'il a de la
    /// valeur — titres, citations imbriquées, listes de tâches, clôtures de
    /// blocs —, et parce que c'est lui qui protège la règle de révélation des
    /// préfixes contre une régression : elle porte sur les marqueurs, bornes
    /// comprises, et c'est exactement ce qui rend l'invariant vrai.
    func testNoCaretPositionFallsInsideAHiddenMarker() throws {
        for (name, source) in Corpus.documents {
            let parsed = MarkdownParser.parse(source)
            for caret in 0...source.utf16.count {
                let line = parsed.positions.lineRange(containing: caret)
                let revealed = RevealPolicy.revealedIndices(spans: parsed.spans,
                                                            selection: NSRange(location: caret, length: 0),
                                                            lineRange: line)
                for (index, span) in parsed.spans.enumerated() {
                    for marker in span.markers where NSLocationInRange(caret, marker) {
                        XCTAssertTrue(revealed.contains(index),
                                      "\(name), position \(caret) : dans un marqueur masqué de \(span.kind)")
                    }
                }
            }
        }
    }

    /// Aucune position du document ne doit faire planter le parcours : c'est le
    /// test qui attrape les erreurs de conversion de plages sur les cas que
    /// personne n'a prévus.
    func testEveryCaretPositionIsSafe() throws {
        for (name, source) in Corpus.documents {
            let parsed = MarkdownParser.parse(source)
            for caret in 0...source.utf16.count {
                let line = parsed.positions.lineRange(containing: caret)
                _ = RevealPolicy.revealedIndices(spans: parsed.spans,
                                                 selection: NSRange(location: caret, length: 0),
                                                 lineRange: line)
            }
            // Toutes les plages doivent tenir dans le document, sinon la pose
            // d'attributs lèverait une exception à l'exécution.
            let length = source.utf16.count
            for span in parsed.spans {
                XCTAssertLessThanOrEqual(span.range.upperBound, length, "\(name) : plage hors bornes")
                for marker in span.markers {
                    XCTAssertLessThanOrEqual(marker.upperBound, length, "\(name) : marqueur hors bornes")
                    XCTAssertGreaterThanOrEqual(marker.location, span.range.location,
                                                "\(name) : marqueur hors de sa construction")
                }
            }
        }
    }
}

/// Le corpus de référence.
///
/// Il est versionné dans le code plutôt que lu depuis des fichiers : les tests
/// doivent tourner sans dépendre de ce qui traîne sur le disque de celui qui
/// les lance.
private enum Corpus {

    static let documents: [String: String] = [
        "prose française": prose,
        "torture": torture,
        "cas limites": edgeCases,
    ]

    /// Du français ordinaire, très accentué : le cas nominal de Fovea.
    static let prose = """
    ---
    title: Un document de démonstration
    auteur: Elior
    ---

    # Le cahier des charges

    Ce document mêle du **gras**, de l'*italique*, du `code inline` et des
    [liens](https://exemple.fr) — le tout avec des accents à foison : é, è, ê,
    ë, à, ù, ç, œ, æ.

    ## Une section

    > Une citation sur deux lignes,
    > qui garde son chevron partout.

    - Un item
    - Un autre, avec du **gras dedans**
      - Un item imbriqué

    1. Premier
    2. Deuxième

    - [ ] Une tâche à faire
    - [x] Une tâche faite

    ```swift
    let x = 1  // du code, avec des accents dans un commentaire : déjà vu
    ```

    ---

    Un renvoi[^note] vers une note.

    [^note]: Le texte de la note.

    """

    /// Tout ce qui peut casser une conversion de plages, réuni sur peu de lignes.
    static let torture = """
    Emoji 🙂 puis **gras**, CJK 日本語 puis *italique*, accent combinant e\u{0301} puis `code`.

    Un ***gras et italique*** imbriqué, du ~~barré~~, et un [lien **gras**](https://x.fr).

    Du <b>HTML brut</b> qui ne doit jamais être interprété.

    ``Un code inline contenant un `backtick` `` et un autre.

    | a | b |
    |---|---|
    | 1 | 2 |
    """

    /// Les cas du §6 : ce qui doit se comporter sans planter ni rien avaler.
    static let edgeCases = """
    ```
    un bloc de code jamais refermé, avec un [^1] dedans et des **étoiles**

    | tableau | malformé
    |---

    ###### Un titre de niveau six

    ####### Sept dièses, qui ne sont pas un titre

    -

    >

    ****

    [lien sans destination]()

    ![](image-sans-alt.png)
    """
}
