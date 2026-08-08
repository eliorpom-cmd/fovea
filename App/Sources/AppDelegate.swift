// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// `@MainActor` : tout ce que fait ce delegate touche AppKit, et les
/// sélecteurs de menu sont appelés depuis la boucle d'événements principale.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Toucher le contrôleur de documents avant tout le reste : c'est lui
        // qui répond à ⌘O, aux Récents et à la restauration de session, et il
        // doit exister avant qu'AppKit ne restaure les fenêtres.
        _ = NSDocumentController.shared

        // Les polices apportées par l'utilisateur (§4.7) sont enregistrées en
        // portée `.process` : elles n'existent que pendant que Fovea tourne, ce
        // qui impose de recommencer à chaque lancement — et avant que la
        // première fenêtre ne réclame une fonte.
        FontLibrary.registerAll()

        // La proposition attend que l'app soit posée : affichée avant que la
        // première fenêtre existe, l'alerte apparaîtrait devant un écran vide.
        Task { @MainActor in DefaultHandler.offerOnceIfNeeded() }
    }

    // MARK: - Commandes globales
    //
    // Elles vivent ici plutôt que dans le contrôleur de fenêtre : elles doivent
    // répondre même sans document ouvert, et le delegate est le dernier maillon
    // de la chaîne de répondeurs.

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.present()
    }

    @objc func makeDefaultMarkdownEditor(_ sender: Any?) {
        Task { await DefaultHandler.makeDefault() }
    }

    @objc func openRepository(_ sender: Any?) {
        NSWorkspace.shared.open(AppConfig.repositoryURL)
    }

    /// Sans ce réglage, relancer l'app depuis le Dock avec une fenêtre déjà
    /// ouverte n'ouvre rien du tout — l'utilisateur clique et rien ne se passe.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        !hasVisibleWindows
    }

    /// L'app survit à sa dernière fenêtre, comme TextEdit et Pages : fermer un
    /// document n'est pas quitter, et le `⌘N` suivant doit rester immédiat.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(makeDefaultMarkdownEditor(_:)) {
            // Cochée quand c'est déjà le cas : l'entrée dit l'état plutôt que
            // de laisser l'utilisateur cliquer pour savoir.
            menuItem.state = DefaultHandler.isDefault ? .on : .off
        }
        return true
    }
}
