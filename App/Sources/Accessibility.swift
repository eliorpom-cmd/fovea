// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import AppKit

/// The system's accessibility settings, behind **a single entry point** (§8).
///
/// A single entry point, not an `NSWorkspace.shared.accessibilityDisplay…`
/// scattered around: that's FreePark's convention, and it holds for the same
/// reason. A setting read in ten places always ends up forgotten at the
/// eleventh, and the eleventh is the one that breaks.
@MainActor
enum Accessibility {

    /// "Reduce Motion".
    ///
    /// Returns `nil` when the setting is on: the state change still applies,
    /// only the movement disappears. That's the distinction that matters: a
    /// disabled animation must never become a disabled feature.
    static func duration(_ normal: TimeInterval) -> TimeInterval? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : normal
    }

    /// Animates, or applies directly if motion is reduced.
    static func animate(_ normal: TimeInterval,
                        changes: () -> Void,
                        completion: (@Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration(normal) ?? 0
            context.allowsImplicitAnimation = true
            changes()
        } completionHandler: {
            guard let completion else { return }
            completion()
        }
    }

    /// "Increase Contrast".
    static var prefersIncreasedContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// The color of revealed markers (§2.1).
    ///
    /// `label/tertiary` is **below the AA threshold**, and that's a
    /// deliberate choice: these are wayfinding elements, not content — the
    /// word stays bold while its `**` reappear, and it's the word that
    /// carries the meaning. But when "Increase Contrast" is on, the user has
    /// said they don't want that compromise: it falls back to
    /// `label/secondary`.
    static var markerColor: NSColor {
        prefersIncreasedContrast ? Theme.NS.labelSecondary : Theme.NS.labelTertiary
    }

    // MARK: - Roles read by VoiceOver (§8)

    /// What a construct **is**, in one sentence readable aloud.
    ///
    /// §8 states the problem most WYSIWYG editors ignore: if the `##` are
    /// invisible on screen, they're still read aloud. "hash hash space
    /// Architecture" makes no sense spoken, and yet that's exactly what a
    /// buffer where the syntax was left in produces.
    ///
    /// The output is therefore "Heading, level 2" placed on the **content**,
    /// while the markers themselves carry an empty label.
    static func roleDescription(of kind: SyntaxSpan.Kind) -> String? {
        switch kind {
        case .heading(let level): "Heading, level \(level)"
        case .strong: "Bold"
        case .emphasis: "Italic"
        case .strikethrough: "Strikethrough"
        case .inlineCode: "Code"
        case .link(let destination): "Link to \(destination)"
        case .image(_, let alt): alt.isEmpty ? "Image" : "Image, \(alt)"
        case .blockQuote: "Blockquote"
        case .listItem: "List item"
        case .taskItem(_, let checked): checked ? "Task done" : "Task to do"
        case .thematicBreak: "Horizontal rule"
        case .codeBlock(let language): language.map { "Code block, \($0)" } ?? "Code block"
        case .table: "Table"
        case .frontMatter: "Metadata"
        case .footnoteReference(let identifier): "Footnote \(identifier)"
        case .footnoteDefinition(let identifier): "Footnote text \(identifier)"
        }
    }
}
