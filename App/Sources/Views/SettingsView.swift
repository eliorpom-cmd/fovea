// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import SwiftUI
import AppKit

/// The settings window (§4.7).
///
/// In SwiftUI, hosted in an AppKit window: this is the only place in the app
/// where SwiftUI is the right tool — forms, not text to lay out. The editor
/// itself stays in pure AppKit.
///
/// Three tabs, and nothing more. A setting with no obvious place to live is
/// almost always a setting that should not exist.
struct SettingsView: View {

    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            AppearanceSettings(settings: settings)
                .tabItem { Label("Appearance", systemImage: "textformat") }
            EditingSettings(settings: settings)
                .tabItem { Label("Editing", systemImage: "pencil.line") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // **A starting size, plus a floor — and the window can grow.**
        //
        // The height was fixed at 560, and `styleMask` had no `.resizable`:
        // on the Appearance tab, "Colorful syntax highlighting" was cut in
        // half by the bottom edge, and on the Editing tab, "Image folder" and
        // its explanation were entirely below the fold. Nothing indicated
        // that scrolling was needed, and nothing allowed the window to grow.
        //
        // Plain intrinsic sizing still does not work — `NSHostingController`
        // does not propagate the height of a `Form` nested in a `TabView` —
        // hence the minimum/ideal pair.
        .frame(minWidth: 480, idealWidth: 480, minHeight: 420, idealHeight: 660)
        // §7: monochrome also applies to the screen that explains the
        // settings. The segmented control, sliders and toggles were the only
        // remaining surfaces of blue accent color in the app.
        //
        // **A `TabView`'s tab bar escapes this**: on macOS it is rendered by
        // the system control, which ignores the tint. It will not be
        // repainted by hand — that would mean rewriting a piece of AppKit for
        // three pixels, and it would stop following the system the day it
        // changes.
        .tint(Color(nsColor: Theme.NS.label))
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Text") {
                FontPicker(title: "Body Font", selection: $settings.bodyFontName,
                           monospaced: false)
                FontPicker(title: "Code Font", selection: $settings.monoFontName,
                           monospaced: true)

                // A size in points means nothing to anyone; what matters is
                // the result. A step of 1 pt is enough — half a point is not
                // visible and doubles the number of steps to scroll through.
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.bodySize, in: 11...32, step: 1)
                        Text("\(Int(settings.bodySize)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                LabeledContent("Line Spacing") {
                    HStack {
                        Slider(value: $settings.lineHeightMultiple, in: 1.0...2.2, step: 0.05)
                        Text(String(format: "%.2f", settings.lineHeightMultiple))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                // Measured in characters, not points: that is the quantity
                // that matters for reading, and it follows the font choice.
                LabeledContent("Column Width") {
                    HStack {
                        Slider(value: .init(get: { Double(settings.columnWidthInCharacters) },
                                            set: { settings.columnWidthInCharacters = Int($0) }),
                               in: 50...100, step: 1)
                        Text("\(settings.columnWidthInCharacters) characters")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 74, alignment: .trailing)
                    }
                }
            }

