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
        for index in ordered {
            applyMarkers(storage, span: spans[index], revealed: revealed.contains(index))
        }
    }

    /// Bascule les marqueurs d'une seule construction, **sans toucher au reste
    /// de son rendu**.
    ///
    /// C'est le chemin emprunté à chaque déplacement du curseur, et il doit
    /// rester séparé de `render(_:)` : celui-ci commence par réinitialiser les
    /// attributs de la plage, ce qui effacerait le gras du mot au moment précis
    /// où l'on fait réapparaître ses étoiles.
    func applyMarkers(_ storage: NSTextStorage, span: SyntaxSpan, revealed: Bool) {
        for marker in span.markers {
            guard marker.length > 0, marker.upperBound <= storage.length else { continue }
            if revealed {
                MarkerMask.reveal(in: storage, range: marker, font: markerFont(for: span))
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

        case .image:
            // Le rendu en attachement est le travail du jalon 4. En attendant,
            // le texte alternatif reste lisible plutôt que masqué : masquer ce
            // qu'on ne sait pas encore rendre reviendrait à le faire disparaître.
            storage.addAttributes([.foregroundColor: Theme.NS.labelSecondary], range: content)

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

        case .table:
            storage.addAttributes([.font: typography.inlineCode], range: whole)
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
