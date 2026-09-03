// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import Foundation

/// Decides **what needs to be re-parsed** after a keystroke.
///
/// # Why this class exists
///
/// §3.3 warned about it: "re-parsing 100,000 words on every keystroke will
/// not hold up." Measurement proved it right. On a 10,000-word document, in
/// Debug, a full cycle cost:
///
/// | Step | Cost |
/// |---|---|
/// | Line table | 1.7 ms |
/// | Parsing (cmark + traversal + conversion) | 36.4 ms |
/// | Applying attributes | 48.0 ms |
/// | **Total** | **88.5 ms** for a budget of 8 ms |
///
/// The two heavy items are proportional to the whole document even though a
/// keystroke only changes one line. The entire optimization comes down to one
/// idea: **only re-parse and re-style the touched block**.
///
/// # When that is not enough
///
/// A block can only be handled in isolation if its meaning does not depend on
/// what surrounds it. Two cases break that assumption, and trigger a full
/// parse:
///
/// - **A code block fence.** Typing ` ``` ` changes the interpretation of
///   *everything that follows*: the rest of the document either becomes code
///   or stops being code. This is the most frequent case in §6, and the most
///   visible.
/// - **An edit inside an existing code block.** Its scope already extends
///   past blank lines, which no longer delimit anything inside it.
enum IncrementalParse {

    /// The scope to re-parse, or `nil` if everything must be redone.
    ///
    /// - Parameters:
    ///   - text: the text **after** the edit.
    ///   - editedRange: the modified range, in the text after the edit.
    ///   - inserted: the inserted text, used to detect a code fence.
    ///   - existingCodeBlocks: the code blocks known **before** the edit.
    static func scope(in text: NSString,
                      editedRange: NSRange,
                      inserted: String,
                      existingCodeBlocks: [NSRange]) -> NSRange? {

        // A code block fence reshuffles everything that follows.
        //
        // **But only a fence.** The rule used to be based on the typed
        // character: a backtick or a tilde, anywhere, triggered a full parse.
        // But a backtick in the middle of a sentence only opens inline
        // `code`, whose scope stops at the next blank line, and an unpaired
        // backtick is not even more than a literal character. The cost of
        // that approximation was steep: on 190,000 characters, typing "a"
        // re-parses 193 characters in 6 ms, typing "`" re-parsed the whole
        // document in 440 ms. A single keystroke, forty times the §9 budget,
        // and auto-pairs insert two of them at once.
        //
        // What matters is therefore not the character but **the line it
        // falls on**: only a closing fence line (three or more of the marker
        // at the start) can change the meaning of what follows.
        if inserted.contains("`") || inserted.contains("~"),
           touchesAFence(in: text, editedRange: editedRange) {
            return nil
        }

        // Editing **inside** a code block: blank lines no longer delimit
        // anything there, block-scoped re-parsing has no meaning.
        if existingCodeBlocks.contains(where: { NSIntersectionRange($0, editedRange).length > 0
                                                || NSLocationInRange(editedRange.location, $0) }) {
            return nil
        }

        var block = blockRange(in: text, around: editedRange)

        // A **neighbouring** code block does not justify redoing everything,
        // but it cannot be cut in two: a fragment starting in the middle of
        // a code block would see its closing fence without its opening one,
        // and read the rest as code.
        //
        // The first version rejected these cases and fell back to a full
        // parse, which, on a document containing a code block every six
        // paragraphs, amounted to having no incremental parsing at all.
        for codeBlock in existingCodeBlocks where NSIntersectionRange(codeBlock, block).length > 0 {
            block = NSUnionRange(block, codeBlock)
        }
        // Widening the range may have touched a new code block: past half
        // the document, a full parse is cheaper than this domino chain
        // anyway.
        if block.length * 2 >= text.length { return nil }
        return block
    }

