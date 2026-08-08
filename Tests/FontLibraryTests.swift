// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// L'import de polices (§4.7).
///
/// La promesse tenue ici est étroite mais précise : **le système de
/// l'utilisateur n'est jamais touché**. Une police déposée n'existe que
/// pendant que Fovea tourne, et la retirer est supprimer un fichier.
@MainActor
final class FontLibraryTests: XCTestCase {

    /// Statique, et non une propriété d'instance : `setUp` et `tearDown` sont
    /// déclarés `nonisolated` par XCTest, et y capturer `self` pour repasser
    /// sur le thread principal est refusé par la concurrence stricte. Une
    /// variable locale passée dans la fermeture ne capture rien.
    private nonisolated(unsafe) static var sandbox: URL!

    // Une classe `@MainActor` voit `setUp` appelé sur le thread principal ;
    // `assumeIsolated` est donc l'affirmation exacte de ce qui est vrai, et
    // elle lèvera une erreur bruyante si ça cesse de l'être.

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

    /// Un vrai fichier de police, pris dans le système. Le test ne le modifie
    /// pas ; il le copie, comme le ferait l'utilisateur.
    private func systemFontFile() throws -> URL {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Academy Engraved LET Fonts.ttf",
            "/System/Library/Fonts/Supplemental/Courier New.ttf",
            "/System/Library/Fonts/Supplemental/Georgia.ttf",
        ].map(URL.init(fileURLWithPath:))

        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("Aucune police système connue sur cette machine")
        }
        return found
    }

    // MARK: - Import

    func testAnImportedFontAppearsInTheLibrary() throws {
        let source = try systemFontFile()
        XCTAssertTrue(FontLibrary.importedFamilies().isEmpty)

        let added = try FontLibrary.importFont(at: source)
        XCTAssertFalse(added.isEmpty, "L'import doit rendre la famille ajoutée")
        XCTAssertEqual(FontLibrary.importedFamilies(), added)
    }

    func testTheFileIsCopiedNotMoved() throws {
        // L'utilisateur dépose une police, il ne la donne pas : l'original
        // reste où il est.
        let source = try systemFontFile()
        _ = try FontLibrary.importFont(at: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.sandbox.appendingPathComponent(source.lastPathComponent).path))
    }

    func testAnImportedFontIsUsableImmediately() throws {
        // Enregistrée en portée `.process`, elle doit être résolvable sans
        // relancer l'app — sinon le réglage ne montrerait rien avant demain.
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
                return XCTFail("Attendu : déjà présente, obtenu \(error)")
            }
        }
    }

    func testAFileThatIsNotAFontIsRefused() throws {
        try FileManager.default.createDirectory(at: Self.sandbox, withIntermediateDirectories: true)
        let fake = Self.sandbox.appendingPathComponent("faux.ttf")
        try Data("ceci n'est pas une police".utf8).write(to: fake)

        XCTAssertThrowsError(try FontLibrary.importFont(at: fake)) { error in
            guard case FontLibrary.ImportError.unreadable = error else {
                return XCTFail("Attendu : illisible, obtenu \(error)")
            }
        }
    }

    // MARK: - Retrait

    func testRemovingAFamilyDeletesItsFile() throws {
        let source = try systemFontFile()
        let added = try FontLibrary.importFont(at: source)
        let family = try XCTUnwrap(added.first)

        FontLibrary.remove(family: family)

        XCTAssertTrue(FontLibrary.importedFamilies().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Self.sandbox.appendingPathComponent(source.lastPathComponent).path))
    }

    // MARK: - Relance

    func testRegisteringAtLaunchPicksUpWhatIsOnDisk() throws {
        // La portée `.process` impose de tout ré-enregistrer à chaque
        // lancement. Ce test vérifie que la boucle de démarrage retrouve bien
        // les fichiers laissés par la session précédente.
        let source = try systemFontFile()
        try FileManager.default.createDirectory(at: Self.sandbox, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source, to: Self.sandbox.appendingPathComponent(source.lastPathComponent))

        FontLibrary.registerAll()
        XCTAssertFalse(FontLibrary.importedFamilies().isEmpty)
    }

    func testAnEmptyLibraryIsNotAnError() {
        // Le cas de très loin le plus fréquent : personne n'a jamais rien
        // importé, et le dossier n'existe même pas.
        XCTAssertTrue(FontLibrary.importedFamilies().isEmpty)
        FontLibrary.registerAll()
    }
}
