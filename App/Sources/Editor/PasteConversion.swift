// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Le collage (§2.5).
///
/// Coller depuis un navigateur, Pages ou Notion apporte du HTML ou du RTF. Le
/// laisser tomber en texte brut perdrait les titres, les listes et les liens
/// que l'utilisateur voyait à l'écran une seconde plus tôt — dans un éditeur
/// markdown, c'est la conversion qui est le comportement attendu, pas le
/// contraire.
///
/// L'ordre d'examen du presse-papier est celui du §2.5 :
///
/// 1. du markdown → collé tel quel ;
/// 2. du HTML ou du RTF → converti ;
/// 3. une image → écrite à côté du document et référencée ;
/// 4. du texte brut → inséré tel quel.
@MainActor
enum PasteConversion {

    /// Ce qu'il faut réellement insérer pour un presse-papier donné.
    ///
    /// - Returns: `nil` quand `NSTextView` doit faire son travail habituel.
    static func markdown(from pasteboard: NSPasteboard) -> String? {
        // 1. Du texte brut qui *est* déjà du markdown structuré. Le convertir
        //    depuis sa version HTML le ferait passer par un aller-retour
        //    inutile, et perdrait la forme exacte des marqueurs — `_` deviendrait
        //    `*`, ce que le §5 interdit.
        if let plain = pasteboard.string(forType: .string), looksLikeMarkdown(plain) {
            return plain
        }

        // 2. Du texte riche. `NSAttributedString` sait lire HTML comme RTF ;
        //    la conversion travaille ensuite sur les attributs, sans jamais
        //    toucher au HTML lui-même — analyser du HTML à la main serait une
        //    source de bugs sans fin.
        for type in [NSPasteboard.PasteboardType.html, .rtf, .rtfd] {
            guard let data = pasteboard.data(forType: type),
                  let rich = attributedString(from: data, type: type) else { continue }
            return convert(rich)
        }
        return nil
    }

    /// Vrai si le texte porte déjà des marques de structure markdown.
    ///
    /// Volontairement prudent : une phrase ordinaire ne doit pas être prise
    /// pour du markdown, mais un document markdown ne doit jamais subir de
    /// conversion. Le doute profite au texte brut, qui est sans risque.
    static func looksLikeMarkdown(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("#"), trimmed.dropFirst(trimmed.prefix { $0 == "#" }.count).hasPrefix(" ") { return true }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("> ") { return true }
            if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().hasPrefix(" ") { return true }
            if trimmed.contains("**") || trimmed.contains("](") { return true }
        }
        return false
    }

    // MARK: - Conversion du texte riche

    /// Traduit une chaîne attribuée en markdown.
    ///
    /// La traduction se fait sur les **attributs** — graisse, italique, lien,
    /// chasse fixe, style de paragraphe — parce que ce sont eux qui portent
    /// l'intention. Un balayage du HTML raterait tout ce que le site a fait
    /// avec du CSS, et se noierait dans ce qu'il a fait avec des `<div>`.
    static func convert(_ rich: NSAttributedString) -> String {
        var output = ""
        let whole = NSRange(location: 0, length: rich.length)

        rich.enumerateAttributes(in: whole) { attributes, range, _ in
            var fragment = (rich.string as NSString).substring(with: range)
            guard !fragment.isEmpty else { return }

            // Les blancs de bord ne doivent pas se retrouver **à l'intérieur**
            // des marqueurs : `** gras **` n'est pas du gras pour cmark.
            let leading = String(fragment.prefix { $0 == " " || $0 == "\n" })
            let trailing = String(fragment.reversed().prefix { $0 == " " || $0 == "\n" }.reversed())
            fragment = String(fragment.dropFirst(leading.count).dropLast(trailing.count))
            guard !fragment.isEmpty else {
                output += leading + trailing
                return
            }

            let font = attributes[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let isMonospaced = font?.isFixedPitch ?? false

            var wrapped = escapeMarkdown(fragment)
            if isMonospaced {
                // Le code inline n'admet pas d'autre formatage à l'intérieur, et
                // ne s'échappe pas : ce qui est entre backticks est littéral.
                wrapped = "`" + fragment + "`"
            } else {
                if traits.contains(.boldFontMask) { wrapped = "**" + wrapped + "**" }
                if traits.contains(.italicFontMask) { wrapped = "*" + wrapped + "*" }
                if let style = attributes[.strikethroughStyle] as? Int, style != 0 {
                    wrapped = "~~" + wrapped + "~~"
                }
            }
            if let link = linkDestination(attributes[.link]) {
                wrapped = "[" + wrapped + "](" + link + ")"
            }
            output += leading + wrapped + trailing
        }
        return normaliseBlankLines(output)
    }

    // MARK: - Détails

    private static func attributedString(from data: Data,
                                         type: NSPasteboard.PasteboardType) -> NSAttributedString? {
        let documentType: NSAttributedString.DocumentType = switch type {
        case .html: .html
        case .rtf: .rtf
        default: .rtfd
        }
        return try? NSAttributedString(
            data: data,
            options: [.documentType: documentType, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
    }

    private static func linkDestination(_ value: Any?) -> String? {
        switch value {
        case let url as URL: url.absoluteString
        case let string as String: string
        default: nil
        }
    }

    /// Protège les caractères qui auraient un sens en markdown.
    ///
    /// Sans cela, coller un texte contenant « 2 * 3 * 4 » depuis une page web
    /// produirait de l'italique là où il n'y avait qu'une multiplication.
    private static func escapeMarkdown(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if "*_`[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Trois sauts de ligne ou plus n'ont pas de sens en markdown : deux
    /// séparent déjà deux blocs. Le HTML des sites en produit beaucoup.
    private static func normaliseBlankLines(_ text: String) -> String {
        var result = text
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
