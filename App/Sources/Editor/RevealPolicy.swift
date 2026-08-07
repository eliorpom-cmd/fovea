// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// Décide quels marqueurs sont visibles, en fonction d'où se trouve le curseur.
///
/// C'est la fonction clé de l'app réduite à sa plus simple expression : une
/// fonction pure, sans AppKit, entièrement testable.
///
/// # La règle et sa conséquence inattendue
///
/// Une construction se révèle quand le curseur touche `[début, fin]`, **bornes
/// comprises**. Le choix des bornes n'est pas cosmétique, il rend la navigation
/// réversible :
///
/// ```
/// Un mot **important** ici
/// 0123456789...
///        ^7        ^18,19   la construction occupe [7, 20]
/// ```
///
/// En avançant, le curseur arrive en 7 : `7 ∈ [7, 20]`, les `**` apparaissent.
/// En 20 ils sont encore là, en 21 ils retombent. En reculant depuis 21, on
/// repasse en 20 et ils réapparaissent au même endroit. **Une flèche droite
/// suivie d'une flèche gauche ramène toujours à l'état de départ** — ce qui
/// serait faux avec un intervalle ouvert, où l'entrée et la sortie ne se
/// feraient pas à la même position.
///
/// La conséquence est plus importante encore, et elle a corrigé le §2.3 du
/// cahier des charges : **toute position située dans un marqueur appartient à
/// l'intervalle de sa propre construction**, donc cette construction est
/// révélée, donc ses marqueurs sont visibles. Autrement dit, le curseur ne
/// peut jamais se trouver dans un marqueur masqué. Les « positions invisibles »
/// que le cahier des charges promettait de contourner en interceptant toutes
/// les commandes de déplacement de `NSTextView` **n'existent pas**.
enum RevealPolicy {

    /// Les indices, dans `spans`, des constructions dont les marqueurs doivent
    /// être visibles.
    ///
    /// - Parameters:
    ///   - spans: toutes les constructions du document, dans n'importe quel ordre.
    ///   - selection: la sélection courante ; une longueur nulle est un curseur.
    ///   - lineRange: la plage de la ligne où se trouve le curseur, terminateur
    ///     exclu. Sert aux constructions à portée ligne (`#`, `>`, `-`).
    static func revealedIndices(spans: [SyntaxSpan],
                                selection: NSRange,
                                lineRange: NSRange) -> Set<Int> {

        // Une sélection non vide ne révèle rien. L'utilisateur sélectionne du
        // texte rendu ; faire apparaître la syntaxe sous la sélection en
        // déplacerait le contenu au moment précis où il vise à la souris.
        guard selection.length == 0 else { return [] }

        let caret = selection.location
        var revealed = Set<Int>()

        // Portée ligne et portée bloc : plusieurs peuvent être révélées en même
        // temps, et c'est voulu — une ligne de liste dans une citation montre
        // à la fois son `>` et son `-`, sinon on ne pourrait pas éditer l'un
        // des deux.
        var innermostInline: (index: Int, length: Int)?

        for (index, span) in spans.enumerated() {
            switch span.kind.revealScope {
            case .innermostInline:
                guard contains(span.range, caret) else { continue }
                // La plus intérieure gagne : c'est la plus courte de celles qui
                // contiennent le curseur. `<` et non `<=` pour que, à longueur
                // égale, la première rencontrée l'emporte de façon stable.
                if innermostInline == nil || span.range.length < innermostInline!.length {
                    innermostInline = (index, span.range.length)
                }

            case .wholeLine:
                if intersects(span.range, lineRange) && contains(lineRange, caret) {
                    revealed.insert(index)
                }

            case .wholeBlock:
                if contains(span.range, caret) {
                    revealed.insert(index)
                }
            }
        }

        if let innermostInline {
            revealed.insert(innermostInline.index)
        }
        return revealed
    }

    /// Appartenance **bornes comprises** — c'est tout l'objet de la règle.
    /// `NSLocationInRange` exclut la borne haute et ne convient donc pas.
    static func contains(_ range: NSRange, _ location: Int) -> Bool {
        location >= range.location && location <= range.location + range.length
    }

    private static func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        let start = max(a.location, b.location)
        let end = min(a.location + a.length, b.location + b.length)
        return start <= end
    }
}
