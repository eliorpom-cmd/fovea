// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit
import UniformTypeIdentifiers

/// Faire de Fovea l'éditeur markdown par défaut du système.
///
/// Une app à documents qui ne s'installe pas comme gestionnaire par défaut
/// oblige à passer par « Ouvrir avec » à chaque fichier. C'est le genre de
/// friction qu'on ne remarque qu'après l'avoir supprimée.
///
/// La demande passe par `NSWorkspace`, donc par le dialogue système : c'est
/// macOS qui décide, pas l'app. Écrire directement dans la base LaunchServices
/// serait à la fois fragile et impoli.
@MainActor
enum DefaultHandler {

    /// Les types que Fovea revendique. `public.plain-text` n'en fait pas
    /// partie : Fovea sait lire un `.txt` mais n'a aucune raison de voler
    /// l'association de TextEdit (voir `LSHandlerRank` dans Info.plist).
    static var claimedTypes: [UTType] {
        [UTType("net.daringfireball.markdown")].compactMap { $0 }
    }

    /// Vrai si Fovea est déjà l'app par défaut pour le markdown.
    static var isDefault: Bool {
        guard let type = claimedTypes.first,
              let current = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return Bundle(url: current)?.bundleIdentifier == AppConfig.bundleIdentifier
    }

    /// Demande au système de faire de Fovea l'app par défaut.
    ///
    /// macOS affiche sa propre confirmation. Un refus n'est pas une erreur :
    /// c'est une réponse, et l'app n'insiste pas.
    static func makeDefault() async {
        let appURL = Bundle.main.bundleURL
        for type in claimedTypes {
            try? await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
        }
    }

    // MARK: - Proposition au premier lancement

    private static let hasAskedKey = "hasAskedToBecomeDefaultHandler"

    /// Propose une fois, et une seule.
    ///
    /// Une app qui redemande à chaque lancement se fait refuser par principe.
    /// La proposition est aussi disponible en permanence dans le menu, pour
    /// ceux qui changent d'avis.
    static func offerOnceIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: hasAskedKey), !isDefault else { return }
        defaults.set(true, forKey: hasAskedKey)

        let alert = NSAlert()
        alert.messageText = "Ouvrir les fichiers Markdown avec \(AppConfig.name) ?"
        alert.informativeText = """
            Les fichiers .md, .markdown et .mdown s'ouvriront dans \(AppConfig.name) \
            d'un double-clic. Vous pourrez revenir en arrière à tout moment depuis le \
            menu \(AppConfig.name).
            """
        alert.addButton(withTitle: "Utiliser \(AppConfig.name)")
        alert.addButton(withTitle: "Plus tard")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await makeDefault() }
    }
}
