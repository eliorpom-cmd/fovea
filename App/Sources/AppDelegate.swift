// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
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

        // The prompt waits for the app to settle: shown before the first
        // window exists, the alert would appear in front of an empty screen.
        Task { @MainActor in DefaultHandler.offerOnceIfNeeded() }
    }

    // MARK: - Global commands
    //
    // They live here rather than in the window controller: they must respond
    // even without an open document, and the delegate is the last link in
    // the responder chain.

    @objc func makeDefaultMarkdownEditor(_ sender: Any?) {
        Task { await DefaultHandler.makeDefault() }
    }

    // MARK: - The four settings (§4.7)
    //
    // # Why there is no settings window
    //
    // There were seventeen settings across three tabs, then four in one pane,
    // and a whole window — plus the app's only SwiftUI file — to hold them.
    // Four settings do not need a window; they need four menu items, which is
    // where macOS puts appearance, font and size in every app that has them.
    //
    // `⌘,` is gone with it. An app with nothing to configure should not open
    // an empty window when the key is pressed.

    /// The theme travels in the item's `representedObject`: one action for
    /// the three, and the same string the menu reads back to place its check.
    @objc func setAppearance(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let value = AppSettings.Appearance(rawValue: raw) else { return }
        AppSettings.shared.appearance = value
    }

    /// Which of the two fonts the panel is about to change.
    ///
    /// `NSFontPanel` is a single shared panel and it reports its choice
    /// through one selector, so the target has to be remembered between
    /// opening it and hearing back.
    private enum FontTarget { case body, code }
    private var fontTarget: FontTarget = .body

    /// Opens **the system font panel**, rather than a picker of our own.
    ///
    /// The list of installed families runs to several hundred entries, and a
    /// menu of several hundred entries is not a menu. Apple already ships the
    /// UI for this, with search, favourites and a preview, and it costs
    /// nothing here: the panel reports back through `changeFont(_:)`.
    @objc func chooseBodyFont(_ sender: Any?) { presentFontPanel(for: .body) }
    @objc func chooseCodeFont(_ sender: Any?) { presentFontPanel(for: .code) }

    private func presentFontPanel(for target: FontTarget) {
        fontTarget = target
        let settings = AppSettings.shared
        let current: NSFont = switch target {
        case .body: settings.typography.body
        case .code: settings.typography.codeBlock
        }
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(current, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    /// What the font panel sends back.
    ///
    /// Only the **family** is kept for code: its size follows the body's, so
    /// that inline code never bulges the line it sits in. For the body, the
    /// size comes along, since choosing 18 pt in the panel and getting 16 is
    /// the panel lying about what it just did.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let settings = AppSettings.shared
        switch fontTarget {
        case .body:
            let chosen = sender.convert(settings.typography.body)
            settings.bodyFontName = chosen.familyName
            settings.bodySize = min(max(chosen.pointSize, 11), 32)
        case .code:
            settings.monoFontName = sender.convert(settings.typography.codeBlock).familyName
        }
    }

    /// The size, on the two keys every reader already presses.
    @objc func increaseTextSize(_ sender: Any?) { nudgeSize(by: 1) }
    @objc func decreaseTextSize(_ sender: Any?) { nudgeSize(by: -1) }

    @objc func resetTextSize(_ sender: Any?) {
        AppSettings.shared.bodySize = EditorTypography.default.bodySize
    }

    private func nudgeSize(by delta: Double) {
        let settings = AppSettings.shared
        settings.bodySize = min(max(settings.bodySize + delta, 11), 32)
    }

    /// Without this setting, relaunching the app from the Dock with no
    /// window open opens nothing at all — the user clicks and nothing
    /// happens.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        !hasVisibleWindows
    }

    /// **Launching alone opens the picker, not a blank page.**
    ///
    /// A document app creates an untitled document when it starts with
    /// nothing to show. That is right for an app you write *in*; this one is
    /// opened to look at a file that already exists, and an empty page is a
    /// question — "what now?" — where the picker is the answer.
    ///
    /// `⌘N` still makes a new document, for the times that is what is wanted.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    /// The app survives its last window, like TextEdit and Pages: closing a
    /// document isn't quitting, and the next `⌘N` must stay instant.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(makeDefaultMarkdownEditor(_:)):
            // Checked when it's already the case: the item states the
            // condition instead of making the user click to find out.
            menuItem.state = DefaultHandler.isDefault ? .on : .off

        case #selector(setAppearance(_:)):
            // The menu is where the current theme is now read, so it has to
            // show it rather than just offer the three.
            menuItem.state = (menuItem.representedObject as? String)
                == AppSettings.shared.appearance.rawValue ? .on : .off

        case #selector(increaseTextSize(_:)):
            return AppSettings.shared.bodySize < 32
        case #selector(decreaseTextSize(_:)):
            return AppSettings.shared.bodySize > 11
        case #selector(resetTextSize(_:)):
            return AppSettings.shared.bodySize != EditorTypography.default.bodySize

        default:
            break
        }
        return true
    }
}
