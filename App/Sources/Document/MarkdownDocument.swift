// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import AppKit

/// The document.
///
/// `NSDocument` provides ⌘O, ⌘S, Recents, in-place autosave, Time Machine
/// versions, session restoration and iCloud Drive for free. None of that is
/// rewritten here: this file only deals with what's specific to markdown,
/// namely the fidelity to the file promised in §5.
final class MarkdownDocument: NSDocument {

    /// The text, as LF in memory. This is the sole source of truth (§3.1).
    private(set) var text: String = ""

    /// The line-ending style found on open, restored as-is on save.
    private var lineEnding: TextFile.LineEnding = .default

    /// The encoding read. Fovea always writes UTF-8; this field only serves
    /// to warn when a conversion will take place (§6).
    private(set) var sourceEncoding: String.Encoding = .utf8

    private weak var editor: EditorController?

    override class var autosavesInPlace: Bool { true }

    /// "Save As" moves the document: images with a relative path then
    /// resolve elsewhere, and the editor needs to know.
    ///
    /// `fileURL` is declared `nonisolated` by AppKit and can change from
    /// file coordination, so this hops back to the main thread explicitly
    /// rather than asserting it's already there.
    override var fileURL: URL? {
        didSet {
            let url = fileURL
            Task { @MainActor [weak self] in self?.editor?.documentURL = url }
        }
    }

    // MARK: - Reading and writing

    // `read` and `data` are declared `nonisolated` by AppKit, because a
    // document *can* be read or written off the main thread. Fovea never
    // asks for that: `canConcurrentlyReadDocuments(ofType:)` and
    // `canAsynchronouslyWrite(to:ofType:for:)` keep their default value,
    // `false`, and AppKit then guarantees the main thread. `assumeIsolated`
    // is therefore an exact statement of what's true, and it will raise a
    // loud error the day someone flips either flag on.

    override func read(from data: Data, ofType typeName: String) throws {
        let contents = try TextFile.read(data)
        MainActor.assumeIsolated {
            text = contents.text
            lineEnding = contents.lineEnding
            sourceEncoding = contents.sourceEncoding
            editor?.setText(text)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        MainActor.assumeIsolated {
            // The editor's buffer is authoritative when it exists: it's
            // what the user sees, and `text` only catches up with it at
            // save time.
            if let editor { text = editor.text }
            return TextFile.write(text: text, lineEnding: lineEnding)
        }
    }

    // MARK: - Window

    override func makeWindowControllers() {
        let controller = DocumentWindowController()
        addWindowController(controller)
        editor = controller.editor
        controller.editor.documentURL = fileURL
        controller.editor.setText(text)
        // The §6 states are communicated once, on open, without interrupting.
        controller.banner.show(DocumentBanner.messages(byteCount: text.utf8.count,
                                                       encoding: sourceEncoding,
                                                       isWritable: isWritable))

        controller.editor.onTextChanged = { [weak self] in
            // `updateChangeCount` is what lights up the close button's dot
            // and triggers autosave.
            self?.updateChangeCount(.changeDone)
        }

        // Where this file was last read. It goes here rather than in the
        // window controller's own layout pass, because that pass runs before
        // this method has said which file the window is showing.
        controller.restoreReadingPositionOnce()
    }

    /// Can the file be rewritten?
    ///
    /// A new document with no location is, by definition: there's nothing
    /// to overwrite yet, and "Save" will open a picker.
    private var isWritable: Bool {
        guard let fileURL else { return true }
        return FileManager.default.isWritableFile(atPath: fileURL.path)
    }

    // MARK: - The file changes under our feet (§5)

    /// A `.md` file is rarely alone: a `git checkout`, a synced folder,
    /// another editor open alongside it, and the file moves while it's
    /// being looked at. Without this watch, the window keeps showing a
    /// stale version, and the next save silently overwrites it.
    ///
    /// `NSDocument` is already an `NSFilePresenter`: file coordination
    /// notifies us on its own, all that was missing was the reaction.
    ///
    /// Two cases, and only one is automatic:
    ///
    /// - **nothing changed here**: reload without asking. This is the
    ///   common case, and an alert would only add a click;
    /// - **unsaved changes**: leave everything untouched, just say so.
    ///   Overwriting someone's work to display another tool's would be the
    ///   worst of both worlds; `NSDocument` will ask the question on its
    ///   own at save time.
    override nonisolated func presentedItemDidChange() {
        super.presentedItemDidChange()
        Task { @MainActor [weak self] in self?.fileChangedOnDisk() }
    }

    @MainActor private func fileChangedOnDisk() {
        guard let url = fileURL, let type = fileType else { return }

        // Our own writes pass through here too: the known date is then
        // already up to date, and there's nothing to reload.
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        guard let modified, let known = fileModificationDate, modified > known else { return }

        guard !isDocumentEdited else {
            windowControllers.compactMap { ($0 as? DocumentWindowController)?.banner }.forEach {
                $0.show(["The file changed on disk. Your changes in progress are "
                         + "kept: they'll be offered at save time."])
            }
            return
        }

        // The caret is restored to its place. The document changed
        // elsewhere, not under the user's fingers: sending it back to the
        // top would be a gratuitous loss.
        let caret = editor?.textView.selectedRange()
        try? revert(toContentsOf: url, ofType: type)
        if let caret, let editor {
            let length = editor.textView.textStorage?.length ?? 0
            editor.textView.setSelectedRange(NSRange(location: min(caret.location, length), length: 0))
        }
    }

    // MARK: - File type

    /// Fovea always writes markdown, even when it opened a `.txt` file
    /// (§5). Without this redirection, "Save As" would offer to re-save as
    /// plain text the document the user just wrote in markdown.
    override func fileNameExtension(forType typeName: String,
                                    saveOperation: NSDocument.SaveOperationType) -> String? {
        AppConfig.defaultExtension
    }
}
