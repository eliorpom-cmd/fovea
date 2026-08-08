// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Pose les attributs de rendu sur le tampon.
///
/// Ce fichier ne modifie **jamais les caractères** : il ne fait qu'habiller
/// ceux qui sont déjà là. C'est la mise en œuvre concrète du §3.1 — le rendu
/// n'est qu'une couche d'attributs sur le texte source.
@MainActor
struct MarkdownRenderer {

    var typography: EditorTypography

    /// §4.3 : monochrome par défaut, vraies couleurs sur demande explicite.
    var colorfulCode = false

    /// L'emplacement du document, pour résoudre les images en chemin relatif.
    var documentURL: URL?

    /// Applique le rendu complet à un tampon.
    ///
    /// - Parameters:
    ///   - revealed: les indices, dans `spans`, dont les marqueurs doivent
    ///     rester visibles — calculés par `RevealPolicy`.
    func render(_ storage: NSTextStorage,
                spans: [SyntaxSpan],
                revealed: Set<Int>,
                in range: NSRange) {
        storage.beginEditing()
        defer { storage.endEditing() }

        applyBaseStyle(storage, range: range)

        // Les blocs d'abord, l'inline ensuite : un titre pose sa fonte sur
        // toute la ligne, et le gras qu'il contient doit pouvoir la reprendre
        // en la modifiant plutôt que se la faire écraser.
        let ordered = spans.indices.sorted { blockFirst(spans[$0], spans[$1]) }

        for index in ordered {
            let span = spans[index]
            guard NSIntersectionRange(span.range, range).length > 0 || range.length == 0 else { continue }
            applyContentStyle(storage, span: span)
        }

        // Le masquage vient en dernier, sur les marqueurs seulement : il doit
        // gagner contre tout attribut de fonte posé plus haut par le bloc
        // porteur, sinon un `#` de titre resterait grand et visible.
        for index in ordered where !isTable(spans[index]) {
            applyMarkers(storage, span: spans[index], revealed: revealed.contains(index))
        }

        // Les tableaux tout à la fin, et pour une raison précise : la grille
        // place ses colonnes sur la largeur **réellement rendue** de chaque
        // cellule. Une cellule contenant du gras a déjà perdu ses `**` à
        // l'étape précédente ; la mesurer avant les aurait comptés.
        for index in ordered where isTable(spans[index]) {
            applyTable(storage, span: spans[index], revealed: revealed.contains(index))
        }
    }

    func isTable(_ span: SyntaxSpan) -> Bool {
        if case .table = span.kind { return true }
        return false
    }

    /// Cette image occupe-t-elle sa ligne à elle seule ?
    ///
    /// C'est la condition pour la rendre **comme un bloc** : hauteur réservée sur
    /// le paragraphe, source masquée sans réduire cette hauteur, dessin dans la
    /// place ainsi laissée.
    ///
    /// Le cas contraire est fréquent et n'avait pas été prévu — `du texte
    /// ![une image](a.png) et la suite`. La hauteur réservée écartait alors la
    /// ligne entière, et l'image, dessinée sur toute la largeur qu'on lui
    /// accordait, passait **par-dessus les mots voisins**. Une image au fil du
    /// texte est donc laissée telle quelle : ses crochets disparaissent, son
    /// texte alternatif reste, et rien ne bouge autour.
    ///
    /// La mesure se fait sur la source et non sur le rendu : elle est appelée
    /// pendant la pose des attributs, avant que TextKit n'ait mis quoi que ce
    /// soit en page.
    static func isBlockImage(_ span: SyntaxSpan, in text: NSString) -> Bool {
        guard case .image = span.kind,
              span.range.length > 0, span.range.upperBound <= text.length else { return false }

        let line = text.lineRange(for: NSRange(location: span.range.location, length: 0))
        guard span.range.upperBound <= line.upperBound else { return false }

        let before = NSRange(location: line.location, length: span.range.location - line.location)
        let after = NSRange(location: span.range.upperBound,
                            length: line.upperBound - span.range.upperBound)
        return isBlank(text, before) && isBlank(text, after)
    }

    private static func isBlank(_ text: NSString, _ range: NSRange) -> Bool {
        guard range.length > 0 else { return true }
        let blanks = CharacterSet.whitespacesAndNewlines
        return text.rangeOfCharacter(from: blanks.inverted, options: [], range: range).location == NSNotFound
    }

