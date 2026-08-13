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
    ///
    /// # Ce que la première version ne faisait pas
    ///
    /// Elle promettait les titres et les listes — c'est écrit en tête de ce
    /// fichier — et ne traitait que l'inline : gras, italique, barré, code,
    /// lien. Coller un article de blog rendait donc ses titres en paragraphes
    /// ordinaires et ses listes en lignes nues, ce qui est précisément la perte
    /// que la conversion existe pour éviter.
    ///
    /// La lecture se fait maintenant **par paragraphe** : chacun demande à son
    /// style ce qu'il est — une liste le dit par ses `textLists`, un titre par
    /// sa taille rapportée à celle du corps — puis son contenu passe par la
    /// conversion inline d'origine, inchangée.
    static func convert(_ rich: NSAttributedString) -> String {
        let text = rich.string as NSString
        let body = dominantFontSize(rich)
        var blocks: [Block] = []

        var cursor = 0
        while cursor < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            cursor = max(paragraph.upperBound, cursor + 1)

            // Le terminateur ne fait pas partie du contenu.
            var range = paragraph
            while range.length > 0, isNewline(text.character(at: range.upperBound - 1)) {
                range.length -= 1
            }

            let block = describe(rich, paragraph: range, body: body)
            let content = inline(rich, in: block.content, ignoringBold: block.isHeading)
            // Une ligne vide sépare deux blocs ; elle n'en est pas un.
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            blocks.append(Block(prefix: block.prefix, content: content, isListItem: block.isListItem))
        }

        var output = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                // Deux items de liste se suivent ligne à ligne ; tout le reste
                // demande la ligne vide qui sépare deux blocs en markdown.
                output += (block.isListItem && blocks[index - 1].isListItem) ? "\n" : "\n\n"
            }
            output += block.prefix + block.content
        }
        return normaliseBlankLines(output)
    }

    private struct Block {
        var prefix: String
        var content: String
        var isListItem: Bool
    }

    /// La conversion des attributs inline d'une portée : celle d'origine, à la
    /// portée près.
    private static func inline(_ rich: NSAttributedString, in whole: NSRange,
                               ignoringBold: Bool = false) -> String {
        guard whole.length > 0 else { return "" }
        var output = ""

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
                // Un titre est déjà gras en markdown : y ajouter des étoiles
                // donnerait `# **Le titre**`, deux fois la même intention.
                if traits.contains(.boldFontMask), !ignoringBold { wrapped = "**" + wrapped + "**" }
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
        return output
    }

    // MARK: - Ce qu'un paragraphe est

    /// Le préfixe markdown d'un paragraphe, et la portée de son contenu.
    private static func describe(_ rich: NSAttributedString, paragraph: NSRange, body: CGFloat)
        -> (prefix: String, content: NSRange, isListItem: Bool, isHeading: Bool) {
        guard paragraph.length > 0 else { return ("", paragraph, false, false) }
        let style = rich.attribute(.paragraphStyle, at: paragraph.location,
                                   effectiveRange: nil) as? NSParagraphStyle

        // Une liste se déclare : `NSTextList` est ce que l'importateur HTML
        // pose sur un `<ul>` ou un `<ol>`, et son imbrication se lit au nombre
        // de listes empilées.
        if let lists = style?.textLists, !lists.isEmpty {
            let indent = String(repeating: "  ", count: max(0, lists.count - 1))
            let marker = lists.last.map { isOrdered($0) ? "1. " : "- " } ?? "- "
            return (indent + marker, withoutListMarker(rich, in: paragraph), true, false)
        }

        // Un titre se mesure. La comparaison porte sur la **plus petite**
        // taille du paragraphe : un seul mot agrandi au milieu d'une phrase ne
        // doit pas la transformer en titre.
        if body > 0, let smallest = smallestFontSize(rich, in: paragraph) {
            let ratio = smallest / body
            let level = ratio >= 1.7 ? 1 : ratio >= 1.4 ? 2 : ratio >= 1.15 ? 3 : 0
            if level > 0 {
                return (String(repeating: "#", count: level) + " ", paragraph, false, true)
            }
        }
        return ("", paragraph, false, false)
    }

    /// La taille de police la plus représentée, prise pour celle du corps.
    ///
    /// Elle ne peut pas être devinée : un site en 14 px et un autre en 18 px
    /// donnent des titres de tailles absolues très différentes. Ce qui est
    /// stable, c'est le **rapport** entre un titre et le texte courant, et
    /// c'est donc le texte courant qu'il faut identifier — le plus long, par
    /// construction.
    private static func dominantFontSize(_ rich: NSAttributedString) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        rich.enumerateAttribute(.font, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            weights[font.pointSize, default: 0] += range.length
        }
        return weights.max { $0.value < $1.value }?.key ?? 0
    }

    private static func smallestFontSize(_ rich: NSAttributedString, in range: NSRange) -> CGFloat? {
        var smallest: CGFloat?
        rich.enumerateAttribute(.font, in: range) { value, _, _ in
            guard let font = value as? NSFont else { return }
            smallest = smallest.map { min($0, font.pointSize) } ?? font.pointSize
        }
        return smallest
    }

    /// Une liste numérotée, ou à puces ?
    private static func isOrdered(_ list: NSTextList) -> Bool {
        switch list.markerFormat {
        case .decimal, .octal,
             .lowercaseAlpha, .uppercaseAlpha,
             .lowercaseLatin, .uppercaseLatin,
             .lowercaseRoman, .uppercaseRoman:
            return true
        default:
            return false
        }
    }

    /// La portée du texte d'un item, **sans la puce que l'importateur y a
    /// écrite**.
    ///
    /// `NSAttributedString` ne se contente pas de poser un `NSTextList` : il
    /// écrit aussi la marque dans le texte, tabulée. La laisser donnerait
    /// `- •\tUn item` — la puce de markdown suivie de celle du HTML.
    private static func withoutListMarker(_ rich: NSAttributedString, in paragraph: NSRange) -> NSRange {
        let text = rich.string as NSString
        var start = paragraph.location
        let end = paragraph.upperBound

        func skipBlanks() {
            while start < end, isBlank(text.character(at: start)) { start += 1 }
        }
        skipBlanks()

        let marked = start
        // Une puce, ou un nombre suivi de son délimiteur.
        if start < end, "•◦▪·-*\u{2022}".utf16.contains(text.character(at: start)) {
            start += 1
        } else {
            var digits = start
            while digits < end, (48...57).contains(text.character(at: digits)) { digits += 1 }
            guard digits > start, digits < end else {
                return NSRange(location: marked, length: end - marked)
            }
            // `NSAttributedString` écrit « 1\t », sans délimiteur. Le point ou
            // la parenthèse restent acceptés — d'autres sources en posent.
            let delimiter = text.character(at: digits)
            let numbered = delimiter == 46 || delimiter == 41
            let candidate = numbered ? digits + 1 : digits
            // **La tabulation est le discriminant.** Un nombre suivi d'une
            // simple espace peut être le début du texte — « 2026 fut une
            // année » — et le manger serait pire que garder une puce.
            let isMarker = candidate < end
                && (text.character(at: candidate) == 9 || (numbered && isBlank(text.character(at: candidate))))
            guard isMarker else { return NSRange(location: marked, length: end - marked) }
            start = candidate
        }
        guard start > marked, start < end, isBlank(text.character(at: start)) else {
            return NSRange(location: marked, length: end - marked)
        }
        skipBlanks()
        return NSRange(location: start, length: end - start)
    }

    private static func isBlank(_ unit: unichar) -> Bool {
        unit == 32 || unit == 9 || unit == 160
    }

    private static func isNewline(_ unit: unichar) -> Bool {
        unit == 10 || unit == 13 || unit == 0x2028 || unit == 0x2029
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
