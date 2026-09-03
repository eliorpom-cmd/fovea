// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import Foundation

/// What happens while typing (§2.5).
///
/// A WYSIWYG editor is judged as much by what happens under the fingers as
/// by what it displays. This whole file is **pure**: it takes a text, a
/// selection and a key, and returns the edit to apply. No AppKit, so it's
/// entirely testable without launching a UI.
enum TypingBehaviour {

    /// An edit to apply to the buffer.
    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
        /// Where to place the caret next, as an absolute offset **after**
        /// the edit.
        var caret: Int
        /// The action's name in the Undo menu. `nil` groups it with the
        /// keystroke in progress instead of opening its own step.
        var undoName: String?
        /// Length of the selection to leave after the edit. Zero, the usual
        /// case, places a plain caret; it's wrapping a selection that needs
        /// to preserve it.
        var selectionLength: Int = 0
    }

    // MARK: - Newline inside a list

    /// `⏎` on an item creates the next item at the same level. `⏎` on an
    /// empty item exits the list and removes the marker (§2.5).
    ///
    /// - Returns: `nil` when the key should keep its usual behavior.
    static func newline(in text: String, selection: NSRange) -> Edit? {
        guard selection.length == 0 else { return nil }
        let units = Array(text.utf16)
        let line = lineRange(units, containing: selection.location)
        guard let prefix = listPrefix(units, line: line) else { return nil }

        // **Before the marker, `⏎` stays a `⏎`.**
        //
        // The caret can land right at the start of the line: the reveal rule
        // lets it enter the `- `, and `⌘←` sends it there. Continuation used
        // to apply anyway: the result was `- - item`, a bullet added in front
        // of the one that hadn't actually been left. What's wanted here is a
        // blank line above, which is the ordinary behavior.
        guard selection.location >= line.location + prefix.length else { return nil }

        // An empty item: the marker alone, nothing after it. `⏎` exits.
        //
        // **Removing the marker alone isn't enough to exit.** The line, now
        // empty, stays attached to the previous item, and the first word
        // typed next becomes a *lazy continuation* in the CommonMark sense:
        // `- item\ntext` files `text` **inside** the bullet. The list looked
        // left, but the file said otherwise, and proved it the next time it
        // was reopened elsewhere. A blank line above is needed, unless there
        // is already one, or the item was the document's first line.
        let contentIsEmpty = line.location + prefix.length >= line.location + line.length
        if contentIsEmpty {
            let separator = needsBlankLineAbove(units, line: line) ? "\n" : ""
            return Edit(range: NSRange(location: line.location, length: prefix.length),
                        replacement: separator,
                        caret: line.location + separator.utf16.count,
                        undoName: "Exit List")
        }

        let next = continuation(units, prefix: prefix)
        return Edit(range: NSRange(location: selection.location, length: 0),
                    replacement: "\n" + next,
                    caret: selection.location + 1 + next.utf16.count,
                    undoName: nil)
    }

    /// The next item's marker: the same indentation, the same bullet, and
    /// the next number for an ordered list. A checked box starts over
    /// unchecked: no one wants ten already-done tasks created at once.
    private static func continuation(_ units: [UInt16], prefix: NSRange) -> String {
        let raw = String(decoding: units[prefix.location..<(prefix.location + prefix.length)], as: UTF16.self)
        let indent = String(raw.prefix { $0 == " " || $0 == "\t" })
        let body = raw.dropFirst(indent.count)

        if let checkbox = body.range(of: "[ ]") ?? body.range(of: "[x]") ?? body.range(of: "[X]") {
            let bullet = body[body.startIndex..<checkbox.lowerBound]
            return indent + bullet + "[ ] "
        }
        let digits = body.prefix { $0.isNumber }
        if let number = Int(digits), let delimiter = body.dropFirst(digits.count).first {
            return "\(indent)\(number + 1)\(delimiter) "
        }
        return raw
    }

    // MARK: - Indentation

    /// `⇥` and `⇧⇥` inside a list change its level. Elsewhere, tab stays tab.
    static func indent(in text: String, selection: NSRange, outdent: Bool) -> Edit? {
        let units = Array(text.utf16)
        let line = lineRange(units, containing: selection.location)
        guard listPrefix(units, line: line) != nil else { return nil }

        if outdent {
            let removable = min(2, leadingSpaces(units, line: line))
            guard removable > 0 else { return nil }
            return Edit(range: NSRange(location: line.location, length: removable),
                        replacement: "",
                        caret: max(line.location, selection.location - removable),
                        undoName: "Outdent")
        }
        return Edit(range: NSRange(location: line.location, length: 0),
                    replacement: "  ",
                    caret: selection.location + 2,
                    undoName: "Indent")
    }

    // MARK: - Insert a link

    /// Places `[text](url)` around the selection.
    ///
    /// The URL comes from the pasteboard when it holds one: that's the real
    /// gesture, an address gets copied from a browser, the app is switched
    /// back to, and the word gets selected. Otherwise the parentheses are
    /// left empty and the caret lands inside them, right where there's
    /// nothing left to do but paste.
    ///
    /// Without a selection, the caret goes **between the brackets**: the text
    /// gets written first, the address after.
    static func link(in text: String, selection: NSRange, url: String?) -> Edit {
        let units = Array(text.utf16)
        let label = selection.length > 0 && selection.upperBound <= units.count
            ? slice(units, selection)
            : ""
        let destination = url ?? ""
        // The caret goes where there's still something left to write: the
        // text if it's missing, the address if that's missing, and after the
        // link once it's complete, the only case where the sentence can be
        // picked back up.
        let caret = switch (label.isEmpty, destination.isEmpty) {
        case (true, _):      selection.location + 1
        case (false, true):  selection.location + label.utf16.count + 3
        case (false, false): selection.location + label.utf16.count + destination.utf16.count + 4
        }

        return Edit(range: selection,
                    replacement: "[\(label)](\(destination))",
                    caret: caret,
                    undoName: "Insert Link")
    }

    /// Does the pasteboard contain something that looks like an address?
    ///
    /// Deliberately literal: a scheme, or a `www.`. Guessing more broadly
    /// would paste any sentence copied between a link's parentheses, which is
    /// more painful to undo than to type.
    static func looksLikeURL(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("www.")
    }

    // MARK: - Toggle a task

    /// Checks or unchecks a task item's box.
    ///
    /// # Why this is a function and not a line in the view layer
    ///
    /// The checkbox is **drawn**: it exists nowhere in the file, where there
    /// is only `- [ ] `. Clicking it can't therefore "check" anything by
    /// itself: a character in the buffer must be rewritten, at the right
    /// spot, on the undo stack, without moving the caret.
    ///
    /// Only one character changes, never the whole line: `[x]` renders as a
    /// lowercase `x`, but a `[X]` already written unchecks without being
    /// normalized: §5 applies to what the app itself edits too.
    ///
    /// - Parameters:
    ///   - marker: the item's marker, `- [ ] ` as a single unit.
    ///   - caret: the current selection, left as is: checking a task must
    ///     not send the caret elsewhere in the document.
    static func toggleTask(in text: String, marker: NSRange, caret: Int) -> Edit? {
        let units = Array(text.utf16)
        guard marker.location >= 0, marker.upperBound <= units.count, marker.length >= 3 else { return nil }

        let open = UInt16(UnicodeScalar("[").value)
        let close = UInt16(UnicodeScalar("]").value)
        for index in marker.location..<(marker.upperBound - 2)
        where units[index] == open && units[index + 2] == close {
            let isChecked = units[index + 1] == UInt16(UnicodeScalar("x").value)
                || units[index + 1] == UInt16(UnicodeScalar("X").value)
            return Edit(range: NSRange(location: index + 1, length: 1),
                        replacement: isChecked ? " " : "x",
                        caret: caret,
                        undoName: isChecked ? "Uncheck Task" : "Check Task")
        }
        return nil
    }

    // MARK: - Recognition while typing

    /// The constructs recognized when the space following their marker is
    /// typed: `# `, `- `, `> `, `1. `.
    ///
    /// There is actually **nothing to do**: the marker is already in the
    /// text, the parser sees it, and the rendering follows on the next
    /// cycle. This function exists only to say which ones are recognized,
    /// and so the test can verify it instead of assuming it.
    ///
    /// This is a direct benefit of §3.1: when the source text is the source
    /// of truth, "recognition while typing" isn't a feature, it's a
    /// consequence.
    static func recognizesConstruct(onLine line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("> ") { return true }
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().hasPrefix(" ") { return true }
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }
            return hashes.count <= 6 && trimmed.dropFirst(hashes.count).hasPrefix(" ")
        }
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let rest = trimmed.dropFirst(digits.count)
            if let delimiter = rest.first, delimiter == "." || delimiter == ")" {
                return rest.dropFirst().hasPrefix(" ")
            }
        }
        return false
    }

    // MARK: - Auto-pairing

    /// The pairs inserted while typing.
    ///
    /// The apostrophe `'` is **deliberately absent** from this set. In
    /// French it is a letter within the word, as in *l'app*, *aujourd'hui*,
    /// and no safeguard catches a pair placed there: MarkText gets by with
    /// "not after an alphanumeric character," which still lets *'Bonjour*
    /// through. The cost of leaving it out is nil; the cost of getting it
    /// wrong is a corrected keystroke on every word.
    static let pairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"",
        "*": "*", "_": "_", "`": "`", "~": "~",
    ]

    /// The markdown markers among the pairs: the ones that must never open
    /// in the middle of a word, or `2*3` would drop a phantom asterisk and
    /// `snake_case` would turn italic.
    private static let markdownPairs: Set<Character> = ["*", "_", "`", "~"]

    /// The characters that retyping **steps over** instead of doubling.
    private static let steppedOver: Set<Character> = [")", "]", "}", "\"", "*", "_", "`", "~"]

    /// What can follow the caret without preventing a closing character from
    /// being placed. A pair opened in the middle of a word would almost
    /// always be wrong.
    private static let permissiveNeighbours: Set<Character> = [")", "]", "}", "\"", ",", ";", ":", ".", "!", "?", "…", "»"]

    /// What typing a character should produce, when it isn't simply itself.
    ///
    /// Three gestures in one, in this order:
    ///
    /// 1. **wrap** — with text selected, typing `(` or `*` wraps the
    ///    selection instead of deleting it. The selection is kept on the
    ///    same text, which allows chaining `*` then `*` to go from italic to
    ///    bold;
    /// 2. **step over** — retyping the closing character that's already to
    ///    the right of the caret moves past it instead of writing a second
    ///    one;
    /// 3. **place the closing character**, if and only if it doesn't split a
    ///    word.
    ///
    /// - Parameter insideCode: the caret is inside code, a block or inline
    ///   `code`. Markdown markers have no meaning there; parentheses do.
    /// - Returns: `nil` when the key should insert normally.
    static func autoPair(typing character: Character, in text: String,
                         selection: NSRange, insideCode: Bool) -> Edit? {
        let units = Array(text.utf16)
        guard selection.location >= 0, selection.upperBound <= units.count else { return nil }
        let forbidden = insideCode && markdownPairs.contains(character)

        if selection.length > 0 {
            guard let closing = pairs[character], !forbidden else { return nil }
            return Edit(range: selection,
                        replacement: String(character) + slice(units, selection) + String(closing),
                        caret: selection.location + 1,
                        undoName: "Wrap",
                        selectionLength: selection.length)
        }

        let caret = selection.location
        let next = caret < units.count ? symbol(units[caret]) : nil
        let previous = caret > 0 ? symbol(units[caret - 1]) : nil

        // Does a markdown marker open, or does it close?
        //
        // The question isn't settled by the preceding character: in
        // `**bold|**` as in `an *|*`, typing `*` sees the same thing around
        // the caret. What tells them apart is the word **before the run of
        // markers**, `bold` on one side, a space on the other. So the run is
        // walked back before judging.
        let isMarkdown = markdownPairs.contains(character)
        var opens = true
        if isMarkdown {
            var start = caret
            while start > 0, symbol(units[start - 1]) == character { start -= 1 }
            if let before = start > 0 ? symbol(units[start - 1]) : nil, before.isLetter || before.isNumber {
                opens = false
            }
        }

        if let next, next == character, steppedOver.contains(character), !(isMarkdown && opens) {
            return Edit(range: NSRange(location: caret, length: 0), replacement: "",
                        caret: caret + 1, undoName: nil)
        }

        guard let closing = pairs[character], !forbidden, previous != "\\", opens else { return nil }
        // The closing character just placed counts as a boundary: that's
        // what lets `*` then `*` produce `**|**` instead of running into its
        // own neighbor.
        guard next == nil || next!.isWhitespace || next! == character
                || permissiveNeighbours.contains(next!) else { return nil }

        return Edit(range: NSRange(location: caret, length: 0),
                    replacement: String(character) + String(closing),
                    caret: caret + 1, undoName: nil)
    }

    /// A line's third backtick opens a **block**, not a third inline
    /// `code`.
    ///
    /// Without this special case, auto-pairing doubled every keystroke and
    /// markdown's most common gesture didn't work:
    ///
    /// | keystroke | buffer |
    /// |---|---|
    /// | 1 | `` `|` `` |
    /// | 2 | `` ``|`` `` |
    /// | 3 | ` ```|``` ` |
    ///
    /// Three keystrokes, six characters, and no block. Stepping over
    /// couldn't catch it: at the start of a line, a run of markers **always**
    /// opens, which is what lets `*` then `*` produce bold, so the third
    /// backtick doubled just like the first two.
    ///
    /// So the exact shape the first two keystrokes produced is recognized,
    /// four backticks with the caret in the middle, at the start of a line,
    /// and it's replaced with the fence, its blank line, and its closing
    /// fence. The caret lands where writing happens: inside the block.
    static func codeFence(typing character: Character, in text: String, selection: NSRange) -> Edit? {
        guard character == "`", selection.length == 0 else { return nil }
        let units = Array(text.utf16)
        let caret = selection.location
        let backtick = UInt16(UnicodeScalar("`").value)
        guard caret >= 2, caret + 2 <= units.count,
              units[caret - 1] == backtick, units[caret - 2] == backtick,
              units[caret] == backtick, units[caret + 1] == backtick else { return nil }

        // A fence opens a line. Elsewhere, in the middle of a sentence,
        // three backticks aren't a block, and the pair is left to do its
        // job.
        let line = lineRange(units, containing: caret)
        let indent = caret - 2 - line.location
        guard indent >= 0, indent <= 3,
              (line.location..<(caret - 2)).allSatisfy({ units[$0] == UInt16(UnicodeScalar(" ").value) })
        else { return nil }

        return Edit(range: NSRange(location: caret - 2, length: 4),
                    replacement: "```\n\n```",
                    caret: caret - 2 + 4,
                    undoName: "Code Block")
    }

    // MARK: - The same gestures, after the fact (dead keys)

    /// `autoPair`'s decision, made **after** the character has been written.
    ///
    /// # Why this second door exists
    ///
    /// On a French keyboard, the grave accent and the tilde are **dead
    /// keys**: the character doesn't arrive raw, it concludes a composition.
    /// `insertText(_:replacementRange:)` then receives it with marked text
    /// and a replacement range, and the two guards that protect the
    /// composition, a closing character cannot be slipped in the middle of
    /// an accent in progress, turned it away **silently**.
    ///
    /// Result measured on the author's keyboard: `(`, `*`, `*`, `"` does
    /// produce `(**"**)`, but three grave accents produce three grave
    /// accents. `` `code` `` never closed, neither did `~~strikethrough~~`,
    /// and promotion to a code block never fired once.
    ///
    /// The composition, though, must be committed by the view before
    /// anything else is touched. So it's left to write, and caught
    /// afterward: the character is already at `caret - 1`, and the three
    /// gestures are replayed on that state.
    ///
    /// - Parameter caret: the position **after** the character that was just
    ///   written.
    static func autoPairAfterTyping(_ character: Character, in text: String,
                                    caret: Int, insideCode: Bool) -> Edit? {
        guard let closing = pairs[character], caret > 0 else { return nil }
        guard !(insideCode && markdownPairs.contains(character)) else { return nil }
        let units = Array(text.utf16)
        guard caret <= units.count, symbol(units[caret - 1]) == character else { return nil }

        // The neighborhood from **before** the keystroke: what followed the
        // caret is now at `caret`, what preceded it is at `caret - 2`.
        let next = caret < units.count ? symbol(units[caret]) : nil
        let previous = caret >= 2 ? symbol(units[caret - 2]) : nil

        let isMarkdown = markdownPairs.contains(character)
        var opens = true
        if isMarkdown {
            var start = caret - 1
            while start > 0, symbol(units[start - 1]) == character { start -= 1 }
            if let before = start > 0 ? symbol(units[start - 1]) : nil, before.isLetter || before.isNumber {
                opens = false
            }
        }

        // Step over: the character that was just written duplicates the
        // closing character that was already there. Ours is removed and we
        // move past it.
        if let next, next == character, steppedOver.contains(character), !(isMarkdown && opens) {
            return Edit(range: NSRange(location: caret - 1, length: 1),
                        replacement: "", caret: caret, undoName: nil)
        }

        guard previous != "\\", opens else { return nil }
        guard next == nil || next!.isWhitespace || next! == character
                || permissiveNeighbours.contains(next!) else { return nil }
        // Place the closing character behind the caret, which doesn't move.
        return Edit(range: NSRange(location: caret, length: 0),
                    replacement: String(closing), caret: caret, undoName: nil)
    }

    /// `codeFence`, after the fact: see `autoPairAfterTyping`.
    ///
    /// The recognized shape is the one the first two keystrokes left behind,
    /// **plus** the third backtick already written: five backticks, the
    /// caret after the third.
    static func codeFenceAfterTyping(_ character: Character, in text: String, caret: Int) -> Edit? {
        guard character == "`", caret >= 3 else { return nil }
        let units = Array(text.utf16)
        let backtick = UInt16(UnicodeScalar("`").value)
        guard caret + 2 <= units.count,
              (caret - 3..<caret).allSatisfy({ units[$0] == backtick }),
              units[caret] == backtick, units[caret + 1] == backtick else { return nil }

        let line = lineRange(units, containing: caret)
        let indent = caret - 3 - line.location
        guard indent >= 0, indent <= 3,
              (line.location..<(caret - 3)).allSatisfy({ units[$0] == UInt16(UnicodeScalar(" ").value) })
        else { return nil }

        return Edit(range: NSRange(location: caret - 3, length: 5),
                    replacement: "```\n\n```",
                    caret: caret - 3 + 4,
                    undoName: "Code Block")
    }

    /// `⌫` between the two halves of a pair deletes both of them.
    ///
    /// Without this, backing out of a parenthesis that wasn't wanted leaves
    /// its twin orphaned, and that's the most common complaint made about
    /// editors that pair without knowing how to undo it.
    static func deletingPair(in text: String, selection: NSRange) -> Edit? {
        guard selection.length == 0, selection.location > 0 else { return nil }
        let units = Array(text.utf16)
        guard selection.location < units.count,
              let opener = symbol(units[selection.location - 1]),
              let closing = pairs[opener],
              symbol(units[selection.location]) == closing else { return nil }
        return Edit(range: NSRange(location: selection.location - 1, length: 2), replacement: "",
                    caret: selection.location - 1, undoName: nil)
    }

    /// The character of a UTF-16 code unit, when it is one entirely on its
    /// own. Half of a surrogate pair can never be one of our delimiters, all
    /// ASCII: returning `nil` is enough.
    private static func symbol(_ unit: UInt16) -> Character? {
        guard let scalar = UnicodeScalar(unit) else { return nil }
        return Character(scalar)
    }

    // MARK: - Wrapping via a shortcut

    /// `⌘B`, `⌘I` and friends: wraps the selection, or **removes** the
    /// formatting if it's already there (§2.5).
    static func wrap(_ text: String, selection: NSRange, with marker: String) -> Edit {
        let units = Array(text.utf16)
        let markerUnits = Array(marker.utf16)
        let length = markerUnits.count

        // Already wrapped: it gets removed, rather than stacking a second
        // level.
        //
        // # What the comparison alone missed
        //
        // It looked at the `length` characters on each side and stopped
        // there. Around `**word**`, `⌘I` therefore read a `*` on the left
        // and a `*` on the right, the inner halves of the bold, concluded
        // "already italic," and **removed the bold**: `⌘B` then `⌘I` gave
        // `*word*` instead of `***word***`. The Format menu's most common
        // gesture was destroying what the previous gesture had just placed.
        //
        // What decides, then, is the **length of the run** of asterisks, not
        // its first characters: two asterisks are bold, three are both at
        // once, and a run of any other length isn't ours.
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: selection.upperBound, length: length)
        if before.location >= 0, after.upperBound <= units.count,
           slice(units, before) == marker, slice(units, after) == marker,
           encloses(units, selection, marker: marker, length: length) {
            let whole = NSRange(location: before.location, length: length * 2 + selection.length)
            return Edit(range: whole,
                        replacement: slice(units, selection),
                        caret: before.location,
                        undoName: "Remove Formatting",
                        selectionLength: selection.length)
        }

        let inner = slice(units, selection)
        return Edit(range: selection,
                    replacement: marker + inner + marker,
                    // On a plain caret, the caret is placed **between** the
                    // markers: the request was for bold to write in bold,
                    // not to drop two asterisks and go looking for where to
                    // type.
                    //
                    // With a selection, it is **kept on the same text**, as
                    // typing a `*` over a selection already does (see
                    // `autoPair`). Without this, `⌘B` then `⌘I` would be
                    // impossible: the first key would undo the selection the
                    // second one needed, and the two paths to the same
                    // gesture wouldn't behave the same way.
                    caret: selection.location + length,
                    undoName: "Format",
                    selectionLength: selection.length)
    }

    /// Is the run of markers surrounding the selection really **the one
    /// being removed**, rather than a longer one it's merely a fragment of?
    ///
    /// Two lengths qualify for removal:
    ///
    /// - `length` exactly: `*word*` for `⌘I`, `**word**` for `⌘B`;
    /// - three, for the asterisk family: `***word***` carries bold **and**
    ///   italic, and each of the two shortcuts must be able to remove its
    ///   own share without taking the other with it.
    ///
    /// Any other length means the selection is bordered by a different
    /// format: it then gets stacked, which is the gesture that was asked
    /// for.
    private static func encloses(_ units: [UInt16], _ selection: NSRange,
                                 marker: String, length: Int) -> Bool {
        guard let symbol = marker.utf16.first else { return false }
        var leading = 0
        while selection.location - leading - 1 >= 0,
              units[selection.location - leading - 1] == symbol { leading += 1 }
        var trailing = 0
        while selection.upperBound + trailing < units.count,
              units[selection.upperBound + trailing] == symbol { trailing += 1 }

        guard leading == trailing else { return false }
        let combinable = marker.allSatisfy { $0 == "*" || $0 == "_" }
        return leading == length || (combinable && leading == 3 && length < 3)
    }

    /// Changes a heading's level, or removes it when `level` is 0.
    static func setHeadingLevel(_ level: Int, in text: String, selection: NSRange) -> Edit {
        let units = Array(text.utf16)
        let line = lineRange(units, containing: selection.location)
        let existing = headingPrefix(units, line: line)
        let replacement = level == 0 ? "" : String(repeating: "#", count: level) + " "
        let delta = replacement.utf16.count - existing
        return Edit(range: NSRange(location: line.location, length: existing),
                    replacement: replacement,
                    caret: max(line.location, selection.location + delta),
                    undoName: level == 0 ? "Body" : "Heading \(level)")
    }

    // MARK: - Line parsing

    /// The range of the line containing `location`, terminator excluded.
    static func lineRange(_ units: [UInt16], containing location: Int) -> NSRange {
        let newline = UInt16(UnicodeScalar("\n").value)
        var start = min(location, units.count)
        while start > 0, units[start - 1] != newline { start -= 1 }
        var end = start
        while end < units.count, units[end] != newline { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The list item marker at the start of a line, indentation and
    /// checkbox included.
    static func listPrefix(_ units: [UInt16], line: NSRange) -> NSRange? {
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        let bullets: Set<UInt16> = [UInt16(UnicodeScalar("-").value),
                                    UInt16(UnicodeScalar("*").value),
                                    UInt16(UnicodeScalar("+").value)]
        var offset = 0
        while offset < line.length, units[line.location + offset] == space || units[line.location + offset] == tab {
            offset += 1
        }
        guard offset < line.length else { return nil }

        let first = units[line.location + offset]
        if bullets.contains(first) {
            offset += 1
        } else if isDigit(first) {
            while offset < line.length, isDigit(units[line.location + offset]) { offset += 1 }
            guard offset < line.length else { return nil }
            let delimiter = units[line.location + offset]
            guard delimiter == UInt16(UnicodeScalar(".").value)
                    || delimiter == UInt16(UnicodeScalar(")").value) else { return nil }
            offset += 1
        } else {
            return nil
        }

        // The space after the marker is part of it. Without it, `-text`,
        // which isn't a list, would be mistaken for an item.
        guard offset < line.length, units[line.location + offset] == space else { return nil }
        offset += 1

        // The checkbox is inseparable from the bullet: `- [x] ` as one unit.
        if offset + 2 < line.length,
           units[line.location + offset] == UInt16(UnicodeScalar("[").value),
           units[line.location + offset + 2] == UInt16(UnicodeScalar("]").value) {
            offset += 3
            if offset < line.length, units[line.location + offset] == space { offset += 1 }
        }
        return NSRange(location: line.location, length: offset)
    }

    private static func headingPrefix(_ units: [UInt16], line: NSRange) -> Int {
        let hash = UInt16(UnicodeScalar("#").value)
        let space = UInt16(UnicodeScalar(" ").value)
        var offset = 0
        while offset < line.length, units[line.location + offset] == hash, offset < 6 { offset += 1 }
        guard offset > 0 else { return 0 }
        if offset < line.length, units[line.location + offset] == space { offset += 1 }
        return offset
    }

    private static func leadingSpaces(_ units: [UInt16], line: NSRange) -> Int {
        let space = UInt16(UnicodeScalar(" ").value)
        var count = 0
        while count < line.length, units[line.location + count] == space { count += 1 }
        return count
    }

    /// Does the line above carry text?
    ///
    /// True only if there is one **and** it isn't already blank: that's
    /// exactly the case where exiting a list must insert a blank line to cut
    /// off the lazy continuation.
    private static func needsBlankLineAbove(_ units: [UInt16], line: NSRange) -> Bool {
        guard line.location > 0 else { return false }
        let previous = lineRange(units, containing: line.location - 1)
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        return (0..<previous.length).contains {
            let unit = units[previous.location + $0]
            return unit != space && unit != tab
        }
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    private static func slice(_ units: [UInt16], _ range: NSRange) -> String {
        guard range.location >= 0, range.upperBound <= units.count, range.length >= 0 else { return "" }
        return String(decoding: units[range.location..<range.upperBound], as: UTF16.self)
    }
}