    /// Bascule les marqueurs d'une seule construction, **sans toucher au reste
    /// de son rendu**.
    ///
    /// C'est le chemin emprunté à chaque déplacement du curseur, et il doit
    /// rester séparé de `render(_:)` : celui-ci commence par réinitialiser les
    /// attributs de la plage, ce qui effacerait le gras du mot au moment précis
    /// où l'on fait réapparaître ses étoiles.
    func applyMarkers(_ storage: NSTextStorage, span: SyntaxSpan, revealed: Bool) {
        // Un tableau a sa propre géométrie : ses `|` ne sont pas masqués à
        // largeur nulle mais à une largeur calculée. Voir `applyTable`.
        if case .table = span.kind {
            applyTable(storage, span: span, revealed: revealed)
            return
        }
        // Une image au fil d'une phrase n'est pas un bloc : voir `isBlockImage`.
        // Elle garde son texte alternatif — rien ne viendra le remplacer — et
        // ses marqueurs se masquent à largeur nulle comme n'importe quels autres.
        let blockImage = Self.isBlockImage(span, in: storage.mutableString)

        // Le texte alternatif d'une image en bloc, lui, fait partie de ce qui
        // disparaît : l'image le remplace à l'écran, et le laisser visible
        // superposerait deux fois la même information.
        if blockImage, !revealed, span.content.length > 0,
           span.content.upperBound <= storage.length {
            MarkerMask.hideKeepingMetrics(in: storage, range: span.content, font: typography.body)
        }
        for marker in span.markers {
            guard marker.length > 0, marker.upperBound <= storage.length else { continue }
            if revealed {
                MarkerMask.reveal(in: storage, range: marker, font: markerFont(for: span))
            } else if blockImage {
                // La source est masquée **sans réduire la hauteur** : la ligne
                // doit garder la place réservée à l'image, sinon le dessin
                // n'aurait nulle part où aller.
                MarkerMask.hideKeepingMetrics(in: storage, range: marker, font: typography.body)
            } else if case .thematicBreak = span.kind {
                // Toute la ligne est un marqueur : la masquer à largeur nulle
                // ferait disparaître la ligne elle-même, et le filet n'aurait
                // plus de place où se dessiner.
                MarkerMask.hideKeepingMetrics(in: storage, range: marker, font: typography.body)
            } else {
                MarkerMask.hide(in: storage, range: marker)
            }
        }
    }

    // MARK: - Tableaux (§2.6)

    /// Gouttière entre deux colonnes, en signes de chasse fixe.
    static let tableGutter = 3

    /// Hauteur réservée à la ligne de délimitation, en fraction du corps.
    /// Elle ne montre rien, mais elle porte le filet d'en-tête.
    static let tableRuleHeight: CGFloat = 0.7

    /// La grille tient-elle dans la colonne de texte ?
    ///
    /// Le calcul se fait sur les signes de la source, pas sur le rendu : c'est
    /// une estimation par excès — une cellule en gras rendra plus court que sa
    /// source — mais elle a l'avantage d'être la même partout, y compris dans
    /// la couche de décoration qui ne peut rien mesurer. Un tableau limite sera
    /// donc laissé en source plutôt que dessiné de travers.
    func fitsAsGrid(_ table: MarkdownTable) -> Bool {
        let advance = ("0" as NSString).size(withAttributes: [.font: typography.codeBlock]).width
        guard advance > 0 else { return false }
        return CGFloat(table.totalWidth(gutter: Self.tableGutter)) * advance <= typography.columnWidth
    }

