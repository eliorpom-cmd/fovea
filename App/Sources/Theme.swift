// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit
import SwiftUI

/// Design system: monochrome, no accent color, neutral gray undertone.
/// Hierarchy comes from weight, size and space, never from hue (§7 of the
/// spec).
///
/// Two rules specific to Fovea, stricter than TBD's:
///
/// 1. **The app must disappear.** Chrome is reduced to a minimum; in full
///    screen only the text column should remain.
/// 2. **The only colored object allowed is the user's content** — their
///    images, and their code blocks, if they've requested colored syntax
///    highlighting.
enum Theme {

    // MARK: - Backgrounds

    /// Background of the editing window. Deliberately not
    /// `windowBackgroundColor`: a crisp white is wanted in light mode, and a
    /// gray that doesn't skew blue in dark mode — text should be the only
    /// thing the eye catches on.
    static let window = adaptive(light: 0xFFFFFF, dark: 0x1C1C1E)

    /// Card surface: command palette, popovers, outline panel.
    static let card = adaptive(light: 0xFFFFFF, dark: 0x2A2A2C)

    // MARK: - Fill ramp
    //
    // Neutral translucent gray, like `NSColor.systemFill`: the hue follows
    // the background, which avoids muddy flat colors in dark mode.

    /// Background of code blocks and inline code.
    static let fillQuaternary = adaptive(light: (0x747480, 0.05), dark: (0x767680, 0.16))
    /// Background of fields and capsules.
    static let fillTertiary = adaptive(light: (0x767680, 0.08), dark: (0x767680, 0.22))
    static let fillSecondary = adaptive(light: (0x787880, 0.12), dark: (0x787880, 0.30))
    /// Hovered row in the outline or the palette.
    static let rowHover = adaptive(light: (0x787880, 0.16), dark: (0x787880, 0.32))
    /// **Selected row** in a list — slash menu, palette, outline.
    ///
    /// One notch above hover, so the two are distinguishable, and gray:
    /// `NSTableView` paints its selection in system blue, which was the only
    /// accent color left in the app. §7 only allows color on the user's
    /// content, and this file already claimed to neutralize it — without the
    /// lists ever applying it.
    static let rowSelection = adaptive(light: (0x787880, 0.22), dark: (0x787880, 0.42))

    // MARK: - Labels

    /// The user's text. Not pure black: on a white background, pure black
    /// vibrates over long writing sessions.
    static let label = adaptive(light: (0x000000, 0.88), dark: (0xFFFFFF, 0.92))
    /// Quotes, metadata, statistics.
    static let labelSecondary = adaptive(light: (0x000000, 0.50), dark: (0xFFFFFF, 0.55))
    /// **Revealed markdown markers** (§2.1), placeholders, disabled text.
    /// Present, never loud.
    static let labelTertiary = adaptive(light: (0x000000, 0.28), dark: (0xFFFFFF, 0.30))
    /// Text dimmed by focus mode (§4.5).
    static let labelDimmed = adaptive(light: (0x000000, 0.22), dark: (0xFFFFFF, 0.24))

    // MARK: - Strokes

    static let separator = adaptive(light: (0x000000, 0.10), dark: (0xFFFFFF, 0.12))
    static let strokeControl = adaptive(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.14))
    /// Keyboard focus ring, neutral — never system blue.
    static let focusRing = adaptive(light: (0x0A0A0A, 0.24), dark: (0xF5F5F5, 0.30))

    /// The vertical bar to the left of a blockquote.
    static let quoteBar = adaptive(light: (0x000000, 0.18), dark: (0xFFFFFF, 0.22))

    // MARK: - Ink (primary button)

    static let ink = adaptive(light: 0x0A0A0A, dark: 0xF5F5F5)
    static let inkOn = adaptive(light: 0xFFFFFF, dark: 0x0A0A0A)

    // MARK: - Selection
    //
    // The system selection is blue. In a monochrome editor where the only
    // allowed color is the user's content, it gets neutralized.

    static let selection = adaptive(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.18))

    // MARK: - Layout

    /// Spacing scale.
    enum Space {
        static let s2: CGFloat = 2
        static let s4: CGFloat = 4
        static let s6: CGFloat = 6
        static let s8: CGFloat = 8
        static let s10: CGFloat = 10
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s20: CGFloat = 20
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        static let s40: CGFloat = 40
        static let s64: CGFloat = 64
    }

    enum Radius {
        static let control: CGFloat = 6
        static let field: CGFloat = 8
        static let row: CGFloat = 8
        static let card: CGFloat = 10
        static let codeBlock: CGFloat = 8
        static let window: CGFloat = 14
    }

    // MARK: - Interface typography ramp
    //
    // For chrome only — status bar, palette, settings, outline. The
    // typography of the **user's text** doesn't live here: it's configurable
    // (§4.7) and computed by `EditorTypography`.

    enum UIText {
        static let title2 = Font.system(size: 17, weight: .regular)
        static let title3 = Font.system(size: 15, weight: .semibold)
        static let headline = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13, weight: .regular)
        static let bodyEmphasized = Font.system(size: 13, weight: .medium)
        static let callout = Font.system(size: 12, weight: .regular)
        static let subheadline = Font.system(size: 11, weight: .regular)
        static let footnote = Font.system(size: 10, weight: .regular)
        /// Section header in small caps.
        static let sectionHeader = Font.system(size: 10, weight: .semibold)
    }

    // MARK: - Color construction

    private static func adaptive(light: Int, dark: Int) -> Color {
        adaptive(light: (light, 1.0), dark: (dark, 1.0))
    }

    private static func adaptive(light: (Int, Double), dark: (Int, Double)) -> Color {
        Color(nsColor: nsAdaptive(light: light, dark: dark))
    }

    private static func nsAdaptive(light: (Int, Double), dark: (Int, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark.0, alpha: dark.1)
                : NSColor(hex: light.0, alpha: light.1)
        }
    }
}

