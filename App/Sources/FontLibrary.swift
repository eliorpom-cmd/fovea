// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit
import CoreText
import UniformTypeIdentifiers

/// Les polices que l'utilisateur apporte lui-même (§4.7).
///
/// # Pourquoi la portée `.process`
///
/// Enregistrer une police en portée `.user` l'installerait dans le système :
/// elle apparaîtrait dans Pages, dans Mail, partout, et son retrait passerait
/// par le Livre des polices. Ce n'est pas ce qu'on demande à un éditeur de
/// texte. En portée `.process`, la police n'existe que pendant que Fovea
/// tourne, **et le retrait est la suppression du fichier**. Rien à défaire,
/// rien à nettoyer si l'app disparaît.
///
/// Le prix à payer est qu'il faut ré-enregistrer à chaque lancement. C'est une
/// boucle sur quelques fichiers, faite avant la première fenêtre.
@MainActor
enum FontLibrary {

    /// Où vivent les fichiers déposés.
    ///
    /// `Application Support` et pas le bac à sable : l'app n'est pas
    /// sandboxée (§10), et ce dossier est celui que l'utilisateur peut ouvrir
    /// dans le Finder pour retirer une police à la main.
    static var folder: URL {
        if let folderOverride { return folderOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(AppConfig.name, isDirectory: true)
            .appendingPathComponent("Fonts", isDirectory: true)
    }

    /// Détourne la bibliothèque, pour les tests seulement.
    ///
    /// Sans cela, la suite écrirait de vraies polices dans le dossier de
    /// l'utilisateur et les y laisserait. Un test qui salit la machine sur
    /// laquelle il tourne finit toujours par ne plus être lancé.
    static var folderOverride: URL?

    static let acceptedExtensions = ["otf", "ttf", "ttc", "otc"]

    /// Les mêmes, pour le sélecteur de fichiers. `.font` couvre les deux
    /// familles et leurs collections, et laisse macOS reconnaître un fichier
    /// dont l'extension serait absente.
    static let acceptedContentTypes: [UTType] = [.font]

    // MARK: - Lancement

    /// Enregistre toutes les polices déposées. À appeler une fois, au démarrage,
    /// **avant** que la première fenêtre ne demande une fonte.
    static func registerAll() {
        for url in files() {
            register(url)
        }
    }

    /// Les familles apportées par l'utilisateur, triées.
    ///
    /// Recalculées depuis les fichiers plutôt que mémorisées : le dossier est
    /// ouvert à l'utilisateur, et une liste en cache mentirait dès qu'il y
    /// supprime un fichier.
    static func importedFamilies() -> [String] {
        Set(files().flatMap(familyNames(in:))).sorted()
    }

    // MARK: - Import

    enum ImportError: LocalizedError {
        case unreadable(String)
        case alreadyPresent(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "« \(name) » n'a pas pu être lu comme une police."
            case .alreadyPresent(let name): "« \(name) » est déjà dans votre bibliothèque."
            }
        }
    }

    /// Copie un fichier de police et l'enregistre immédiatement.
    ///
    /// - Returns: les familles ajoutées, pour que les réglages puissent
    ///   sélectionner la nouvelle tout de suite.
    @discardableResult
    static func importFont(at source: URL) throws -> [String] {
        let names = familyNames(in: source)
        guard !names.isEmpty else { throw ImportError.unreadable(source.lastPathComponent) }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ImportError.alreadyPresent(source.deletingPathExtension().lastPathComponent)
        }

        try FileManager.default.copyItem(at: source, to: destination)
        register(destination)
        // Le cache est indexé par (famille, taille) : sans purge, la nouvelle
        // famille ne serait vue qu'au prochain lancement.
        FontCache.shared.clear()
        return names
    }

    /// Retire une famille : on désenregistre, puis on supprime les fichiers qui
    /// la portent.
    static func remove(family: String) {
        for url in files() where familyNames(in: url).contains(family) {
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: url)
        }
        FontCache.shared.clear()
    }

    // MARK: - Détails

    private static func files() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { acceptedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// L'échec est silencieux, et c'est voulu : une police devenue illisible ne
    /// doit pas empêcher l'app de démarrer. Elle disparaît simplement de la
    /// liste, et le texte retombe sur la police système.
    private static func register(_ url: URL) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// Les familles contenues dans un fichier. Un `.ttc` en contient plusieurs.
    private static func familyNames(in url: URL) -> [String] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor] else { return [] }
        let names = descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
        }
        return Array(Set(names)).sorted()
    }
}
