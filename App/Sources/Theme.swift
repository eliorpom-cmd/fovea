// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit
import SwiftUI

/// Système de design : monochrome, aucune couleur d'accent, sous-teinte grise
/// neutre. La hiérarchie vient de la graisse, de la taille et de l'espace,
/// jamais de la teinte (§7 du cahier des charges).
///
/// Deux règles propres à Fovea, plus strictes que celles de TBD :
///
/// 1. **L'app doit disparaître.** Le chrome est réduit au minimum ; en plein
///    écran il ne doit rester que la colonne de texte.
/// 2. **Le seul objet coloré autorisé est le contenu de l'utilisateur** — ses
///    images, et ses blocs de code s'il a demandé la coloration en couleurs.
enum Theme {

    // MARK: - Fonds

    /// Fond de la fenêtre d'édition. Volontairement pas `windowBackgroundColor` :
    /// on veut un blanc franc en clair, et un gris qui ne tire pas au bleu en
    /// sombre — le texte doit être la seule chose que l'œil accroche.
    static let window = adaptive(light: 0xFFFFFF, dark: 0x1C1C1E)

    /// Surface de carte : palette de commandes, popovers, panneau de plan.
    static let card = adaptive(light: 0xFFFFFF, dark: 0x2A2A2C)

    // MARK: - Rampe de remplissage
    //
    // Gris translucide neutre, comme `NSColor.systemFill` : la teinte suit le
    // fond, ce qui évite les aplats boueux en mode sombre.

    /// Fond des blocs de code et du code inline.
    static let fillQuaternary = adaptive(light: (0x747480, 0.05), dark: (0x767680, 0.16))
    /// Fond des champs et capsules.
    static let fillTertiary = adaptive(light: (0x767680, 0.08), dark: (0x767680, 0.22))
    static let fillSecondary = adaptive(light: (0x787880, 0.12), dark: (0x787880, 0.30))
    /// Ligne survolée dans le plan ou la palette.
    static let rowHover = adaptive(light: (0x787880, 0.16), dark: (0x787880, 0.32))
    /// **Ligne sélectionnée** dans une liste — menu slash, palette, plan.
    ///
    /// Un cran au-dessus du survol, pour qu'on distingue les deux, et gris :
    /// `NSTableView` peint sa sélection en bleu système, ce qui était la seule
    /// couleur d'accent restée dans l'app. Le §7 n'autorise la couleur que sur
    /// le contenu de l'utilisateur, et ce fichier annonçait déjà la neutraliser
    /// — sans que les listes l'appliquent jamais.
    static let rowSelection = adaptive(light: (0x787880, 0.22), dark: (0x787880, 0.42))

    // MARK: - Libellés

    /// Le texte de l'utilisateur. Pas du noir pur : sur un fond blanc, le noir
    /// pur vibre sur les longues sessions d'écriture.
    static let label = adaptive(light: (0x000000, 0.88), dark: (0xFFFFFF, 0.92))
    /// Citations, métadonnées, statistiques.
    static let labelSecondary = adaptive(light: (0x000000, 0.50), dark: (0xFFFFFF, 0.55))
    /// **Les marqueurs markdown révélés** (§2.1), les substituts, le texte
    /// désactivé. Présents, jamais bruyants.
    static let labelTertiary = adaptive(light: (0x000000, 0.28), dark: (0xFFFFFF, 0.30))
    /// Le texte atténué par le mode focus (§4.5).
    static let labelDimmed = adaptive(light: (0x000000, 0.22), dark: (0xFFFFFF, 0.24))

    // MARK: - Traits

