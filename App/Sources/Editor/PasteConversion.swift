// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// Pasting (§2.5).
///
/// Pasting from a browser, Pages or Notion brings in HTML or RTF. Letting
/// it fall back to plain text would lose the headings, lists and links the
/// user was looking at a second earlier — in a markdown editor, conversion
/// is the expected behavior, not the exception.
///
/// The order in which the pasteboard is examined is the one from §2.5:
///
/// 1. markdown → pasted as is;
/// 2. HTML or RTF → converted;
/// 3. an image → written next to the document and referenced;
/// 4. plain text → inserted as is.
@MainActor
enum PasteConversion {

    /// What should actually be inserted for a given pasteboard.
    ///
    /// - Returns: `nil` when `NSTextView` should do its usual work.
    static func markdown(from pasteboard: NSPasteboard) -> String? {
        // 1. Plain text that *is* already structured markdown. Converting
        //    it from its HTML version would send it through a pointless
        //    round-trip, and would lose the exact shape of the markers —
        //    `_` would become `*`, which §5 forbids.
        if let plain = pasteboard.string(forType: .string), looksLikeMarkdown(plain) {
            return plain
        }

        // 2. Rich text. `NSAttributedString` can read HTML as well as RTF;
        //    the conversion then works on the attributes, never touching
        //    the HTML itself — parsing HTML by hand would be an endless
        //    source of bugs.
        for type in [NSPasteboard.PasteboardType.html, .rtf, .rtfd] {
            guard let data = pasteboard.data(forType: type),
                  let rich = attributedString(from: data, type: type) else { continue }
            return convert(rich)
        }
        return nil
    }

    /// True if the text already carries markdown structure marks.
    ///
    /// Deliberately cautious: an ordinary sentence must not be mistaken for
    /// markdown, but a markdown document must never go through conversion.
    /// The benefit of the doubt goes to plain text, which carries no risk.
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

    // MARK: - Rich text conversion

    /// Translates an attributed string into markdown.
    ///
    /// The translation works on the **attributes** — weight, italic, link,
    /// fixed pitch, paragraph style — because they are what carries the
    /// intent. Scanning the HTML would miss everything the site did with
    /// CSS, and would drown in whatever it did with `<div>`s.
    ///
    /// # What the first version did not do
    ///
    /// It promised headings and lists — that is written at the top of this
    /// file — and only handled inline: bold, italic, strikethrough, code,
    /// link. Pasting a blog post therefore rendered its headings as
    /// ordinary paragraphs and its lists as bare lines, which is exactly
    /// the loss conversion exists to avoid.
    ///
    /// Reading now happens **paragraph by paragraph**: each one asks its
    /// style what it is — a list says so through its `textLists`, a
    /// heading through its size relative to the body's — then its content
    /// goes through the original inline conversion, unchanged.
    static func convert(_ rich: NSAttributedString) -> String {
        let text = rich.string as NSString
        let body = dominantFontSize(rich)
        var blocks: [Block] = []

        var cursor = 0
        while cursor < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            cursor = max(paragraph.upperBound, cursor + 1)

            // The terminator is not part of the content.
            var range = paragraph
            while range.length > 0, isNewline(text.character(at: range.upperBound - 1)) {
                range.length -= 1
            }

            let block = describe(rich, paragraph: range, body: body)
            let content = inline(rich, in: block.content,
                                 ignoringBold: block.isHeading, ignoringCode: block.isCode)
            // A blank line separates two blocks; it is not one itself.
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            blocks.append(Block(prefix: block.prefix, content: content,
                                isListItem: block.isListItem, isCode: block.isCode))
        }