    /// Pose — ou retire — la grille d'un tableau.
    ///
    /// # Le repli du §2.6, et pourquoi c'est le bon
    ///
    /// Le cahier des charges visait une grille réellement éditable, avec un
    /// `firstResponder` imbriqué par cellule, et armait d'avance un repli :
    /// *grille en lecture, source à l'édition*. C'est ce repli qui est en
    /// place, et pas par manque de temps — la couche de décoration, écrite
    /// pour les images, l'a rendu **meilleur** que la cible d'origine.
    ///
    /// Un éditeur dans l'éditeur aurait signifié deux piles d'annulation à
    /// tenir synchrones, une sélection qui ne traverse plus le tableau, et un
    /// `⌘F` qui s'arrête à ses bords. Ici il n'y a toujours qu'un seul tampon :
    /// la sélection traverse la grille, la recherche y trouve, l'annulation est
    /// celle de la frappe.
    ///
    /// # Comment la grille tient sans un caractère ajouté
    ///
    /// Chaque `|` est masqué, mais reçoit **une avance calculée** : celle qu'il
    /// faut pour que la cellule suivante tombe sur sa colonne. Les blancs de
    /// remplissage de la source passent à zéro — c'est la grille qui espace,
    /// plus l'auteur. La ligne `|---|` est masquée entière et sa hauteur
    /// réduite à la place d'un filet.
    ///
    /// Les colonnes sont mesurées, pas comptées : `**Titre**` rend six signes
    /// de moins que sa source, et une colonne calculée sur les signes serait
    /// large de six de trop.
    func applyTable(_ storage: NSTextStorage, span: SyntaxSpan, revealed: Bool) {
        guard case .table(let table) = span.kind, let table,
              span.range.upperBound <= storage.length else { return }

        let font = typography.codeBlock
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        guard advance > 0 else { return }

        // Un tableau plus large que la colonne de texte se replierait ligne à
        // ligne, et une grille repliée ne se lit plus du tout. On renonce alors
        // à la grille et on montre la source, comme pour un tableau malformé.
        guard fitsAsGrid(table), !revealed else {
            showTableSource(storage, table: table, font: font)
            return
        }
        layOutTable(storage, table: table, advance: advance)
    }

    /// Le tableau tel qu'il est écrit : `|` et blancs visibles, ligne de
    /// délimitation à sa hauteur normale. C'est l'état sous le curseur, et
    /// celui d'un tableau trop large pour la colonne.
    private func showTableSource(_ storage: NSTextStorage, table: MarkdownTable, font: NSFont) {
        for marker in table.markerRanges where marker.upperBound <= storage.length {
            MarkerMask.reveal(in: storage, range: marker, font: font)
        }
        // Le repli à la ligne est **rétabli** : la source à pipes est plus large
        // que la grille qu'elle remplace, et la tronquer cacherait à l'auteur
        // la moitié de ce qu'il est en train d'éditer.
        applyRowStyles(storage, table: table, clipping: false, reducedRuleLine: false)
    }

    private func layOutTable(_ storage: NSTextStorage, table: MarkdownTable, advance: CGFloat) {
        // 1. Tout ce qui est syntaxe disparaît d'abord, à largeur nulle. Les
        //    avances utiles seront réécrites juste après ; celles qui ne le
        //    sont pas — un `|` de bord droit — doivent rester à zéro.
        for marker in table.markerRanges where marker.upperBound <= storage.length {
            MarkerMask.hide(in: storage, range: marker)
        }

        // 2. Hauteurs de ligne, dont celle — réduite — de la délimitation.
        applyRowStyles(storage, table: table, clipping: true, reducedRuleLine: true)

        // 3. Largeur de chaque colonne, mesurée sur le rendu réel.
        var widths = [CGFloat](repeating: 0, count: table.columnCount)
        for row in table.rows {
            for (column, cell) in row.cells.enumerated() where column < widths.count {
                widths[column] = max(widths[column], measure(storage, cell.content))
            }
        }

        // 4. Abscisse de départ de chaque colonne.
        let gutter = CGFloat(Self.tableGutter) * advance
        var origins: [CGFloat] = []
        var cursor: CGFloat = 0
        for width in widths {
            origins.append(cursor)
            cursor += width + gutter
        }

        // 5. Chaque `|` reçoit l'avance qui mène au début de sa cellule.
        for row in table.rows {
            var pen: CGFloat = 0
            for (column, cell) in row.cells.enumerated() {
                let own = measure(storage, cell.content)
                let origin = column < origins.count ? origins[column] : pen
                let slack = column < widths.count ? max(0, widths[column] - own) : 0
                let offset: CGFloat = switch alignment(of: table, column: column) {
                case .leading: 0
                case .center: (slack / 2).rounded()
                case .trailing: slack
                }

                // Le séparateur qui précède la cellule : le `|` de bord gauche
                // pour la première, celui qui la sépare de la précédente sinon.
                let pipeIndex = row.hasLeadingPipe ? column : column - 1
                if pipeIndex >= 0, pipeIndex < row.pipes.count,
                   row.pipes[pipeIndex].upperBound <= storage.length {
                    MarkerMask.hide(in: storage, range: row.pipes[pipeIndex],
                                    advance: origin + offset - pen)
                    pen = origin + offset
                }
                pen += own
            }
        }
    }

