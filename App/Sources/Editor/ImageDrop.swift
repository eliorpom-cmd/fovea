// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit
import UniformTypeIdentifiers

/// Drops or pastes an image (§4.4).
///
/// The file is **copied next to the document**, into a subfolder whose name
/// is configurable, and the markdown link is written as a **relative path**.
/// Relative, not absolute: this is what lets the folder be moved, committed
/// or sent without anything breaking.
@MainActor
enum ImageDrop {

    /// What there is to insert after a drop, or `nil` if nothing usable came
    /// out of it.
    struct Result {
        var markdown: String
    }

    static let acceptedTypes: [UTType] = [.fileURL, .png, .jpeg, .tiff, .gif, .heic, .webP, .image]

    // MARK: - Drop

    /// Processes a drop pasteboard and returns the markdown to insert.
    ///
    /// - Parameter document: the document's location; without it there is no
    ///   "next to" to copy into, and the link would be absolute or broken.
    static func handle(_ pasteboard: NSPasteboard, document: URL?) -> Result? {
        guard let document else { return unsavedDocumentWarning() }

        // 1. Files dropped from the Finder.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let images = urls.filter { isImage($0) }
            guard !images.isEmpty else { return nil }
            let links = images.compactMap { copy($0, nextTo: document) }
            guard !links.isEmpty else { return nil }
            return Result(markdown: links.joined(separator: "\n\n"))
        }

        // 2. A raw image, pasted from another app: there is no file, so no
        //    name. One is made up with a timestamp.
        if let image = NSImage(pasteboard: pasteboard), let link = write(image, nextTo: document) {
            return Result(markdown: link)
        }
        return nil
    }

    // MARK: - Writing

    /// Copies an image file and returns its relative markdown link.
    private static func copy(_ source: URL, nextTo document: URL) -> String? {
        let folder = assetsFolder(for: document)
        guard ensure(folder) else { return nil }

        let destination = uniqueURL(in: folder, preferredName: source.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            return nil
        }
        return link(to: destination, from: document, alt: source.deletingPathExtension().lastPathComponent)
    }

    /// Writes an image with no source file, as PNG.
    ///
    /// PNG, not JPEG: what gets pasted into a text editor is almost always a
    /// screenshot or a diagram, which JPEG would degrade.
    private static func write(_ image: NSImage, nextTo document: URL) -> String? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return nil }

        let folder = assetsFolder(for: document)
        guard ensure(folder) else { return nil }

        let stamp = Self.stampFormatter.string(from: Date())
        let destination = uniqueURL(in: folder, preferredName: "image-\(stamp).png")
        guard (try? data.write(to: destination)) != nil else { return nil }
        return link(to: destination, from: document, alt: "")
    }

    // MARK: - Details

    private static func assetsFolder(for document: URL) -> URL {
        document.deletingLastPathComponent()
            .appendingPathComponent(AppSettings.shared.assetsFolderName, isDirectory: true)
    }

    private static func ensure(_ folder: URL) -> Bool {
        (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
            || FileManager.default.fileExists(atPath: folder.path)
    }

    /// A free name in the folder: dropping "capture.png" twice must not
    /// overwrite the first one.
    private static func uniqueURL(in folder: URL, preferredName: String) -> URL {
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var candidate = folder.appendingPathComponent(preferredName)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(index).\(ext)")
            index += 1
        }
        return candidate
    }

    /// The markdown link, as a path **relative** to the document.
    private static func link(to file: URL, from document: URL, alt: String) -> String {
        let folder = AppSettings.shared.assetsFolderName
        let relative = "\(folder)/\(file.lastPathComponent)"
        // Spaces in a filename would break the link: markdown would read
        // them as the end of the destination and the start of a title.
        let encoded = relative.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? relative
        return "![\(alt)](\(encoded))"
    }

    private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// A document that has never been saved has no "next to".
    ///
    /// Rather than writing into a temporary folder (which macOS sweeps, and
    /// which would leave a broken link on the next launch), this is reported
    /// instead.
    private static func unsavedDocumentWarning() -> Result? {
        let alert = NSAlert()
        alert.messageText = "Save the document first"
        alert.informativeText = """
            Images are copied next to the file and referenced by relative \
            path. Until the document has a location, there is no "next to" \
            for it.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return nil
    }
}
