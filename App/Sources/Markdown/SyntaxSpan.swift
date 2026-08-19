// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import Foundation

/// A markdown construct located in the source text, with its ranges
/// expressed in UTF-16 units — the ones `NSTextStorage` uses.
///
/// This is the only object the rendering layer receives from the parser. It
/// carries **no text**, only positions: the text stays in the buffer, which
/// is the source of truth (§3.1).
struct SyntaxSpan: Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        // Inline — revealed at the level of the innermost construct.
        case strong
        case emphasis
        case inlineCode
        case strikethrough
        case link(destination: String)
        case image(source: String, alt: String)
        case footnoteReference(identifier: String)

        // Line-scoped — revealed as soon as the caret is on the line (§2.2).
        case heading(level: Int)
        case blockQuote(depth: Int)
        case listItem(marker: ListMarker)
        case taskItem(marker: ListMarker, checked: Bool)
        case thematicBreak
        /// The `[^1]: …` line that carries the footnote's text.
        case footnoteDefinition(identifier: String)

        // Delimited block — both fences revealed together.
        case codeBlock(language: String?)
        case frontMatter
        /// The geometry is carried by the construct itself: rendering needs
        /// it on every caret movement, and re-reading it from the text at
        /// that point would cost a scan per keystroke. `nil` when the block
        /// is not a readable grid — see §6, malformed table.
        case table(MarkdownTable?)

        /// The reveal scope, as defined by the table in §2.2.
        var revealScope: RevealScope {
            switch self {
            case .strong, .emphasis, .inlineCode, .strikethrough,
                 .link, .image, .footnoteReference:
                return .innermostInline
            case .heading, .blockQuote, .listItem, .taskItem, .thematicBreak,
                 .footnoteDefinition:
                return .wholeLine
            case .codeBlock, .frontMatter, .table:
                return .wholeBlock
            }
        }
    }

    enum ListMarker: Equatable, Sendable {
        case bullet(Character)
        case ordered(number: Int, delimiter: Character)
    }

    enum RevealScope: Equatable, Sendable {
        /// Only the innermost construct containing the caret.
        case innermostInline
        /// Revealed as soon as the caret is anywhere on the line.
        case wholeLine
        /// Both fences revealed together as soon as the caret is inside.
        case wholeBlock
    }

    var kind: Kind

    /// The full range, **markers included**. This is what decides the reveal
    /// (see `RevealPolicy`).
    var range: NSRange

    /// The sub-ranges that are pure syntax, to hide when the construct is
    /// not revealed. Ordered, disjoint, included in `range`.
    var markers: [NSRange]

    /// The range of the carried content: the text the user wrote, which must
    /// stay visible no matter what.
    var content: NSRange

    /// Nesting depth, the innermost being the greatest. Set by the parser,
    /// this avoids recomputing it on every selection change.
    var depth: Int

    /// The range of the whole block, when `range` had to be narrowed.
    ///
    /// A multi-line list item is revealed **at the line** (§2.2): `range`
    /// therefore stops at the first `\n`, otherwise the bullet would come
    /// back on screen while the caret is three lines further down. But its
    /// **layout** — the indentation, and the continuation indentation that
    /// aligns the following lines under the text rather than under the
    /// bullet — applies to the whole item. The two needs are contradictory,
    /// hence two ranges. `nil` when they coincide, which is the case for
    /// everything else.
    var blockRange: NSRange?

    /// Nesting level of a list item, starting at 0.
    ///
    /// The AST alternates list and item: `Document > List > Item > List >
    /// Item`. A top-level item is therefore at depth 2, a nested item at
    /// depth 4 — hence the division by two.
    static func listLevel(forDepth depth: Int) -> Int {
        max(0, (depth - 2) / 2)
    }

    init(kind: Kind, range: NSRange, markers: [NSRange], content: NSRange, depth: Int = 0,
         blockRange: NSRange? = nil) {
        self.kind = kind
        self.range = range
        self.markers = markers
        self.content = content
        self.depth = depth
        self.blockRange = blockRange
    }

    /// The range on which to apply the block's layout.
    var layoutRange: NSRange { blockRange ?? range }

    /// Shifts all of the construct's positions.
    ///
    /// A single place does this computation, and that matters: fragment
    /// parsing (§3.3) triggers it on every keystroke, and a construct
    /// carrying positions outside `range`, `content` and `markers` — a
    /// table, with its grid — would be left behind by a shift written by
    /// hand at the call site.
    func shifted(by delta: Int) -> SyntaxSpan {
        guard delta != 0 else { return self }
        var moved = self
        moved.range.location += delta
        moved.content.location += delta
        moved.blockRange?.location += delta
        moved.markers = markers.map { NSRange(location: $0.location + delta, length: $0.length) }
        if case .table(let table?) = kind {
            moved.kind = .table(table.shifted(by: delta))
        }
        return moved
    }
}
