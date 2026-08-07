// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Charge les images référencées par le document (§4.4).
///
/// # Le rendu sans attachement
///
/// Une image ne peut pas être un `NSTextAttachment` ici : un attachement
/// remplace un caractère, et le §3.1 interdit d'en insérer un. La source
/// `![alt](chemin)` doit rester intacte dans le tampon.
///
/// La solution tient en deux morceaux déjà en place :
///
/// 1. La ligne entière est **masquée à largeur nulle**, comme n'importe quel
///    marqueur, et son style de paragraphe reçoit un `minimumLineHeight` égal
///    à la hauteur d'affichage de l'image. La place est réservée sans qu'un
///    seul caractère ait été ajouté.
/// 2. `DecorationPainter` dessine l'image dans cette place.
///
/// Le curseur se comporte comme pour toute construction à portée ligne : entrer
/// sur la ligne fait réapparaître la source, en sortir remet l'image.
@MainActor
final class ImageStore {

    static let shared = ImageStore()

    /// Ce qu'on sait d'une image référencée.
    enum Entry {
        case loaded(NSImage)
        /// Le fichier n'existe pas, ou n'est pas une image lisible (§6).
        case missing
    }

    private var cache: [URL: Entry] = [:]

    /// Taille maximale chargée en mémoire. Au-delà, l'image est refusée plutôt
    /// que de faire gonfler l'app de plusieurs centaines de mégaoctets pour un
    /// document qu'on ne fait que relire (§6).
    private static let maximumBytes = 20 * 1024 * 1024

    // MARK: - Résolution

    /// Résout un lien markdown en URL de fichier.
    ///
    /// Les liens relatifs sont résolus **à côté du document**, ce qui est tout
    /// l'intérêt du §4.4 : le dossier peut être déplacé, commité ou envoyé sans
    /// que rien ne casse. Les URL distantes sont ignorées — un éditeur qui va
    /// chercher sur le réseau pendant la frappe est un éditeur qui se fige.
    static func resolve(_ source: String, relativeTo document: URL?) -> URL? {
        guard !source.isEmpty else { return nil }
        if let url = URL(string: source), url.scheme != nil {
            return url.isFileURL ? url : nil
        }
        let decoded = source.removingPercentEncoding ?? source
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        guard let document else { return nil }
        return document.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
    }

    // MARK: - Chargement

    func entry(for source: String, relativeTo document: URL?) -> Entry {
        guard let url = Self.resolve(source, relativeTo: document) else { return .missing }
        if let cached = cache[url] { return cached }

        let entry: Entry
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > Self.maximumBytes {
            entry = .missing
        } else if let image = NSImage(contentsOf: url), image.size.width > 0 {
            entry = .loaded(image)
        } else {
            entry = .missing
        }
        cache[url] = entry
        return entry
    }

    /// Oublie ce qui a été chargé.
    ///
    /// Appelé quand le document est enregistré ailleurs ou qu'une image est
    /// remplacée sur le disque : sans cela, l'ancienne version resterait à
    /// l'écran jusqu'à la fermeture de la fenêtre.
    func invalidate() {
        cache.removeAll(keepingCapacity: true)
    }

    // MARK: - Mise à l'échelle

    /// Hauteur d'affichage d'une image dans une colonne donnée.
    ///
    /// Bornée à la largeur de colonne (§6) et à une hauteur raisonnable : une
    /// capture d'écran verticale de téléphone, laissée à ses proportions,
    /// occuperait trois écrans et rendrait le document impraticable.
    static func displaySize(of image: NSImage, columnWidth: CGFloat) -> NSSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return .zero }

        let maximumHeight = columnWidth * 1.2
        var width = min(natural.width, columnWidth)
        var height = width * natural.height / natural.width
        if height > maximumHeight {
            height = maximumHeight
            width = height * natural.width / natural.height
        }
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    /// Hauteur réservée pour une image manquante : de quoi dessiner un cadre
    /// lisible avec son chemin, pas plus.
    static let missingPlaceholderHeight: CGFloat = 56
}
