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
///
/// # Ce que l'usage a corrigé : la portée ligne bougeait trop
///
/// La première version révélait une construction à portée ligne — `#`, `>`,
/// `-` — dès que le curseur était **n'importe où sur sa ligne**. La règle est
/// facile à énoncer, et c'est ce qui rendait l'app pénible à utiliser :
/// descendre dans un document faisait sauter vers la droite, puis revenir,
/// *chaque* ligne de titre, de liste et de citation qu'on traversait. Le `## `
/// d'un titre fait une quarantaine de points à la taille d'un titre 2 : le
/// texte se déplaçait de trois signes à chaque flèche vers le bas.
///
/// La règle est maintenant **la même que pour l'inline, appliquée aux
/// marqueurs** : une construction à portée ligne se révèle quand le curseur
/// touche l'un de ses marqueurs, bornes comprises. Deux propriétés en
/// découlent :
///
/// - L'invariant du §2.3 tient toujours, et pour la même raison qu'avant :
///   toute position *dans* un marqueur touche ce marqueur.
/// - Naviguer verticalement au milieu des lignes ne révèle plus rien, donc ne
///   déplace plus rien. On ne voit le `##` que lorsqu'on va le chercher, au
///   début de la ligne — là où on va de toute façon pour le modifier.
///
/// # Le loquet : ne pas se refermer sous les doigts
///
/// La règle ci-dessus, seule, rouvrait un défaut symétrique : après un `⏎` qui
/// continue une liste, le curseur est juste derrière le `- ` fraîchement
/// inséré, donc le marqueur est révélé — et il se serait masqué **à la première
/// lettre tapée**, décalant la ligne au pire moment.
///
/// D'où `linePrefixesLatched` : une fois les préfixes d'une ligne révélés, ils
/// le restent tant que le curseur ne quitte pas cette ligne. L'état n'est donc
/// plus une pure fonction de la position, il dépend du chemin — mais dans le
/// seul sens qui compte, celui qui **enlève** du mouvement : le loquet ne
/// révèle jamais rien qui ne le serait pas déjà.
enum RevealPolicy {

    /// Les indices, dans `spans`, des constructions dont les marqueurs doivent
    /// être visibles.
    ///
    /// - Parameters:
    ///   - spans: toutes les constructions du document, dans n'importe quel ordre.
    ///   - selection: la sélection courante ; une longueur nulle est un curseur.
    ///   - lineRange: la plage de la ligne où se trouve le curseur, terminateur
    ///     exclu. Sert au loquet des constructions à portée ligne.
    ///   - linePrefixesLatched: vrai quand les préfixes de `lineRange` sont
    ///     déjà révélés et que le curseur n'a pas quitté cette ligne depuis.
    static func revealedIndices(spans: [SyntaxSpan],
                                selection: NSRange,
                                lineRange: NSRange,
                                linePrefixesLatched: Bool = false) -> Set<Int> {
        revealedIndices(index: SpanIndex(spans), selection: selection, lineRange: lineRange,
                        linePrefixesLatched: linePrefixesLatched)
    }

    /// La même décision, mais en consultant un index au lieu de balayer.
    ///
    /// C'est le chemin emprunté à chaque flèche du clavier. Le balayage
    /// linéaire coûtait 3,3 ms sur un document de 100 000 mots — pour un budget
    /// d'une milliseconde, et sur l'opération la plus fréquente de l'app.
    static func revealedIndices(index: SpanIndex,
                                selection: NSRange,
                                lineRange: NSRange,
                                linePrefixesLatched: Bool = false) -> Set<Int> {
        let caret = selection.location
        var revealed = Set<Int>()
        var innermost: (index: Int, length: Int)?

        for candidate in index.candidates(near: caret, line: lineRange) {
            let span = index.spans[candidate]
            switch span.kind.revealScope {
            case .innermostInline:
                if selection.length == 0, holdsCaretInAMarker(span, caret: caret) {
                    revealed.insert(candidate)
                }
                guard !span.markers.isEmpty, encloses(span.range, selection) else { continue }
                if innermost == nil || span.range.length < innermost!.length {
                    innermost = (candidate, span.range.length)
                }
            case .wholeLine:
                if revealsLinePrefix(span, caret: caret, line: lineRange, latched: linePrefixesLatched) {
                    revealed.insert(candidate)
                }
            case .wholeBlock:
                // Un bloc délimité ne se révèle pas sous une sélection : ses
                // deux clôtures sont des lignes entières, et les faire
                // réapparaître au milieu d'un glissement de souris déplacerait
                // verticalement ce que l'utilisateur est en train de viser.
                if selection.length == 0, contains(span.range, caret) {
                    revealed.insert(candidate)
                }
            }
        }
        if let innermost { revealed.insert(innermost.index) }
        return revealed
    }

