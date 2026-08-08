// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

extension NSAttributedString.Key {
    /// Marque une plage comme **marqueur markdown actuellement masqué**.
    ///
    /// L'attribut n'a aucun effet visuel par lui-même : c'est un drapeau posé
    /// en même temps que les attributs qui, eux, rendent la plage invisible.
    /// Il sert au reste de l'éditeur — suppression intelligente (§2.5),
    /// accessibilité (§8), export — à savoir ce qui est syntaxe et ce qui est
    /// contenu, sans avoir à re-parser.
    static let foveaMasked = NSAttributedString.Key("foveaMasked")

    /// Marque une plage comme **marqueur markdown révélé** : elle appartient à
    /// la construction que le curseur touche en ce moment (§2.2).
    static let foveaRevealed = NSAttributedString.Key("foveaRevealed")
}

/// Le mécanisme qui fait disparaître les marqueurs.
///
/// # Le pari du jalon 0
///
/// Le cahier des charges (§3.4) posait deux mécanismes possibles et n'en
/// tranchait aucun. Celui retenu est **A — rendu à largeur nulle** : les
/// marqueurs restent dans le tampon *et* dans la chaîne d'affichage, mais
/// reçoivent une police de taille infinitésimale et une couleur transparente.
///
/// L'intérêt décisif est que **les plages du tampon et de l'affichage restent
/// identiques**. Sélection, `NSTextFinder`, `NSUndoManager`, accessibilité et
/// export continuent de fonctionner sans le moindre mapping, là où le
/// mécanisme B — renvoyer un `NSTextParagraph` plus court depuis
/// `NSTextContentStorageDelegate` — aurait fait diverger `NSTextLocation` et
/// les offsets de stockage dans tous ces sous-systèmes à la fois.
///
/// # Ce que le prototype a corrigé dans le cahier des charges
///
/// Le §2.3 annonçait des « positions de curseur invisibles » à contourner en
/// interceptant toutes les commandes de déplacement de `NSTextView`. **Cette
/// crainte était infondée**, et c'est la règle de révélation qui l'annule :
/// une construction se révèle dès que le curseur touche `[début, fin]`,
/// bornes comprises. Or toute position située dans un marqueur est par
/// construction dans cet intervalle. Donc **quand un marqueur est masqué, le
/// curseur ne peut pas s'y trouver**, et il n'y a rien à intercepter.
///
/// Voir `RevealPolicy` pour la démonstration, et `MarkerMaskTests` pour la
/// vérification exhaustive sur un document réel.
///
/// `@MainActor` parce que le masquage résout des `NSFont` et lit les réglages
/// d'accessibilité du système : AppKit n'est pas thread-safe, et cette couche
/// n'est de toute façon appelée que depuis le rendu, lui-même sur le thread
/// principal.
@MainActor
enum MarkerMask {

    /// Pas zéro : `NSFont` accepte 0 mais TextKit produit alors des métriques
    /// dégénérées, et une largeur `NaN` se propage jusqu'au rect du curseur.
    /// Une taille infinitésimale donne une avance sous le dixième de point,
    /// invisible à toute échelle d'écran.
    static let hiddenFontSize: CGFloat = 0.01

    /// Rend une plage invisible et de largeur nulle.
    ///
    /// La police de substitution est délibérément la police système et non
    /// celle du texte porteur : à 0,01 pt, aucun dessin n'a lieu, et charger la
    /// vraie fonte à une taille absurde coûterait une entrée de cache par
    /// couple (fonte, taille) pour rien.
    static func hide(in storage: NSTextStorage, range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttributes([
            .font: NSFont.systemFont(ofSize: hiddenFontSize),
            .foregroundColor: NSColor.clear,
            // Sans cette remise à zéro explicite, un crénage hérité du texte
            // porteur survivrait et rendrait la plage large de quelques
            // dixièmes de point — assez pour qu'un `**` décale visiblement une
            // ligne de titre.
            .kern: 0,
            .foveaMasked: true,
        ], range: range)
        storage.removeAttribute(.foveaRevealed, range: range)
    }

    /// Rend une plage invisible en lui imposant **une largeur choisie**.
    ///
    /// C'est ce qui permet à la grille des tableaux d'exister sans qu'un seul
    /// caractère soit ajouté au fichier (§3.1) : le `|` qui sépare deux
    /// cellules ne se dessine plus, mais son avance est calculée pour poser la
    /// colonne suivante exactement où elle doit tomber. Le crénage porte cette
    /// avance, la fonte infinitésimale annule celle du glyphe.
    static func hide(in storage: NSTextStorage, range: NSRange, advance: CGFloat) {
        guard range.length > 0 else { return }
        storage.addAttributes([
            .font: NSFont.systemFont(ofSize: hiddenFontSize),
            .foregroundColor: NSColor.clear,
            .kern: max(0, advance),
            .foveaMasked: true,
        ], range: range)
        storage.removeAttribute(.foveaRevealed, range: range)
    }

    /// Rend une plage invisible **sans réduire sa largeur ni sa hauteur**.
    ///
    /// Pour une ligne dont *tout* le contenu est un marqueur — le `---` d'un
    /// filet horizontal — le masquage ordinaire ferait s'effondrer la hauteur
    /// de ligne, puisque plus aucun caractère ne porterait la fonte normale. Le
    /// filet n'aurait alors nulle part où se dessiner.
    ///
    /// Ici la fonte reste celle du corps et seule la couleur devient
    /// transparente : la ligne garde sa place, et `DecorationPainter` y trace
    /// le trait.
    static func hideKeepingMetrics(in storage: NSTextStorage, range: NSRange, font: NSFont) {
        guard range.length > 0 else { return }
        storage.addAttributes([
            .font: font,
            .foregroundColor: NSColor.clear,
            .foveaMasked: true,
        ], range: range)
        storage.removeAttribute(.foveaRevealed, range: range)
    }

    /// Affiche une plage de marqueurs, en retrait : présente, jamais bruyante.
    ///
    /// Le texte porteur ne change pas de style — le mot reste gras pendant que
    /// ses `**` réapparaissent (§2.1).
    static func reveal(in storage: NSTextStorage, range: NSRange, font: NSFont) {
        guard range.length > 0 else { return }
        storage.addAttributes([
            .font: font,
            // §8 : sous le seuil AA, et assumé — ce sont des repères, pas du
            // contenu. Quand « Augmenter le contraste » est actif, l'utilisateur
            // a dit qu'il ne voulait pas de ce compromis.
            .foregroundColor: Accessibility.markerColor,
            .kern: 0,
            .foveaRevealed: true,
        ], range: range)
        storage.removeAttribute(.foveaMasked, range: range)
    }

    static func isMasked(_ storage: NSTextStorage, at location: Int) -> Bool {
        guard location >= 0, location < storage.length else { return false }
        return storage.attribute(.foveaMasked, at: location, effectiveRange: nil) != nil
    }

    /// La plage masquée contenant `location`, s'il y en a une.
    ///
    /// Utile à la suppression intelligente (§2.5) et aux tests, qui doivent
    /// pouvoir affirmer qu'une position donnée n'est *pas* dans du masqué.
    static func maskedRange(in storage: NSTextStorage, at location: Int) -> NSRange? {
        guard location >= 0, location < storage.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard storage.attribute(.foveaMasked, at: location, effectiveRange: &range) != nil else { return nil }
        return range
    }
}