    /// Les styles de paragraphe des lignes du tableau.
    ///
    /// L'espace au-dessus du bloc ne va que sur la **première** ligne. Posé sur
    /// toute la plage, comme il l'était d'abord, il s'appliquait à chaque ligne
    /// source — c'est-à-dire à chaque rangée — et le tableau se lisait aussi
    /// aéré qu'une suite de paragraphes.
    private func applyRowStyles(_ storage: NSTextStorage, table: MarkdownTable,
                                clipping: Bool, reducedRuleLine: Bool) {
        for (index, row) in table.rows.enumerated() {
            let style = tableParagraphStyle(clipping: clipping)
            if index == 0 { style.paragraphSpacingBefore = (typography.bodySize * 0.6).rounded() }
            storage.addAttribute(.paragraphStyle, value: style,
                                 range: paragraph(of: row.line, in: storage))
        }

        let ruleStyle = tableParagraphStyle(clipping: clipping)
        if reducedRuleLine {
            // La ligne ne montre rien : sa hauteur est celle du filet qu'elle
            // porte, pas celle d'une rangée vide.
            ruleStyle.minimumLineHeight = (typography.bodySize * Self.tableRuleHeight).rounded()
            ruleStyle.maximumLineHeight = ruleStyle.minimumLineHeight
            ruleStyle.lineHeightMultiple = 1
        }
        storage.addAttribute(.paragraphStyle, value: ruleStyle,
                             range: paragraph(of: table.delimiter, in: storage))
    }

    private func alignment(of table: MarkdownTable, column: Int) -> MarkdownTable.Alignment {
        column < table.alignments.count ? table.alignments[column] : .leading
    }

    /// Largeur réellement rendue d'une plage, attributs compris.
    private func measure(_ storage: NSTextStorage, _ range: NSRange) -> CGFloat {
        guard range.length > 0, range.upperBound <= storage.length else { return 0 }
        return storage.attributedSubstring(from: range).size().width
    }

    /// La plage du paragraphe qui porte une ligne, terminateur compris.
    ///
    /// Un style de paragraphe posé sur la ligne sans son `\n` laisse TextKit
    /// lire celui du caractère suivant : la hauteur réduite ne prendrait pas.
    private func paragraph(of line: NSRange, in storage: NSTextStorage) -> NSRange {
        var range = line
        if range.upperBound < storage.length,
           storage.mutableString.character(at: range.upperBound) == 10 {
            range.length += 1
        }
        return NSRange(location: range.location, length: min(range.length, storage.length - range.location))
    }

    /// Interlignage resserré : un tableau est une grille, pas de la prose.
    ///
    /// - Parameter clipping: vrai quand la grille est posée. Une rangée ne doit
    ///   alors jamais passer à la ligne — le calcul de largeur garantit qu'elle
    ///   tient, et un repli décalerait toutes les rangées en dessous. En source,
    ///   au contraire, le repli est ce qui rend le bloc lisible.
    private func tableParagraphStyle(clipping: Bool) -> NSMutableParagraphStyle {
        let style = typography.paragraphStyle()
        style.lineHeightMultiple = 1.2
        style.lineBreakMode = clipping ? .byClipping : .byWordWrapping
        return style
    }

    // MARK: - Style de base

    private func applyBaseStyle(_ storage: NSTextStorage, range: NSRange) {
        let target = range.length > 0 ? range : NSRange(location: 0, length: storage.length)
        guard target.length > 0 else { return }
        storage.setAttributes([
            .font: typography.body,
            .foregroundColor: Theme.NS.label,
            .paragraphStyle: typography.paragraphStyle(),
        ], range: target)
    }

    // MARK: - Style du contenu

    private func applyContentStyle(_ storage: NSTextStorage, span: SyntaxSpan) {
        let content = clamp(span.content, to: storage.length)
        let whole = clamp(span.range, to: storage.length)

        switch span.kind {
        case .strong:
            addTrait(storage, range: content, bold: true)

        case .emphasis:
            addTrait(storage, range: content, italic: true)

        case .strikethrough:
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .strikethroughColor: Theme.NS.labelSecondary], range: content)

        case .inlineCode:
            storage.addAttributes([.font: typography.inlineCode,
                                   .backgroundColor: Theme.NS.fillQuaternary], range: content)

