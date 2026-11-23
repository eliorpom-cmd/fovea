// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import AppKit

/// Printing: the document as it reads on screen, on white paper.
///
/// # Why it came back, and why it isn't the old export
///
/// Printing went out on 22/08/2026 with the PDF and HTML exports, because
/// all of them rested on a 470-line HTML writer. It was, in daily use, the
/// most useful of the lot: opening a `.md` and handing someone a sheet of
/// paper. It comes back **without** that writer. The page is drawn by the
/// editor's own pipeline — parser, renderer, decorations — in a disposable
/// text view, so the paper shows exactly what the window shows: hidden
/// markers, bullets, checkboxes, tables, code backgrounds, images.
///
/// "Save as PDF" is the print panel's own button: no separate export needed.
///
/// # Why a disposable view
///
/// Printing the editing view itself would carry over its column width, its
/// dark-mode colours, its centering margin and whatever the caret currently
/// reveals. A fresh view, laid out at the printable width, in the light
/// appearance and with nothing revealed, has none of that.
@MainActor
enum DocumentPrinting {

    /// Margins of the printed page, in points (about 2 cm).
    static let margin: CGFloat = 56

    /// Body size on paper, derived from the screen size.
    ///
    /// The default 16 points reads well at arm's length on a screen and is
    /// oversized on paper, where 11 is the usual body size. The ratio keeps
    /// a user who chose a larger size with a larger print.
    static func printTypography(from screen: EditorTypography) -> EditorTypography {
        var paper = screen
        paper.bodySize = max(9, (screen.bodySize * 0.7).rounded())
        return paper
    }

    /// The print operation for a markdown text.
    static func operation(for text: String,
                          documentURL: URL?,
                          typography: EditorTypography,
                          printInfo base: NSPrintInfo) -> NSPrintOperation {
        let info = base.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = max(100, info.paperSize.width - info.leftMargin - info.rightMargin)
        let view = renderedView(for: text, documentURL: documentURL,
                                typography: printTypography(from: typography), width: width)
        return NSPrintOperation(view: PrintedPage(text: view), printInfo: info)
    }

    /// A read-only text view holding the rendered document, sized to its
    /// content at the given width.
    static func renderedView(for text: String,
                             documentURL: URL?,
                             typography: EditorTypography,
                             width: CGFloat) -> EditorTextView {
        let view = EditorTextView.make()
        // Paper is white: the theme's colours resolve in the light appearance
        // whatever the system is set to.
        view.appearance = NSAppearance(named: .aqua)
        view.typography = typography
        view.documentURL = documentURL
        view.isEditable = false
        view.isSelectable = false
        // The page behind it paints the white and the marks: see `PrintedPage`.
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        view.textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false

        guard let storage = view.textStorage else { return view }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        let parsed = MarkdownParser.parse(text)
        // Nothing revealed: there is no caret on paper.
        // Tables get the text's width, padding excluded: see
        // `EditorController.renderedColumnWidth`.
        let grid = max(1, width - (view.textContainer?.lineFragmentPadding ?? 0) * 2)
        MarkdownRenderer(typography: typography, availableWidth: grid)
            .render(storage, spans: parsed.spans, revealed: [], in: whole)
        storage.endEditing()
        view.decorations = EditorDecoration.build(from: parsed.spans, in: storage,
                                                  typography: typography,
                                                  availableWidth: grid)

        if let layout = view.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        }
        view.sizeToFit()
        return view
    }
}

/// The view actually handed to `NSPrintOperation`: white paper, the marks,
/// then the text on top.
///
/// A TextKit 2 text view doesn't call `drawBackground(in:)` when it prints,
/// and that's where the editor paints its marks — bullets, numbers,
/// checkboxes, rules, code backgrounds, images. Printed alone, the text came
/// out without any of them. This view paints them itself, in the text view's
/// coordinates (same size, same origin, both flipped), and the text view,
/// a subview with no background, draws the text over them.
@MainActor
final class PrintedPage: NSView {

    let text: EditorTextView

    init(text: EditorTextView) {
        self.text = text
        super.init(frame: NSRect(origin: .zero, size: text.frame.size))
        appearance = NSAppearance(named: .aqua)
        text.frame.origin = .zero
        addSubview(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        DecorationPainter(typography: text.typography, documentURL: text.documentURL)
            .draw(text.decorations, in: text, dirtyRect: dirtyRect)
    }

    /// Moves a page break up to the top of the line it would cut.
    ///
    /// `NSTextView`'s own version of this works on TextKit 1 line
    /// fragments; with TextKit 2 it left the break where it fell, and a line
    /// sitting on it came out in two halves, the bottom of its letters at the
    /// top of the next sheet. The line under the proposed break is looked up
    /// in the layout fragments, and the break moved to its top — unless that
    /// would shrink the page past the limit AppKit allows.
    override func adjustPageHeightNew(_ newBottom: UnsafeMutablePointer<CGFloat>,
                                      top oldTop: CGFloat, bottom oldBottom: CGFloat, limit bottomLimit: CGFloat) {
        newBottom.pointee = oldBottom
        guard let layout = text.textLayoutManager else { return }
        let origin = text.textContainerOrigin
        let y = oldBottom - origin.y
        guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return }
        let frame = fragment.layoutFragmentFrame
        for line in fragment.textLineFragments {
            let bounds = line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
            guard bounds.minY < y, bounds.maxY > y else { continue }
            // Not the line's top but the top of its letters, minus a point.
            // Line spacing puts the surplus **above** the letters, and the
            // descenders of the line before reach into that surplus: a break
            // at the very top printed their tips at the top of the next sheet.
            let font = line.attributedString.length > line.characterRange.location
                ? line.attributedString.attribute(.font, at: line.characterRange.location,
                                                  effectiveRange: nil) as? NSFont
                : nil
            let letters = (font ?? text.typography.body).ascender - (font ?? text.typography.body).descender
            let top = max(bounds.minY, bounds.maxY - letters - 1) + origin.y
            // A break already in the empty band above the letters stays put:
            // AppKit raises if a break moves down.
            if top < oldBottom, top >= bottomLimit { newBottom.pointee = top }
            return
        }
    }
}