    /// Le curseur est-il **dans** l'un des marqueurs de cette construction ?
    ///
    /// # Le trou que ce test bouche
    ///
    /// « La plus intérieure gagne » suffisait tant que deux constructions inline
    /// ne se disputaient pas la même plage. Deux cas réels la lui disputent :
    ///
    /// - `***gras et italique***`. cmark rend une emphase dont le contenu est
    ///   *exactement* le gras qu'elle enveloppe. L'emphase n'a donc **aucun
    ///   marqueur** — le complément est vide — mais la même longueur que le
    ///   gras. À longueur égale elle passait la première, gagnait le concours,
    ///   et les trois étoiles du gras restaient masquées **avec le curseur
    ///   dedans**.
    /// - `[lien **gras**](https://x.fr)`. À la position qui suit `**gras**`, le
    ///   curseur touche la fin du gras — bornes comprises — et le début du
    ///   `](…)` du lien. Le gras, plus court, gagnait ; le marqueur du lien
    ///   restait masqué avec le curseur dedans.
    ///
    /// Les deux étaient exactement ce que le §2.3 déclarait impossible. La règle
    /// devient donc : **un marqueur qui contient le curseur est révélé, quoi
    /// qu'il arrive**, et le concours de la plus intérieure ne décide plus que
    /// du reste. C'est le seul ordre de priorité qui rende l'invariant vrai par
    /// construction, et `FidelityTests` le vérifie sur chaque position de
    /// chaque document du corpus.
    ///
    /// `NSLocationInRange` et non `contains` : la borne haute d'un marqueur est
    /// la position qui le suit, elle n'est pas *dedans*.
    private static func holdsCaretInAMarker(_ span: SyntaxSpan, caret: Int) -> Bool {
        span.markers.contains { NSLocationInRange(caret, $0) }
    }

    /// Une construction à portée ligne montre-t-elle ses marqueurs ?
    ///
    /// Le test porte sur les **marqueurs** et non sur la plage : une citation de
    /// dix lignes en pose un par ligne, et c'est celui de la ligne du curseur
    /// qui décide. Sans cette restriction, être sur la première ligne d'un long
    /// bloc suffirait à révéler les neuf autres.
    private static func revealsLinePrefix(_ span: SyntaxSpan,
                                          caret: Int,
                                          line: NSRange,
                                          latched: Bool) -> Bool {
        for marker in span.markers {
            guard contains(line, marker.location) else { continue }
            // Bornes comprises, exactement comme pour l'inline : c'est ce qui
            // garantit qu'aucune position d'un marqueur masqué n'est atteignable.
            if contains(marker, caret) { return true }
        }
        // Le loquet ne s'applique qu'à la ligne où il a été posé, et seulement
        // aux constructions qui y sont — sinon un titre garderait ses dièses
        // pendant qu'on écrit trois lignes plus bas.
        return latched && intersects(span.range, line) && contains(line, caret)
    }

    /// Version de référence, par balayage.
    ///
    /// Conservée parce qu'elle est la définition littérale de la règle, et
    /// parce que `SpanIndexTests` s'en sert pour vérifier que l'index rend
    /// exactement la même réponse.
    static func revealedIndicesByScan(spans: [SyntaxSpan],
                                      selection: NSRange,
                                      lineRange: NSRange,
                                      linePrefixesLatched: Bool = false) -> Set<Int> {

        let caret = selection.location
        var revealed = Set<Int>()

        // Portée ligne et portée bloc : plusieurs peuvent être révélées en même
        // temps, et c'est voulu — une ligne de liste dans une citation montre
        // à la fois son `>` et son `-` dès que le curseur touche les deux
        // préfixes, sinon on ne pourrait pas éditer l'un des deux.
        var innermostInline: (index: Int, length: Int)?

        for (index, span) in spans.enumerated() {
            switch span.kind.revealScope {
            case .innermostInline:
                if selection.length == 0, holdsCaretInAMarker(span, caret: caret) {
                    revealed.insert(index)
                }
                // La plus intérieure gagne : c'est la plus courte de celles qui
                // contiennent le curseur. `<` et non `<=` pour que, à longueur
                // égale, la première rencontrée l'emporte de façon stable. Une
                // construction sans marqueur n'entre pas dans le concours : elle
                // n'a rien à montrer, et gagner l'empêcherait de montrer.
                guard !span.markers.isEmpty, encloses(span.range, selection) else { continue }
                if innermostInline == nil || span.range.length < innermostInline!.length {
                    innermostInline = (index, span.range.length)
                }

            case .wholeLine:
                if revealsLinePrefix(span, caret: caret, line: lineRange, latched: linePrefixesLatched) {
                    revealed.insert(index)
                }

            case .wholeBlock:
                if selection.length == 0, contains(span.range, caret) {
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

    /// La construction couvre-t-elle **toute** la sélection, bornes comprises ?
    ///
    /// Sur un curseur — longueur nulle — c'est exactement `contains`. Sur une
    /// sélection, c'est ce qui remplace l'ancien « une sélection ne révèle
    /// rien » : garder les marqueurs d'une construction qui contient toute la
    /// sélection ne fait *apparaître* aucune syntaxe, puisque le curseur les
    /// montrait déjà avant qu'on étende. Ce qui disparaît, c'est le saut de
    /// ligne à chaque `⇧→` dans un mot en gras. Une sélection qui déborde de la
    /// construction, elle, ne révèle toujours rien : c'est le cas du glissement
    /// à la souris, où le texte ne doit pas bouger sous le pointeur.
    static func encloses(_ range: NSRange, _ selection: NSRange) -> Bool {
        selection.location >= range.location && selection.upperBound <= range.upperBound
    }

    private static func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        let start = max(a.location, b.location)
        let end = min(a.location + a.length, b.location + b.length)
        return start <= end
    }
}
