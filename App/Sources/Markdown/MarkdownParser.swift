// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation
import Markdown

/// Traduit le texte source en `SyntaxSpan`, sans jamais le réécrire.
///
/// Le parseur ne sert qu'à savoir **où** poser les attributs. L'AST est
/// consommé puis jeté ; il n'est jamais re-sérialisé, ce qui est exactement ce
/// qui garantit la fidélité au fichier promise au §5.
///
/// # Ce que `swift-markdown` donne, et ce qu'il faut déduire
///
/// La bibliothèque donne la plage complète d'un nœud et celle de son contenu.
/// **Les marqueurs sont le complément de l'un dans l'autre** — c'est le seul
/// calcul que fait ce fichier, et il vaut pour le gras comme pour les liens.
///
/// Quelques nœuds n'ont pas d'enfant qui délimite leur contenu (`InlineCode`,
/// `CodeBlock`, les préfixes de citation) : leurs marqueurs sont alors lus
/// directement dans le texte, ligne par ligne.
struct MarkdownParser {

    /// Le résultat d'une analyse : les constructions, et la table de conversion
    /// qui a servi à les situer. La table est conservée parce que l'éditeur en
    /// a besoin à chaque déplacement du curseur, pour connaître la ligne
    /// courante sans re-parcourir le texte.
    struct Result {
        var spans: [SyntaxSpan]
        var positions: SourcePositionMap
    }

    static func parse(_ text: String) -> Result {
        let positions = SourcePositionMap(text: text)
        let utf16 = Array(text.utf16)

        // Le front matter YAML est retiré avant cmark, qui ne le connaît pas et
        // prendrait le `---` d'ouverture pour un filet horizontal (§4.1).
        var spans: [SyntaxSpan] = []
        let bodyStart = frontMatter(in: text, positions: positions, into: &spans)

        let document = Document(parsing: text)
        var builder = Builder(positions: positions, utf16: utf16, bodyStart: bodyStart)
        builder.visit(document, depth: 0)

        // cmark ignore le front matter et lit son `---` de fermeture comme le
        // soulignement d'un titre `setext` : sans ce filtre, « title: … » et
        // « date: … » s'affichent en gros titres au-dessus du document. Tout ce
        // que l'AST place avant le début du corps est donc écarté.
        spans.append(contentsOf: builder.spans.filter { $0.range.location >= bodyStart })

        // Les notes de bas de page ne sont pas parsées par `swift-markdown` —
        // vérifié, `[^1]` en ressort comme du texte brut. Elles sont donc
        // repérées par une passe maison, le motif étant sans ambiguïté (§4.1).
        spans.append(contentsOf: Footnotes.scan(utf16: utf16, skippingCodeIn: builder.verbatimRanges))

        return Result(spans: spans, positions: positions)
    }

    // MARK: - Front matter

    /// Détecte l'en-tête YAML et renvoie l'offset UTF-16 où commence le corps.
    ///
    /// Le bloc doit commencer à la toute première ligne : un `---` plus bas
    /// dans le document est un filet horizontal, et le confondre couperait le
    /// rendu en deux.
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

    // MARK: - Parcours de l'AST

    private struct Builder {
        let positions: SourcePositionMap
        let utf16: [UInt16]
        /// Fin du front matter : tout ce qui précède est déjà traité.
        let bodyStart: Int

        var spans: [SyntaxSpan] = []
        /// Plages où le texte est littéral — code et HTML brut. Les passes
        /// maison qui suivent doivent les ignorer, sans quoi un `[^1]` dans un
        /// bloc de code deviendrait une note de bas de page (§6).
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

            // Les cellules d'un tableau sont visitées pour leur contenu inline,
            // mais la grille elle-même est un attachement : on ne descend pas
            // dans un bloc de code, il n'y a rien de markdown dedans.
            guard !(markup is CodeBlock) else { return }
            for child in markup.children {
                visit(child, depth: depth + 1)
            }
        }

        // MARK: Nœuds à contenu délimité par un enfant

