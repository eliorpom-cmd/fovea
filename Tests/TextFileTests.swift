// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
@testable import Fovea

/// **La promesse du §5 : le fichier survivra à l'app.**
///
/// Un éditeur WYSIWYG qui renormalise à l'enregistrement produit des diffs
/// illisibles — c'est précisément ce qui rend Typora inutilisable sur un dépôt
/// git. Ces tests vérifient qu'ouvrir puis réenregistrer sans rien toucher rend
/// **exactement** les mêmes octets.
final class TextFileTests: XCTestCase {

    // MARK: - L'aller-retour

    func testRoundTripIsByteForByteIdentical() throws {
        let source = """
        # Titre

        Un paragraphe avec des accents : é à ù, un emoji 🙂, et du 日本語.

        - une liste
        * une autre puce, volontairement différente
        + et encore une

        1) une numérotation à parenthèse

            un bloc indenté par quatre espaces

        ```swift
        let x = 1
        ```

        Deux espaces en fin de ligne valent un retour forcé :
        et voici la ligne suivante.
        """
        try assertRoundTrip(Data(source.utf8))
    }

    func testCRLFSurvivesUntouched() throws {
        // Un fichier Windows doit ressortir en CRLF. Le convertir en LF
        // réécrirait chaque ligne du fichier dans le diff.
        let data = Data("# Titre\r\n\r\nDu texte.\r\n".utf8)
        try assertRoundTrip(data)
    }

    func testTrailingSpacesAreNeverTrimmed() throws {
        // Deux espaces en fin de ligne sont un retour forcé en markdown : les
        // retirer « pour faire propre » changerait le rendu du document.
        let data = Data("ligne avec deux espaces  \nligne suivante\n".utf8)
        try assertRoundTrip(data)
    }

    func testFinalNewlinePresenceIsPreserved() throws {
        try assertRoundTrip(Data("sans saut final".utf8))
        try assertRoundTrip(Data("avec saut final\n".utf8))
    }

    func testUnderscoreEmphasisIsNeverConvertedToStars() throws {
        // La règle de non-normalisation du §5, prise au mot.
        try assertRoundTrip(Data("un _mot_ et un __autre__\n".utf8))
    }

    // MARK: - Fins de ligne

    func testLineEndingDetectionUsesTheFirstTerminator() {
        XCTAssertEqual(TextFile.detectLineEnding("a\nb"), .lf)
        XCTAssertEqual(TextFile.detectLineEnding("a\r\nb"), .crlf)
        XCTAssertEqual(TextFile.detectLineEnding("a\rb"), .cr)
        XCTAssertEqual(TextFile.detectLineEnding("sans aucun saut"), .lf)
    }

    func testBufferAlwaysHoldsLFRegardlessOfTheFile() throws {
        // En mémoire le texte vit en LF, sans quoi les index de `NSTextStorage`
        // et ceux de `swift-markdown` divergeraient d'un caractère par ligne.
        let contents = try TextFile.read(Data("a\r\nb\r\nc".utf8))
        XCTAssertEqual(contents.text, "a\nb\nc")
        XCTAssertEqual(contents.lineEnding, .crlf)
    }

    // MARK: - Encodages

    func testUTF8WithBOMIsReadAndWrittenWithout() throws {
        // La BOM est retirée : c'est le seul écart assumé au §5, et il va dans
        // le sens de tous les outils de la chaîne, qui la traitent comme du
        // bruit en tête de fichier.
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("# Titre\n".utf8)
        let contents = try TextFile.read(data)
        XCTAssertEqual(contents.text, "# Titre\n")
        XCTAssertTrue(contents.hadBOM)
        XCTAssertEqual(TextFile.write(text: contents.text, lineEnding: contents.lineEnding),
                       Data("# Titre\n".utf8))
    }

    func testLatin1IsReadAsALastResort() throws {
        // Un fichier écrit avant qu'UTF-8 ne s'impose doit s'ouvrir plutôt que
        // de renvoyer une erreur.
        let data = Data([0x63, 0x61, 0x66, 0xE9]) // « café » en Latin-1
        let contents = try TextFile.read(data)
        XCTAssertEqual(contents.text, "café")
        XCTAssertNotEqual(contents.sourceEncoding, .utf8)
    }

    func testBinaryFileIsRefusedRatherThanShownAsGarbage() {
        // §6 : un binaire renommé `.md` ne doit pas s'ouvrir en un mégaoctet de
        // charabia.
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x0D, 0x0A, 0x1A])
        XCTAssertThrowsError(try TextFile.read(data)) { error in
            XCTAssertEqual(error as? TextFile.ReadError, .binary)
        }
    }

    func testUTF16WithBOMIsNotMistakenForBinary() throws {
        // L'UTF-16 est plein d'octets nuls : sans exemption pour sa BOM, le
        // garde-fou anti-binaire le refuserait.
        var data = Data([0xFF, 0xFE])
        data.append(contentsOf: Array("# Titre".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let contents = try TextFile.read(data)
        XCTAssertEqual(contents.text, "# Titre")
    }

    // MARK: - Outil

    private func assertRoundTrip(_ data: Data,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let contents = try TextFile.read(data)
        let written = TextFile.write(text: contents.text, lineEnding: contents.lineEnding)
        XCTAssertEqual(written, data,
                       "L'aller-retour a modifié le fichier",
                       file: file, line: line)
    }
}