        case .link:
            // Souligné et non coloré : le seul objet coloré autorisé est le
            // contenu de l'utilisateur (§7).
            storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .underlineColor: Theme.NS.labelTertiary,
                                   .cursor: NSCursor.pointingHand], range: content)

        case .image(let source, _):
            // **Réserver la place, sans insérer un seul caractère.**
            //
            // Une image ne peut pas être un `NSTextAttachment` : un attachement
            // remplace un caractère, et le §3.1 interdit d'en ajouter un. La
            // hauteur est donc réservée par `minimumLineHeight` sur le
            // paragraphe, la source est masquée à largeur nulle comme n'importe
            // quel marqueur, et `DecorationPainter` peint dans la place ainsi
            // laissée.
            //
            // Rien de tout cela pour une image au fil du texte : réserver la
            // hauteur écarterait la ligne où elle se trouve, et le dessin se
            // poserait par-dessus les mots qui l'entourent.
            guard Self.isBlockImage(span, in: storage.mutableString) else { break }
            let style = typography.paragraphStyle()
            style.minimumLineHeight = reservedHeight(for: source)
            style.lineHeightMultiple = 1
            style.paragraphSpacingBefore = typography.bodySize * 0.5
            storage.addAttributes([.paragraphStyle: style], range: whole)

        case .footnoteReference:
            // L'exposant porte sur le seul identifiant : les crochets sont des
            // marqueurs et seront masqués, mais le numéro doit rester à
            // l'écran, sinon l'auteur perd le repère vers sa note.
            storage.addAttributes([.font: typography.font(size: typography.bodySize * 0.7),
                                   .baselineOffset: typography.bodySize * 0.32,
                                   .foregroundColor: Theme.NS.labelSecondary], range: content)

        case .heading(let level):
            let style = typography.paragraphStyle()
            style.paragraphSpacingBefore = typography.spacingBefore(headingLevel: level)
            storage.addAttributes([.font: typography.heading(level: level),
                                   .paragraphStyle: style], range: whole)

        case .blockQuote:
            let style = typography.paragraphStyle()
            style.firstLineHeadIndent = typography.quoteIndent
            style.headIndent = typography.quoteIndent
            storage.addAttributes([.foregroundColor: Theme.NS.labelSecondary,
                                   .paragraphStyle: style], range: whole)

        case .listItem, .taskItem:
            // `firstLineHeadIndent` **et** `headIndent`. Le second seul ne
            // décale que les lignes de continuation : la première resterait
            // collée à la marge, et la puce, dessinée à sa gauche, tomberait à
            // une abscisse négative — donc hors de la vue.
            let style = typography.paragraphStyle()
            let indent = typography.listIndent(level: SyntaxSpan.listLevel(forDepth: span.depth))
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            storage.addAttributes([.paragraphStyle: style], range: whole)

        case .thematicBreak:
            // Rendu comme un filet plutôt qu'un texte : la ligne entière est un
            // marqueur, elle sera donc masquée, et c'est la bordure du
            // paragraphe qui dessine le trait.
            break

        case .codeBlock(let language):
            // Pas de `.backgroundColor` : posé caractère par caractère, il
            // produit un liseré dentelé qui s'arrête au dernier signe de chaque
            // ligne. Le fond est dessiné par `DecorationPainter`, en un seul
            // rectangle arrondi qui couvre toute la colonne.
            let style = typography.paragraphStyle()
            style.lineHeightMultiple = 1.25
            style.firstLineHeadIndent = typography.codeBlockIndent
            style.headIndent = typography.codeBlockIndent
            storage.addAttributes([.font: typography.codeBlock,
                                   .paragraphStyle: style], range: whole)
            highlightCode(storage, content: content, language: language)

        case .frontMatter:
            storage.addAttributes([.font: typography.codeBlock,
                                   .foregroundColor: Theme.NS.labelSecondary], range: whole)

        case .table(let table):
            // Chasse fixe pour tout le bloc, y compris sous le curseur : c'est
            // ce qui rend la source à pipes lisible pendant qu'on l'édite, et
            // ce sur quoi la grille appuie ses colonnes. Les hauteurs de ligne,
            // elles, dépendent de l'état de révélation et sont posées par
            // `applyRowStyles`.
            storage.addAttributes([.font: typography.codeBlock,
                                   .paragraphStyle: tableParagraphStyle(clipping: false)],
                                  range: whole)

            // L'en-tête en gras. Il l'est aussi sous le curseur : c'est la
            // seule information de structure que la source à pipes ne donne
            // pas d'elle-même.
            if let header = table?.rows.first {
                // `convert(toHaveTrait:)` plutôt que le passage par la famille :
                // la chasse fixe du système s'appelle `.AppleSystemUIFontMono‑
                // spaced`, un nom que `NSFontManager` ne sait pas retrouver, et
                // la conversion par famille retombait silencieusement sur le
                // maigre.
                let bold = NSFontManager.shared.convert(typography.codeBlock, toHaveTrait: .boldFontMask)
                for cell in header.cells {
                    let range = clamp(cell.content, to: storage.length)
                    guard range.length > 0 else { continue }
                    storage.addAttribute(.font, value: bold, range: range)
                }
            }
        }
    }

    /// Hauteur à réserver pour une image, cadre d'absence compris.
    private func reservedHeight(for source: String) -> CGFloat {
        switch ImageStore.shared.entry(for: source, relativeTo: documentURL) {
        case .loaded(let image, _):
            ImageStore.displaySize(of: image, columnWidth: typography.columnWidth).height
        case .oversized(let thumbnail, _):
            thumbnail.map { ImageStore.displaySize(of: $0, columnWidth: typography.columnWidth).height }
                ?? ImageStore.missingPlaceholderHeight
        case .missing:
            ImageStore.missingPlaceholderHeight
        }
    }

    /// Colorie le contenu d'un bloc de code.
    ///
    /// Un langage absent ou inconnu ne produit aucune catégorie : le bloc reste
    /// en chasse fixe, non coloré. Jamais d'erreur, jamais de bloc vide (§4.3).
    private func highlightCode(_ storage: NSTextStorage, content: NSRange, language: String?) {
        guard content.length > 0, content.upperBound <= storage.length else { return }
        let code = storage.attributedSubstring(from: content).string
        let font = typography.codeBlock
        for (range, category) in CodeHighlighter.categorize(code, language: language, offset: content.location) {
            guard range.upperBound <= storage.length else { continue }
            let attributes = colorfulCode
                ? CodeHighlighter.colorAttributes(for: category, font: font)
                : CodeHighlighter.monochromeAttributes(for: category, font: font)
            storage.addAttributes(attributes, range: range)
        }
    }

    /// Ajoute une graisse ou une italique **sans perdre celle déjà posée** :
    /// c'est ce qui permet à `***texte***` de ressortir gras *et* italique,
    /// alors que deux poses successives de `.font` se seraient écrasées.
    private func addTrait(_ storage: NSTextStorage, range: NSRange, bold: Bool = false, italic: Bool = false) {
        guard range.length > 0 else { return }
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let current = (value as? NSFont) ?? typography.body
            var traits = NSFontManager.shared.traits(of: current)
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            let converted = NSFontManager.shared.font(withFamily: current.familyName ?? current.fontName,
                                                      traits: traits,
                                                      weight: bold ? 9 : 5,
                                                      size: current.pointSize)
            storage.addAttribute(.font, value: converted ?? current, range: subrange)
        }
    }

    /// La fonte d'un marqueur révélé : celle de son bloc porteur, pour que le
    /// `##` d'un titre ne soit pas rendu à la taille du corps de texte au
    /// milieu d'une ligne de titre.
    private func markerFont(for span: SyntaxSpan) -> NSFont {
        switch span.kind {
        case .heading(let level): typography.heading(level: level)
        case .codeBlock, .frontMatter, .table: typography.codeBlock
        case .inlineCode: typography.inlineCode
        default: typography.body
        }
    }

    private func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        return NSRange(location: location, length: max(0, min(range.length, length - location)))
    }

    /// Ordre de pose : les blocs avant l'inline, et les plus englobants avant
    /// les plus intérieurs.
    private func blockFirst(_ a: SyntaxSpan, _ b: SyntaxSpan) -> Bool {
        let rank = { (span: SyntaxSpan) -> Int in
            switch span.kind.revealScope {
            case .wholeBlock: 0
            case .wholeLine: 1
            case .innermostInline: 2
            }
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        return a.depth < b.depth
    }
}

@MainActor
private extension EditorTypography {
    /// Fonte du corps à une taille arbitraire — pour l'exposant des notes.
    func font(size: CGFloat) -> NSFont {
        FontCache.shared.font(name: bodyFontName, size: size, weight: .regular)
    }
}
