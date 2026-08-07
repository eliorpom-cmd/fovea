// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// La typographie du **texte de l'utilisateur** — distincte de celle du chrome,
/// qui vit dans `Theme.UIText`.
///
/// Elle est ici parce qu'elle est réglable (§4.7) : police, taille, interlignage
/// et largeur de colonne changent, et tout ce qui en dépend doit être recalculé
/// d'un seul endroit. Les fontes sont mises en cache : une pose d'attributs
/// touche des milliers de plages, et `NSFont` n'est pas gratuit à instancier.
/// `@MainActor` parce qu'elle résout des `NSFont` : AppKit n'est pas
/// thread-safe, et la seule alternative serait un verrou payé à chaque
/// caractère rendu.
@MainActor
struct EditorTypography {

    /// Nom de la famille, ou `nil` pour la police système (SF Pro, le défaut
    /// du §7). L'utilisateur peut en choisir une autre, y compris une police
    /// qu'il a lui-même déposée.
    var bodyFontName: String?
    var monoFontName: String?
    var bodySize: CGFloat
    var lineHeightMultiple: CGFloat
    /// Largeur de la colonne de texte, **en signes** et non en points : c'est
    /// la mesure qui a du sens en lecture, et elle suit la taille de police.
    var columnWidthInCharacters: Int

    static let `default` = EditorTypography(bodyFontName: nil,
                                            monoFontName: nil,
                                            bodySize: 16,
                                            lineHeightMultiple: 1.5,
                                            columnWidthInCharacters: 68)

    // MARK: - Fontes

    var body: NSFont { font(bodyFontName, size: bodySize, weight: .regular) }
    var bodyEmphasized: NSFont { font(bodyFontName, size: bodySize, weight: .semibold) }
    var bodyItalic: NSFont { italic(body) }
    var bodyBoldItalic: NSFont { italic(bodyEmphasized) }

    /// Le code inline est très légèrement réduit : à taille égale, une chasse
    /// fixe paraît plus grosse que la proportionnelle qui l'entoure et fait
    /// bosseler la ligne.
    var inlineCode: NSFont { mono(size: bodySize * 0.92) }
    var codeBlock: NSFont { mono(size: bodySize * 0.92) }

    /// Échelle des titres. Six niveaux dans une app d'écriture, ce n'est pas
    /// six tailles : au-delà du quatrième, la hiérarchie passe par la graisse,
    /// sinon un titre 6 finirait plus petit que le corps de texte.
    func heading(level: Int) -> NSFont {
        let scale: CGFloat = switch level {
        case 1: 1.85
        case 2: 1.50
        case 3: 1.25
        case 4: 1.10
        default: 1.0
        }
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        return font(bodyFontName, size: (bodySize * scale).rounded(), weight: weight)
    }

    /// Espace au-dessus d'un titre, proportionnel à son importance. C'est cet
    /// espace, bien plus que la taille, qui fait lire une structure.
    func spacingBefore(headingLevel level: Int) -> CGFloat {
        let scale: CGFloat = switch level {
        case 1: 1.6
        case 2: 1.4
        case 3: 1.1
        default: 0.9
        }
        return (bodySize * scale).rounded()
    }

    // MARK: - Mise en page

    var lineHeight: CGFloat { (bodySize * lineHeightMultiple).rounded() }

    /// Retrait d'un item de liste, par niveau d'imbrication.
    ///
    /// Il doit être **plus large que la puce plus son écart**, sinon la puce se
    /// dessinerait à une abscisse négative, donc hors de la vue — c'est
    /// exactement ce qui est arrivé au premier essai.
    func listIndent(level: Int) -> CGFloat {
        (bodySize * 1.6 * CGFloat(level + 1)).rounded()
    }

    /// Écart entre la puce et le texte qu'elle introduit.
    var listMarkerGap: CGFloat { (bodySize * 0.45).rounded() }

