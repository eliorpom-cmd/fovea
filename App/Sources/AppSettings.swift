// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit
import Observation

/// Les préférences, adossées à `UserDefaults`.
///
/// Le §4.7 les répartit en trois onglets ; elles vivent toutes ici, dans un
/// seul objet observable, pour qu'un changement se propage à toutes les
/// fenêtres ouvertes sans qu'aucune n'ait à s'abonner à quoi que ce soit.
@MainActor
@Observable
final class AppSettings {

    static let shared = AppSettings()

    // MARK: - Apparence

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: "Système"
            case .light: "Clair"
            case .dark: "Sombre"
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

    /// `nil` = police système, c'est-à-dire SF Pro (§7).
    var bodyFontName: String? { didSet { store(bodyFontName, .bodyFontName); notify() } }
    var monoFontName: String? { didSet { store(monoFontName, .monoFontName); notify() } }
    var bodySize: Double = 16 { didSet { store(bodySize, .bodySize); notify() } }
    var lineHeightMultiple: Double = 1.5 { didSet { store(lineHeightMultiple, .lineHeight); notify() } }
    var columnWidthInCharacters: Int = 68 { didSet { store(columnWidthInCharacters, .columnWidth); notify() } }

    /// §4.3 : le seul endroit de l'app où la couleur est autorisée, et
    /// seulement sur demande explicite.
    var colorfulCodeBlocks = false { didSet { store(colorfulCodeBlocks, .colorfulCode); notify() } }

    // MARK: - Édition

    enum FocusUnit: String, CaseIterable, Identifiable {
        case sentence, paragraph
        var id: String { rawValue }
        var label: String {
            switch self {
            case .sentence: "La phrase"
            case .paragraph: "Le paragraphe"
            }
        }
    }

    var focusMode = false { didSet { store(focusMode, .focusMode); notify() } }
    var focusUnit: FocusUnit = .sentence { didSet { store(focusUnit.rawValue, .focusUnit); notify() } }

    /// **Désactivé par défaut** : le défilement normal est le défaut (§4.5).
    var typewriterMode = false { didSet { store(typewriterMode, .typewriter); notify() } }

    var showStatistics = true { didSet { store(showStatistics, .statistics); notify() } }
    var sessionWordGoal: Int = 0 { didSet { store(sessionWordGoal, .wordGoal); notify() } }

    /// Où la touche `/` ouvre le menu d'insertion de bloc (§4.5).
    ///
    /// Trois états et pas un interrupteur : « en début de ligne » était le
    /// comportement d'origine, et c'est celui qui privait du menu les gens à qui
    /// il sert le plus. « Partout » est donc le défaut, et le réglage reste pour
    /// qui écrit des chemins de fichiers à longueur de journée.
    enum SlashMenuScope: String, CaseIterable, Identifiable {
        case off, lineStart, anywhere
        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: "Jamais"
            case .lineStart: "En début de ligne"
            case .anywhere: "Partout"
            }
        }
    }

    var markdownShortcutsWhileTyping = true { didSet { store(markdownShortcutsWhileTyping, .shortcuts) } }
    var slashMenuScope: SlashMenuScope = .anywhere { didSet { store(slashMenuScope.rawValue, .slashMenuScope) } }
    var assetsFolderName = AppConfig.defaultAssetsFolderName { didSet { store(assetsFolderName, .assetsFolder) } }

    // MARK: - Diffusion aux fenêtres

    /// Émise quand un réglage qui touche au rendu change. Les contrôleurs
    /// d'édition s'y abonnent, plutôt que d'observer chaque propriété.
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

    // MARK: - Persistance

    private enum Key: String {
        case appearance, bodyFontName, monoFontName, bodySize, lineHeight, columnWidth
        case colorfulCode, focusMode, focusUnit, typewriter, statistics, wordGoal
        case shortcuts, slashMenu, slashMenuScope, assetsFolder
    }

    private let defaults = UserDefaults.standard
    /// Empêche les `didSet` de réécrire — et de diffuser — pendant le
    /// chargement initial.
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
        focusMode = read(.focusMode) as? Bool ?? false
        if let raw = read(.focusUnit) as? String, let value = FocusUnit(rawValue: raw) { focusUnit = value }
        typewriterMode = read(.typewriter) as? Bool ?? false
        showStatistics = read(.statistics) as? Bool ?? true
        sessionWordGoal = read(.wordGoal) as? Int ?? 0
        markdownShortcutsWhileTyping = read(.shortcuts) as? Bool ?? true
        if let raw = read(.slashMenuScope) as? String, let value = SlashMenuScope(rawValue: raw) {
            slashMenuScope = value
        } else if read(.slashMenu) as? Bool == false {
            // L'ancien interrupteur, respecté : qui avait coupé le menu ne doit
            // pas le voir revenir parce que le réglage a changé de forme.
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
