// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import AppKit
import UniformTypeIdentifiers

/// What a `⌘`-click on a link to a local file is allowed to do.
///
/// A markdown file is often someone else's: a README in a cloned repository,
/// notes received by email. Its links point wherever its author wanted, and
/// handing a local file to `NSWorkspace.open` lets the system pick what runs
/// it. For a `.command` file that is Terminal, which executes it on the spot;
/// for an `.app` it is the app itself. A file cloned with git carries no
/// quarantine flag, so Gatekeeper says nothing. `[the docs](setup.command)`
/// would run a script on a single click.
///
/// So a local link opens only what is read, never what runs: text, images,
/// PDFs, audio and video. Everything else (applications, scripts, executables,
/// packages, folders, and any type the system doesn't know) is shown in
/// Finder instead, selected, for the reader to decide.
enum LinkOpening {
    enum Action: Equatable {
        case open
        case revealInFinder
    }

    /// The action for `url`. Remote addresses (`http`, `https`, `mailto`)
    /// always open: the browser or the mail app is the one that decides.
    static func action(for url: URL) -> Action {
        guard url.isFileURL else { return .open }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isApplicationKey,
                                         .isExecutableKey, .contentTypeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return .revealInFinder }
        if values.isDirectory == true || values.isPackage == true || values.isApplication == true {
            return .revealInFinder
        }
        // The executable bit alone is enough: a script without an extension
        // is still a script.
        if values.isExecutable == true { return .revealInFinder }
        guard let type = values.contentType else { return .revealInFinder }
        // A shell script is plain text to the type system (`public.script`
        // conforms to `public.text`), so the runnable kinds are excluded
        // before the readable ones are allowed.
        let runnable: [UTType] = [.script, .executable, .application, .applicationBundle,
                                  .package, .bundle]
        if runnable.contains(where: { type.conforms(to: $0) }) { return .revealInFinder }
        let readable: [UTType] = [.text, .image, .pdf, .audiovisualContent]
        return readable.contains(where: { type.conforms(to: $0) }) ? .open : .revealInFinder
    }

    /// Opens `url`, or shows it in Finder, as `action(for:)` decides.
    static func follow(_ url: URL) {
        switch action(for: url) {
        case .open:
            NSWorkspace.shared.open(url)
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