            Section("Code Blocks") {
                Toggle("Colorful syntax highlighting", isOn: $settings.colorfulCodeBlocks)
                Text("Without this option, highlighting relies on weight and opacity instead. "
                     + "This is the only place in the app where color is allowed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Editing

private struct EditingSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            // Each setting in its own section, with its own explanation.
            // The two used to share one box and a single sentence below both:
            // it looked like it described focus mode, which had none of its
            // own — and that is the one of the two whose behavior is most
            // surprising.
            Section("Writing") {
                Toggle("Focus Mode", isOn: $settings.focusMode)
                if settings.focusMode {
                    Picker("Keep in focus", selection: $settings.focusUnit) {
                        ForEach(AppSettings.FocusUnit.allCases) { Text($0.label).tag($0) }
                    }
                }
                Text("Everything dims except what you're writing. The active unit stops "
                     + "at blank lines, headings and each list item.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Typewriter Mode", isOn: $settings.typewriterMode)
                Text("The active line stays at a fixed height and the text scrolls underneath. "
                     + "When disabled, scrolling behaves like any other app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Statistics") {
                Toggle("Show statistics", isOn: $settings.showStatistics)
                if settings.showStatistics {
                    LabeledContent("Session Goal") {
                        HStack {
                            TextField("", value: $settings.sessionWordGoal, format: .number)
                                .labelsHidden()
                                .frame(width: 70)
                            Text(settings.sessionWordGoal == 0 ? "none" : "words")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Markdown") {
                Toggle("Recognize constructs while typing", isOn: $settings.markdownShortcutsWhileTyping)
                Text("`-` continues the list on Return, ⇥ changes the level.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Close pairs automatically", isOn: $settings.automaticPairs)
                Text("`(` inserts `()`, `**` inserts `****` and places the caret in the middle; "
                     + "⇥ steps out of the format. With text selected, the key wraps it instead "
                     + "of deleting it. The apostrophe is left alone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Insertion menu on \"/\"", selection: $settings.slashMenuScope) {
                    ForEach(AppSettings.SlashMenuScope.allCases) { Text($0.label).tag($0) }
                }
                Text("A `/` offers blocks: heading, list, blockquote, code, table, "
                     + "horizontal rule. It only opens the menu when it starts a word, never "
                     + "right after a character — `https://` and `12/03` stay as they are.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                LabeledContent("Image folder") {
                    TextField("", text: $settings.assetsFolderName)
                        .labelsHidden()
                        .frame(width: 140)
                }
                Text("Images dropped there are copied next to the document, "
                     + "and referenced with a relative path.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutSettings: View {
    @State private var isDefaultHandler = DefaultHandler.isDefault

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppConfig.name).font(.title2.weight(.semibold))
                        Text("Version \(AppConfig.version) (\(AppConfig.build))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Markdown Files") {
                    if isDefaultHandler {
                        Label("Opened with \(AppConfig.name)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Use \(AppConfig.name) by Default") {
                            Task {
                                await DefaultHandler.makeDefault()
                                isDefaultHandler = DefaultHandler.isDefault
                            }
                        }
                    }
                }
            }

            Section {
                Link("Source Code and Issues", destination: AppConfig.repositoryURL)
                Text("GNU AGPL v3 or later. Markdown parsing by swift-markdown (Apple), "
                     + "under the Apache 2.0 license.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Font Picker

/// A font picker that only offers what makes sense here.
///
/// The full list of installed fonts has hundreds of entries, including
/// dingbats and non-Latin alphabets. Only families **readable for running
/// text** are shown, and for code, only monospaced ones.
private struct FontPicker: View {
    let title: String
    @Binding var selection: String?
    let monospaced: Bool

    var body: some View {
        Picker(title, selection: $selection) {
            Text(monospaced ? "SF Mono (system)" : "SF Pro (system)").tag(String?.none)
            Divider()
            ForEach(FontCatalogue.families(monospaced: monospaced), id: \.self) { family in
                Text(family).tag(String?.some(family))
            }
        }
    }
}

/// The offerable families, **computed once**.
///
/// Sorting used to instantiate an `NSFont` per installed family to check
/// whether it is monospaced — several hundred of them — and it lived in a
/// computed property of the view. SwiftUI re-evaluates the body on every
/// keystroke and every slider step: dragging the size setting redid all of
/// that work dozens of times per second, and the settings sliders lagged.
///
/// The installed families cannot change while the app runs, so one entry per
/// variant is enough: body and code.
@MainActor
private enum FontCatalogue {

    private static var cache: [Bool: [String]] = [:]

    static func families(monospaced: Bool) -> [String] {
        if let hit = cache[monospaced] { return hit }

        let result = NSFontManager.shared.availableFontFamilies
            .filter { family in
                // Families whose name is prefixed with a dot are internal to
                // the system; offering them would only cause confusion.
                guard !family.hasPrefix(".") else { return false }
                guard let font = NSFont(name: family, size: 12) else { return false }
                return monospaced ? font.isFixedPitch : true
            }
            .sorted()

        cache[monospaced] = result
        return result
    }
}

// MARK: - Window

/// The settings window, as a single instance.
@MainActor
final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    private convenience init() {
        let hosting = NSHostingController(rootView: SettingsView(settings: .shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .resizable]
        // `idealHeight` does not propagate up to the window through the
        // `TabView`: the starting size is set here, and `.resizable` lets
        // the user enlarge it if their system font is larger.
        window.setContentSize(NSSize(width: 480, height: 660))
        // A settings window left open behind the editor muddles the return
        // to the text; this one closes and reopens identically.
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
