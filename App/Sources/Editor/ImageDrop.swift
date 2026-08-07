// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit
import UniformTypeIdentifiers

/// Déposer ou coller une image (§4.4).
///
/// Le fichier est **copié à côté du document**, dans un sous-dossier dont le
/// nom est réglable, et le lien markdown écrit en **chemin relatif**. Relatif
/// et non absolu : c'est ce qui permet de déplacer le dossier, de le commiter
/// ou de l'envoyer sans que rien ne casse.
@MainActor
enum ImageDrop {

    /// Ce qu'il y a à insérer après un dépôt, ou `nil` si rien d'exploitable.
    struct Result {
        var markdown: String
    }

    static let acceptedTypes: [UTType] = [.fileURL, .png, .jpeg, .tiff, .gif, .heic, .webP, .image]

    // MARK: - Dépôt

    /// Traite un presse-papier de dépôt et renvoie le markdown à insérer.
    ///
    /// - Parameter document: l'emplacement du document ; sans lui, il n'y a pas
    ///   de « à côté » où copier, et le lien serait absolu ou cassé.
    static func handle(_ pasteboard: NSPasteboard, document: URL?) -> Result? {
        guard let document else { return unsavedDocumentWarning() }

        // 1. Des fichiers déposés depuis le Finder.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let images = urls.filter { isImage($0) }
            guard !images.isEmpty else { return nil }
            let links = images.compactMap { copy($0, nextTo: document) }
            guard !links.isEmpty else { return nil }
            return Result(markdown: links.joined(separator: "\n\n"))
        }

        // 2. Une image brute, collée depuis un autre logiciel : il n'y a pas de
        //    fichier, donc pas de nom. On en fabrique un daté.
        if let image = NSImage(pasteboard: pasteboard), let link = write(image, nextTo: document) {
            return Result(markdown: link)
        }
        return nil
    }

    // MARK: - Écriture

    /// Copie un fichier image et renvoie son lien markdown relatif.
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

    /// Écrit une image sans fichier d'origine, en PNG.
    ///
    /// PNG et non JPEG : ce qu'on colle dans un éditeur de texte est presque
    /// toujours une capture d'écran ou un schéma, que le JPEG abîmerait.
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

    // MARK: - Détails

    private static func assetsFolder(for document: URL) -> URL {
        document.deletingLastPathComponent()
            .appendingPathComponent(AppSettings.shared.assetsFolderName, isDirectory: true)
    }

    private static func ensure(_ folder: URL) -> Bool {
        (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
            || FileManager.default.fileExists(atPath: folder.path)
    }

    /// Un nom libre dans le dossier : déposer deux fois « capture.png » ne doit
    /// pas écraser la première.
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

    /// Le lien markdown, en chemin **relatif** au document.
    private static func link(to file: URL, from document: URL, alt: String) -> String {
        let folder = AppSettings.shared.assetsFolderName
        let relative = "\(folder)/\(file.lastPathComponent)"
        // Les espaces d'un nom de fichier casseraient le lien : markdown y
        // verrait la fin de la destination et le début d'un titre.
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

    /// Un document jamais enregistré n'a pas de « à côté ».
    ///
    /// Plutôt que d'écrire dans un dossier temporaire — que macOS balaie, et
    /// qui laisserait un lien cassé au prochain lancement — on le dit.
    private static func unsavedDocumentWarning() -> Result? {
        let alert = NSAlert()
        alert.messageText = "Enregistrez le document d'abord"
        alert.informativeText = """
            Les images sont copiées à côté du fichier et référencées en chemin \
            relatif. Tant que le document n'a pas d'emplacement, il n'y a pas \
            de « à côté ».
            """
        alert.addButton(withTitle: "D'accord")
        alert.runModal()
        return nil
    }
}
