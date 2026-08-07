// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Toucher le contrôleur de documents avant tout le reste : c'est lui
        // qui répond à ⌘O, aux Récents et à la restauration de session, et il
        // doit exister avant qu'AppKit ne restaure les fenêtres.
        _ = NSDocumentController.shared
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
}
