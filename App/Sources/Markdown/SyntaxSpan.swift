// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// Une construction markdown repérée dans le texte source, avec ses plages
/// exprimées en unités UTF-16 — celles de `NSTextStorage`.
///
/// C'est le seul objet que la couche de rendu reçoit du parseur. Il ne contient
/// **aucun texte**, seulement des positions : le texte reste dans le tampon,
/// qui est la source de vérité (§3.1).
struct SyntaxSpan: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        // Inline — révélé au niveau de la construction la plus intérieure.
        case strong
        case emphasis
        case inlineCode
        case strikethrough
        case link(destination: String)
        case image(source: String, alt: String)
        case footnoteReference(identifier: String)

        // Portée ligne — révélé dès que le curseur est sur la ligne (§2.2).
        case heading(level: Int)
        case blockQuote(depth: Int)
        case listItem(marker: ListMarker)
        case taskItem(marker: ListMarker, checked: Bool)
        case thematicBreak
        /// La ligne `[^1]: …` qui porte le texte de la note.
        case footnoteDefinition(identifier: String)

        // Bloc délimité — les deux clôtures révélées ensemble.
        case codeBlock(language: String?)
        case frontMatter
        /// La géométrie est portée par la construction elle-même : le rendu en
        /// a besoin à chaque déplacement du curseur, et la relire dans le texte
        /// à ce moment-là coûterait un balayage par frappe. `nil` quand le
        /// bloc n'est pas une grille lisible — voir §6, tableau malformé.
        case table(MarkdownTable?)

        /// La portée de révélation, telle que définie par le tableau du §2.2.
        var revealScope: RevealScope {
            switch self {
            case .strong, .emphasis, .inlineCode, .strikethrough,
                 .link, .image, .footnoteReference:
                return .innermostInline
            case .heading, .blockQuote, .listItem, .taskItem, .thematicBreak,
                 .footnoteDefinition:
                return .wholeLine
            case .codeBlock, .frontMatter, .table:
                return .wholeBlock
            }
        }
    }

    enum ListMarker: Equatable, Sendable {
        case bullet(Character)
        case ordered(number: Int, delimiter: Character)
    }

    enum RevealScope: Equatable, Sendable {
        /// Seule la construction la plus intérieure contenant le curseur.
        case innermostInline
        /// Révélé dès que le curseur est n'importe où sur la ligne.
        case wholeLine
        /// Les deux clôtures révélées ensemble dès que le curseur est dedans.
        case wholeBlock
    }

    var kind: Kind

    /// La plage complète, **marqueurs compris**. C'est elle qui décide de la
    /// révélation (voir `RevealPolicy`).
    var range: NSRange

    /// Les sous-plages qui sont de la syntaxe pure, à masquer quand la
    /// construction n'est pas révélée. Ordonnées, disjointes, incluses dans
    /// `range`.
    var markers: [NSRange]

    /// La plage du contenu porteur — le texte que l'utilisateur a écrit et qui
    /// doit rester visible quoi qu'il arrive.
    var content: NSRange

    /// Profondeur d'imbrication, la plus intérieure étant la plus grande.
    /// Renseignée par le parseur, elle évite de la recalculer à chaque
    /// changement de sélection.
    var depth: Int

    /// Niveau d'imbrication d'un item de liste, à partir de 0.
    ///
    /// L'AST alterne liste et item : `Document > List > Item > List > Item`.
    /// Un item de premier niveau est donc à la profondeur 2, un item imbriqué
    /// à la profondeur 4 — d'où la division par deux.
    static func listLevel(forDepth depth: Int) -> Int {
        max(0, (depth - 2) / 2)
    }

    init(kind: Kind, range: NSRange, markers: [NSRange], content: NSRange, depth: Int = 0) {
        self.kind = kind
        self.range = range
        self.markers = markers
        self.content = content
        self.depth = depth
    }

    /// Décale toutes les positions de la construction.
    ///
    /// Un seul endroit fait ce calcul, et c'est important : l'analyse par
    /// fragment (§3.3) le déclenche à chaque frappe, et une construction qui
    /// porte des positions ailleurs que dans `range`, `content` et `markers` —
    /// un tableau, avec sa grille — serait laissée en arrière par un décalage
    /// écrit à la main sur le lieu d'appel.
    func shifted(by delta: Int) -> SyntaxSpan {
        guard delta != 0 else { return self }
        var moved = self
        moved.range.location += delta
        moved.content.location += delta
        moved.markers = markers.map { NSRange(location: $0.location + delta, length: $0.length) }
        if case .table(let table?) = kind {
            moved.kind = .table(table.shifted(by: delta))
        }
        return moved
    }
}
