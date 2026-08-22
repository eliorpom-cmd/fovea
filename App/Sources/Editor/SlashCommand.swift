// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import Foundation

/// The blocks that can be inserted from the keyboard, without knowing their syntax (§4.5).
///
/// # Why this menu is not just a convenience
///
/// It is the direct counterpart to §2.1. An app that **hides** markers must
/// offer another way to place them: without it, inserting a table would
/// require knowing by heart a syntax the editor has just made disappear from
/// the screen.
///
/// Everything lives here rather than in the view, and without AppKit: what
/// each entry inserts is a product decision, not an interface detail, and a
/// test should be able to read it.
enum SlashCommand: String, CaseIterable, Sendable {
    case heading1, heading2, heading3
    case bulletList, numberedList, taskList
    case quote, codeBlock, table, rule

    var title: String {
        switch self {
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bulletList: "Bulleted List"
        case .numberedList: "Numbered List"
        case .taskList: "Task List"
        case .quote: "Blockquote"
        case .codeBlock: "Code Block"
        case .table: "Table"
        case .rule: "Horizontal Rule"
        }
    }

    /// What's shown on the right: the syntax it places. The menu teaches
    /// markdown to anyone who wants to learn it, instead of hiding it forever.
    var hint: String {
        switch self {
        case .heading1: "#"
        case .heading2: "##"
        case .heading3: "###"
        case .bulletList: "-"
        case .numberedList: "1."
        case .taskList: "- [ ]"
        case .quote: ">"
        case .codeBlock: "```"
        case .table: "| |"
        case .rule: "---"
        }
    }

    /// What can be typed to find it, in addition to the title.
    ///
    /// Aliases, not synonyms of the title: someone who knows markdown reaches
    /// for `/hr`, `/todo` or `/pre` without ever thinking of the word the menu
    /// displays.
    var keywords: [String] {
        switch self {
        case .heading1: ["title", "heading", "h1"]
        case .heading2: ["title", "heading", "h2"]
        case .heading3: ["title", "heading", "h3"]
        case .bulletList: ["list", "bullet"]
        case .numberedList: ["list", "number", "ordered"]
        case .taskList: ["task", "todo", "check", "checkbox", "box"]
        case .quote: ["quote", "citation", "blockquote"]
        case .codeBlock: ["code", "block", "pre"]
        case .table: ["table", "grid"]
        case .rule: ["rule", "hr", "line", "separator", "divider"]
        }
    }
}

extension SlashCommand {

    /// The entries that match what was typed after the `/`.
    ///
    /// Typing `/tb` should find "Table", and `/hr` "Horizontal Rule": the
    /// letters in order, not the exact word. See `SubsequenceMatch`.
    static func matching(_ query: String) -> [SlashCommand] {
        guard !query.isEmpty else { return allCases }
        return allCases
            .compactMap { command -> (SlashCommand, Int)? in
                let candidates = [command.title] + command.keywords
                guard let best = candidates.compactMap({ SubsequenceMatch.score($0, query: query) }).max() else {
                    return nil
                }
                return (command, best)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

extension TypingBehaviour {

    /// What the caret just typed to open the menu.
    struct SlashTrigger: Equatable {
        /// The range to replace: the `/` and whatever was typed after it.
        var range: NSRange
        /// What follows the `/`, to filter the list.
        var query: String
        /// True when text precedes the `/` on the line: the inserted block
        /// must then start with a newline, otherwise it would stick to the
        /// sentence in progress and would not be a block at all.
        var startsNewLine = false
    }

    /// Should the menu be open, given the current line and the caret?
    ///
    /// # What decides is what precedes the `/`
    ///
    /// The first version only opened the menu on a **blank line**, out of
    /// concern that a `/` in the middle of a sentence — `https://`, `/Users/`,
    /// `12/03`, `and/or` — would make the key unusable. The concern is well
    /// founded, but the condition was too broad: it denied the menu to
    /// exactly the people it serves, those who don't know the syntax that
    /// was hidden from them and who will never guess that a blank line is
    /// required first.
    ///
    /// The right discriminant is narrower: **the `/` must open a word**,
    /// that is, be at the start of the line or preceded by whitespace. All
    /// four feared cases have a character glued in front of the `/`, so they
    /// are all ruled out by the same rule, at no cost to the rest.
    ///
    /// The function takes **the line**, not the document. This is
    /// deliberate: it is called on every keystroke and every caret move, and
    /// the first version, which built the UTF-16 array of the whole
    /// document, would on its own have pushed the typing cycle above the §9
    /// budget on a long text.
    ///
    /// - Parameters:
    ///   - line: the caret's line, terminator excluded.
    ///   - lineStart: its offset in the document, to produce an absolute range.
    ///   - caret: the caret, as an absolute offset.
    static func slashTrigger(inLine line: String, lineStart: Int, caret: Int) -> SlashTrigger? {
        let units = Array(line.utf16)
        let offset = caret - lineStart
        guard offset > 0, offset <= units.count else { return nil }

        // The caret must be at the end of the line. The menu accompanies
        // typing; opening in the middle of already-written text would leave
        // the end of the sentence behind the inserted block, in the last
        // cell of a table or after a code fence.
        guard offset == units.count else { return nil }

        // The `/` that opened it: the last one before the caret, with no
        // whitespace between them — what follows it is the search in progress.
        let slash = UInt16(UnicodeScalar("/").value)
        var start = offset - 1
        while start >= 0, !isBlank(units[start]), units[start] != slash { start -= 1 }
        guard start >= 0, units[start] == slash else { return nil }

        // The rule that makes the `/` key usable again for what it is: glued
        // to a character, it opens nothing.
        if start > 0, !isBlank(units[start - 1]) { return nil }

        let query = String(decoding: units[(start + 1)..<offset], as: UTF16.self)
        return SlashTrigger(range: NSRange(location: lineStart + start, length: offset - start),
                            query: query,
                            startsNewLine: units[..<start].contains { !isBlank($0) })
    }

    private static func isBlank(_ unit: UInt16) -> Bool {
        unit == UInt16(UnicodeScalar(" ").value) || unit == UInt16(UnicodeScalar("\t").value)
    }

    /// The edit that replaces `/query` with the chosen block.
    static func insertion(of command: SlashCommand, replacing trigger: SlashTrigger) -> Edit {
        let (body, caretOffset) = template(for: command)
        // A block placed after a sentence starts on its own line. The
        // whitespace left before the newline has no effect in markdown, and
        // removing it would touch text the user didn't ask to have touched.
        let lead = trigger.startsNewLine ? "\n" : ""
        return Edit(range: trigger.range,
                    replacement: lead + body,
                    caret: trigger.range.location + lead.utf16.count + caretOffset,
                    undoName: "Insert: \(command.title)")
    }

    /// The text placed, and where the caret lands inside it.
    ///
    /// The caret goes **where you write next**: inside the code block and
    /// not after its closing fence, in the table's first cell and not on the
    /// next line. That's what makes the difference between a menu that helps
    /// and a menu that leaves work behind.
    private static func template(for command: SlashCommand) -> (String, Int) {
        switch command {
        case .heading1: ("# ", 2)
        case .heading2: ("## ", 3)
        case .heading3: ("### ", 4)
        case .bulletList: ("- ", 2)
        case .numberedList: ("1. ", 3)
        case .taskList: ("- [ ] ", 6)
        case .quote: ("> ", 2)
        case .codeBlock: ("```\n\n```", 4)
        case .rule: ("---\n\n", 5)
        case .table: (
            """
            |  |  |
            |---|---|
            |  |  |
            """, 2)
        }
    }
}
