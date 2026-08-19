// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit
import CoreText
import UniformTypeIdentifiers

/// Fonts the user brings in themselves (§4.7).
///
/// # Why the `.process` scope
///
/// Registering a font in `.user` scope would install it system-wide: it
/// would show up in Pages, in Mail, everywhere, and removing it would go
/// through Font Book. That's not what's expected of a text editor. In
/// `.process` scope, the font only exists while Fovea is running, **and
/// removal is just deleting the file**. Nothing to undo, nothing to clean up
/// if the app disappears.
///
/// The price to pay is that it must be re-registered at every launch. That's
/// a loop over a handful of files, done before the first window.
@MainActor
enum FontLibrary {

    /// Where the dropped files live.
    ///
    /// `Application Support`, not the sandbox: the app isn't sandboxed (§10),
    /// and this folder is the one the user can open in the Finder to remove a
    /// font by hand.
    static var folder: URL {
        if let folderOverride { return folderOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(AppConfig.name, isDirectory: true)
            .appendingPathComponent("Fonts", isDirectory: true)
    }

    /// Redirects the library, for tests only.
    ///
    /// Without this, the suite would write real fonts into the user's folder
    /// and leave them there. A test that dirties the machine it runs on
    /// always ends up not being run anymore.
    static var folderOverride: URL?

    static let acceptedExtensions = ["otf", "ttf", "ttc", "otc"]

    /// The same, for the file picker. `.font` covers both families and their
    /// collections, and lets macOS recognize a file whose extension might be
    /// missing.
    static let acceptedContentTypes: [UTType] = [.font]

    // MARK: - Launch

    /// Registers every dropped font. To be called once, at startup,
    /// **before** the first window asks for a font.
    static func registerAll() {
        for url in files() {
            register(url)
        }
    }

    /// The families brought in by the user, sorted.
    ///
    /// Recomputed from the files rather than cached: the folder is open to
    /// the user, and a cached list would lie as soon as they delete a file
    /// in it.
    static func importedFamilies() -> [String] {
        Set(files().flatMap(familyNames(in:))).sorted()
    }

    // MARK: - Import

    enum ImportError: LocalizedError {
        case unreadable(String)
        case alreadyPresent(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "\"\(name)\" couldn't be read as a font."
            case .alreadyPresent(let name): "\"\(name)\" is already in your library."
            }
        }
    }

    /// Copies a font file and registers it immediately.
    ///
    /// - Returns: the families added, so settings can select the new one
    ///   right away.
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
        // The cache is indexed by (family, size): without a purge, the new
        // family wouldn't be seen until the next launch.
        FontCache.shared.clear()
        return names
    }

    /// Removes a family: unregister, then delete the files that carry it.
    static func remove(family: String) {
        for url in files() where familyNames(in: url).contains(family) {
            CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: url)
        }
        FontCache.shared.clear()
    }

    // MARK: - Details

    private static func files() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { acceptedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Failure is silent, and that's deliberate: a font that has become
    /// unreadable must not prevent the app from starting. It simply
    /// disappears from the list, and text falls back to the system font.
    private static func register(_ url: URL) {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// The families contained in a file. A `.ttc` contains several.
    private static func familyNames(in url: URL) -> [String] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor] else { return [] }
        let names = descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
        }
        return Array(Set(names)).sorted()
    }
}
