// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Les réglages d'accessibilité du système, en **un seul point d'entrée** (§8).
///
/// Un seul point d'entrée, et pas un `NSWorkspace.shared.accessibilityDisplay…`
/// disséminé : c'est la convention de FreePark, et elle tient pour la même
/// raison. Un réglage lu à dix endroits finit toujours par être oublié au
/// onzième, et le onzième est celui qui casse.
@MainActor
enum Accessibility {

    /// « Réduire les animations ».
    ///
    /// Rend `nil` quand le réglage est actif : le changement d'état s'applique
    /// quand même, seul le mouvement disparaît. C'est la distinction qui
    /// compte — une animation coupée ne doit jamais devenir une fonction
    /// coupée.
    static func duration(_ normal: TimeInterval) -> TimeInterval? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : normal
    }

    /// Anime, ou applique directement si les animations sont réduites.
    static func animate(_ normal: TimeInterval,
                        changes: () -> Void,
                        completion: (@Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration(normal) ?? 0
            context.allowsImplicitAnimation = true
            changes()
        } completionHandler: {
            guard let completion else { return }
            completion()
        }
    }

    /// « Augmenter le contraste ».
    static var prefersIncreasedContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// La couleur des marqueurs révélés (§2.1).
    ///
    /// `label/tertiary` est **sous le seuil AA**, et c'est assumé : ce sont des
    /// éléments de repérage, pas du contenu — le mot reste gras pendant que ses
    /// `**` réapparaissent, et c'est le mot qui porte le sens. Mais quand
    /// « Augmenter le contraste » est actif, l'utilisateur a dit qu'il ne
    /// voulait pas de ce compromis : on passe à `label/secondary`.
    static var markerColor: NSColor {
        prefersIncreasedContrast ? Theme.NS.labelSecondary : Theme.NS.labelTertiary
    }

    /// Le voile du mode focus (§4.5).
    ///
    /// Plus il est opaque, moins le texte inactif se lit. À contraste renforcé
    /// on l'allège : atténuer est une aide à la concentration, pas un moyen de
    /// rendre le reste du document illisible.
    static var focusVeilOpacity: CGFloat {
        prefersIncreasedContrast ? 0.55 : 0.74
    }

    // MARK: - Rôles lus par VoiceOver (§8)

    /// Ce qu'une construction **est**, en une phrase lisible à voix haute.
    ///
    /// Le §8 pose le problème que la plupart des éditeurs WYSIWYG ignorent : si
    /// les `##` sont invisibles à l'écran, ils n'en sont pas moins lus. « dièse
    /// dièse espace Architecture » n'a aucun sens à l'oral, et c'est pourtant
    /// exactement ce que produit un tampon où la syntaxe est restée.
    ///
    /// La sortie est donc « Titre, niveau 2 » posé sur le **contenu**, pendant
    /// que les marqueurs, eux, portent un libellé vide.
    static func roleDescription(of kind: SyntaxSpan.Kind) -> String? {
        switch kind {
        case .heading(let level): "Titre, niveau \(level)"
        case .strong: "Gras"
        case .emphasis: "Italique"
        case .strikethrough: "Barré"
        case .inlineCode: "Code"
        case .link(let destination): "Lien vers \(destination)"
        case .image(_, let alt): alt.isEmpty ? "Image" : "Image, \(alt)"
        case .blockQuote: "Citation"
        case .listItem: "Élément de liste"
        case .taskItem(_, let checked): checked ? "Tâche faite" : "Tâche à faire"
        case .thematicBreak: "Séparateur"
        case .codeBlock(let language): language.map { "Bloc de code, \($0)" } ?? "Bloc de code"
        case .table: "Tableau"
        case .frontMatter: "Métadonnées"
        case .footnoteReference(let identifier): "Note \(identifier)"
        }
    }
}
