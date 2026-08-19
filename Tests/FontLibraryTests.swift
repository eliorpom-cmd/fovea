// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Font import (§4.7).
///
/// The promise kept here is narrow but precise: **the user's system is
/// never touched**. An imported font exists only while Fovea is running,
/// and removing it means deleting a file.
@MainActor
final class FontLibraryTests: XCTestCase {

    /// Static, not an instance property: `setUp` and `tearDown` are declared
    /// `nonisolated` by XCTest, and capturing `self` in them to hop back to
    /// the main thread is rejected by strict concurrency. A local variable
    /// passed into the closure captures nothing.
    private nonisolated(unsafe) static var sandbox: URL!

    // A `@MainActor` class sees `setUp` called on the main thread;
    // `assumeIsolated` is therefore the exact assertion of what is true,
    // and it will raise a loud error if that ever stops being the case.

    override nonisolated func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        Self.sandbox = folder
        MainActor.assumeIsolated { FontLibrary.folderOverride = folder }
    }

    override nonisolated func tearDown() {
        let folder = Self.sandbox
        MainActor.assumeIsolated {
            for family in FontLibrary.importedFamilies() {
                FontLibrary.remove(family: family)
            }
            FontLibrary.folderOverride = nil
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }

    /// A real font file, taken from the system. The test does not modify
    /// it; it copies it, the way a user would.
    private func systemFontFile() throws -> URL {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Academy Engraved LET Fonts.ttf",
            "/System/Library/Fonts/Supplemental/Courier New.ttf",
            "/System/Library/Fonts/Supplemental/Georgia.ttf",
        ].map(URL.init(fileURLWithPath:))

        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("No known system font found on this machine")
        }
        return found
    }

    // MARK: - Import

    func testAnImportedFontAppearsInTheLibrary() throws {
        let source = try systemFontFile()
        XCTAssertTrue(FontLibrary.importedFamilies().isEmpty)

        let added = try FontLibrary.importFont(at: source)
        XCTAssertFalse(added.isEmpty, "The import must return the family that was added")
        XCTAssertEqual(FontLibrary.importedFamilies(), added)
    }

    func testTheFileIsCopiedNotMoved() throws {
        // The user drops a font in, they don't give it away: the original
        // stays where it is.
        let source = try systemFontFile()
        _ = try FontLibrary.importFont(at: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.sandbox.appendingPathComponent(source.lastPathComponent).path))
    }

    func testAnImportedFontIsUsableImmediately() throws {
        // Registered at `.process` scope, it must be resolvable without
        // relaunching the app — otherwise the setting would show nothing
        // until tomorrow.
        let source = try systemFontFile()
        let added = try FontLibrary.importFont(at: source)
        let family = try XCTUnwrap(added.first)
        XCTAssertNotNil(NSFont(name: family, size: 14))
    }

    func testImportingTwiceIsRefusedWithAReason() throws {
        let source = try systemFontFile()
        _ = try FontLibrary.importFont(at: source)

        XCTAssertThrowsError(try FontLibrary.importFont(at: source)) { error in
            guard case FontLibrary.ImportError.alreadyPresent = error else {
                return XCTFail("Expected: already present, got \(error)")
            }
        }
    }

    func testAFileThatIsNotAFontIsRefused() throws {
        try FileManager.default.createDirectory(at: Self.sandbox, withIntermediateDirectories: true)
        let fake = Self.sandbox.appendingPathComponent("fake.ttf")
        try Data("this is not a font".utf8).write(to: fake)

        XCTAssertThrowsError(try FontLibrary.importFont(at: fake)) { error in
            guard case FontLibrary.ImportError.unreadable = error else {
                return XCTFail("Expected: unreadable, got \(error)")
            }
        }
    }

    // MARK: - Removal

    func testRemovingAFamilyDeletesItsFile() throws {
        let source = try systemFontFile()
        let added = try FontLibrary.importFont(at: source)
        let family = try XCTUnwrap(added.first)

        FontLibrary.remove(family: family)

        XCTAssertTrue(FontLibrary.importedFamilies().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Self.sandbox.appendingPathComponent(source.lastPathComponent).path))
    }

    // MARK: - Relaunch

    func testRegisteringAtLaunchPicksUpWhatIsOnDisk() throws {
        // The `.process` scope requires re-registering everything on every
        // launch. This test checks that the startup loop does find the
        // files left behind by the previous session.
        let source = try systemFontFile()
        try FileManager.default.createDirectory(at: Self.sandbox, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source, to: Self.sandbox.appendingPathComponent(source.lastPathComponent))

        FontLibrary.registerAll()
        XCTAssertFalse(FontLibrary.importedFamilies().isEmpty)
    }

    func testAnEmptyLibraryIsNotAnError() {
        // By far the most frequent case: nobody has ever imported
        // anything, and the folder doesn't even exist.
        XCTAssertTrue(FontLibrary.importedFamilies().isEmpty)
        FontLibrary.registerAll()
    }
}
