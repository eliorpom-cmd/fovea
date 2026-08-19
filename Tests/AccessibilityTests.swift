// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Accessibility, per §8.
///
/// What's checked here is what **can** be checked without a screen reader: the
/// labels produced, the adaptation to contrast, the single entry point for
/// animations, and the layout holding up from 11 to 32 points. The actual
/// behavior of VoiceOver requires a machine and an ear.
@MainActor
final class AccessibilityTests: XCTestCase {

    // MARK: - What VoiceOver should hear

    func testEveryConstructHasASpokenRole() {
        let kinds: [SyntaxSpan.Kind] = [
            .heading(level: 2), .strong, .emphasis, .strikethrough, .inlineCode,
            .link(destination: "https://x.fr"), .image(source: "a.png", alt: "A cat"),
            .blockQuote(depth: 1), .listItem(marker: .bullet("-")),
            .taskItem(marker: .bullet("-"), checked: true), .thematicBreak,
            .codeBlock(language: "swift"), .frontMatter, .table(nil),
            .footnoteReference(identifier: "1"),
        ]
        for kind in kinds {
            XCTAssertNotNil(Accessibility.roleDescription(of: kind),
                            "No role stated for \(kind)")
        }
    }

    func testARoleNeverSpeaksMarkdownSyntax() {
        // The problem §8 raises: "hash hash space Architecture" makes no
        // sense spoken aloud. A role that contained the syntax would
        // reproduce it.
        let syntax: Set<Character> = ["#", "*", "`", "~", "|", ">", "[", "]"]
        let kinds: [SyntaxSpan.Kind] = [
            .heading(level: 1), .strong, .emphasis, .inlineCode, .strikethrough,
            .blockQuote(depth: 1), .table(nil), .thematicBreak,
        ]
        for kind in kinds {
            let role = Accessibility.roleDescription(of: kind) ?? ""
            XCTAssertFalse(role.contains(where: syntax.contains),
                           "\"\(role)\" contains markdown syntax")
        }
    }

    func testAHeadingAnnouncesItsLevel() {
        XCTAssertEqual(Accessibility.roleDescription(of: .heading(level: 3)), "Heading, level 3")
    }

    func testATaskAnnouncesWhetherItIsDone() {
        // The state of a checkbox is **drawn**: that's exactly the kind of
        // information a screen reader cannot guess.
        XCTAssertEqual(Accessibility.roleDescription(of: .taskItem(marker: .bullet("-"), checked: true)),
                       "Task done")
        XCTAssertEqual(Accessibility.roleDescription(of: .taskItem(marker: .bullet("-"), checked: false)),
                       "Task to do")
    }

    func testAnImageIsDescribedByItsAlternativeText() {
        XCTAssertEqual(Accessibility.roleDescription(of: .image(source: "chat.png", alt: "A ginger cat")),
                       "Image, A ginger cat")
        // Without alt text, the app still announces there's an image,
        // rather than leaving silence.
        XCTAssertEqual(Accessibility.roleDescription(of: .image(source: "x.png", alt: "")), "Image")
    }

    func testALinkAnnouncesItsDestination() {
        XCTAssertEqual(Accessibility.roleDescription(of: .link(destination: "https://example.com")),
                       "Link to https://example.com")
    }

    // MARK: - Contrast

    func testTheMarkerColourFollowsTheContrastSetting() {
        // The system setting can't be changed from a test; this checks that
        // the rendered color is one of the two expected ones, never a third
        // one hardcoded elsewhere.
        let expected = [Theme.NS.labelTertiary, Theme.NS.labelSecondary]
        XCTAssertTrue(expected.contains(Accessibility.markerColor))
        XCTAssertEqual(Accessibility.markerColor,
                       Accessibility.prefersIncreasedContrast
                           ? Theme.NS.labelSecondary : Theme.NS.labelTertiary)
    }

    func testTheFocusVeilLightensAtHigherContrast() {
        // Dimming helps concentration; it must not make the rest of the
        // document unreadable for someone who asked for more contrast.
        XCTAssertEqual(Accessibility.focusVeilOpacity,
                       Accessibility.prefersIncreasedContrast ? 0.55 : 0.74)
    }

    // MARK: - Motion

    func testReducedMotionRemovesTheDurationNotTheChange() {
        // The distinction that matters: a cut animation must never become a
        // cut feature.
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        XCTAssertEqual(Accessibility.duration(0.2), reduced ? nil : 0.2)

        var applied = false
        Accessibility.animate(0.2) { applied = true }
        XCTAssertTrue(applied, "The change applies regardless of the setting")
    }

    // MARK: - Text size, from 11 to 32 (§8)

    func testTheLayoutHoldsAcrossTheWholeSizeRange() throws {
        // macOS has no Dynamic Type: the app's size setting stands in for
        // it, and the layout must hold across its whole range.
        var previousHeight: CGFloat = 0
        for size in stride(from: 11.0, through: 32.0, by: 3.0) {
            let typography = EditorTypography(bodyFontName: nil, monoFontName: nil,
                                              bodySize: size, lineHeightMultiple: 1.5,
                                              columnWidthInCharacters: 68)
            XCTAssertGreaterThan(typography.columnWidth, 0)
            // A bullet's indent must stay wider than the bullet itself;
            // otherwise it's drawn at a negative x-coordinate, which puts
            // it off screen.
            XCTAssertGreaterThan(typography.listIndent(level: 0), typography.listMarkerGap)

            let height = try lineHeight(of: "# Heading\n\nSome text.\n", typography: typography)
            XCTAssertGreaterThan(height, previousHeight,
                                 "Line height must increase with size")
            previousHeight = height
        }
    }

    func testATableStaysReadableAtTheLargestSize() throws {
        // At 32 points, a three-column grid no longer fits in 68
        // characters: it must fall back to source mode, not fold up
        // crooked.
        let typography = EditorTypography(bodyFontName: nil, monoFontName: nil,
                                          bodySize: 32, lineHeightMultiple: 1.5,
                                          columnWidthInCharacters: 68)
        let source = "| one column | a second one | a third one |\n|---|---|---|\n| a | b | c |"
        let utf16 = Array(source.utf16)
        let table = try XCTUnwrap(MarkdownTable.scan(utf16: utf16,
                                                     in: NSRange(location: 0, length: utf16.count)))
        // The guard makes the call, and it makes the same call everywhere:
        // rendering and decorations read the same geometry, `TableLayout`.
        let storage = NSTextStorage(string: source)
        let renderer = MarkdownRenderer(typography: typography)
        XCTAssertEqual(renderer.gridLayout(for: table, in: storage) != nil,
                       EditorDecoration.build(from: [SyntaxSpan(kind: .table(table),
                                                                range: NSRange(location: 0, length: utf16.count),
                                                                markers: table.markerRanges,
                                                                content: NSRange(location: 0, length: utf16.count))],
                                              in: storage,
                                              typography: typography).isEmpty == false)
    }

    // MARK: - Helper

    private func lineHeight(of source: String, typography: EditorTypography) throws -> CGFloat {
        let view = EditorTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.textContainer?.size = NSSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false

        let storage = try XCTUnwrap(view.textStorage)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: source)

        let parsed = MarkdownParser.parse(source)
        MarkdownRenderer(typography: typography)
            .render(storage, spans: parsed.spans, revealed: [],
                    in: NSRange(location: 0, length: storage.length))

        let layout = try XCTUnwrap(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)

        var height: CGFloat?
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            height = fragment.layoutFragmentFrame.height
            return false
        }
        return try XCTUnwrap(height)
    }
}
