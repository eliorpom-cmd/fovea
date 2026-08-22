// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit
import Observation

/// The preferences, backed by `UserDefaults`.
///
/// §4.7 splits them across three tabs; they all live here, in a single
/// observable object, so a change propagates to every open window without
/// any of them having to subscribe to anything.
@MainActor
@Observable
final class AppSettings {

    static let shared = AppSettings()

    // MARK: - Appearance

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var nsAppearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    var appearance: Appearance = .system {
        didSet {
            store(appearance.rawValue, .appearance)
            NSApp.appearance = appearance.nsAppearance
        }
    }

    /// `nil` = system font, i.e. SF Pro (§7).
    var bodyFontName: String? { didSet { store(bodyFontName, .bodyFontName); notify() } }
    var monoFontName: String? { didSet { store(monoFontName, .monoFontName); notify() } }
    var bodySize: Double = 16 { didSet { store(bodySize, .bodySize); notify() } }
    var lineHeightMultiple: Double = 1.5 { didSet { store(lineHeightMultiple, .lineHeight); notify() } }
    var columnWidthInCharacters: Int = 68 { didSet { store(columnWidthInCharacters, .columnWidth); notify() } }

    /// §4.3: the only place in the app where color is allowed, and only on
    /// explicit request.
    var colorfulCodeBlocks = false { didSet { store(colorfulCodeBlocks, .colorfulCode); notify() } }

    // MARK: - Editing

    /// Where the `/` key opens the block insertion menu (§4.5).
    ///
    /// Three states rather than a toggle: "at the start of a line" was the
    /// original behavior, and it's the one that denied the menu to the people
    /// it serves the most. "Everywhere" is therefore the default, and the
    /// setting remains for anyone who writes file paths all day long.
    enum SlashMenuScope: String, CaseIterable, Identifiable {
        case off, lineStart, anywhere
        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: "Never"
            case .lineStart: "At the Start of a Line"
            case .anywhere: "Everywhere"
            }
        }
    }

    var markdownShortcutsWhileTyping = true { didSet { store(markdownShortcutsWhileTyping, .shortcuts) } }
    var automaticPairs = true { didSet { store(automaticPairs, .automaticPairs) } }
    var slashMenuScope: SlashMenuScope = .anywhere { didSet { store(slashMenuScope.rawValue, .slashMenuScope) } }
    var assetsFolderName = AppConfig.defaultAssetsFolderName { didSet { store(assetsFolderName, .assetsFolder) } }

    // MARK: - Broadcasting to windows

    /// Posted when a setting that affects rendering changes. Editing
    /// controllers subscribe to it, rather than observing each property.
    static let didChange = Notification.Name("foveaSettingsDidChange")

    private func notify() {
        guard isLoaded else { return }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    var typography: EditorTypography {
        EditorTypography(bodyFontName: bodyFontName,
                         monoFontName: monoFontName,
                         bodySize: bodySize,
                         lineHeightMultiple: lineHeightMultiple,
                         columnWidthInCharacters: columnWidthInCharacters)
    }

    // MARK: - Persistence

    private enum Key: String {
        case appearance, bodyFontName, monoFontName, bodySize, lineHeight, columnWidth
        case colorfulCode
        case shortcuts, automaticPairs, slashMenu, slashMenuScope, assetsFolder
    }

    private let defaults = UserDefaults.standard
    /// Prevents `didSet` from writing back — and broadcasting — during
    /// initial loading.
    private var isLoaded = false

    private init() {
        let read = { (key: Key) in self.defaults.object(forKey: key.rawValue) }

        if let raw = read(.appearance) as? String, let value = Appearance(rawValue: raw) { appearance = value }
        bodyFontName = read(.bodyFontName) as? String
        monoFontName = read(.monoFontName) as? String
        bodySize = read(.bodySize) as? Double ?? 16
        lineHeightMultiple = read(.lineHeight) as? Double ?? 1.5
        columnWidthInCharacters = read(.columnWidth) as? Int ?? 68
        colorfulCodeBlocks = read(.colorfulCode) as? Bool ?? false
        markdownShortcutsWhileTyping = read(.shortcuts) as? Bool ?? true
        automaticPairs = read(.automaticPairs) as? Bool ?? true
        if let raw = read(.slashMenuScope) as? String, let value = SlashMenuScope(rawValue: raw) {
            slashMenuScope = value
        } else if read(.slashMenu) as? Bool == false {
            // The old toggle, honored: whoever had turned the menu off
            // shouldn't see it come back just because the setting changed
            // shape.
            slashMenuScope = .off
        }
        assetsFolderName = read(.assetsFolder) as? String ?? AppConfig.defaultAssetsFolderName

        isLoaded = true
        NSApp?.appearance = appearance.nsAppearance
    }

    private func store(_ value: Any?, _ key: Key) {
        guard isLoaded else { return }
        defaults.set(value, forKey: key.rawValue)
    }
}
