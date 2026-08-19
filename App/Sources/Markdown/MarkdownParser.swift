// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import Foundation
import Markdown

/// Translates the source text into `SyntaxSpan`, never rewriting it.
///
/// The parser only serves to know **where** to place attributes. The AST is
/// consumed then discarded; it is never re-serialized, which is exactly what
/// guarantees the fidelity to the file promised in §5.
///
/// # What `swift-markdown` gives, and what has to be deduced
///
/// The library gives the full range of a node and the range of its content.
/// **The markers are the complement of one in the other**: it is the only
/// calculation this file performs, and it holds for bold as much as for
/// links.
///
/// A few nodes have no child that delimits their content (`InlineCode`,
/// `CodeBlock`, blockquote prefixes): their markers are then read directly
/// from the text, line by line.
struct MarkdownParser {

    /// The result of a parse: the constructs, and the conversion table used
    /// to locate them. The table is kept because the editor needs it on
    /// every caret movement, to know the current line without re-scanning
    /// the text.
    struct Result {
        var spans: [SyntaxSpan]
        var positions: SourcePositionMap
    }

    static func parse(_ text: String) -> Result {
        let positions = SourcePositionMap(text: text)
        let utf16 = Array(text.utf16)

        // The YAML front matter is stripped before cmark, which does not
        // know about it and would take the opening `---` for a horizontal
        // rule (§4.1).
        var spans: [SyntaxSpan] = []
        let bodyStart = frontMatter(in: text, positions: positions, into: &spans)

        let document = Document(parsing: text)
        var builder = Builder(positions: positions, utf16: utf16, bodyStart: bodyStart)
        builder.visit(document, depth: 0)

        // cmark ignores the front matter and reads its closing `---` as the
        // underline of a `setext` heading: without this filter, "title: …"
        // and "date: …" would display as large headings above the document.
        // Anything the AST places before the start of the body is therefore
        // discarded.
        spans.append(contentsOf: builder.spans.filter { $0.range.location >= bodyStart })

        // Footnotes are not parsed by `swift-markdown`: verified, `[^1]`
        // comes out as plain text. They are therefore detected by a custom
        // pass, the pattern being unambiguous (§4.1).
        spans.append(contentsOf: Footnotes.scan(utf16: utf16, skippingCodeIn: builder.verbatimRanges))

        return Result(spans: spans, positions: positions)
    }

    // MARK: - Front matter

