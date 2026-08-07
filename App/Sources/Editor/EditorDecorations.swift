// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Ce qui est **dessiné** plutôt qu'écrit.
///
/// # Pourquoi cette couche existe
///
/// Masquer `- ` fait disparaître le tiret, mais ne fait apparaître aucune
/// puce. Or le §3.1 interdit d'insérer le moindre caractère dans le tampon :
/// un `•` ajouté au texte se retrouverait dans le fichier.
///
/// La sortie est de **dessiner derrière le texte**. La puce, la barre de
/// citation, le filet horizontal et le fond des blocs de code n'existent nulle
/// part dans le document : ce sont des marques posées par l'éditeur, au même
/// titre qu'un curseur.
///
/// Le fond des blocs de code y gagne aussi en qualité. Un `.backgroundColor`
/// posé caractère par caractère produit un liseré dentelé qui s'arrête au
/// dernier signe de chaque ligne ; dessiné, c'est un rectangle arrondi propre
/// qui couvre toute la colonne.
struct EditorDecoration {

    enum Kind: Equatable {
        /// Barre verticale à gauche d'une citation.
        case quoteBar
        /// Puce ou numéro d'un item de liste, dessiné dans le retrait.
        case listMarker(String)
        /// Case à cocher d'une liste de tâches.
        case checkbox(checked: Bool)
        /// Filet horizontal d'un `---`.
        case rule
        /// Fond arrondi d'un bloc de code.
        case codeBackground
    }

    var kind: Kind
    /// La plage de texte sur laquelle la marque s'appuie pour trouver sa place.
    var range: NSRange
    /// Retrait de gauche du paragraphe porteur, en points.
    var indent: CGFloat
}

extension EditorDecoration {

    /// Construit les décorations à partir des constructions repérées.
    @MainActor
    static func build(from spans: [SyntaxSpan], typography: EditorTypography) -> [EditorDecoration] {
        var decorations: [EditorDecoration] = []
        for span in spans {
            switch span.kind {
            case .blockQuote:
                decorations.append(EditorDecoration(kind: .quoteBar,
                                                    range: span.range,
                                                    indent: typography.quoteIndent))

            case .listItem(let marker):
                decorations.append(EditorDecoration(
                    kind: .listMarker(symbol(for: marker)),
                    range: span.content,
                    indent: typography.listIndent(level: SyntaxSpan.listLevel(forDepth: span.depth))))

            case .taskItem(_, let checked):
                decorations.append(EditorDecoration(
                    kind: .checkbox(checked: checked),
                    range: span.content,
                    indent: typography.listIndent(level: SyntaxSpan.listLevel(forDepth: span.depth))))

            case .thematicBreak:
                decorations.append(EditorDecoration(kind: .rule, range: span.range, indent: 0))

            case .codeBlock:
                decorations.append(EditorDecoration(kind: .codeBackground,
                                                    range: span.range,
                                                    indent: typography.codeBlockIndent))

            default:
                break
            }
        }
        return decorations
    }

    /// La puce d'une liste à puces est toujours `•`, quel que soit le signe
    /// écrit : `-`, `*` et `+` veulent dire la même chose, et rendre trois
    /// symboles différents ferait croire à trois listes différentes.
    ///
    /// Le numéro d'une liste ordonnée, lui, est celui du fichier et non celui
    /// que l'éditeur recalculerait : un document où l'auteur a écrit `1.` sur
    /// chaque ligne doit se lire tel qu'il l'a écrit.
    private static func symbol(for marker: SyntaxSpan.ListMarker) -> String {
        switch marker {
        case .bullet: "•"
        case .ordered(let number, let delimiter): "\(number)\(delimiter)"
        }
    }
}

// MARK: - Dessin

@MainActor
struct DecorationPainter {

    var typography: EditorTypography

    /// Dessine les marques dans la vue, derrière le texte.
    ///
    /// - Parameter dirtyRect: en coordonnées de la vue. Les marques hors champ
    ///   sont écartées avant tout calcul de position, qui est la partie chère.
    func draw(_ decorations: [EditorDecoration],
              in view: NSTextView,
              dirtyRect: NSRect) {
        guard let layout = view.textLayoutManager,
              let content = view.textContentStorage else { return }

        let origin = view.textContainerOrigin
        for decoration in decorations {
            guard let frame = boundingFrame(of: decoration.range, layout: layout, content: content) else { continue }
            let placed = frame.offsetBy(dx: origin.x, dy: origin.y)
            guard placed.intersects(dirtyRect) else { continue }
            paint(decoration, at: placed, columnWidth: view.textContainer?.size.width ?? placed.width)
        }
    }

