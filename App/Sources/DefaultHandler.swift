// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit
import UniformTypeIdentifiers

/// Makes Fovea the system's default markdown editor.
///
/// A document-based app that doesn't install itself as the default handler
/// forces the user through "Open With" for every file. That's the kind of
/// friction one only notices after it's gone.
///
/// The request goes through `NSWorkspace`, and therefore through the system
/// dialog: it's macOS that decides, not the app. Writing directly into the
/// LaunchServices database would be both fragile and impolite.
@MainActor
enum DefaultHandler {

    /// The types Fovea claims. `public.plain-text` isn't among them: Fovea
    /// can read a `.txt` but has no reason to steal TextEdit's association
    /// (see `LSHandlerRank` in Info.plist).
    static var claimedTypes: [UTType] {
        [UTType("net.daringfireball.markdown")].compactMap { $0 }
    }

    /// True if Fovea is already the default app for markdown.
    static var isDefault: Bool {
        guard let type = claimedTypes.first,
              let current = NSWorkspace.shared.urlForApplication(toOpen: type) else { return false }
        return Bundle(url: current)?.bundleIdentifier == AppConfig.bundleIdentifier
    }

    /// Asks the system to make Fovea the default app.
    ///
    /// macOS shows its own confirmation. A refusal isn't an error: it's an
    /// answer, and the app doesn't insist.
    static func makeDefault() async {
        let appURL = Bundle.main.bundleURL
        for type in claimedTypes {
            try? await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type)
        }
    }

    // MARK: - Prompt on first launch

    private static let hasAskedKey = "hasAskedToBecomeDefaultHandler"

    /// Offers once, and only once.
    ///
    /// An app that asks again at every launch gets refused on principle. The
    /// offer is also permanently available in the menu, for anyone who
    /// changes their mind.
    static func offerOnceIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: hasAskedKey), !isDefault else { return }
        defaults.set(true, forKey: hasAskedKey)

        let alert = NSAlert()
        alert.messageText = "Open Markdown files with \(AppConfig.name)?"
        alert.informativeText = """
            .md, .markdown and .mdown files will open in \(AppConfig.name) with a \
            double-click. You can change this back at any time from the \
            \(AppConfig.name) menu.
            """
        alert.addButton(withTitle: "Use \(AppConfig.name)")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await makeDefault() }
    }
}
