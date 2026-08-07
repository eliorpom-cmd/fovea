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
    static func html(from markdown: String, title: String, documentURL: URL?) -> String {
        let spans = MarkdownParser.parse(markdown).spans
        let body = HTMLWriter(source: markdown, spans: spans, documentURL: documentURL).run()
        return """
        <!doctype html>
        <html lang="fr">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body {
          max-width: 42rem; margin: 4rem auto; padding: 0 1.5rem;
          font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
          color: #1a1a1a; background: #fff;
          -webkit-text-size-adjust: 100%;
        }
        @media (prefers-color-scheme: dark) {
          body { color: #e8e8e8; background: #1c1c1e; }
          blockquote { border-color: #444; color: #a8a8a8; }
          code, pre { background: #2a2a2c; }
          hr { border-color: #3a3a3c; }
          a { color: inherit; }
        }
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
        let source = html(from: markdown, title: "", documentURL: documentURL)
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
            output.append("<p>\(inline(in: line))</p>")
        }
        closeLists(&listStack, into: &output)
        return output.joined(separator: "\n")
    }

    // MARK: - Inline

    /// Rend une plage de texte, en appliquant les constructions inline qu'elle
    /// contient. Le parcours va de gauche à droite, en sautant les marqueurs.
    private func inline(in range: NSRange) -> String {
        let text = source as NSString
        var output = ""
        var index = range.location

        while index < range.upperBound {
            if let span = innermostInline(at: index, within: range) {
                output += renderInline(span)
                index = span.range.upperBound
                continue
            }
            output += MarkdownExport.escape(String(UnicodeScalar(text.character(at: index)) ?? " "))
            index += 1
        }
        return output
    }

    private func renderInline(_ span: SyntaxSpan) -> String {
        switch span.kind {
        case .strong: "<strong>\(inline(in: span.content))</strong>"
        case .emphasis: "<em>\(inline(in: span.content))</em>"
        case .strikethrough: "<del>\(inline(in: span.content))</del>"
        case .inlineCode: "<code>\(MarkdownExport.escape((source as NSString).substring(with: span.content)))</code>"
        case .link(let destination):
            "<a href=\"\(MarkdownExport.escape(destination))\">\(inline(in: span.content))</a>"
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

    private func frontMatter(containing location: Int) -> SyntaxSpan? {
        spans.first {
            if case .frontMatter = $0.kind { return NSLocationInRange(location, $0.range) }
            return false
        }
    }

    /// La construction inline la plus intérieure qui commence exactement ici.
    private func innermostInline(at location: Int, within range: NSRange) -> SyntaxSpan? {
        spans
            .filter { $0.kind.revealScope == .innermostInline
                      && $0.range.location == location
                      && $0.range.upperBound <= range.upperBound }
            .max { $0.range.length < $1.range.length }
    }

    private func isNewline(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }
}
