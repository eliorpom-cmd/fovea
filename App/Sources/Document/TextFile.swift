// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// Lecture et écriture du fichier texte, sans AppKit — donc testable.
///
/// Ce type porte la promesse du §5 du cahier des charges : **ce que
/// l'utilisateur n'a pas touché ressort octet pour octet**. Rien ici ne
/// normalise, ne rogne ni ne reformate quoi que ce soit.
enum TextFile {

    /// Le style de fin de ligne trouvé à l'ouverture, à restituer tel quel.
    enum LineEnding: String, Sendable {
        case lf = "\n"
        case crlf = "\r\n"
        /// Mac OS classique. Quasi disparu, mais un fichier qui en contient
        /// doit ressortir comme il est entré.
        case cr = "\r"

        /// Nouveau document : LF, la convention d'à peu près tout aujourd'hui.
        static let `default` = LineEnding.lf
    }

    struct Contents: Sendable {
        /// Le texte, **toujours normalisé en LF en mémoire**.
        ///
        /// C'est une commodité d'édition, pas une réécriture : `NSTextStorage`
        /// et `swift-markdown` comptent tous les deux les lignes en LF, et un
        /// CRLF dans le tampon ferait diverger leurs index. Le style d'origine
        /// est conservé dans `lineEnding` et restitué à l'écriture.
        var text: String
        var lineEnding: LineEnding
        /// L'encodage lu. Fovea écrit **toujours** en UTF-8 (§5) ; ce champ ne
        /// sert qu'à prévenir l'utilisateur quand une conversion aura lieu.
        var sourceEncoding: String.Encoding
        var hadBOM: Bool
    }

    enum ReadError: LocalizedError {
        case binary
        case undecodable

        var errorDescription: String? {
            switch self {
            case .binary:
                return "Ce fichier n'est pas du texte."
            case .undecodable:
                return "Impossible de lire ce fichier comme du texte."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .binary:
                return "Il contient des données binaires. Son extension est peut-être trompeuse."
            case .undecodable:
                return "Son encodage n'a pas pu être identifié."
            }
        }
    }

    // MARK: - Lecture

    static func read(_ data: Data) throws -> Contents {
        let (payload, hadBOM, bomEncoding) = stripBOM(data)

        // Un octet nul ne peut pas apparaître dans du texte valide sur un octet.
        // Sans ce garde-fou, un binaire renommé `.md` s'ouvrirait en un
        // mégaoctet de charabia (§6).
        //
        // L'UTF-16 est justement plein d'octets nuls — d'où l'exemption quand
        // une BOM UTF-16 l'annonce explicitement. Sans BOM, un UTF-16 sera
        // refusé comme binaire : c'est le compromis assumé, personne n'écrit
        // du markdown en UTF-16 sans BOM.
        let isDeclaredUTF16 = bomEncoding == .utf16LittleEndian || bomEncoding == .utf16BigEndian
        if !isDeclaredUTF16, payload.prefix(8192).contains(0) { throw ReadError.binary }

        let encoding: String.Encoding
        let text: String
        if let bomEncoding, let decoded = String(data: payload, encoding: bomEncoding) {
            encoding = bomEncoding
            text = decoded
        } else if let utf8 = String(data: payload, encoding: .utf8) {
            encoding = .utf8
            text = utf8
        } else if let guessed = guessLegacyEncoding(payload) {
            encoding = guessed.encoding
            text = guessed.text
        } else {
            throw ReadError.undecodable
        }

        return Contents(text: normalizeToLF(text),
                        lineEnding: detectLineEnding(text),
                        sourceEncoding: encoding,
                        hadBOM: hadBOM)
    }

    // MARK: - Écriture

    /// UTF-8 sans BOM, toujours (§5). Le style de fin de ligne d'origine est
    /// rétabli au dernier moment, sur le texte qui vivait en LF en mémoire.
    static func write(text: String, lineEnding: LineEnding) -> Data {
        let restored = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        return Data(restored.utf8)
    }

    // MARK: - Détails

    /// Le **premier** terminateur rencontré fait foi. Un fichier mixte — ça
    /// existe, notamment après une fusion git bâclée — sera uniformisé à
    /// l'enregistrement, et c'est le seul cas où Fovea touche à ce qu'elle n'a
    /// pas édité. L'alternative serait de mémoriser le style ligne par ligne,
    /// pour un fichier déjà cassé.
    static func detectLineEnding(_ text: String) -> LineEnding {
        var iterator = text.unicodeScalars.makeIterator()
        var previous: Unicode.Scalar?
        while let scalar = iterator.next() {
            if scalar == "\n" { return previous == "\r" ? .crlf : .lf }
            if previous == "\r" { return .cr }
            previous = scalar
        }
        return previous == "\r" ? .cr : .default
    }

    static func normalizeToLF(_ text: String) -> String {
        // `text.contains("\r")` serait faux : Swift compare des **graphèmes**,
        // et `\r\n` en est un seul, distinct de `\r`. Un fichier Windows
        // passait donc au travers de la normalisation, puis voyait chacun de
        // ses `\n` re-préfixé à l'enregistrement — un `\r` de plus par ligne, à
        // chaque sauvegarde. Le parcours se fait donc sur les scalaires.
        guard text.unicodeScalars.contains("\r") else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func stripBOM(_ data: Data) -> (Data, Bool, String.Encoding?) {
        let boms: [([UInt8], String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for (marker, encoding) in boms where data.starts(with: marker) {
            return (data.dropFirst(marker.count), true, encoding)
        }
        return (data, false, nil)
    }

    /// Dernier recours, pour les fichiers écrits avant qu'UTF-8 ne s'impose.
    /// Latin-1 accepte n'importe quelle suite d'octets, donc il vient en
    /// dernier : il ne doit jamais masquer un encodage qui aurait mieux marché.
    private static func guessLegacyEncoding(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        for encoding: String.Encoding in [.windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return (text, encoding)
            }
        }
        return nil
    }
}