    /// The block containing the range, delimited by blank lines, **plus the
    /// neighbouring block on each side**.
    ///
    /// The neighbouring margin is not gratuitous caution. A `setext` heading
    /// is underlined by the following line; a list whose blank line
    /// separating it from the next one is deleted merges with it. A margin
    /// block on each side covers these cases at negligible cost.
    static func blockRange(in text: NSString, around range: NSRange) -> NSRange {
        let start = blockBoundaryBackward(in: text, from: range.location, blocks: 2)
        let end = blockBoundaryForward(in: text, from: min(range.upperBound, text.length), blocks: 2)
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Details

    /// Walks back to the start of the n-th preceding block.
    private static func blockBoundaryBackward(in text: NSString, from location: Int, blocks: Int) -> Int {
        var index = min(location, text.length)
        var found = 0
        while index > 0 {
            let lineStart = text.lineRange(for: NSRange(location: index - 1, length: 0)).location
            if isBlank(text, lineAt: lineStart) {
                found += 1
                if found >= blocks { return lineStart }
            }
            if lineStart == 0 { return 0 }
            index = lineStart
        }
        return 0
    }

    private static func blockBoundaryForward(in text: NSString, from location: Int, blocks: Int) -> Int {
        var index = min(location, text.length)
        var found = 0
        while index < text.length {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            if isBlank(text, lineAt: line.location) {
                found += 1
                if found >= blocks { return line.upperBound }
            }
            if line.upperBound <= index { return text.length }
            index = line.upperBound
        }
        return text.length
    }

    /// Is any of the lines touched by the edit a closing fence?
    ///
    /// The test is run on the text **after** the edit: that is the state
    /// that the interpretation of what follows depends on. Every line in the
    /// range is examined, not just the first, so that pasting several lines
    /// containing a fence is caught.
    private static func touchesAFence(in text: NSString, editedRange: NSRange) -> Bool {
        var index = min(editedRange.location, text.length)
        let end = min(editedRange.upperBound, text.length)
        repeat {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            if isFence(text, line: line) { return true }
            guard line.upperBound > index else { break }
            index = line.upperBound
        } while index <= end && index < text.length
        return false
    }

    /// A closing fence line: up to three blanks, then at least three
    /// backticks or three tildes. This is the CommonMark definition, and
    /// nothing else opens a block whose scope extends past the paragraph.
    private static func isFence(_ text: NSString, line: NSRange) -> Bool {
        var offset = line.location
        var blanks = 0
        while offset < line.upperBound, text.character(at: offset) == 32 || text.character(at: offset) == 9 {
            blanks += 1
            offset += 1
        }
        guard blanks <= 3, offset < line.upperBound else { return false }
        let marker = text.character(at: offset)
        guard marker == 96 || marker == 126 else { return false }   // ` or ~
        var run = 0
        while offset < line.upperBound, text.character(at: offset) == marker {
            run += 1
            offset += 1
        }
        return run >= 3
    }

    /// A blank line: empty, or whitespace only.
    private static func isBlank(_ text: NSString, lineAt location: Int) -> Bool {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        for offset in line.location..<line.upperBound {
            let unit = text.character(at: offset)
            guard unit == 10 || unit == 13 || unit == 32 || unit == 9 else { return false }
        }
        return true
    }
}

extension MarkdownParser {

    /// Parses an excerpt and **shifts its positions** so they refer to the
    /// whole document.
    ///
    /// The excerpt is parsed as a standalone document, which is exactly the
    /// assumption `IncrementalParse.scope` verified before splitting it out:
    /// a block delimited by blank lines reads correctly without its context.
    static func parse(_ text: String, offsetBy offset: Int) -> [SyntaxSpan] {
        let spans = offset == 0 ? parse(text).spans : parse(text).spans.map { $0.shifted(by: offset) }
        // Sorted by position, so that `splice` returns a sorted list and
        // `SpanIndex` has nothing left to sort. The fragment is small: this
        // sort replaces the whole-document one, on every keystroke.
        return spans.sorted { $0.range.location < $1.range.location }
    }

    /// In a list of constructs, replaces the ones that fell within the
    /// re-parsed scope, and shifts the ones that follow.
    ///
    /// - Parameters:
    ///   - previous: the constructs from before the edit.
    ///   - scope: the re-parsed scope, in coordinates **after** the edit.
    ///   - delta: the change in the document's length.
    static func splice(_ previous: [SyntaxSpan],
                       replacing scope: NSRange,
                       with fresh: [SyntaxSpan],
                       delta: Int) -> [SyntaxSpan] {
        // The scope expressed in coordinates from before the edit, to sort
        // the old constructs.
        let oldScopeEnd = scope.upperBound - delta

        // `previous` is sorted by position, and so is `fresh`: the
        // concatenation is therefore sorted too, which `SpanIndex` relies on.
        var result = previous.filter { $0.range.upperBound <= scope.location }
        result += fresh
        result += previous
            .filter { $0.range.location >= oldScopeEnd }
            .map { $0.shifted(by: delta) }
        return result
    }
}
