// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// `@MainActor`: everything this delegate does touches AppKit, and menu
/// selectors are called from the main event loop.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Touch the document controller before everything else: it's the one
        // that responds to ⌘O, to Recents and to session restoration, and it
        // must exist before AppKit restores windows.
        _ = NSDocumentController.shared

        // Fonts brought in by the user (§4.7) are registered in `.process`
        // scope: they only exist while Fovea is running, which requires
        // starting over at every launch — and before the first window asks
        // for a font.
        FontLibrary.registerAll()

        // The prompt waits for the app to settle: shown before the first
        // window exists, the alert would appear in front of an empty screen.
        Task { @MainActor in DefaultHandler.offerOnceIfNeeded() }
    }

    // MARK: - Global commands
    //
    // They live here rather than in the window controller: they must respond
    // even without an open document, and the delegate is the last link in
    // the responder chain.

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.present()
    }

    @objc func makeDefaultMarkdownEditor(_ sender: Any?) {
        Task { await DefaultHandler.makeDefault() }
    }

    /// Without this setting, relaunching the app from the Dock with no
    /// window open opens nothing at all — the user clicks and nothing
    /// happens.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        !hasVisibleWindows
    }

    /// The app survives its last window, like TextEdit and Pages: closing a
    /// document isn't quitting, and the next `⌘N` must stay instant.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(makeDefaultMarkdownEditor(_:)) {
            // Checked when it's already the case: the item states the
            // condition instead of making the user click to find out.
            menuItem.state = DefaultHandler.isDefault ? .on : .off
        }
        return true
    }
}
