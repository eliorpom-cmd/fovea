// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// The writing features from §4.5: focus mode, typewriter mode,
/// statistics.
///
/// Everything computable lives here, as pure functions: what the current
/// unit is, how many words there are, where the active line must sit. The
/// AppKit part is reduced to setting an opacity and scrolling.
enum WritingModes {

    // MARK: - Focus mode

    /// The range to leave at full intensity, with everything else dimmed.
    ///
    /// - Parameter unit: sentence or paragraph, at the user's choice.
    static func focusRange(in text: NSString, caret: Int, unit: AppSettings.FocusUnit) -> NSRange {
        switch unit {
        case .paragraph:
            return paragraphRange(in: text, containing: caret)
        case .sentence:
            return sentenceRange(in: text, containing: caret)
        }
    }

    /// The paragraph: delimited by blank lines, not by a plain line break.
    ///
    /// A markdown document is almost always hand-wrapped around 80
    /// characters. Taking the line as the paragraph would dim half the
    /// sentence currently being written.
    static func paragraphRange(in text: NSString, containing caret: Int) -> NSRange {
        let position = min(max(0, caret), text.length)
        let current = text.lineRange(for: NSRange(location: position, length: 0))

        // **On a blank line, the unit is that line.**
        //
        // Otherwise the two loops started on either side of the caret and
        // never met: the paragraph above **and** the one below both stayed
        // at full intensity. That is the state reached after every `⏎ ⏎`,
        // that is, at every paragraph change.
        guard !isBlank(text, current) else { return current }

        // A heading is a **one**-line block: without this case, it
        // absorbed the paragraph written right below it, and focus mode
        // left both at full intensity. A list item, though, can continue
        // onto the next line — the loop below handles that.
        if startsHeading(text, current) { return current }

        var start = current.location
        // **A list item and a heading are their own blocks.**
        //
        // A markdown list has no blank line between its items: it was
        // therefore **a single paragraph**, and since an item almost never
        // has strong punctuation, the "sentence" unit fell back to it. Ten
        // items, focus mode on, caret in the middle: no dimming at all. The
        // mode looked broken while it was correctly applying its rule.
        if !startsBlock(text, current) {
            while start > 0 {
                let previous = text.lineRange(for: NSRange(location: start - 1, length: 0))
                // A heading is a boundary that is not crossed; the list
                // item above, on the other hand, is the head of the block
                // being written: it is taken, then the loop stops.
                if isBlank(text, previous) || startsHeading(text, previous) { break }
                start = previous.location
                if startsListItem(text, previous) { break }
            }
        }

        var end = current.upperBound
        while end < text.length {
            let next = text.lineRange(for: NSRange(location: end, length: 0))
            if isBlank(text, next) || startsBlock(text, next) { break }
            end = next.upperBound
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Does this line open a block by itself — a heading, a list item?
    ///
    /// Read directly on the `NSString`, without building a UTF-16 array:
    /// the function is called for every line scanned, on every caret
    /// movement.
    static func startsBlock(_ text: NSString, _ line: NSRange) -> Bool {
        startsHeading(text, line) || startsListItem(text, line)
    }

    /// A heading: up to six "#", then a space.
    static func startsHeading(_ text: NSString, _ line: NSRange) -> Bool {
        guard var index = contentStart(text, line) else { return false }
        let limit = line.upperBound
        guard text.character(at: index) == 35 else { return false }
        var hashes = 0
        while index < limit, text.character(at: index) == 35 {
            index += 1
            hashes += 1
        }
        return hashes <= 6 && index < limit && isSpace(text.character(at: index))
    }

    /// A list item: a bullet or a number, then a space.
    static func startsListItem(_ text: NSString, _ line: NSRange) -> Bool {
        guard var index = contentStart(text, line) else { return false }
        let limit = line.upperBound

        // A bullet: "-", "*" or "+", then a space.
        let first = text.character(at: index)
        if first == 45 || first == 42 || first == 43 {
            return index + 1 < limit && isSpace(text.character(at: index + 1))
        }

        // A number: digits, "." or ")", then a space.
        var digits = 0
        while index < limit, text.character(at: index) >= 48, text.character(at: index) <= 57 {
            index += 1
            digits += 1
        }
        guard digits > 0, index < limit else { return false }
        let delimiter = text.character(at: index)
        guard delimiter == 46 || delimiter == 41 else { return false }
        return index + 1 < limit && isSpace(text.character(at: index + 1))
    }

    /// The first non-blank character of a line, if it has one and it is
    /// not indented too far — beyond three spaces, it is no longer a block
    /// marker.
    private static func contentStart(_ text: NSString, _ line: NSRange) -> Int? {
        var index = line.location
        var indent = 0
        while index < line.upperBound, isSpace(text.character(at: index)) {
            index += 1
            indent += 1
        }
        guard indent <= 3, index < line.upperBound else { return nil }
        return index
    }

    /// The sentence, bounded by its paragraph.
    ///
    /// Strong punctuation makes the boundary, except when it follows a
    /// common abbreviation: "Mr. Smith" or "etc." do not end a sentence,
    /// and the dimming would flicker in the middle of a word.
    static func sentenceRange(in text: NSString, containing caret: Int) -> NSRange {
        let paragraph = paragraphRange(in: text, containing: caret)
        guard paragraph.length > 0 else { return paragraph }
        let position = min(max(paragraph.location, caret), paragraph.upperBound)

        var start = paragraph.location
        var index = paragraph.location
        var lastBoundary = paragraph.location
        while index < paragraph.upperBound {
            let character = text.character(at: index)
            if character == 46 || character == 33 || character == 63 { // . ! ?
                var after = index + 1
                while after < paragraph.upperBound,
                      isSpace(text.character(at: after)) || isClosingPunctuation(text.character(at: after)) {
                    after += 1
                }
                if after > position { break }
                if !endsWithAbbreviation(text, endingAt: index) {
                    lastBoundary = after
                }
            }
            index += 1
        }
        start = lastBoundary

        var end = paragraph.upperBound
        index = max(start, position)
        while index < paragraph.upperBound {
            let character = text.character(at: index)
            if character == 46 || character == 33 || character == 63,
               !endsWithAbbreviation(text, endingAt: index) {
                var after = index + 1
                while after < paragraph.upperBound, isClosingPunctuation(text.character(at: after)) {
                    after += 1
                }
                end = after
                break
            }
            index += 1
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Statistics

    struct Statistics: Equatable {
        var words: Int
        var characters: Int
        /// Minutes, rounded up, never zero for non-empty text.
        var readingMinutes: Int
    }

    /// Counts words the way a reader would count them.
    ///
    /// Markdown syntax is excluded: the `#` of a heading, the `**` of a
    /// bold word and a link's URL are not words. Counting the source would
    /// give a total that means nothing to anyone — and that would inflate
    /// with every bit of formatting.
    /// The constructs received **are not guaranteed to fit inside the
    /// text**, and that is what used to crash the app.
    ///
    /// On a selection, the caller brings the constructs back to the
    /// coordinates of the selected fragment by shifting them by
    /// `-selection.location`. A construct that *starts before* the
    /// selection — a `**bold**` of which only the end was taken, a link
    /// straddling the boundary — then ends up at a **negative** position,
    /// and one that ends after overflows on the other side.
    ///
    /// The old bounding wrote `max(0, start)..<min(units, end)`. Each bound
    /// taken separately looks safe; together, they flip as soon as the
    /// range falls entirely on one side or the other — `0..<-3` — and Swift
    /// halts the program. Selecting two paragraphs was enough to trigger a
    /// `Range requires lowerBound <= upperBound`, on every mouse movement
    /// during the drag.
    ///
    /// Hence the intersection, which is what the two bounds meant to say.
    private static func clamped(_ range: NSRange, to units: Int) -> Range<Int>? {
        let lower = max(0, range.location)
        let upper = min(units, range.upperBound)
        return lower < upper ? lower..<upper : nil
    }

    static func statistics(of text: String, spans: [SyntaxSpan]) -> Statistics {
        let units = text.utf16.count
        var isSyntax = [Bool](repeating: false, count: units)
        for span in spans {
            for marker in span.markers {
                guard let range = clamped(marker, to: units) else { continue }
                for offset in range { isSyntax[offset] = true }
            }
            // A URL is not text to read; a link's label is.
            if case .link = span.kind {
                let url = NSRange(location: span.content.upperBound,
                                  length: max(0, span.range.upperBound - span.content.upperBound))
                guard let range = clamped(url, to: units) else { continue }
                for offset in range { isSyntax[offset] = true }
            }
        }

        var words = 0
        var characters = 0
        var inWord = false
        let string = text as NSString
        for offset in 0..<units where !isSyntax[offset] {
            let character = string.character(at: offset)
            if isSpace(character) || character == 10 {
                inWord = false
            } else {
                characters += 1
                if !inWord { words += 1; inWord = true }
            }
        }

        // 200 words per minute: the silent reading speed commonly used for
        // prose.
        let minutes = words == 0 ? 0 : max(1, Int((Double(words) / 200).rounded(.up)))
        return Statistics(words: words, characters: characters, readingMinutes: minutes)
    }

    // MARK: - Details

    private static func isBlank(_ text: NSString, _ line: NSRange) -> Bool {
        for offset in line.location..<line.upperBound {
            let character = text.character(at: offset)
            guard character == 10 || character == 13 || character == 32 || character == 9 else { return false }
        }
        return true
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 32 || character == 9 || character == 160
    }

    private static func isClosingPunctuation(_ character: unichar) -> Bool {
        character == 34 || character == 39 || character == 41 || character == 93 // " ' ) ]
            || character == 0x00BB || character == 0x201D // » ”
    }

    /// "Mr.", "etc.", "cf.": strong punctuation that ends nothing.
    ///
    /// The list is English honorifics and the usual scholarly abbreviations,
    /// matched case-sensitively against the word before the dot. It is a
    /// heuristic, not a parser: an unlisted abbreviation splits the sentence
    /// in two, which at worst makes the focus dimming stop one clause short.
    private static func endsWithAbbreviation(_ text: NSString, endingAt dotIndex: Int) -> Bool {
        let abbreviations = ["Mr", "Mrs", "Ms", "Dr", "Prof", "St", "Jr", "Sr",
                             "etc", "cf", "e.g", "i.e", "vs", "p", "pp", "vol", "no", "Fig"]
        var start = dotIndex
        while start > 0 {
            let character = text.character(at: start - 1)
            guard !isSpace(character), character != 10 else { break }
            start -= 1
        }
        guard start < dotIndex else { return false }
        let word = text.substring(with: NSRange(location: start, length: dotIndex - start))
        return abbreviations.contains(word)
    }
}