        /// Le cas général : les marqueurs sont ce qui reste de la plage du nœud
        /// quand on lui retire la plage de son contenu.
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
            // Un titre `setext` (souligné par `===`) n'a pas de préfixe : son
            // contenu commence à la colonne 1. Le complément est alors vide en
            // tête et couvre la ligne de soulignement, ce qui est correct.
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

        // MARK: Nœuds dont le contenu doit être lu dans le texte

        /// `InlineCode` n'a pas d'enfant. Le nombre de backticks est variable —
        /// ``` ``x`` ``` est légal — donc on les compte des deux côtés.
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

        /// Un bloc clôturé a deux lignes de délimiteur ; un bloc indenté n'en a
        /// aucune. Le langage fait partie de la ligne d'ouverture, donc du
        /// marqueur — il se révèle avec elle.
        private mutating func emitCodeBlock(_ node: CodeBlock, depth: Int) {
            guard let full = range(of: node) else { return }
            verbatimRanges.append(full)

            let backtick = UInt16(UnicodeScalar("`").value)
            let tilde = UInt16(UnicodeScalar("~").value)
            let opening = lineRange(at: full.location)
            let fenceLength = max(countLeading(backtick, from: opening.location, limit: opening.length),
                                  countLeading(tilde, from: opening.location, limit: opening.length))

            guard fenceLength >= 3 else {
                // Bloc indenté par quatre espaces : pas de clôture à masquer,
                // l'indentation *est* le contenu tel que l'utilisateur l'a écrit.
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

        /// Le `>` se répète sur chaque ligne : il faut donc un marqueur par
        /// ligne, et non un seul en tête de bloc.
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

        /// Le marqueur d'un item est tout ce qui précède son premier contenu :
        /// l'indentation, la puce ou le numéro, et pour une tâche la case à
        /// cocher — `- [x] ` d'un seul tenant.
        private mutating func emitListItem(_ node: ListItem, depth: Int) {
            guard let full = range(of: node), let inner = contentRange(of: node) else { return }
            let markerRange = NSRange(location: full.location, length: max(0, inner.location - full.location))
            guard let marker = listMarker(in: markerRange) else { return }

            let kind: SyntaxSpan.Kind = switch node.checkbox {
            case .checked:   .taskItem(marker: marker, checked: true)
            case .unchecked: .taskItem(marker: marker, checked: false)
            case nil:        .listItem(marker: marker)
            }

            // La plage retenue s'arrête à la fin de la **première** ligne : un
            // item multi-lignes ne doit pas révéler son marqueur quand le
            // curseur est trois lignes plus bas (§2.2, portée ligne).
            let firstLine = lineRange(at: full.location)
            spans.append(SyntaxSpan(kind: kind,
                                    range: firstLine,
                                    markers: [markerRange],
                                    content: NSRange(location: inner.location,
                                                     length: max(0, firstLine.location + firstLine.length - inner.location)),
                                    depth: depth))
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

        /// La grille est relevée dans la source plutôt que dans l'arbre : cmark
        /// ne rend ni les `|` ni la ligne de délimitation, et ce sont
        /// précisément les caractères à masquer. Voir `MarkdownTable`.
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

        // MARK: Outils

        private func range(of markup: Markup) -> NSRange? {
            guard let source = markup.range else { return nil }
            let converted = positions.range(fromLine: source.lowerBound.line,
                                            fromColumn: source.lowerBound.column,
                                            toLine: source.upperBound.line,
                                            toColumn: source.upperBound.column)
            return converted.length > 0 ? converted : nil
        }

        /// La plage qui couvre tous les enfants du nœud, donc son contenu.
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

        /// Ce qui reste de `full` quand on lui retire `inner` : les marqueurs.
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

        /// La plage de la ligne contenant `location`, terminateur exclu.
        private func lineRange(at location: Int) -> NSRange {
            positions.lineRange(containing: location)
        }

        /// La dernière ligne du bloc, si elle est bien une clôture. Un bloc non
        /// fermé n'en a pas — le cas le plus fréquent pendant la frappe (§6).
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

        /// `> ` en tête de ligne, espace optionnel compris.
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

        /// Identifie la puce ou le numéro dans le préfixe d'un item.
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