    private func paint(_ decoration: EditorDecoration, at frame: NSRect, columnWidth: CGFloat) {
        switch decoration.kind {
        case .quoteBar:
            // Le texte est retiré de `indent` ; la barre se pose au tiers de
            // cet espace, ce qui lui laisse de l'air des deux côtés.
            let bar = NSRect(x: frame.minX - decoration.indent + (decoration.indent - 2) / 3,
                             y: frame.minY,
                             width: 2,
                             height: frame.height)
            Theme.NS.quoteBar.setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()

        case .listMarker(let symbol):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: typography.body,
                .foregroundColor: Theme.NS.labelTertiary,
            ]
            let size = (symbol as NSString).size(withAttributes: attributes)
            // Aligné à droite sur l'écart : les numéros à deux chiffres restent
            // alors alignés avec ceux à un chiffre, ce qui est le seul moyen de
            // rendre une liste de dix items lisible.
            // Alignée par le **bas** et non centrée dans la boîte de ligne.
            // Avec un interlignage supérieur à 1, TextKit ajoute son surplus
            // au-dessus du texte : centrer la puce dans la boîte la ferait
            // flotter nettement plus haut que la ligne qu'elle introduit.
            let point = NSPoint(x: frame.minX - size.width - typography.listMarkerGap,
                                y: frame.maxY - size.height)
            (symbol as NSString).draw(at: point, withAttributes: attributes)

        case .checkbox(let checked):
            let side = typography.bodySize * 0.8
            // Même raison que pour la puce : on s'aligne sur le bas de la
            // ligne, en remontant d'un cheveu pour compenser le jambage.
            let box = NSRect(x: frame.minX - side - typography.listMarkerGap,
                             y: frame.maxY - side - typography.bodySize * 0.22,
                             width: side, height: side)
            let path = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
            if checked {
                Theme.NS.label.setFill()
                path.fill()
                // La coche est tracée en négatif dans le carré plein : pas de
                // couleur, seulement du contraste (§7).
                //
                // Les ordonnées descendent : `NSTextView` est une vue
                // retournée, et le tracé lu « vers le haut » y dessinait un
                // chevron à l'envers. Le point bas de la coche est donc celui
                // dont l'ordonnée est la plus **grande**.
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + side * 0.24, y: box.minY + side * 0.52))
                check.line(to: NSPoint(x: box.minX + side * 0.43, y: box.minY + side * 0.72))
                check.line(to: NSPoint(x: box.maxX - side * 0.22, y: box.minY + side * 0.30))
                check.lineWidth = max(1.5, side * 0.14)
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                Theme.NS.window.setStroke()
                check.stroke()
            } else {
                Theme.NS.labelTertiary.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }

        case .rule:
            // Le filet occupe toute la colonne, pas la largeur des trois tirets
            // invisibles sur lesquels il s'appuie.
            let rule = NSRect(x: frame.minX,
                              y: frame.midY - 0.5,
                              width: columnWidth - frame.minX * 2,
                              height: 1)
            Theme.NS.separator.setFill()
            NSBezierPath(rect: rule).fill()

        case .codeBackground:
            let padding = typography.bodySize * 0.5
            let left = frame.minX - decoration.indent
            let box = NSRect(x: left,
                             y: frame.minY - padding,
                             width: columnWidth - left * 2,
                             height: frame.height + padding * 2)
            Theme.NS.fillQuaternary.setFill()
            NSBezierPath(roundedRect: box,
                         xRadius: Theme.Radius.codeBlock,
                         yRadius: Theme.Radius.codeBlock).fill()
        }
    }

    /// Rectangle englobant d'une plage, en coordonnées du conteneur de texte.
    private func boundingFrame(of range: NSRange,
                               layout: NSTextLayoutManager,
                               content: NSTextContentStorage) -> NSRect? {
        guard range.length >= 0,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }

        var union: NSRect?
        layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            union = union.map { $0.union(frame) } ?? frame
            return true
        }
        return union
    }
}