    /// Detects the YAML header and returns the UTF-16 offset where the body
    /// starts.
    ///
    /// The block must start on the very first line: a `---` further down in
    /// the document is a horizontal rule, and confusing the two would cut
    /// the rendering in half.
    private static func frontMatter(in text: String,
                                    positions: SourcePositionMap,
                                    into spans: inout [SyntaxSpan]) -> Int {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return 0 }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return 0 }

        for index in 1..<lines.count where lines[index] == "---" || lines[index] == "..." {
            let openRange = NSRange(location: 0, length: 3)
            let closeStart = positions.utf16Offset(line: index + 1, column: 1)
            let closeRange = NSRange(location: closeStart, length: 3)
            let end = closeStart + 3
            spans.append(SyntaxSpan(kind: .frontMatter,
                                    range: NSRange(location: 0, length: end),
                                    markers: [openRange, closeRange],
                                    content: NSRange(location: 4, length: max(0, closeStart - 4))))
            return end
        }
        return 0
    }

    // MARK: - AST traversal

    private struct Builder {
        let positions: SourcePositionMap
        let utf16: [UInt16]
        /// End of the front matter: everything before it is already handled.
        let bodyStart: Int

        var spans: [SyntaxSpan] = []
        /// Ranges where the text is literal: code and raw HTML. The custom
        /// passes that follow must ignore these, otherwise a `[^1]` inside a
        /// code block would become a footnote (§6).
        var verbatimRanges: [NSRange] = []

        mutating func visit(_ markup: Markup, depth: Int) {
            switch markup {
            case let node as Heading:          emitHeading(node, depth: depth)
            case let node as Strong:           emitWrapping(node, kind: .strong, depth: depth)
            case let node as Emphasis:         emitWrapping(node, kind: .emphasis, depth: depth)
            case let node as Strikethrough:    emitWrapping(node, kind: .strikethrough, depth: depth)
            case let node as Link:             emitLink(node, depth: depth)
            case let node as Image:            emitImage(node, depth: depth)
            case let node as InlineCode:       emitInlineCode(node, depth: depth)
            case let node as CodeBlock:        emitCodeBlock(node, depth: depth)
            case let node as BlockQuote:       emitBlockQuote(node, depth: depth)
            case let node as ListItem:         emitListItem(node, depth: depth)
            case let node as ThematicBreak:    emitThematicBreak(node, depth: depth)
            case let node as Table:            emitTable(node, depth: depth)
            case let node as HTMLBlock:        markVerbatim(node)
            case let node as InlineHTML:       markVerbatim(node)
            default:                           break
            }

            // A table's cells are visited for their inline content, but the
            // grid itself is an attachment: traversal does not descend into
            // a code block, there is nothing markdown about what's inside.
            guard !(markup is CodeBlock) else { return }
            for child in markup.children {
                visit(child, depth: depth + 1)
            }
        }

        // MARK: Nodes whose content is delimited by a child

        /// The general case: the markers are what remains of the node's
        /// range once its content range has been removed from it.
        private mutating func emitWrapping(_ node: Markup, kind: SyntaxSpan.Kind, depth: Int) {
            guard let full = range(of: node), let inner = contentRange(of: node) else { return }
            spans.append(SyntaxSpan(kind: kind,
                                    range: full,
                                    markers: complement(of: inner, in: full),
                                    content: inner,
                                    depth: depth))
        }

        private mutating func emitHeading(_ node: Heading, depth: Int) {
            guard let full = range(of: node) else { return }
            // A `setext` heading (underlined with `===`) has no prefix: its
            // content starts at column 1. The complement is then empty at
            // the start and covers the underline row, which is correct.
            let inner = contentRange(of: node) ?? full
            spans.append(SyntaxSpan(kind: .heading(level: node.level),
                                    range: full,
                                    markers: complement(of: inner, in: full),
                                    content: inner,
                                    depth: depth))
        }

        private mutating func emitLink(_ node: Link, depth: Int) {
            guard let full = range(of: node) else { return }
            let inner = contentRange(of: node) ?? full
            spans.append(SyntaxSpan(kind: .link(destination: node.destination ?? ""),
                                    range: full,
                                    markers: complement(of: inner, in: full),
                                    content: inner,
                                    depth: depth))
        }

        private mutating func emitImage(_ node: Image, depth: Int) {
            guard let full = range(of: node) else { return }
            let inner = contentRange(of: node) ?? NSRange(location: full.location, length: 0)
            spans.append(SyntaxSpan(kind: .image(source: node.source ?? "", alt: node.plainText),
                                    range: full,
                                    markers: complement(of: inner, in: full),
                                    content: inner,
                                    depth: depth))
        }

        // MARK: Nodes whose content must be read from the text

        /// `InlineCode` has no child. The number of backticks is variable
        /// (``` ``x`` ``` is legal), so they are counted on both sides.
        private mutating func emitInlineCode(_ node: InlineCode, depth: Int) {
            guard let full = range(of: node) else { return }
            let ticks = countLeading(UInt16(UnicodeScalar("`").value), from: full.location, limit: full.length)
            guard ticks > 0, full.length > ticks * 2 else { return }
            let inner = NSRange(location: full.location + ticks, length: full.length - ticks * 2)
            spans.append(SyntaxSpan(kind: .inlineCode,
                                    range: full,
                                    markers: complement(of: inner, in: full),
                                    content: inner,
                                    depth: depth))
            verbatimRanges.append(full)
        }

        /// A fenced block has two delimiter lines; an indented block has
        /// none. The language is part of the opening line, so of the
        /// marker: it reveals along with it.
        private mutating func emitCodeBlock(_ node: CodeBlock, depth: Int) {
            guard let full = range(of: node) else { return }
            verbatimRanges.append(full)

            let backtick = UInt16(UnicodeScalar("`").value)
            let tilde = UInt16(UnicodeScalar("~").value)
            let opening = lineRange(at: full.location)
            let fenceLength = max(countLeading(backtick, from: opening.location, limit: opening.length),
                                  countLeading(tilde, from: opening.location, limit: opening.length))

            guard fenceLength >= 3 else {
                // Block indented by four spaces: no fence to hide, the
                // indentation *is* the content as the user wrote it.
                spans.append(SyntaxSpan(kind: .codeBlock(language: nil),
                                        range: full, markers: [], content: full, depth: depth))
                return
            }

            let closing = closingFenceRange(in: full, openingLine: opening)
            let contentStart = min(opening.location + opening.length + 1, full.location + full.length)
            let contentEnd = closing?.location ?? (full.location + full.length)
            let content = NSRange(location: contentStart, length: max(0, contentEnd - contentStart))

            spans.append(SyntaxSpan(kind: .codeBlock(language: node.language),
                                    range: full,
                                    markers: [opening, closing].compactMap { $0 },
                                    content: content,
                                    depth: depth))
        }

        /// The `>` repeats on every line: a marker is therefore needed per
        /// line, not a single one at the start of the block.
        private mutating func emitBlockQuote(_ node: BlockQuote, depth: Int) {
            guard let full = range(of: node) else { return }
            var markers: [NSRange] = []
            var cursor = full.location
            let end = full.location + full.length
            while cursor < end {
                let line = lineRange(at: cursor)
                if let prefix = quotePrefix(in: line) { markers.append(prefix) }
                cursor = line.location + line.length + 1
            }
            let contentStart = markers.first.map { $0.location + $0.length } ?? full.location
            spans.append(SyntaxSpan(kind: .blockQuote(depth: depth),
                                    range: full,
                                    markers: markers,
                                    content: NSRange(location: contentStart,
                                                     length: max(0, end - contentStart)),
                                    depth: depth))
        }

        /// The marker of an item is everything that precedes its first
        /// content: the indentation, the bullet or the number, and for a
        /// task the checkbox — `- [x] ` as a single unit.
        private mutating func emitListItem(_ node: ListItem, depth: Int) {
            guard let full = range(of: node), let inner = contentRange(of: node) else { return }
            let markerRange = NSRange(location: full.location, length: max(0, inner.location - full.location))
            guard let marker = listMarker(in: markerRange) else { return }

            let kind: SyntaxSpan.Kind = switch node.checkbox {
            case .checked:   .taskItem(marker: marker, checked: true)
            case .unchecked: .taskItem(marker: marker, checked: false)
            case nil:        .listItem(marker: marker)
            }

            // The retained range stops at the end of the **first** line: a
            // multi-line item must not reveal its marker when the caret is
            // three lines further down (§2.2, line-scoped).
            //
            // The layout, on the other hand, needs the whole item: see
            // `SyntaxSpan.blockRange`. Without it, continuation lines fell
            // back to the base style: they were drawn **to the left of their
            // own bullet**, and their source indentation showed up as blank
            // space in front of the text.
            let firstLine = lineRange(at: full.location)
            spans.append(SyntaxSpan(kind: kind,
                                    range: firstLine,
                                    markers: [markerRange],
                                    content: NSRange(location: inner.location,
                                                     length: max(0, firstLine.location + firstLine.length - inner.location)),
                                    depth: depth,
                                    blockRange: full.length > firstLine.length ? full : nil))
        }

        private mutating func emitThematicBreak(_ node: ThematicBreak, depth: Int) {
            guard let full = range(of: node) else { return }
            let line = lineRange(at: full.location)
            spans.append(SyntaxSpan(kind: .thematicBreak,
                                    range: line,
                                    markers: [line],
                                    content: NSRange(location: line.location, length: 0),
                                    depth: depth))
        }

        /// The grid is read from the source rather than from the tree: cmark
        /// exposes neither the `|` nor the delimiter row, and those are
        /// precisely the characters that need to be hidden. See
        /// `MarkdownTable`.
        private mutating func emitTable(_ node: Table, depth: Int) {
            guard let full = range(of: node) else { return }
            let table = MarkdownTable.scan(utf16: utf16, in: full)
            spans.append(SyntaxSpan(kind: .table(table),
                                    range: full,
                                    markers: table?.markerRanges ?? [],
                                    content: full,
                                    depth: depth))
        }

        private mutating func markVerbatim(_ node: Markup) {
            if let range = range(of: node) { verbatimRanges.append(range) }
        }

        // MARK: Tools

        private func range(of markup: Markup) -> NSRange? {
            guard let source = markup.range else { return nil }
            let converted = positions.range(fromLine: source.lowerBound.line,
                                            fromColumn: source.lowerBound.column,
                                            toLine: source.upperBound.line,
                                            toColumn: source.upperBound.column)
            return converted.length > 0 ? converted : nil
        }

        /// The range that covers all of the node's children, so its content.
        private func contentRange(of markup: Markup) -> NSRange? {
            var lower: Int?
            var upper: Int?
            for child in markup.children {
                guard let childRange = range(of: child) else { continue }
                lower = min(lower ?? childRange.location, childRange.location)
                upper = max(upper ?? 0, childRange.location + childRange.length)
            }
            guard let lower, let upper, upper > lower else { return nil }
            return NSRange(location: lower, length: upper - lower)
        }

        /// What remains of `full` once `inner` has been removed from it: the markers.
        private func complement(of inner: NSRange, in full: NSRange) -> [NSRange] {
            var result: [NSRange] = []
            let leading = inner.location - full.location
            if leading > 0 {
                result.append(NSRange(location: full.location, length: leading))
            }
            let innerEnd = inner.location + inner.length
            let fullEnd = full.location + full.length
            if fullEnd > innerEnd {
                result.append(NSRange(location: innerEnd, length: fullEnd - innerEnd))
            }
            return result
        }

        private func countLeading(_ unit: UInt16, from location: Int, limit: Int) -> Int {
            var count = 0
            while count < limit, location + count < utf16.count, utf16[location + count] == unit {
                count += 1
            }
            return count
        }

        /// The range of the line containing `location`, terminator excluded.
        private func lineRange(at location: Int) -> NSRange {
            positions.lineRange(containing: location)
        }

        /// The last line of the block, if it is indeed a closing fence. An
        /// unclosed block has none: the most frequent case while typing (§6).
        private func closingFenceRange(in full: NSRange, openingLine: NSRange) -> NSRange? {
            let end = full.location + full.length
            guard end > openingLine.location + openingLine.length else { return nil }
            let last = lineRange(at: max(full.location, end - 1))
            guard last.location > openingLine.location else { return nil }
            let backtick = UInt16(UnicodeScalar("`").value)
            let tilde = UInt16(UnicodeScalar("~").value)
            let fence = max(countLeading(backtick, from: last.location, limit: last.length),
                            countLeading(tilde, from: last.location, limit: last.length))
            return fence >= 3 ? last : nil
        }

        /// `> ` at the start of a line, optional space included.
        private func quotePrefix(in line: NSRange) -> NSRange? {
            let space = UInt16(UnicodeScalar(" ").value)
            let angle = UInt16(UnicodeScalar(">").value)
            var offset = 0
            while offset < line.length, utf16[line.location + offset] == space { offset += 1 }
            guard offset < line.length, utf16[line.location + offset] == angle else { return nil }
            offset += 1
            if offset < line.length, utf16[line.location + offset] == space { offset += 1 }
            return NSRange(location: line.location, length: offset)
        }

        /// Identifies the bullet or the number in an item's prefix.
        private func listMarker(in prefix: NSRange) -> SyntaxSpan.ListMarker? {
            let zero = UInt16(UnicodeScalar("0").value)
            let nine = UInt16(UnicodeScalar("9").value)
            let bullets: Set<UInt16> = [UInt16(UnicodeScalar("-").value),
                                        UInt16(UnicodeScalar("*").value),
                                        UInt16(UnicodeScalar("+").value)]
            var offset = 0
            while offset < prefix.length, utf16[prefix.location + offset] == UInt16(UnicodeScalar(" ").value) {
                offset += 1
            }
            guard offset < prefix.length else { return nil }

            let first = utf16[prefix.location + offset]
            if bullets.contains(first) {
                return .bullet(Character(UnicodeScalar(first)!))
            }
            guard first >= zero, first <= nine else { return nil }

            var number = 0
            while offset < prefix.length {
                let unit = utf16[prefix.location + offset]
                guard unit >= zero, unit <= nine else { break }
                number = number * 10 + Int(unit - zero)
                offset += 1
            }
            guard offset < prefix.length, let delimiter = UnicodeScalar(utf16[prefix.location + offset]) else {
                return nil
            }
            return .ordered(number: number, delimiter: Character(delimiter))
        }
    }
}
