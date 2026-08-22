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
/// # One pane, four settings
///
/// There were three tabs and seventeen stored keys: focus mode and its unit,
/// typewriter mode, a word goal, colourful code, an image folder, three
/// toggles for markdown behaviour. Every one of them asked the reader to make
/// a decision before they could read.
///
/// What is left is what genuinely differs from one person to the next: how
/// the text should look. Everything else is now a chosen default. A setting
/// with no obvious place to live is almost always a setting that should not
/// exist — and the shortest way to honour that is to have nowhere to put it.
struct SettingsView: View {

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
                Text("Version \(AppConfig.version) (\(AppConfig.build)). GNU AGPL v3 or later. "
                     + "Markdown parsing by swift-markdown (Apple), under the Apache 2.0 license.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // The window no longer has to guess: one `Form`, no `TabView` in the
        // way, so the intrinsic height propagates and the pane fits what it
        // holds. The floor is kept for a larger system font.
        .frame(minWidth: 420, idealWidth: 420, minHeight: 300)
        // §7: monochrome also applies to the screen that explains the
        // settings. The segmented control and the slider were the only
        // remaining surfaces of blue accent color in the app.
        .tint(Color(nsColor: Theme.NS.label))
    }

    @State private var isDefaultHandler = DefaultHandler.isDefault
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
        window.setContentSize(NSSize(width: 420, height: 420))
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
