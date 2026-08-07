// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// Trouve rapidement les constructions proches d'une position.
///
/// # Pourquoi
///
/// À chaque flèche du clavier, `RevealPolicy` doit savoir quelles constructions
/// touchent le curseur. En les balayant toutes, l'opération la plus fréquente
/// de l'app devenait la plus chère : **3,3 ms sur un document de 100 000 mots**,
/// pour un budget d'une milliseconde (§9). Un document de cette taille compte
/// des dizaines de milliers de constructions, dont le curseur n'en touche
/// jamais plus de trois.
///
/// # Comment
///
/// Les constructions sont séparées en deux familles, parce qu'elles se
/// cherchent différemment :
///
/// - **Les courtes** — inline et portée ligne. Nombreuses mais brèves : un
///   `**gras**` fait quinze caractères, un item de liste une ligne. Triées par
///   position, elles se trouvent par dichotomie, puis par un pas en arrière
///   borné par la plus longue d'entre elles.
/// - **Les longues** — blocs de code, tableaux, front matter. Elles peuvent
///   couvrir la moitié du document, ce qui rendrait la borne inutile ; mais il
///   y en a une poignée, et les balayer ne coûte rien.
struct SpanIndex {

    let spans: [SyntaxSpan]

    /// Indices des constructions courtes, triés par position de début.
    private let shortOrder: [Int]
    /// La plus longue des constructions courtes : la distance maximale à
    /// remonter depuis le curseur.
    private let longestShort: Int
    /// Indices des constructions longues, balayées telles quelles.
    private let longIndices: [Int]

    init(_ spans: [SyntaxSpan]) {
        self.spans = spans

        var short: [Int] = []
        var long: [Int] = []
        var longest = 0
        short.reserveCapacity(spans.count)

        for (index, span) in spans.enumerated() {
            switch span.kind.revealScope {
            case .wholeBlock:
                long.append(index)
            case .innermostInline, .wholeLine:
                short.append(index)
                longest = max(longest, span.range.length)
            }
        }
        // `sorted` sur une liste déjà triée coûte quand même un tri complet —
        // à chaque frappe, sur des dizaines de milliers de constructions. Or
        // `MarkdownParser.splice` maintient l'ordre par position : le cas
        // courant est donc de n'avoir rien à trier, et il faut le reconnaître.
        self.shortOrder = SpanIndex.isSorted(short, in: spans)
            ? short
            : short.sorted { spans[$0].range.location < spans[$1].range.location }
        self.longestShort = longest
        self.longIndices = long
    }

    /// Les constructions susceptibles de concerner cette position.
    ///
    /// Le filtrage final — bornes inclusives, imbrication — reste à
    /// `RevealPolicy` : cet index élague, il ne décide pas.
    func candidates(near location: Int, line: NSRange) -> [Int] {
        var result = longIndices

        // La zone utile va du début de la ligne (pour les constructions à
        // portée ligne) jusqu'au curseur, élargie en arrière de la plus longue
        // construction courte — au-delà, aucune ne peut plus atteindre le
        // curseur.
        let lowerBound = min(line.location, location) - longestShort
        let upperBound = max(line.upperBound, location)

        var position = firstIndex(withLocationAtLeast: lowerBound)
        while position < shortOrder.count {
            let candidate = shortOrder[position]
            guard spans[candidate].range.location <= upperBound else { break }
            result.append(candidate)
            position += 1
        }
        return result
    }

    private static func isSorted(_ order: [Int], in spans: [SyntaxSpan]) -> Bool {
        for position in 1..<max(1, order.count)
        where spans[order[position]].range.location < spans[order[position - 1]].range.location {
            return false
        }
        return true
    }

    /// Dichotomie sur `shortOrder`.
    private func firstIndex(withLocationAtLeast target: Int) -> Int {
        var low = 0
        var high = shortOrder.count
        while low < high {
            let middle = (low + high) / 2
            if spans[shortOrder[middle]].range.location < target {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
