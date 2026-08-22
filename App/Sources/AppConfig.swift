// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import Foundation

/// The app's identity, in a single place.
///
/// Unlike TBD, which carried three names depending on display width, "Fovea"
/// is short enough to serve everywhere: bundle, executable, Swift module,
/// Finder and the app menu. The values below must stay in agreement with
/// `project.yml` and `App/Info.plist`.
enum AppConfig {
    static let name = "Fovea"
    static let bundleIdentifier = "com.byelior.fovea"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// **Readable** extensions. `.txt` is accepted, but Fovea doesn't own it
    /// (see `LSHandlerRank` in Info.plist).
    static let readableExtensions = ["md", "markdown", "mdown", "mkd", "mdtext", "txt"]

    /// **Written** extension, always. See §5 of the spec.
    static let defaultExtension = "md"

    static let repositoryURL = URL(string: "https://github.com/byelior/fovea")!
}
