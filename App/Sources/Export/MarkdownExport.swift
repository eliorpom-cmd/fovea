// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The §4.6 exports: standalone HTML, rich text, PDF.
///
/// # The only place where the AST is re-serialized
///
/// Everywhere else, Fovea only dresses up the source text (§3.1). Here it's
/// different, and it's safe: this writes to an **other** file. The markdown
/// document itself is never touched.
@MainActor
enum MarkdownExport {

    // MARK: - Standalone HTML

    /// A single file, inline CSS, images as `data:` URIs (§4.6).
    ///
    /// Standalone means what it says: the file opens in a browser without
    /// its image folder, can be emailed, and stays readable in ten years.
    /// `followingSystemAppearance` only applies to the standalone file,
    /// which opens in a browser: the browser also applies the
    /// **background**, so the dark variant holds up there. Rich text and
    /// PDF land on paper or in another app's document, where the background
    /// stays white: the dark variant there left nothing but unreadable
    /// light gray.
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
        <html lang="en">
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

    // MARK: - Rich text

    /// What `⌘⇧C` puts on the pasteboard (§4.6).
    ///
    /// In practice the most used export: pasted into Mail, Pages or Slack.
    /// It's produced from the HTML, because that's the only format all
    /// these apps read the same way.
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

// MARK: - HTML body writing

/// Translates the recognized constructs into HTML.
///
/// The walk happens **over the text**, not over a tree: the `SyntaxSpan`
/// values already give the ranges, and traversing them in order is enough.
/// This is also what guarantees the export shows exactly what the screen
/// showed.
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
            // The line range includes its terminator; this works without it.
            var content = line
            while content.length > 0, isNewline(text.character(at: content.upperBound - 1)) {
                content.length -= 1
            }
            index = line.upperBound
            if line.upperBound <= line.location { break }
            line = content

            // A code block is handled as a whole: its lines aren't
            // paragraphs.
            if let block = codeBlock(containing: line.location) {
                output.append(renderCodeBlock(block))
                index = max(index, block.range.upperBound)
                closeLists(&listStack, into: &output)
                continue
            }
            // Neither is a table. Without this case, each of its lines came
            // out as a paragraph, pipes included.
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
            // A paragraph wrapped at 80 characters stays **one** paragraph.
            // Line by line, each used to come out as its own `<p>`, with the
            // spacing of a full paragraph between them, and any construct
            // straddling the wrap point was lost, leaving its raw syntax on
            // screen.
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

    /// Renders a text range, applying the inline constructs it contains.
    /// The walk goes left to right, skipping markers.
    ///
    /// `deeperThan` is the AST depth of the construct currently being
    /// rendered: only its descendants are considered. Without this guard,
    /// `***bold***` looped forever: cmark gives the `emphasis` node and the
    /// `strong` node **the same** source range, so the emphasis's content is
    /// its own range, and it kept getting re-selected without ever
    /// advancing.
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

            // A backslash at the end of a line is a hard break: it isn't
            // written out, the `<br>` replaces it.
            if unit == 92, index + 1 < range.upperBound, isNewline(text.character(at: index + 1)) {
                index += 1
                continue
            }
            // In a paragraph, a line break is worth a space: it's the
            // browser that collapses it. Unless the author made it hard.
            if isNewline(unit) {
                output += isHardBreak(before: index) ? "<br>\n" : "\n"
                index += 1
                if unit == 13, index < range.upperBound, text.character(at: index) == 10 { index += 1 }
                continue
            }

            // A surrogate pair is copied **whole**. Converting the lone
            // UTF-16 unit to a `UnicodeScalar` used to fail on the high half
            // of an emoji, and every emoji came out as two spaces.
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

    /// An image becomes a `data:` URI: this is what makes the file
    /// **standalone** (§4.6). If it can't be found, the path is kept, which
    /// stays more useful than a broken image with no clue.
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

    // MARK: - Blocks

    private func renderCodeBlock(_ span: SyntaxSpan) -> String {
        let code = MarkdownExport.escape((source as NSString).substring(with: span.content))
        guard case .codeBlock(let language) = span.kind, let language, !language.isEmpty else {
            return "<pre><code>\(code)</code></pre>"
        }
        return "<pre><code class=\"language-\(MarkdownExport.escape(language))\">\(code)</code></pre>"
    }

    /// The table, with its header row and alignments.
    ///
    /// The geometry comes from the same read as the screen's: what's
    /// exported is therefore exactly what the grid showed, alignments
    /// included.
    private func renderTable(_ span: SyntaxSpan) -> String {
        guard case .table(let table) = span.kind, let table, let header = table.rows.first else {
            // Malformed table: the source, as-is, just like on screen (§6).
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
        // The `>` on the current line is a marker; the content is what's
        // left of the line after it.
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

    // MARK: - Construct lookup

    /// The line starting at `location`, without its terminator, and where
    /// the next one starts.
    private func line(at location: Int) -> (content: NSRange, next: Int) {
        let text = source as NSString
        let full = text.lineRange(for: NSRange(location: location, length: 0))
        var content = full
        while content.length > 0, isNewline(text.character(at: content.upperBound - 1)) {
            content.length -= 1
        }
        return (content, full.upperBound)
    }

    /// True if this line opens something other than the continuation of a
    /// paragraph.
    ///
    /// Used to reassemble a paragraph wrapped at 80 characters: subsequent
    /// lines are consumed as long as they continue it.
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

    /// The innermost inline construct that starts exactly here, among the
    /// descendants at depth `depth`.
    private func innermostInline(at location: Int,
                                 within range: NSRange,
                                 deeperThan depth: Int) -> SyntaxSpan? {
        spans
            .filter { $0.kind.revealScope == .innermostInline
                      && $0.range.location == location
                      && $0.range.upperBound <= range.upperBound
                      && $0.depth > depth }
            .min { lhs, rhs in
                // Longest first; at equal length, the outermost, so that
                // `***bold***` comes out as `<em><strong>` and not the
                // reverse.
                lhs.range.length != rhs.range.length
                    ? lhs.range.length > rhs.range.length
                    : lhs.depth < rhs.depth
            }
    }

    private func isNewline(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }

    /// Two spaces or a backslash at the end of a line: the break is hard.
    private func isHardBreak(before newline: Int) -> Bool {
        let text = source as NSString
        if newline >= 1, text.character(at: newline - 1) == 92 { return true }
        guard newline >= 2 else { return false }
        return text.character(at: newline - 1) == 32 && text.character(at: newline - 2) == 32
    }
}
