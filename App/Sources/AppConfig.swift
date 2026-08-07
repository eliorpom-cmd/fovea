// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// Identité de l'app, en un seul endroit.
///
/// Contrairement à TBD qui portait trois noms selon la largeur d'affichage,
/// « Fovea » est assez court pour servir partout : bundle, exécutable, module
/// Swift, Finder et menu de l'app. Les valeurs ci-dessous doivent rester
/// d'accord avec `project.yml` et `App/Info.plist`.
enum AppConfig {
    static let name = "Fovea"
    static let bundleIdentifier = "com.byelior.fovea"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Extensions **lues**. `.txt` est accepté mais Fovea n'en est pas le
    /// propriétaire (voir `LSHandlerRank` dans Info.plist).
    static let readableExtensions = ["md", "markdown", "mdown", "mkd", "mdtext", "txt"]

    /// Extension **écrite**, toujours. Voir §5 du cahier des charges.
    static let defaultExtension = "md"

    /// Dossier où sont copiées les images déposées (§4.4). Réglable.
    static let defaultAssetsFolderName = "assets"

    static let repositoryURL = URL(string: "https://github.com/byelior/fovea")!
}