        var output = ""
        for (index, block) in blocks.enumerated() {
            let previous = index > 0 ? blocks[index - 1] : nil
            let opensRun = block.isCode && previous?.isCode != true
            let closesRun = block.isCode
                && (index + 1 >= blocks.count || blocks[index + 1].isCode == false)
            // **A single fixed-pitch line stays inline code.** A code word
            // copied in the middle of a sentence arrives exactly like a
            // one-line `<pre>`: nothing distinguishes them. What actually
            // separates them is that a block spans more than one.
            let isFenced = block.isCode && !(opensRun && closesRun)

            if let previous {
                // Two list items follow each other line by line, and so do
                // two code lines; everything else needs the blank line that
                // separates two blocks in markdown.
                let tight = (block.isListItem && previous.isListItem)
                    || (block.isCode && previous.isCode)
                output += tight ? "\n" : "\n\n"
            }
            if isFenced, opensRun { output += "```\n" }
            output += block.prefix + (isFenced || !block.isCode ? block.content
                                                                : "`" + block.content + "`")
            if isFenced, closesRun { output += "\n```" }
        }
        return normaliseBlankLines(output)
    }

    private struct Block {
        var prefix: String
        var content: String
        var isListItem: Bool
        var isCode: Bool
    }

    /// The inline attribute conversion for a range: the original one,
    /// scoped down.
    private static func inline(_ rich: NSAttributedString, in whole: NSRange,
                               ignoringBold: Bool = false,
                               ignoringCode: Bool = false) -> String {
        guard whole.length > 0 else { return "" }
        var output = ""

        rich.enumerateAttributes(in: whole) { attributes, range, _ in
            var fragment = (rich.string as NSString).substring(with: range)
            guard !fragment.isEmpty else { return }

            // Edge whitespace must not end up **inside** the markers:
            // `** bold **` is not bold for cmark.
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
            if isMonospaced, ignoringCode {
                // Already inside a fence: what is inside it is literal, and
                // backticks on top of it would read as part of the block.
                wrapped = fragment
            } else if isMonospaced {
                // Inline code does not accept other formatting inside it,
                // and is not escaped: what is between backticks is literal.
                wrapped = "`" + fragment + "`"
            } else {
                // A heading is already bold in markdown: adding asterisks
                // to it would give `# **The heading**`, the same intent
                // twice.
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

    // MARK: - What a paragraph is

    /// A paragraph's markdown prefix, and the range of its content.
    private static func describe(_ rich: NSAttributedString, paragraph: NSRange, body: CGFloat)
        -> (prefix: String, content: NSRange, isListItem: Bool, isHeading: Bool, isCode: Bool) {
        guard paragraph.length > 0 else { return ("", paragraph, false, false, false) }
        let style = rich.attribute(.paragraphStyle, at: paragraph.location,
                                   effectiveRange: nil) as? NSParagraphStyle

        // A list declares itself: `NSTextList` is what the HTML importer
        // sets on a `<ul>` or `<ol>`, and its nesting is read from the
        // number of stacked lists.
        if let lists = style?.textLists, !lists.isEmpty {
            let indent = String(repeating: "  ", count: max(0, lists.count - 1))
            let marker = lists.last.map { isOrdered($0) ? "1. " : "- " } ?? "- "
            return (indent + marker, withoutListMarker(rich, in: paragraph), true, false, false)
        }

        // **A `<pre>` is a block, not inline code.** It used to arrive
        // wrapped in single backticks, on one line: a code block pasted
        // from a site lost its line breaks and its fence. What
        // distinguishes them is extent — the whole paragraph is in fixed
        // pitch, whereas a `<code>` only covers part of it.
        if isEntirely(rich, paragraph: paragraph, monospaced: true) {
            return ("", paragraph, false, false, true)
        }

        // **A blockquote is read from its indent.** The HTML importer has
        // no attribute for `<blockquote>`: what it sets is an indentation.
        // Without this case, a pasted blockquote became an ordinary
        // paragraph and nothing said it had been one anymore.
        if let style, style.headIndent > 0 || style.firstLineHeadIndent > 0 {
            return ("> ", paragraph, false, false, false)
        }

        // A heading is measured. The comparison uses the **smallest** size
        // in the paragraph: a single enlarged word in the middle of a
        // sentence must not turn it into a heading.
        if body > 0, let smallest = smallestFontSize(rich, in: paragraph) {
            let ratio = smallest / body
            let level = ratio >= 1.7 ? 1 : ratio >= 1.4 ? 2 : ratio >= 1.15 ? 3 : 0
            if level > 0 {
                return (String(repeating: "#", count: level) + " ", paragraph, false, true, false)
            }
        }
        return ("", paragraph, false, false, false)
    }

    /// Is the whole paragraph set in this pitch?
    private static func isEntirely(_ rich: NSAttributedString,
                                   paragraph: NSRange, monospaced: Bool) -> Bool {
        guard paragraph.length > 0 else { return false }
        var uniform = true
        rich.enumerateAttribute(.font, in: paragraph) { value, range, stop in
            // Whitespace has no pitch that counts.
            let piece = (rich.string as NSString).substring(with: range)
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if ((value as? NSFont)?.isFixedPitch ?? false) != monospaced {
                uniform = false
                stop.pointee = true
            }
        }
        return uniform
    }

    /// The most represented font size, taken as the body's.
    ///
    /// It cannot be guessed: a site set in 14 px and another in 18 px give
    /// headings with very different absolute sizes. What is stable is the
    /// **ratio** between a heading and the running text, so it is the
    /// running text that must be identified — the longest one, by
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

    /// A numbered list, or a bulleted one?
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

    /// The range of an item's text, **without the bullet the importer
    /// wrote into it**.
    ///
    /// `NSAttributedString` does not just set an `NSTextList`: it also
    /// writes the mark into the text, tab-separated. Leaving it would give
    /// `- •\tAn item` — the markdown bullet followed by the HTML one.
    private static func withoutListMarker(_ rich: NSAttributedString, in paragraph: NSRange) -> NSRange {
        let text = rich.string as NSString
        var start = paragraph.location
        let end = paragraph.upperBound

        func skipBlanks() {
            while start < end, isBlank(text.character(at: start)) { start += 1 }
        }
        skipBlanks()

        let marked = start
        // A bullet, or a number followed by its delimiter.
        if start < end, "•◦▪·-*\u{2022}".utf16.contains(text.character(at: start)) {
            start += 1
        } else {
            var digits = start
            while digits < end, (48...57).contains(text.character(at: digits)) { digits += 1 }
            guard digits > start, digits < end else {
                return NSRange(location: marked, length: end - marked)
            }
            // `NSAttributedString` writes "1\t", without a delimiter. The
            // period or the parenthesis are still accepted — other sources
            // set them.
            let delimiter = text.character(at: digits)
            let numbered = delimiter == 46 || delimiter == 41
            let candidate = numbered ? digits + 1 : digits
            // **The tab is the discriminant.** A number followed by a
            // simple space can be the start of the text — "2026 was a
            // year" — and eating it would be worse than keeping a bullet.
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

    // MARK: - Details

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

    /// Escapes the characters that would have meaning in markdown.
    ///
    /// Without this, pasting text containing "2 * 3 * 4" from a web page
    /// would produce italics where there was only a multiplication.
    private static func escapeMarkdown(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if "*_`[]".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Three or more line breaks have no meaning in markdown: two already
    /// separate two blocks. Sites' HTML produces plenty of them.
    private static func normaliseBlankLines(_ text: String) -> String {
        var result = text
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
