// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import AppKit

/// Loads the images referenced by the document (§4.4).
///
/// # Rendering without an attachment
///
/// An image cannot be an `NSTextAttachment` here: an attachment replaces a
/// character, and §3.1 forbids inserting one. The `![alt](path)` source must
/// stay intact in the buffer.
///
/// The solution is made of two pieces already in place:
///
/// 1. The whole line is **hidden at zero width**, like any other marker, and
///    its paragraph style gets a `minimumLineHeight` equal to the display
///    height of the image. The space is reserved without a single character
///    being added.
/// 2. `DecorationPainter` draws the image into that space.
///
/// The caret behaves like it does for any line-scoped construct: entering the
/// line reveals the source again, leaving it restores the image.
@MainActor
final class ImageStore {

    static let shared = ImageStore()

    /// What is known about a referenced image.
    enum Entry {
        case loaded(NSImage, animated: Bool)
        /// Too large to decode in full: a thumbnail is shown, and this is
        /// reported (§6). The file exists, and calling it "missing" would be
        /// a lie, which was nonetheless the previous behaviour.
        case oversized(NSImage?, bytes: Int)
        /// The file does not exist, or is not a readable image (§6).
        case missing
    }

    private var cache: [URL: Entry] = [:]

    /// Maximum size loaded into memory. Beyond it, the image is refused
    /// rather than letting the app balloon by several hundred megabytes for a
    /// document that is only being read (§6).
    private static let maximumBytes = 20 * 1024 * 1024

    // MARK: - Resolution

    /// Resolves a markdown link to a file URL.
    ///
    /// Relative links are resolved **next to the document**, which is the
    /// whole point of §4.4: the folder can be moved, committed or sent
    /// without anything breaking. Remote URLs are ignored: an editor that
    /// hits the network while typing is an editor that freezes.
    static func resolve(_ source: String, relativeTo document: URL?) -> URL? {
        guard !source.isEmpty else { return nil }
        if let url = URL(string: source), url.scheme != nil {
            return url.isFileURL ? url : nil
        }
        let decoded = source.removingPercentEncoding ?? source
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        guard let document else { return nil }
        return document.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
    }

    // MARK: - Loading

    func entry(for source: String, relativeTo document: URL?) -> Entry {
        guard let url = Self.resolve(source, relativeTo: document) else { return .missing }
        if let cached = cache[url] { return cached }

        let entry: Entry
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > Self.maximumBytes {
            entry = .oversized(Self.thumbnail(of: url), bytes: size)
        } else if let image = NSImage(contentsOf: url), image.size.width > 0 {
            entry = .loaded(image, animated: Self.isAnimated(url))
        } else {
            entry = .missing
        }
        cache[url] = entry
        return entry
    }

    /// A thumbnail read **without decoding the whole image**.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` works on the stream: this is
    /// what makes it possible to show something for a 200 MB image without
    /// paying its memory cost, which is precisely the reason for the cap.
    private static func thumbnail(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// An animated image has several frames in its file.
    ///
    /// Only the first is drawn: animating inside an editor is a permanent CPU
    /// cost, paid while typing, for an image nobody is looking at (§6). The
    /// rendering reports this rather than hiding it.
    private static func isAnimated(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// Forgets what has been loaded.
    ///
    /// Called when the document is saved elsewhere, or an image is replaced
    /// on disk: without this, the old version would stay on screen until the
    /// window closes.
    func invalidate() {
        cache.removeAll(keepingCapacity: true)
    }

    // MARK: - Scaling

    /// Display height of an image in a given column.
    ///
    /// Bounded to the column width (§6) and to a reasonable height: a
    /// vertical phone screenshot, left at its natural proportions, would
    /// occupy three screens and make the document unusable.
    static func displaySize(of image: NSImage, columnWidth: CGFloat) -> NSSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return .zero }

        let maximumHeight = columnWidth * 1.2
        var width = min(natural.width, columnWidth)
        var height = width * natural.height / natural.width
        if height > maximumHeight {
            height = maximumHeight
            width = height * natural.width / natural.height
        }
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    /// Height reserved for a missing image: enough to draw a readable frame
    /// with its path, nothing more.
    static let missingPlaceholderHeight: CGFloat = 56
}
