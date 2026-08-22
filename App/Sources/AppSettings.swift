// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit
import Observation

/// The preferences, backed by `UserDefaults`.
///
/// Four of them, in a single observable object, so a change propagates to
/// every open window without any of them having to subscribe to anything.
///
/// Four is what is left of seventeen, and they have no window: appearance,
/// the two fonts and the size are four items in the View menu. See
/// `AppDelegate` for why.
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

    // MARK: - Broadcasting to windows

    /// Posted when a setting that affects rendering changes. Editing
    /// controllers subscribe to it, rather than observing each property.
    static let didChange = Notification.Name("foveaSettingsDidChange")

    private func notify() {
        guard isLoaded else { return }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Line spacing and column width are **no longer adjustable**.
    ///
    /// They were two sliders that every reader had to form an opinion about
    /// before reading a line. 1.5 and 68 characters were their defaults and
    /// are good measures for running text; they are now simply the measures.
    var typography: EditorTypography {
        EditorTypography(bodyFontName: bodyFontName,
                         monoFontName: monoFontName,
                         bodySize: bodySize,
                         lineHeightMultiple: EditorTypography.default.lineHeightMultiple,
                         columnWidthInCharacters: EditorTypography.default.columnWidthInCharacters)
    }

    // MARK: - Persistence

    private enum Key: String {
        case appearance, bodyFontName, monoFontName, bodySize
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

        isLoaded = true
        NSApp?.appearance = appearance.nsAppearance
    }

    private func store(_ value: Any?, _ key: Key) {
        guard isLoaded else { return }
        defaults.set(value, forKey: key.rawValue)
    }
}