    static let separator = adaptive(light: (0x000000, 0.10), dark: (0xFFFFFF, 0.12))
    static let strokeControl = adaptive(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.14))
    /// Halo de focus clavier, neutre — jamais le bleu système.
    static let focusRing = adaptive(light: (0x0A0A0A, 0.24), dark: (0xF5F5F5, 0.30))

    /// La barre verticale à gauche d'une citation.
    static let quoteBar = adaptive(light: (0x000000, 0.18), dark: (0xFFFFFF, 0.22))

    // MARK: - Encre (bouton principal)

    static let ink = adaptive(light: 0x0A0A0A, dark: 0xF5F5F5)
    static let inkOn = adaptive(light: 0xFFFFFF, dark: 0x0A0A0A)

    // MARK: - Sélection
    //
    // La sélection système est bleue. Dans un éditeur monochrome où la seule
    // couleur autorisée est le contenu de l'utilisateur, on la neutralise.

    static let selection = adaptive(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.18))

    // MARK: - Mise en page

    /// Échelle d'espacement.
    enum Space {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        static let s40: CGFloat = 40
        static let s64: CGFloat = 64
    }

    enum Radius {
        static let control: CGFloat = 6
        static let field: CGFloat = 8
        static let row: CGFloat = 8
        static let card: CGFloat = 10
        static let codeBlock: CGFloat = 8
        static let window: CGFloat = 14
    }

    // MARK: - Rampe typographique de l'interface
    //
    // Pour le chrome uniquement — barre d'état, palette, réglages, plan. La
    // typographie du **texte de l'utilisateur** ne vit pas ici : elle est
    // réglable (§4.7) et calculée par `EditorTypography`.

    enum UIText {
        static let title2 = Font.system(size: 17, weight: .regular)
        static let title3 = Font.system(size: 15, weight: .semibold)
        static let headline = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13, weight: .regular)
        static let bodyEmphasized = Font.system(size: 13, weight: .medium)
        static let callout = Font.system(size: 12, weight: .regular)
        static let subheadline = Font.system(size: 11, weight: .regular)
        static let footnote = Font.system(size: 10, weight: .regular)
        /// En-tête de section en petites capitales.
        static let sectionHeader = Font.system(size: 10, weight: .semibold)
    }

    // MARK: - Construction des couleurs

    private static func adaptive(light: Int, dark: Int) -> Color {
        adaptive(light: (light, 1.0), dark: (dark, 1.0))
    }

    private static func adaptive(light: (Int, Double), dark: (Int, Double)) -> Color {
        Color(nsColor: nsAdaptive(light: light, dark: dark))
    }

    private static func nsAdaptive(light: (Int, Double), dark: (Int, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark.0, alpha: dark.1)
                : NSColor(hex: light.0, alpha: light.1)
        }
    }
}

// MARK: - Accès AppKit
//
// L'éditeur est en AppKit pur : il lui faut des NSColor, pas des Color SwiftUI.
// Ce miroir évite un `NSColor(theme.x)` disséminé dans tout le code de rendu,
// qui coûte une conversion à chaque pose d'attribut — et il y en a des milliers
// par frappe.

extension Theme {
    enum NS {
        static let window = ns(light: (0xFFFFFF, 1.0), dark: (0x1C1C1E, 1.0))
        static let card = ns(light: (0xFFFFFF, 1.0), dark: (0x2A2A2C, 1.0))

        static let fillQuaternary = ns(light: (0x747480, 0.05), dark: (0x767680, 0.16))
        static let fillTertiary = ns(light: (0x767680, 0.08), dark: (0x767680, 0.22))
        static let fillSecondary = ns(light: (0x787880, 0.12), dark: (0x787880, 0.30))

        static let label = ns(light: (0x000000, 0.88), dark: (0xFFFFFF, 0.92))
        static let labelSecondary = ns(light: (0x000000, 0.50), dark: (0xFFFFFF, 0.55))
        static let labelTertiary = ns(light: (0x000000, 0.28), dark: (0xFFFFFF, 0.30))
        static let labelDimmed = ns(light: (0x000000, 0.22), dark: (0xFFFFFF, 0.24))

        static let separator = ns(light: (0x000000, 0.10), dark: (0xFFFFFF, 0.12))
        static let quoteBar = ns(light: (0x000000, 0.18), dark: (0xFFFFFF, 0.22))
        static let selection = ns(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.18))
        static let rowSelection = ns(light: (0x787880, 0.22), dark: (0x787880, 0.42))
        static let ink = ns(light: (0x0A0A0A, 1.0), dark: (0xF5F5F5, 1.0))

        private static func ns(light: (Int, Double), dark: (Int, Double)) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(hex: dark.0, alpha: dark.1)
                    : NSColor(hex: light.0, alpha: light.1)
            }
        }
    }
}

extension NSColor {
    /// Construit une couleur sRGB depuis un entier hexadécimal 0xRRGGBB.
    convenience init(hex: Int, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
