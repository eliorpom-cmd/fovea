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
        /// Une image rendue dans le flux (§4.4).
        case image(source: String, alt: String)
        /// Un des filets horizontaux d'un tableau (§2.6).
        case tableRule(TableRule, width: CGFloat)
        /// Les filets verticaux entre les colonnes, sur toute la hauteur du
        /// tableau. Les abscisses viennent de `TableLayout`, celle-là même qui a
        /// posé le crénage : les filets tombent donc exactement entre les
        /// colonnes, et non à côté.
        case tableColumns(x: [CGFloat], width: CGFloat)
    }

    /// Où se pose un filet horizontal dans la plage qui le porte.
    ///
    /// # Ce qui a changé, et pourquoi
    ///
    /// Il n'y en avait que trois — en haut, sous l'en-tête, en bas — au motif
    /// qu'« un cadre complet avec ses traits verticaux donnerait une feuille de
    /// calcul au milieu d'un texte ». L'intention était bonne, le résultat ne
    /// l'était pas : sans séparation, on ne voit **pas les cellules**. Trois
    /// colonnes alignées sans rien entre elles se lisent comme trois listes
    /// posées côte à côte, pas comme un tableau.
    ///
    /// La grille est donc complète — un filet sous chaque rangée, un entre
    /// chaque colonne — mais tracée dans la couleur des séparateurs, à 10 % :
    /// assez pour structurer, trop peu pour faire du bruit. La discrétion se
    /// joue sur la valeur du trait, pas sur son absence.
    enum TableRule: Equatable {
        /// Au sommet de la première ligne.
        case top
        /// Au milieu de la ligne de délimitation, dont la hauteur a été réduite
        /// pour lui faire exactement cette place. Plus appuyé que les autres.
        case header
        /// Sous une rangée de contenu.
        case row
        /// Sous la dernière ligne.
        case bottom
    }

    var kind: Kind
    /// La plage de texte sur laquelle la marque s'appuie pour trouver sa place.
    var range: NSRange
    /// Retrait de gauche du paragraphe porteur, en points.
    var indent: CGFloat
}

extension EditorDecoration {

    /// Construit les décorations à partir des constructions repérées.
    ///
    /// - Parameter revealed: les constructions que le curseur touche.
    ///
    /// # La règle : une marque dessinée **remplace** une source masquée
    ///
    /// Une marque n'existe que parce que sa syntaxe est cachée. Dès que la
    /// source réapparaît, la marque doit donc s'effacer, sans quoi l'écran
    /// affiche deux fois la même chose — et c'était le cas : un item de liste
    /// sous le curseur montrait `• - Un item`, la puce dessinée par l'éditeur
    /// juste à côté du tiret du fichier. Voir aussi la puce et le tiret dans un
    /// filet horizontal, dont le trait barrait les `---` revenus.
    ///
    /// Deux exceptions, et elles se justifient : la barre d'une citation et le
    /// fond d'un bloc de code ne **remplacent** rien — ils cadrent un bloc, et
    /// ce bloc existe autant sous le curseur qu'ailleurs.
    @MainActor
    static func build(from spans: [SyntaxSpan],
                      in storage: NSTextStorage,
                      typography: EditorTypography,
                      revealed: Set<Int> = []) -> [EditorDecoration] {
        let text = storage.mutableString
        var decorations: [EditorDecoration] = []
        for (index, span) in spans.enumerated() {
            let isRevealed = revealed.contains(index)
            switch span.kind {
            // Les filets ne s'effacent plus sous le curseur : la grille non plus.
            // On écrit dedans, elle doit donc rester cadrée pendant qu'on écrit.
            case .table(let table?):
                decorations.append(contentsOf: rules(for: table, in: storage, typography: typography))
            case .blockQuote:
                decorations.append(EditorDecoration(kind: .quoteBar,
                                                    range: span.range,
                                                    indent: typography.quoteIndent))

            case .listItem(let marker) where !isRevealed:
                decorations.append(EditorDecoration(
                    kind: .listMarker(symbol(for: marker)),
                    range: span.content,
                    indent: typography.listIndent(level: SyntaxSpan.listLevel(forDepth: span.depth))))

            case .taskItem(_, let checked) where !isRevealed:
                decorations.append(EditorDecoration(
                    kind: .checkbox(checked: checked),
                    range: span.content,
                    indent: typography.listIndent(level: SyntaxSpan.listLevel(forDepth: span.depth))))

            case .thematicBreak where !isRevealed:
                decorations.append(EditorDecoration(kind: .rule, range: span.range, indent: 0))

            case .codeBlock:
                decorations.append(EditorDecoration(kind: .codeBackground,
                                                    range: span.range,
                                                    indent: typography.codeBlockIndent))

            // Une image au fil du texte ne se dessine pas : il n'y a pas de place
            // réservée où la mettre. Voir `MarkdownRenderer.isBlockImage`.
            case .image(let source, let alt)
                where !isRevealed && MarkdownRenderer.isBlockImage(span, in: text):
                decorations.append(EditorDecoration(kind: .image(source: source, alt: alt),
                                                    range: span.range,
                                                    indent: 0))

            default:
                break
            }
        }
        return decorations
    }