    /// Retrait d'une citation : la place de sa barre verticale, plus l'air
    /// qu'il faut entre la barre et le texte.
    var quoteIndent: CGFloat { (bodySize * 1.2).rounded() }

    var codeBlockIndent: CGFloat { (bodySize * 0.75).rounded() }

    /// **Zéro, volontairement.**
    ///
    /// Pour TextKit, chaque `\n` ouvre un nouveau paragraphe. Or un document
    /// markdown est presque toujours coupé à la main autour de 80 signes : un
    /// espacement de paragraphe s'appliquerait alors entre *chaque ligne
    /// source*, et un paragraphe de six lignes s'étalerait comme six
    /// paragraphes.
    ///
    /// La séparation vient donc de là où l'auteur l'a mise — la ligne vide
    /// qu'il a tapée, qui se rend à la hauteur d'une ligne. C'est la seule
    /// solution cohérente avec le §3.1 : l'écran montre ce que le fichier dit,
    /// il n'ajoute pas d'espace que personne n'a écrit.
    var paragraphSpacing: CGFloat { 0 }

    /// Largeur de la colonne en points, mesurée sur la fonte réelle.
    ///
    /// Le « n » est l'étalon habituel des typographes pour une largeur moyenne
    /// de caractère ; l'espace serait trop étroit et le « m » trop large, et
    /// tous deux donneraient une colonne fausse dès qu'on change de police.
    var columnWidth: CGFloat {
        let reference = body
        let advance = ("n" as NSString).size(withAttributes: [.font: reference]).width
        return (advance * CGFloat(columnWidthInCharacters)).rounded()
    }

    /// Style de paragraphe de base, partagé par tout le corps de texte.
    func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = paragraphSpacing
        return style
    }

    // MARK: - Fabrique de fontes

    private func font(_ name: String?, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        FontCache.shared.font(name: name, size: size, weight: weight)
    }

    private func mono(size: CGFloat) -> NSFont {
        FontCache.shared.mono(name: monoFontName, size: size)
    }

    private func italic(_ base: NSFont) -> NSFont {
        FontCache.shared.italic(of: base)
    }
}

/// Cache de fontes.
///
/// Sans lui, chaque reparse instancie quelques milliers de `NSFont` identiques.
/// La classe est `@MainActor` parce que la pose d'attributs l'est aussi : il
/// n'y a jamais deux threads pour y accéder, donc pas de verrou à payer.
@MainActor
final class FontCache {
    static let shared = FontCache()

    private struct Key: Hashable {
        let name: String?
        let size: CGFloat
        let weight: CGFloat
        let italic: Bool
        let mono: Bool
    }

    private var cache: [Key: NSFont] = [:]

    func font(name: String?, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let key = Key(name: name, size: size, weight: weight.rawValue, italic: false, mono: false)
        if let hit = cache[key] { return hit }

        let resolved: NSFont
        if let name, let named = NSFont(name: name, size: size) {
            // Une famille choisie par l'utilisateur n'a pas forcément la graisse
            // demandée. Le gestionnaire de fontes s'en approche, et retombe sur
            // la fonte de départ plutôt que d'échouer.
            resolved = NSFontManager.shared.convert(named, toHaveTrait: weight >= .semibold ? .boldFontMask : [])
        } else {
            resolved = NSFont.systemFont(ofSize: size, weight: weight)
        }
        cache[key] = resolved
        return resolved
    }

    func mono(name: String?, size: CGFloat) -> NSFont {
        let key = Key(name: name, size: size, weight: NSFont.Weight.regular.rawValue, italic: false, mono: true)
        if let hit = cache[key] { return hit }
        let resolved = name.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        cache[key] = resolved
        return resolved
    }

    func italic(of base: NSFont) -> NSFont {
        let key = Key(name: base.fontName, size: base.pointSize, weight: 0, italic: true, mono: false)
        if let hit = cache[key] { return hit }
        let resolved = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        cache[key] = resolved
        return resolved
    }

    func clear() { cache.removeAll(keepingCapacity: true) }
}