// MARK: - AppKit access
//
// The editor is pure AppKit: it needs NSColor, not SwiftUI Color. This
// mirror avoids an `NSColor(theme.x)` scattered throughout the rendering
// code, which costs a conversion at every attribute application — and there
// are thousands of those per keystroke.

extension Theme {
    enum NS {
        static let window = ns(light: (0xFFFFFF, 1.0), dark: (0x1C1C1E, 1.0))
        static let card = ns(light: (0xFFFFFF, 1.0), dark: (0x2A2A2C, 1.0))

        static let fillQuaternary = ns(light: (0x747480, 0.05), dark: (0x767680, 0.16))
        static let fillTertiary = ns(light: (0x767680, 0.08), dark: (0x767680, 0.22))
        static let fillSecondary = ns(light: (0x787880, 0.12), dark: (0x787880, 0.30))

        static let label = ns(light: (0x000000, 0.88), dark: (0xFFFFFF, 0.92))
        static let labelSecondary = ns(light: (0x000000, 0.50), dark: (0xFFFFFF, 0.55))
        static let labelTertiary = ns(light: (0x000000, 0.28), dark: (0xFFFFFF, 0.30))
        static let labelDimmed = ns(light: (0x000000, 0.22), dark: (0xFFFFFF, 0.24))

        static let separator = ns(light: (0x000000, 0.10), dark: (0xFFFFFF, 0.12))
        static let quoteBar = ns(light: (0x000000, 0.18), dark: (0xFFFFFF, 0.22))
        static let selection = ns(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.18))
        /// **Hovered** row in a list. One notch below selection, so "what I'm
        /// about to click" is distinguishable from "what's chosen".
        static let rowHover = ns(light: (0x787880, 0.10), dark: (0x787880, 0.20))
        static let rowSelection = ns(light: (0x787880, 0.22), dark: (0x787880, 0.42))
        static let ink = ns(light: (0x0A0A0A, 1.0), dark: (0xF5F5F5, 1.0))

        private static func ns(light: (Int, Double), dark: (Int, Double)) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(hex: dark.0, alpha: dark.1)
                    : NSColor(hex: light.0, alpha: light.1)
            }
        }
    }
}

extension NSView {

    /// Sets a background color on the layer, **in the view's appearance**.
    ///
    /// # The pitfall this method exists to close
    ///
    /// `NSColor.cgColor` resolves the color with `NSAppearance.current` — the
    /// **thread's appearance at call time** — not the view's. As long as the
    /// app follows the system, the two coincide and nothing shows.
    ///
    /// As soon as the app is forced into the other theme, a view **created**
    /// at that moment is born with the other theme's colors. Measured: light
    /// theme over dark system, the outline was a **black** rectangle in a
    /// white window, and its welcome message — whose color, dynamic, is
    /// resolved at draw time — was written there in **black on black**. The
    /// status bar became a dark gray capsule sitting on the page.
    ///
    /// And no recovery was possible through
    /// `viewDidChangeEffectiveAppearance`: there is no *change*, the view is
    /// born wrong.
    ///
    /// It must therefore be called at the three moments when appearance can
    /// differ: at construction, on entering a window, and on theme change.
    func applyLayerBackground(_ color: NSColor) {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}

extension NSColor {
    /// Builds an sRGB color from a 0xRRGGBB hexadecimal integer.
    convenience init(hex: Int, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}