    /// Cette construction a-t-elle une marque dessinée qui dépend de son état de
    /// révélation ?
    ///
    /// Sert au cycle de déplacement du curseur, qui ne doit reconstruire la
    /// couche de décoration que lorsqu'elle a réellement changé — c'est
    /// l'opération la plus fréquente de l'app (§9).
    static func hasRevealDependentMark(_ kind: SyntaxSpan.Kind) -> Bool {
        switch kind {
        case .table, .listItem, .taskItem, .thematicBreak, .image: true
        default: false
        }
    }

    /// La grille d'un tableau, ou rien si elle ne tient pas dans la colonne —
    /// auquel cas le rendu montre la source, qu'il ne faut pas cadrer comme une
    /// grille.
    @MainActor
    private static func rules(for table: MarkdownTable,
                              in storage: NSTextStorage,
                              typography: EditorTypography) -> [EditorDecoration] {
        guard let layout = MarkdownRenderer(typography: typography).gridLayout(for: table, in: storage),
              let first = table.rows.first, let last = table.rows.last else { return [] }

        let width = layout.width
        var decorations = [
            EditorDecoration(kind: .tableRule(.top, width: width), range: first.line, indent: 0),
            EditorDecoration(kind: .tableRule(.header, width: width), range: table.delimiter, indent: 0),
            EditorDecoration(kind: .tableRule(.bottom, width: width), range: last.line, indent: 0),
        ]

        // Un filet sous chaque rangée, sauf la dernière — le filet du bas y est
        // déjà, et deux traits au même endroit se voient.
        for row in table.rows.dropFirst().dropLast() {
            decorations.append(EditorDecoration(kind: .tableRule(.row, width: width),
                                                range: row.line, indent: 0))
        }

        // Les filets entre colonnes, **plus les deux bords**. Sans eux la grille
        // était ouverte à gauche et à droite : les filets horizontaux
        // s'arrêtaient en l'air, et un tableau se lisait comme des lignes
        // soulignées plutôt que comme une boîte.
        var separators = table.alignments.indices.compactMap { layout.separatorX(before: $0) }
        separators.append(0)
        separators.append((width - 1).rounded())
        if !separators.isEmpty {
            decorations.append(EditorDecoration(kind: .tableColumns(x: separators, width: width),
                                                range: NSRange(location: first.line.location,
                                                               length: last.line.upperBound - first.line.location),
                                                indent: 0))
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
    /// L'emplacement du document, pour résoudre les chemins d'image relatifs.
    var documentURL: URL?

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
        let columnWidth = view.textContainer?.size.width ?? view.bounds.width
        let onScreen = characterRange(coveredBy: dirtyRect, in: view, layout: layout, content: content)

        for decoration in decorations {
            guard touches(decoration.range, onScreen) else { continue }
            guard let frame = boundingFrame(of: decoration.range, layout: layout, content: content) else { continue }
            let placed = frame.offsetBy(dx: origin.x, dy: origin.y)
            guard placed.intersects(dirtyRect) else { continue }
            paint(decoration, at: placed, columnLeft: origin.x, columnWidth: columnWidth)
        }
    }

    /// - Parameters:
    ///   - frame: la place du texte porteur, **en coordonnées de la vue**.
    ///   - columnLeft: l'abscisse du bord gauche de la colonne, dans les mêmes
    ///     coordonnées. Sans elle, tout ce qui doit s'étendre sur la largeur de
    ///     la colonne se calculait en mélangeant deux repères : les filets et le
    ///     fond des blocs de code recevaient `columnWidth - frame.minX * 2`, où
    ///     `frame.minX` comptait déjà la marge de centrage. Dans une fenêtre
    ///     large — 1512 points, colonne de 612 —, cette largeur valait **−288** :
    ///     les trois filets d'un tableau, le filet horizontal et le fond des
    ///     blocs de code se dessinaient à l'envers, entièrement dans la marge
    ///     gauche. Le défaut ne se voyait pas dans la fenêtre par défaut, où la
    ///     marge est assez étroite pour que le compte reste positif.
    ///   - columnWidth: la largeur du conteneur de texte.
    private func paint(_ decoration: EditorDecoration, at frame: NSRect,
                       columnLeft: CGFloat, columnWidth: CGFloat) {
        /// La bande occupée par la colonne à la hauteur du texte porteur, une
        /// fois retiré de chaque côté le retrait du paragraphe porteur.
        func columnSpan(inset: CGFloat) -> (x: CGFloat, width: CGFloat) {
            let indent = max(0, frame.minX - inset - columnLeft)
            return (columnLeft + indent, max(0, columnWidth - indent * 2))
        }

        switch decoration.kind {
        case .quoteBar:
            // Le texte est retiré de `indent` ; la barre se pose au tiers de
            // cet espace, ce qui lui laisse de l'air des deux côtés.
            //
            // **La hauteur n'est pas celle du cadre.** Avec un interlignage
            // supérieur à 1, TextKit ajoute tout son surplus **au-dessus** du
            // texte : le rectangle d'une ligne commence donc bien plus haut que
            // la première lettre, et la barre dépassait d'autant — très visible
            // sur une citation d'une seule ligne, où il n'y a rien pour
            // rattraper l'œil. On retire ce surplus en haut ; en bas, le cadre
            // s'arrête déjà sur le jambage.
            let leading = max(0, typography.lineHeight - (typography.body.ascender - typography.body.descender))
            let bar = NSRect(x: frame.minX - decoration.indent + (decoration.indent - 2) / 3,
                             y: frame.minY + leading,
                             width: 2,
                             height: max(1, frame.height - leading))
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
            let box = checkboxBox(at: frame)
            let side = box.width
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
            let span = columnSpan(inset: 0)
            let rule = NSRect(x: span.x, y: frame.midY - 0.5, width: span.width, height: 1)
            Theme.NS.separator.setFill()
            NSBezierPath(rect: rule).fill()

        case .image(let source, let alt):
            paint(image: source, alt: alt, at: frame, columnWidth: columnWidth)

        case .tableRule(let position, let width):
            // Le filet d'en-tête est plus appuyé que les autres : c'est lui qui
            // sépare les titres des données, et c'est la séparation dont un
            // tableau de prose a le plus besoin.
            let drop = MarkdownRenderer.rowRuleOffset(typography)
            let y: CGFloat = switch position {
            case .top: frame.minY + drop
            case .header: (frame.midY - 0.5).rounded() + drop
            case .row, .bottom: frame.maxY - 1 + drop
            }
            // La largeur est celle de la **grille**, pas celle de la colonne de
            // texte : un filet qui court jusqu'au bord droit autour d'un tableau
            // de trois mots ne cadre rien, il souligne du vide.
            let rule = NSRect(x: frame.minX, y: y, width: width, height: 1)
            (position == .header ? Theme.NS.labelTertiary : Theme.NS.separator).setFill()
            NSBezierPath(rect: rule).fill()

        case .tableColumns(let positions, _):
            // Décalés comme les filets horizontaux, sinon la grille se disloque
            // d'un demi-interligne à chaque croisement.
            let drop = MarkdownRenderer.rowRuleOffset(typography)
            Theme.NS.separator.setFill()
            for x in positions {
                NSBezierPath(rect: NSRect(x: (frame.minX + x).rounded(), y: frame.minY + drop,
                                          width: 1, height: frame.height)).fill()
            }

        case .codeBackground:
            let padding = typography.bodySize * 0.5
            let span = columnSpan(inset: decoration.indent)
            let box = NSRect(x: span.x,
                             y: frame.minY - padding,
                             width: span.width,
                             height: frame.height + padding * 2)
            Theme.NS.fillQuaternary.setFill()
            NSBezierPath(roundedRect: box,
                         xRadius: Theme.Radius.codeBlock,
                         yRadius: Theme.Radius.codeBlock).fill()
        }
    }

    /// Dessine l'image, ou son cadre d'absence.
    ///
    /// La place a déjà été réservée par `minimumLineHeight` sur le paragraphe :
    /// ici on ne fait que peindre dedans.
    private func paint(image source: String, alt: String, at frame: NSRect, columnWidth: CGFloat) {
        switch ImageStore.shared.entry(for: source, relativeTo: documentURL) {
        case .loaded(let image, let animated):
            let size = ImageStore.displaySize(of: image, columnWidth: columnWidth)
            let box = NSRect(x: frame.minX, y: frame.minY, width: size.width, height: size.height)
            NSGraphicsContext.current?.imageInterpolation = .high
            // `.sourceOver` et non `.copy` : une image à canal alpha doit se
            // composer sur le fond, pas le remplacer par du transparent.
            image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
            // §6 : seule la première trame est dessinée. Le dire évite de
            // laisser croire que l'animation est cassée.
            if animated { paintTag("Animé", in: box) }

        case .oversized(let thumbnail, let bytes):
            // Le fichier existe : l'annoncer « introuvable » serait faux.
            let size = thumbnail.map { ImageStore.displaySize(of: $0, columnWidth: columnWidth) }
                ?? NSSize(width: min(columnWidth, 420), height: ImageStore.missingPlaceholderHeight - 8)
            let box = NSRect(x: frame.minX, y: frame.minY, width: size.width, height: size.height)
            if let thumbnail {
                NSGraphicsContext.current?.imageInterpolation = .high
                thumbnail.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
            }
            paintTag("\(bytes / (1024 * 1024)) Mo — aperçu", in: box)

        case .missing:
            // §6 : un cadre au trait avec le chemin, et jamais un espace vide
            // qui laisserait croire à un bug de l'éditeur.
            let box = NSRect(x: frame.minX, y: frame.minY,
                             width: min(columnWidth, 420),
                             height: ImageStore.missingPlaceholderHeight - 8)
            let path = NSBezierPath(roundedRect: box, xRadius: Theme.Radius.card, yRadius: Theme.Radius.card)
            path.lineWidth = 1
            Theme.NS.separator.setStroke()
            path.stroke()

            let title = alt.isEmpty ? "Image introuvable" : "Image introuvable — \(alt)"
            draw(title, in: box, at: 8, font: typography.uiFont(size: 12, weight: .medium),
                 color: Theme.NS.labelSecondary)
            draw(source, in: box, at: 26, font: typography.uiFont(size: 11, weight: .regular),
                 color: Theme.NS.labelTertiary)
        }
    }

    /// Une pastille discrète dans le coin bas-gauche d'une image.
    ///
    /// Posée sur l'image et non à côté : elle décrit cette image-là, et une
    /// ligne de texte en dessous décalerait tout ce qui suit.
    private func paintTag(_ text: String, in box: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: typography.uiFont(size: 10, weight: .medium),
            .foregroundColor: Theme.NS.window,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 5
        let pill = NSRect(x: box.minX + 8,
                          y: box.maxY - size.height - padding * 2 - 8,
                          width: size.width + padding * 2,
                          height: size.height + padding)
        Theme.NS.label.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + padding, y: pill.minY + padding / 2),
                                withAttributes: attributes)
    }

    private func draw(_ text: String, in box: NSRect, at offset: CGFloat,
                      font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        (text as NSString).draw(
            in: NSRect(x: box.minX + 12, y: box.minY + offset, width: box.width - 24, height: 18),
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    /// La case à cocher d'un item de tâche, posée à gauche de son texte.
    ///
    /// Alignée par le **bas** de la ligne et non centrée dans sa boîte : avec un
    /// interlignage supérieur à 1, TextKit ajoute son surplus au-dessus du
    /// texte, et une case centrée flotterait au-dessus de la ligne qu'elle
    /// introduit. Le cheveu retiré en plus compense le jambage.
    ///
    /// Une seule définition, parce qu'elle a deux lecteurs : le dessin, et le
    /// clic qui coche (§2.5). Deux copies auraient divergé au premier
    /// changement d'interlignage, et la case aurait cessé de répondre là où
    /// elle se voit.
    func checkboxBox(at frame: NSRect) -> NSRect {
        let side = typography.bodySize * 0.8
        return NSRect(x: frame.minX - side - typography.listMarkerGap,
                      y: frame.maxY - side - typography.bodySize * 0.22,
                      width: side, height: side)
    }

    /// Les cases à cocher affichées, avec la plage de la tâche qu'elles portent.
    ///
    /// La zone sensible est élargie de quelques points autour du dessin : une
    /// case fait treize points de côté à la taille par défaut, et viser
    /// treize points à la souris n'est pas une expérience qu'on inflige. Elle
    /// sert au clic **et** au pointeur, qui doivent répondre exactement à la
    /// même surface — un pointeur qui change sans que le clic ne fasse rien est
    /// pire que pas de pointeur du tout.
    ///
    /// Seules les cases **visibles** sont calculées, et pour la même raison que
    /// le dessin : demander la position d'une case met en page la portion du
    /// document où elle se trouve. Ce que la souris ne peut pas atteindre n'a
    /// de toute façon pas de zone à poser — `resetCursorRects` ne s'intéresse
    /// qu'au champ visible, et un clic ne tombe jamais ailleurs.
    func checkboxTargets(among decorations: [EditorDecoration],
                         in view: NSTextView) -> [(range: NSRange, box: NSRect)] {
        guard let layout = view.textLayoutManager, let content = view.textContentStorage else { return [] }
        let origin = view.textContainerOrigin
        let onScreen = characterRange(coveredBy: view.visibleRect, in: view,
                                      layout: layout, content: content)

        return decorations.compactMap { decoration in
            guard case .checkbox = decoration.kind, touches(decoration.range, onScreen),
                  let frame = boundingFrame(of: decoration.range, layout: layout, content: content)
            else { return nil }
            let box = checkboxBox(at: frame.offsetBy(dx: origin.x, dy: origin.y))
            return (decoration.range, box.insetBy(dx: -5, dy: -5))
        }
    }

    /// La tâche dont la case se trouve sous ce point, en coordonnées de la vue.
    func task(at point: NSPoint, among decorations: [EditorDecoration],
              in view: NSTextView) -> NSRange? {
        checkboxTargets(among: decorations, in: view).first { $0.box.contains(point) }?.range
    }

    /// La plage de caractères couverte par une bande de la vue.
    ///
    /// # Le défaut que ce calcul répare
    ///
    /// La boucle de dessin écartait bien les marques hors champ — mais
    /// **après** avoir demandé leur position. Or demander la position d'une
    /// plage force TextKit 2 à la mettre en page, et il y a une marque par
    /// item de liste, par citation et par bloc de code du document. Peindre le
    /// fond mettait donc en page le document **entier**, à chaque passe de
    /// dessin, depuis l'intérieur de cette passe.
    ///
    /// Mesuré sur 40 000 mots : la hauteur mise en page passait de 634 points
    /// — le seul écran visible — à 35 160 pendant le dessin, en 56 ms. La vue
    /// de texte se redimensionnait donc au milieu de son propre affichage, la
    /// vue de défilement rattrapait, et le texte sautait sous le curseur. Le
    /// même calcul relancé après une frappe coûtait 283 ms : la frappe invalide
    /// la mise en page, et le dessin suivant la refaisait en entier.
    ///
    /// La bande est prise en coordonnées de la vue et convertie en plage de
    /// caractères par les fragments qui la bordent — ce que la mise en page du
    /// viewport a déjà calculé, donc gratuit. Une marque dont la plage ne la
    /// touche pas ne coûte plus rien du tout.
    ///
    /// - Returns: `nil` quand la bande ne peut pas être résolue, auquel cas
    ///   rien n'est écarté : mieux vaut un dessin lent qu'un dessin absent.
    private func characterRange(coveredBy band: NSRect,
                                in view: NSTextView,
                                layout: NSTextLayoutManager,
                                content: NSTextContentStorage) -> NSRange? {
        // De quoi couvrir ce qu'une marque déborde de son texte porteur :
        // l'espace au-dessus d'un titre, la marge d'un fond de bloc de code.
        // Un bloc qui traverse la bande, lui, est retenu par sa plage — elle
        // couvre les caractères visibles — quelle que soit sa hauteur.
        let margin: CGFloat = 120
        let origin = view.textContainerOrigin
        let top = max(0, band.minY - origin.y - margin)
        let bottom = max(0, band.maxY - origin.y + margin)

        guard let first = layout.textLayoutFragment(for: CGPoint(x: 0, y: top)) else { return nil }
        let end = layout.textLayoutFragment(for: CGPoint(x: 0, y: bottom))?.rangeInElement.endLocation
            ?? content.documentRange.endLocation

        let start = content.offset(from: content.documentRange.location,
                                   to: first.rangeInElement.location)
        let finish = content.offset(from: content.documentRange.location, to: end)
        guard start != NSNotFound, finish != NSNotFound, finish >= start else { return nil }
        return NSRange(location: start, length: finish - start)
    }

    /// Les deux plages se touchent-elles, bornes comprises ?
    ///
    /// `NSIntersectionRange` ne convient pas : la plage d'une marque peut être
    /// vide — l'item de liste sans texte — et une intersection vide l'écarterait
    /// alors qu'elle est bel et bien à l'écran.
    private func touches(_ range: NSRange, _ band: NSRange?) -> Bool {
        guard let band else { return true }
        return range.location <= band.upperBound && band.location <= range.upperBound
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
