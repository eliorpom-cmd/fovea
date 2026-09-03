// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import AppKit

/// Design system: monochrome, no accent color, neutral gray undertone.
/// Hierarchy comes from weight, size and space, never from hue (§7).
///
/// Two rules specific to Fovea:
///
/// 1. **The app must disappear.** Chrome is reduced to a minimum; in full
///    screen only the text column should remain.
/// 2. **The only colored object allowed is the user's content** — their
///    images. Code blocks used to be able to earn colour too, behind a
///    setting; that setting is gone, and with it the last hue in the app.
///
/// # Why there is no SwiftUI half
///
/// There used to be two parallel palettes: `Color` for SwiftUI and `NSColor`
/// under `Theme.NS`, every value written twice. The editor is pure AppKit and
/// only ever read the second; the settings pane, the one SwiftUI screen left,
/// uses the system's own `Form` styling and asks this file for a single tint.
/// The `Color` half, an interface typography ramp and half the spacing scale
/// were carried, documented and maintained without a single caller.
enum Theme {

    /// Spacing scale, reduced to the steps in use.
    enum Space {
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
        static let s40: CGFloat = 40
        static let s64: CGFloat = 64
    }

    enum Radius {
        static let card: CGFloat = 10
        static let codeBlock: CGFloat = 8
    }
}

// MARK: - Colors
//
// The editor is pure AppKit: it needs NSColor, not SwiftUI Color. Resolving
// one from the other costs a conversion at every attribute application, and
// there are thousands of those per keystroke.

extension Theme {
    enum NS {
        /// Background of the editing window. Deliberately not
        /// `windowBackgroundColor`: a crisp white is wanted in light mode, and
        /// a gray that doesn't skew blue in dark mode — text should be the
        /// only thing the eye catches on.
        static let window = ns(light: (0xFFFFFF, 1.0), dark: (0x1C1C1E, 1.0))

        /// Background of code blocks and inline code. Neutral translucent
        /// gray, like `NSColor.systemFill`: the hue follows the background,
        /// which avoids muddy flat colors in dark mode.
        static let fillQuaternary = ns(light: (0x747480, 0.05), dark: (0x767680, 0.16))

        /// The user's text. Not pure black: on a white background, pure black
        /// vibrates over long reading.
        static let label = ns(light: (0x000000, 0.88), dark: (0xFFFFFF, 0.92))
        /// Quotes and metadata.
        static let labelSecondary = ns(light: (0x000000, 0.50), dark: (0xFFFFFF, 0.55))
        /// **Revealed markdown markers** (§2.1), placeholders, disabled text.
        /// Present, never loud.
        static let labelTertiary = ns(light: (0x000000, 0.28), dark: (0xFFFFFF, 0.30))

        static let separator = ns(light: (0x000000, 0.10), dark: (0xFFFFFF, 0.12))
        /// The vertical bar to the left of a blockquote.
        static let quoteBar = ns(light: (0x000000, 0.18), dark: (0xFFFFFF, 0.22))

        // The system selection is blue. In a monochrome editor where the only
        // allowed color is the user's content, it gets neutralized.
        static let selection = ns(light: (0x000000, 0.12), dark: (0xFFFFFF, 0.18))

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
    /// theme over dark system, a panel was a **black** rectangle in a white
    /// window, and its message — whose color, dynamic, is resolved at draw
    /// time — was written there in **black on black**.
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
