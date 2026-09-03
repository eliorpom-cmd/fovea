// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import Foundation

/// Where a document was last being read: **the first character on screen**.
///
/// Reopening a file and landing at the top is the difference between opening
/// a file and coming back to it. The whole point of this app is the second
/// one, so the position survives the window.
///
/// # A character, not a scroll offset
///
/// A pixel offset is only meaningful for the font, the window width and the
/// layout it was recorded in: change the text size and the reader comes back
/// to the wrong paragraph. It is also unusable at restore time, because
/// TextKit 2 lays out the viewport and leaves the rest, so the height to
/// clamp against is one screenful rather than the document — a file reopened
/// at its end landed a third of the way down.
///
/// A character index has neither problem. It survives a font change, and
/// asking the layout manager for its fragment lays out exactly as much of the
/// document as reaching it requires.
///
/// # Why not `NSDocument`'s own state restoration
///
/// `encodeRestorableState(with:)` restores a **session**: it brings back the
/// windows that were open when the app quit. It says nothing about a file
/// closed on Monday and opened again on Thursday, which is the case that
/// matters here.
///
/// # Why it stays small
///
/// One number per file, keyed by path, and the fifty most recent kept. An
/// unbounded map would grow for the life of the install to record something
/// nobody would miss; fifty covers the documents anyone is actually going
/// back and forth in.
enum ReadingPosition {

    private static let key = "foveaReadingPositions"
    private static let limit = 50

    /// Stored as `[path: [characterIndex, timestamp]]`: two doubles, so the
    /// whole thing round-trips through `UserDefaults` without a coder.
    private static var stored: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func character(for url: URL?) -> Int? {
        guard let url, let entry = stored[url.path], let index = entry.first else { return nil }
        return Int(index)
    }

    static func remember(character index: Int, for url: URL?) {
        guard let url else { return }
        var all = stored

        // The top of a document is where it opens anyway. Recording it would
        // spend an entry to change nothing, and would keep a file in the list
        // that is no longer being read part-way through.
        guard index > 0 else {
            all.removeValue(forKey: url.path)
            stored = all
            return
        }

        all[url.path] = [Double(index), Date.now.timeIntervalSince1970]
        if all.count > limit {
            let oldest = all.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }
                .prefix(all.count - limit)
            for entry in oldest { all.removeValue(forKey: entry.key) }
        }
        stored = all
    }
}
