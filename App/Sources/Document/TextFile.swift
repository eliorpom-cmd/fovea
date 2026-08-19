// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import Foundation

/// Reading and writing the text file, without AppKit, so it's testable.
///
/// This type carries the promise of §5 of the spec: **what the user hasn't
/// touched comes back out byte for byte**. Nothing here normalizes, trims
/// or reformats anything.
enum TextFile {

    /// The line-ending style found on open, to be restored as-is.
    enum LineEnding: String, Sendable {
        case lf = "\n"
        case crlf = "\r\n"
        /// Classic Mac OS. Nearly extinct, but a file that has it must come
        /// back out the way it came in.
        case cr = "\r"

        /// New document: LF, the convention of just about everything today.
        static let `default` = LineEnding.lf
    }

    struct Contents: Sendable {
        /// The text, **always normalized to LF in memory**.
        ///
        /// This is an editing convenience, not a rewrite: `NSTextStorage`
        /// and `swift-markdown` both count lines in LF, and a CRLF in the
        /// buffer would make their indexes diverge. The original style is
        /// kept in `lineEnding` and restored on write.
        var text: String
        var lineEnding: LineEnding
        /// The encoding read. Fovea **always** writes UTF-8 (§5); this
        /// field only serves to warn the user when a conversion will take
        /// place.
        var sourceEncoding: String.Encoding
        var hadBOM: Bool
    }

    enum ReadError: LocalizedError {
        case binary
        case undecodable

        var errorDescription: String? {
            switch self {
            case .binary:
                return "This file isn't text."
            case .undecodable:
                return "This file can't be read as text."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .binary:
                return "It contains binary data. Its extension may be misleading."
            case .undecodable:
                return "Its encoding couldn't be identified."
            }
        }
    }

    // MARK: - Reading

    static func read(_ data: Data) throws -> Contents {
        let (payload, hadBOM, bomEncoding) = stripBOM(data)

        // A null byte can't appear in valid single-byte text. Without this
        // guard, a binary file renamed to `.md` would open as a megabyte of
        // gibberish (§6).
        //
        // UTF-16 is precisely full of null bytes, hence the exemption when
        // a UTF-16 BOM explicitly announces it. Without a BOM, UTF-16 gets
        // rejected as binary: that's the accepted trade-off, nobody writes
        // markdown in UTF-16 without a BOM.
        let isDeclaredUTF16 = bomEncoding == .utf16LittleEndian || bomEncoding == .utf16BigEndian
        if !isDeclaredUTF16, payload.prefix(8192).contains(0) { throw ReadError.binary }

        let encoding: String.Encoding
        let text: String
        if let bomEncoding, let decoded = String(data: payload, encoding: bomEncoding) {
            encoding = bomEncoding
            text = decoded
        } else if let utf8 = String(data: payload, encoding: .utf8) {
            encoding = .utf8
            text = utf8
        } else if let guessed = guessLegacyEncoding(payload) {
            encoding = guessed.encoding
            text = guessed.text
        } else {
            throw ReadError.undecodable
        }

        return Contents(text: normalizeToLF(text),
                        lineEnding: detectLineEnding(text),
                        sourceEncoding: encoding,
                        hadBOM: hadBOM)
    }

    // MARK: - Writing

    /// UTF-8 without a BOM, always (§5). The original line-ending style is
    /// restored at the last moment, on the text that lived as LF in memory.
    static func write(text: String, lineEnding: LineEnding) -> Data {
        let restored = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        return Data(restored.utf8)
    }

    // MARK: - Details

    /// The **first** terminator encountered wins. A mixed file exists,
    /// notably after a sloppy git merge, and gets normalized on save: this
    /// is the only case where Fovea touches something it hasn't edited.
    /// The alternative would be to remember the style line by line, for a
    /// file that's already broken.
    static func detectLineEnding(_ text: String) -> LineEnding {
        var iterator = text.unicodeScalars.makeIterator()
        var previous: Unicode.Scalar?
        while let scalar = iterator.next() {
            if scalar == "\n" { return previous == "\r" ? .crlf : .lf }
            if previous == "\r" { return .cr }
            previous = scalar
        }
        return previous == "\r" ? .cr : .default
    }

    static func normalizeToLF(_ text: String) -> String {
        // `text.contains("\r")` would be false: Swift compares
        // **graphemes**, and `\r\n` is a single one, distinct from `\r`. A
        // Windows file used to slip through normalization, and then had
        // each of its `\n` re-prefixed on save: one more `\r` per line,
        // every time it was saved. The walk is therefore done over the
        // scalars.
        guard text.unicodeScalars.contains("\r") else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func stripBOM(_ data: Data) -> (Data, Bool, String.Encoding?) {
        let boms: [([UInt8], String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for (marker, encoding) in boms where data.starts(with: marker) {
            return (data.dropFirst(marker.count), true, encoding)
        }
        return (data, false, nil)
    }

    /// Last resort, for files written before UTF-8 took over. Latin-1
    /// accepts any sequence of bytes, so it comes last: it must never mask
    /// an encoding that would have worked better.
    private static func guessLegacyEncoding(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        for encoding: String.Encoding in [.windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return (text, encoding)
            }
        }
        return nil
    }
}
