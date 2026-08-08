// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Les états limites du §6.
///
/// Le cahier des charges pose la règle : chacun a un comportement défini, et
/// **aucun n'a le droit d'être un état par défaut**. Un écran vide, un message
/// faux ou un silence sont trois façons de rater la même chose.
@MainActor
final class EdgeStateTests: XCTestCase {

    // MARK: - Ce que le bandeau dit, et quand il se tait

    func testAnOrdinaryDocumentSaysNothing() {
        // Le cas de très loin le plus fréquent. Un bandeau qui s'affiche pour
        // rien serait exactement le chrome que le §7 interdit.
        XCTAssertTrue(DocumentBanner.messages(byteCount: 4_000, encoding: .utf8, isWritable: true).isEmpty)
    }

    func testALargeDocumentSuggestsSourceModeWithoutSwitching() {
        let messages = DocumentBanner.messages(byteCount: 2_000_000, encoding: .utf8, isWritable: true)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("⌘/"), messages[0])
        // « L'app ne bascule jamais toute seule » : le message informe, il ne
        // dit pas qu'il a agi.
        XCTAssertFalse(messages[0].lowercased().contains("activé"))
    }

    func testTheThresholdIsAMegabyte() {
        XCTAssertTrue(DocumentBanner.messages(byteCount: 1_000_000, encoding: .utf8, isWritable: true).isEmpty)
        XCTAssertFalse(DocumentBanner.messages(byteCount: 1_000_001, encoding: .utf8, isWritable: true).isEmpty)
    }

    func testALegacyEncodingAnnouncesTheConversion() {
        let messages = DocumentBanner.messages(byteCount: 100, encoding: .isoLatin1, isWritable: true)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("ISO-8859-1"), messages[0])
        XCTAssertTrue(messages[0].contains("UTF-8"), messages[0])
    }

    func testAReadOnlyFileSaysHowToKeepChanges() {
        // §6 : le document s'ouvre et reste modifiable. Ce qui ne marchera pas,
        // c'est l'enregistrement — et il vaut mieux l'apprendre avant d'écrire
        // trois pages.
        let messages = DocumentBanner.messages(byteCount: 100, encoding: .utf8, isWritable: false)
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("Enregistrer sous"), messages[0])
    }

    func testSeveralFactsAreAllSaid() {
        // Un gros fichier latin-1 en lecture seule : les trois se disent, aucun
        // n'en masque un autre.
        let messages = DocumentBanner.messages(byteCount: 2_000_000, encoding: .windowsCP1252,
                                               isWritable: false)
        XCTAssertEqual(messages.count, 3)
    }

    // MARK: - Images (§6)

    func testAnOversizedImageIsNotCalledMissing() throws {
        // Le fichier existe : l'annoncer « introuvable » serait faux, et c'était
        // pourtant le comportement précédent.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Une image réelle, mais déclarée trop lourde par sa taille sur disque.
        let image = NSImage(size: NSSize(width: 2000, height: 2000))
        image.lockFocus()
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: 2000, height: 2000).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
        try XCTSkipUnless(data.count > 20 * 1024 * 1024,
                          "L'image d'essai n'atteint pas la borne des 20 Mo")

        let file = folder.appendingPathComponent("enorme.tiff")
        try data.write(to: file)

        ImageStore.shared.invalidate()
        defer { ImageStore.shared.invalidate() }
        let document = folder.appendingPathComponent("doc.md")
        guard case .oversized = ImageStore.shared.entry(for: "enorme.tiff", relativeTo: document) else {
            return XCTFail("Une image trop lourde doit être annoncée comme telle, pas comme absente")
        }
    }

    func testAStillImageIsNotReportedAsAnimated() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appendingPathComponent("fixe.png"))

        ImageStore.shared.invalidate()
        defer { ImageStore.shared.invalidate() }
        let document = folder.appendingPathComponent("doc.md")
        guard case .loaded(_, let animated) = ImageStore.shared.entry(for: "fixe.png", relativeTo: document) else {
            return XCTFail("L'image devrait être chargée")
        }
        XCTAssertFalse(animated)
    }

    func testARemoteURLIsNeverFetched() {
        // Un éditeur qui va chercher sur le réseau pendant la frappe est un
        // éditeur qui se fige.
        XCTAssertNil(ImageStore.resolve("https://exemple.fr/photo.png", relativeTo: nil))
    }

    // MARK: - Mode source avec sélection (§6)

    func testSwitchingToSourceExtendsTheSelectionToItsMarkers() {
        // Sélectionner un mot en gras ne sélectionne que le mot — ses `**`
        // étaient invisibles. Sans extension, un ⌘X en mode source laisserait
        // un `**` orphelin.
        let controller = EditorController()
        controller.setText("Un mot **important** ici.\n")

        let word = ("Un mot **important** ici.\n" as NSString).range(of: "important")
        controller.textView.setSelectedRange(word)
        controller.toggleSourceMode()

        let extended = controller.textView.selectedRange()
        XCTAssertEqual(extended, NSRange(location: 7, length: 13),
                       "La sélection doit couvrir **important**, étoiles comprises")
    }

    func testSwitchingBackDoesNotShrinkTheSelection() {
        // Le retour au rendu ne retire rien : ce qui a été sélectionné reste
        // sélectionné, sinon l'aller-retour perdrait du texte.
        let controller = EditorController()
        controller.setText("Un mot **important** ici.\n")
        controller.textView.setSelectedRange(NSRange(location: 7, length: 13))

        controller.toggleSourceMode()
        let inSource = controller.textView.selectedRange()
        controller.toggleSourceMode()

        XCTAssertEqual(controller.textView.selectedRange(), inSource)
    }

    func testAnEmptySelectionIsLeftAlone() {
        // Un curseur seul n'est pas une sélection : l'étendre déplacerait le
        // point d'insertion sans que personne ne l'ait demandé.
        let controller = EditorController()
        controller.setText("Un mot **important** ici.\n")
        controller.textView.setSelectedRange(NSRange(location: 12, length: 0))

        controller.toggleSourceMode()
        XCTAssertEqual(controller.textView.selectedRange(), NSRange(location: 12, length: 0))
    }

    // MARK: - Document vide

    func testAnEmptyDocumentRendersWithoutComplaint() {
        // « Curseur, colonne de texte, et rien d'autre. »
        let controller = EditorController()
        controller.setText("")
        XCTAssertEqual(controller.text, "")
        XCTAssertTrue(controller.spans.isEmpty)
    }
}
