// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Les exports du §4.6 : HTML autonome, texte riche, PDF.
///
/// # Le seul endroit où l'AST est re-sérialisé
///
/// Partout ailleurs, Fovea ne fait qu'habiller le texte source (§3.1). Ici
/// c'est différent, et c'est sans danger : on écrit dans un **autre** fichier.
/// Le document markdown, lui, n'est jamais touché.
@MainActor
enum MarkdownExport {

    // MARK: - HTML autonome

    /// Un seul fichier, CSS en ligne, images en `data:` (§4.6).
    ///
    /// Autonome veut dire ce qu'il dit : le fichier s'ouvre dans un navigateur
    /// sans son dossier d'images, s'envoie par courriel, et se lit dans dix ans.
    /// `followingSystemAppearance` ne vaut que pour le fichier autonome, qui
    /// s'ouvre dans un navigateur — celui-ci applique aussi le **fond**, donc
    /// la variante sombre s'y tient. Le texte riche et le PDF atterrissent sur
    /// du papier ou dans le document d'une autre app, où le fond reste blanc :
    /// la variante sombre n'y laissait qu'un gris clair illisible.
    static func html(from markdown: String,
                     title: String,
                     documentURL: URL?,
                     followingSystemAppearance: Bool = true) -> String {
        let spans = MarkdownParser.parse(markdown).spans
        let body = HTMLWriter(source: markdown, spans: spans, documentURL: documentURL).run()
        let dark = """
        @media (prefers-color-scheme: dark) {
          body { color: #e8e8e8; background: #1c1c1e; }
          blockquote { border-color: #444; color: #a8a8a8; }
          code, pre { background: #2a2a2c; }
          hr { border-color: #3a3a3c; }
          a { color: inherit; }
        }
        """
        return """
        <!doctype html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: \(followingSystemAppearance ? "light dark" : "light"); }
        body {
          max-width: 42rem; margin: 4rem auto; padding: 0 1.5rem;
          font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
          color: #1a1a1a; background: #fff;
          -webkit-text-size-adjust: 100%;
        }
        \(followingSystemAppearance ? dark : "")
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 2em 0 .6em; font-weight: 600; }
        h1 { font-size: 1.85em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
        p, ul, ol, blockquote, pre { margin: 0 0 1.1em; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 2px solid #ddd; color: #555; }
        code { font: .9em/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
               background: rgba(127,127,127,.12); padding: .1em .35em; border-radius: 4px; }
        pre { background: rgba(127,127,127,.10); padding: 1em; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        hr { border: 0; border-top: 1px solid #ddd; margin: 2.5em 0; }
        a { color: inherit; text-underline-offset: .15em; }
        table { border-collapse: collapse; width: 100%; margin: 0 0 1.1em; }
        th, td { border: 1px solid rgba(127,127,127,.3); padding: .4em .6em; text-align: left; }
        ul li input[type=checkbox] { margin-right: .4em; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: - Texte riche

    /// Ce que `⌘⇧C` met dans le presse-papier (§4.6).
    ///
    /// En pratique l'export le plus utilisé : on colle dans Mail, Pages ou
    /// Slack. Il est produit depuis le HTML, parce que c'est le seul format que
    /// toutes ces apps savent lire de la même façon.
    static func richText(from markdown: String, documentURL: URL?) -> NSAttributedString? {
        let source = html(from: markdown, title: "", documentURL: documentURL,
                          followingSystemAppearance: false)
        return try? NSAttributedString(
            data: Data(source.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }
}

// MARK: - Écriture du corps HTML

/// Traduit les constructions repérées en HTML.
///
/// Le parcours se fait **sur le texte**, pas sur un arbre : les `SyntaxSpan`
/// donnent déjà les plages, et les traverser dans l'ordre suffit. C'est aussi
/// ce qui garantit que l'export montre exactement ce que l'écran montrait.
@MainActor
private struct HTMLWriter {

    let source: String
    let spans: [SyntaxSpan]
    let documentURL: URL?

    func run() -> String {
        let text = source as NSString
        var output: [String] = []
        var listStack: [String] = []
        var index = 0

        while index < text.length {
            var line = text.lineRange(for: NSRange(location: index, length: 0))
            // La plage de ligne inclut son terminateur ; on travaille sans.
            var content = line
            while content.length > 0, isNewline(text.character(at: content.upperBound - 1)) {
                content.length -= 1
            }
            index = line.upperBound
            if line.upperBound <= line.location { break }
            line = content

            // Un bloc de code est traité d'un tenant : ses lignes ne sont pas
            // des paragraphes.
            if let block = codeBlock(containing: line.location) {
                output.append(renderCodeBlock(block))
                index = max(index, block.range.upperBound)
                closeLists(&listStack, into: &output)
                continue
            }
            // Un tableau non plus. Sans ce cas, chacune de ses lignes ressortait
            // en paragraphe, pipes compris.
            if let block = table(containing: line.location) {
                closeLists(&listStack, into: &output)
                output.append(renderTable(block))
                index = max(index, block.range.upperBound)
                continue
            }
            if frontMatter(containing: line.location) != nil { continue }

            let raw = text.substring(with: line)
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                closeLists(&listStack, into: &output)
                continue
            }

            if let span = span(onLine: line, matching: { if case .thematicBreak = $0.kind { return true } else { return false } }) {
                _ = span
                closeLists(&listStack, into: &output)
                output.append("<hr>")
                continue
            }
            if let span = span(onLine: line, matching: { if case .heading = $0.kind { return true } else { return false } }),
               case .heading(let level) = span.kind {
                closeLists(&listStack, into: &output)
                output.append("<h\(level)>\(inline(in: span.content))</h\(level)>")
                continue
            }
            if let span = span(onLine: line, matching: { if case .taskItem = $0.kind { return true } else { return false } }),
               case .taskItem(_, let checked) = span.kind {
                openList("ul", &listStack, into: &output)
                let box = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")>"
                output.append("<li>\(box)\(inline(in: span.content))</li>")
                continue
            }
            if let span = span(onLine: line, matching: { if case .listItem = $0.kind { return true } else { return false } }),
               case .listItem(let marker) = span.kind {
                openList(isOrdered(marker) ? "ol" : "ul", &listStack, into: &output)
                output.append("<li>\(inline(in: span.content))</li>")
                continue
            }
            if let span = span(containing: line.location, matching: { if case .blockQuote = $0.kind { return true } else { return false } }) {
                closeLists(&listStack, into: &output)
                output.append("<blockquote>\(inline(in: quoteContent(of: span, line: line)))</blockquote>")
                continue
            }

            closeLists(&listStack, into: &output)
            // Un paragraphe coupé à 80 signes reste **un** paragraphe. Ligne à
            // ligne, chacune ressortait en `<p>` — avec l'espacement d'un
            // paragraphe entier entre deux — et toute construction à cheval sur
            // la coupure était perdue, laissant sa syntaxe brute à l'écran.
            var paragraph = line
            while index < text.length {
                let following = self.line(at: index)
                if startsAnotherBlock(following.content) { break }
                paragraph.length = following.content.upperBound - paragraph.location
                index = following.next
            }
            output.append("<p>\(inline(in: paragraph))</p>")
        }
        closeLists(&listStack, into: &output)
        return output.joined(separator: "\n")
    }

    // MARK: - Inline

    /// Rend une plage de texte, en appliquant les constructions inline qu'elle
    /// contient. Le parcours va de gauche à droite, en sautant les marqueurs.
    ///
    /// `deeperThan` est la profondeur AST de la construction qu'on est en train
    /// de rendre : on ne considère que ses descendants. Sans ce garde-fou,
    /// `***gras***` bouclait à l'infini — cmark donne au nœud `emphasis` et au
    /// nœud `strong` **la même** plage source, donc le contenu de l'emphase est
    /// sa propre plage, et on la re-sélectionnait sans jamais avancer.
    private func inline(in range: NSRange, deeperThan depth: Int = Int.min) -> String {
        let text = source as NSString
        var output = ""
        var index = range.location

        while index < range.upperBound {
            if let span = innermostInline(at: index, within: range, deeperThan: depth) {
                output += renderInline(span)
                index = max(span.range.upperBound, index + 1)
                continue
            }
            let unit = text.character(at: index)

            // Une barre inverse en fin de ligne est une coupure dure : elle ne
            // s'écrit pas, c'est le `<br>` qui la remplace.
            if unit == 92, index + 1 < range.upperBound, isNewline(text.character(at: index + 1)) {
                index += 1
                continue
            }
            // Dans un paragraphe, une coupure de ligne vaut une espace — c'est
            // le navigateur qui la replie. Sauf si l'auteur l'a rendue dure.
            if isNewline(unit) {
                output += isHardBreak(before: index) ? "<br>\n" : "\n"
                index += 1
                if unit == 13, index < range.upperBound, text.character(at: index) == 10 { index += 1 }
                continue
            }

            // Une paire de substitution se copie **entière**. Convertir l'unité
            // UTF-16 seule en `UnicodeScalar` échouait sur la moitié haute d'un
            // emoji, et chaque emoji ressortait en deux espaces.
            var step = 1
            if unit >= 0xD800, unit <= 0xDBFF, index + 1 < range.upperBound { step = 2 }
            output += MarkdownExport.escape(text.substring(with: NSRange(location: index, length: step)))
            index += step
        }
        return output
    }

    private func renderInline(_ span: SyntaxSpan) -> String {
        switch span.kind {
        case .strong: "<strong>\(inline(in: span.content, deeperThan: span.depth))</strong>"
        case .emphasis: "<em>\(inline(in: span.content, deeperThan: span.depth))</em>"
        case .strikethrough: "<del>\(inline(in: span.content, deeperThan: span.depth))</del>"
        case .inlineCode: "<code>\(MarkdownExport.escape((source as NSString).substring(with: span.content)))</code>"
        case .link(let destination):
            "<a href=\"\(MarkdownExport.escape(destination))\">\(inline(in: span.content, deeperThan: span.depth))</a>"
        case .image(let src, let alt):
            "<img src=\"\(embeddedSource(src))\" alt=\"\(MarkdownExport.escape(alt))\">"
        case .footnoteReference(let identifier):
            "<sup>\(MarkdownExport.escape(identifier))</sup>"
        default:
            MarkdownExport.escape((source as NSString).substring(with: span.range))
        }
    }

    /// Une image devient une `data:` URI : c'est ce qui rend le fichier
    /// **autonome** (§4.6). Si elle est introuvable, on garde le chemin, qui
    /// reste plus utile qu'une image cassée sans indice.
    private func embeddedSource(_ source: String) -> String {
        guard let url = ImageStore.resolve(source, relativeTo: documentURL),
              let data = try? Data(contentsOf: url), data.count < 8 * 1024 * 1024 else {
            return MarkdownExport.escape(source)
        }
        let type = mimeType(for: url.pathExtension)
        return "data:\(type);base64,\(data.base64EncodedString())"
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        default: "application/octet-stream"
        }
    }

    // MARK: - Blocs

    private func renderCodeBlock(_ span: SyntaxSpan) -> String {
        let code = MarkdownExport.escape((source as NSString).substring(with: span.content))
        guard case .codeBlock(let language) = span.kind, let language, !language.isEmpty else {
            return "<pre><code>\(code)</code></pre>"
        }
        return "<pre><code class=\"language-\(MarkdownExport.escape(language))\">\(code)</code></pre>"
    }

    /// Le tableau, avec son en-tête et ses alignements.
    ///
    /// La géométrie vient de la même lecture que celle de l'écran : ce qui est
    /// exporté est donc exactement ce que la grille montrait, alignements
    /// compris.
    private func renderTable(_ span: SyntaxSpan) -> String {
        guard case .table(let table) = span.kind, let table, let header = table.rows.first else {
            // Tableau malformé : la source, telle quelle, comme à l'écran (§6).
            return "<pre><code>\(MarkdownExport.escape((source as NSString).substring(with: span.range)))</code></pre>"
        }

        func cells(_ row: MarkdownTable.Row, tag: String) -> String {
            row.cells.enumerated().map { column, cell in
                let style = switch column < table.alignments.count ? table.alignments[column] : .leading {
                case MarkdownTable.Alignment.center: " style=\"text-align:center\""
                case .trailing: " style=\"text-align:right\""
                case .leading: ""
                }
                return "<\(tag)\(style)>\(inline(in: cell.content))</\(tag)>"
            }.joined()
        }

        var rows = ["<thead><tr>\(cells(header, tag: "th"))</tr></thead>"]
        let body = table.rows.dropFirst().map { "<tr>\(cells($0, tag: "td"))</tr>" }
        if !body.isEmpty { rows.append("<tbody>\(body.joined())</tbody>") }
        return "<table>\(rows.joined())</table>"
    }

    private func quoteContent(of span: SyntaxSpan, line: NSRange) -> NSRange {
        // Le `>` de la ligne courante est un marqueur ; le contenu est ce qui
        // reste de la ligne après lui.
        for marker in span.markers where NSIntersectionRange(marker, line).length > 0 {
            let start = marker.upperBound
            return NSRange(location: start, length: max(0, line.upperBound - start))
        }
        return line
    }

    private func openList(_ tag: String, _ stack: inout [String], into output: inout [String]) {
        if stack.last == tag { return }
        closeLists(&stack, into: &output)
        stack.append(tag)
        output.append("<\(tag)>")
    }

    private func closeLists(_ stack: inout [String], into output: inout [String]) {
        while let tag = stack.popLast() { output.append("</\(tag)>") }
    }

    private func isOrdered(_ marker: SyntaxSpan.ListMarker) -> Bool {
        if case .ordered = marker { return true }
        return false
    }

    // MARK: - Recherche de constructions

    /// La ligne qui commence à `location`, sans son terminateur, et l'endroit
    /// où commence la suivante.
    private func line(at location: Int) -> (content: NSRange, next: Int) {
        let text = source as NSString
        let full = text.lineRange(for: NSRange(location: location, length: 0))
        var content = full
        while content.length > 0, isNewline(text.character(at: content.upperBound - 1)) {
            content.length -= 1
        }
        return (content, full.upperBound)
    }

    /// Vrai si cette ligne ouvre autre chose que la suite d'un paragraphe.
    ///
    /// Sert à recoller un paragraphe coupé à 80 signes : on avale les lignes
    /// suivantes tant qu'elles le continuent.
    private func startsAnotherBlock(_ line: NSRange) -> Bool {
        let text = source as NSString
        if line.length == 0 { return true }
        if text.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if codeBlock(containing: line.location) != nil { return true }
        if table(containing: line.location) != nil { return true }
        if frontMatter(containing: line.location) != nil { return true }
        if span(containing: line.location,
                matching: { if case .blockQuote = $0.kind { return true } else { return false } }) != nil {
            return true
        }
        return span(onLine: line) {
            switch $0.kind {
            case .thematicBreak, .heading, .taskItem, .listItem, .footnoteDefinition: true
            default: false
            }
        } != nil
    }

    private func span(onLine line: NSRange, matching predicate: (SyntaxSpan) -> Bool) -> SyntaxSpan? {
        spans.first { predicate($0) && NSIntersectionRange($0.range, line).length > 0 && $0.range.location >= line.location }
    }

    private func span(containing location: Int, matching predicate: (SyntaxSpan) -> Bool) -> SyntaxSpan? {
        spans.first { predicate($0) && NSLocationInRange(location, $0.range) }
    }

    private func codeBlock(containing location: Int) -> SyntaxSpan? {
        spans.first {
            if case .codeBlock = $0.kind { return NSLocationInRange(location, $0.range) }
            return false
        }
    }

    private func table(containing location: Int) -> SyntaxSpan? {
        spans.first {
            if case .table = $0.kind { return NSLocationInRange(location, $0.range) }
            return false
        }
    }

    private func frontMatter(containing location: Int) -> SyntaxSpan? {
        spans.first {
            if case .frontMatter = $0.kind { return NSLocationInRange(location, $0.range) }
            return false
        }
    }

    /// La construction inline la plus intérieure qui commence exactement ici,
    /// parmi les descendantes de la profondeur `depth`.
    private func innermostInline(at location: Int,
                                 within range: NSRange,
                                 deeperThan depth: Int) -> SyntaxSpan? {
        spans
            .filter { $0.kind.revealScope == .innermostInline
                      && $0.range.location == location
                      && $0.range.upperBound <= range.upperBound
                      && $0.depth > depth }
            .min { lhs, rhs in
                // La plus longue d'abord ; à longueur égale, la plus extérieure,
                // pour que `***gras***` sorte `<em><strong>` et non l'inverse.
                lhs.range.length != rhs.range.length
                    ? lhs.range.length > rhs.range.length
                    : lhs.depth < rhs.depth
            }
    }

    private func isNewline(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }

    /// Deux espaces ou une barre inverse en fin de ligne : la coupure est dure.
    private func isHardBreak(before newline: Int) -> Bool {
        let text = source as NSString
        if newline >= 1, text.character(at: newline - 1) == 92 { return true }
        guard newline >= 2 else { return false }
        return text.character(at: newline - 1) == 32 && text.character(at: newline - 2) == 32
    }
}
