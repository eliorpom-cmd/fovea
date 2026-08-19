// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The typography of the **user's text** — distinct from the chrome's,
/// which lives in `Theme.UIText`.
///
/// It lives here because it's adjustable (§4.7): font, size, line spacing
/// and column width can change, and everything that depends on them must be
/// recomputed from a single place. Fonts are cached: applying attributes
/// touches thousands of ranges, and `NSFont` isn't free to instantiate.
/// `@MainActor` because it resolves `NSFont` values: AppKit isn't
/// thread-safe, and the only alternative would be a lock paid for on every
/// character rendered.
@MainActor
struct EditorTypography: Equatable {

    /// Family name, or `nil` for the system font (SF Pro, the default from
    /// §7). The user can choose another one, including a font they imported
    /// themselves.
    var bodyFontName: String?
    var monoFontName: String?
    var bodySize: CGFloat
    var lineHeightMultiple: CGFloat
    /// Text column width, **in characters** rather than points: that's the
    /// measure that makes sense for reading, and it follows the font size.
    var columnWidthInCharacters: Int

    static let `default` = EditorTypography(bodyFontName: nil,
                                            monoFontName: nil,
                                            bodySize: 16,
                                            lineHeightMultiple: 1.5,
                                            columnWidthInCharacters: 68)

    // MARK: - Fonts

    var body: NSFont { font(bodyFontName, size: bodySize, weight: .regular) }
    var bodyEmphasized: NSFont { font(bodyFontName, size: bodySize, weight: .semibold) }
    var bodyItalic: NSFont { italic(body) }
    var bodyBoldItalic: NSFont { italic(bodyEmphasized) }

    /// Inline code is very slightly reduced: at equal size, a monospaced
    /// font looks bigger than the proportional font around it and makes the
    /// line bulge.
    var inlineCode: NSFont { mono(size: bodySize * 0.92) }
    var codeBlock: NSFont { mono(size: bodySize * 0.92) }

    /// Heading scale. Six levels in a writing app isn't six sizes: past the
    /// fourth, hierarchy is carried by weight instead, otherwise a heading 6
    /// would end up smaller than body text.
    func heading(level: Int) -> NSFont {
        let scale: CGFloat = switch level {
        case 1: 1.85
        case 2: 1.50
        case 3: 1.25
        case 4: 1.10
        default: 1.0
        }
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        return font(bodyFontName, size: (bodySize * scale).rounded(), weight: weight)
    }

    /// Space above a heading, proportional to its importance. It's this
    /// space, far more than the size, that reads as structure.
    func spacingBefore(headingLevel level: Int) -> CGFloat {
        let scale: CGFloat = switch level {
        case 1: 1.6
        case 2: 1.4
        case 3: 1.1
        default: 0.9
        }
        return (bodySize * scale).rounded()
    }

    // MARK: - Layout

    var lineHeight: CGFloat { (bodySize * lineHeightMultiple).rounded() }

    /// Indentation of a list item, per nesting level.
    ///
    /// It must be **wider than the bullet plus its gap**, otherwise the
    /// bullet would draw at a negative x-coordinate, i.e. off view — which is
    /// exactly what happened on the first attempt.
    func listIndent(level: Int) -> CGFloat {
        (bodySize * 1.6 * CGFloat(level + 1)).rounded()
    }

    /// Gap between the bullet and the text it introduces.
    var listMarkerGap: CGFloat { (bodySize * 0.45).rounded() }

    /// Indentation of a blockquote: room for its vertical bar, plus the
    /// breathing space needed between the bar and the text.
    var quoteIndent: CGFloat { (bodySize * 1.2).rounded() }

    var codeBlockIndent: CGFloat { (bodySize * 0.75).rounded() }

    /// **Zero, deliberately.**
    ///
    /// For TextKit, every `\n` opens a new paragraph. But a markdown
    /// document is almost always hand-wrapped around 80 characters: a
    /// paragraph spacing would then apply between *every source line*, and a
    /// six-line paragraph would spread out like six paragraphs.
    ///
    /// The separation therefore comes from wherever the author put it — the
    /// blank line they typed, which renders at the height of one line. It's
    /// the only solution consistent with §3.1: the screen shows what the
    /// file says, it doesn't add spacing nobody wrote.
    var paragraphSpacing: CGFloat { 0 }

    /// Column width in points, measured on the actual font.
    ///
    /// The "n" is the typographer's usual yardstick for an average character
    /// width; a space would be too narrow and an "m" too wide, and both
    /// would give a wrong column width as soon as the font changes.
    var columnWidth: CGFloat {
        let reference = body
        let advance = ("n" as NSString).size(withAttributes: [.font: reference]).width
        return (advance * CGFloat(columnWidthInCharacters)).rounded()
    }

    /// Base paragraph style, shared across the whole body of text.
    func paragraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = paragraphSpacing
        return style
    }

    /// Source mode (§4.2) is laid out tighter than prose: it shows a file,
    /// and a file reads in blocks. The value lives here rather than at the
    /// point of use, because the caret is measured against it too — an empty
    /// line in source mode has no character to take its metrics from.
    static let sourceLineHeightMultiple: CGFloat = 1.35

    func sourceParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = Self.sourceLineHeightMultiple
        return style
    }

    /// A system font at a free size, for what the editor **draws** rather
    /// than lays out: missing-image frame, bullets, numbers.
    func uiFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        FontCache.shared.font(name: nil, size: size, weight: weight)
    }

    // MARK: - Font factory

    private func font(_ name: String?, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        FontCache.shared.font(name: name, size: size, weight: weight)
    }

    private func mono(size: CGFloat) -> NSFont {
        FontCache.shared.mono(name: monoFontName, size: size)
    }

    private func italic(_ base: NSFont) -> NSFont {
        FontCache.shared.italic(of: base)
    }
}

/// Font cache.
///
/// Without it, every reparse instantiates a few thousand identical `NSFont`
/// instances. The class is `@MainActor` because applying attributes is too:
/// there are never two threads accessing it, so there's no lock to pay for.
@MainActor
final class FontCache {
    static let shared = FontCache()

    private struct Key: Hashable {
        let name: String?
        let size: CGFloat
        let weight: CGFloat
        let italic: Bool
        let mono: Bool
    }

    private var cache: [Key: NSFont] = [:]

    func font(name: String?, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let key = Key(name: name, size: size, weight: weight.rawValue, italic: false, mono: false)
        if let hit = cache[key] { return hit }

        let resolved: NSFont
        if let name, let named = NSFont(name: name, size: size) {
            // A family chosen by the user doesn't necessarily have the
            // requested weight. The font manager gets as close as it can,
            // and falls back to the starting font rather than failing.
            resolved = NSFontManager.shared.convert(named, toHaveTrait: weight >= .semibold ? .boldFontMask : [])
        } else {
            resolved = NSFont.systemFont(ofSize: size, weight: weight)
        }
        cache[key] = resolved
        return resolved
    }

    func mono(name: String?, size: CGFloat) -> NSFont {
        let key = Key(name: name, size: size, weight: NSFont.Weight.regular.rawValue, italic: false, mono: true)
        if let hit = cache[key] { return hit }
        let resolved = name.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        cache[key] = resolved
        return resolved
    }

    func italic(of base: NSFont) -> NSFont {
        let key = Key(name: base.fontName, size: base.pointSize, weight: 0, italic: true, mono: false)
        if let hit = cache[key] { return hit }
        let resolved = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        cache[key] = resolved
        return resolved
    }

    func clear() { cache.removeAll(keepingCapacity: true) }
}
