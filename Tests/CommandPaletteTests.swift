// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
@testable import Fovea

/// Le filtrage de la palette (§4.5).
///
/// C'est une recherche approchée : on tape quelques lettres dans l'ordre, pas
/// le titre exact. Ce qui compte est qu'elle trouve ce qu'on vise sans exiger
/// qu'on l'écrive juste.
final class CommandPaletteTests: XCTestCase {

    /// **Les accents ne doivent pas être une condition d'entrée.**
    ///
    /// La comparaison se faisait sur un `lowercased()` seul : dans une app
    /// française, dont les titres sont accentués une fois sur deux, il fallait
    /// taper l'accent juste — donc connaître déjà ce qu'on cherche.
    func testAccentsAreNotRequiredToFindATitle() {
        XCTAssertNotNil(CommandPalette.score("2. Les tâches — dans 2 — Notes de réunion", query: "taches"))
        XCTAssertNotNil(CommandPalette.score("2. Les tâches — dans 2 — Notes de réunion", query: "reunion"))
        XCTAssertNotNil(CommandPalette.score("Écrire les mentions légales", query: "legales"))
        XCTAssertNotNil(CommandPalette.score("Décisions", query: "decisions"))
    }

    /// Et l'inverse : taper l'accent doit continuer de marcher.
    func testTypingTheAccentStillWorks() {
        XCTAssertNotNil(CommandPalette.score("2. Les tâches", query: "tâches"))
        XCTAssertNotNil(CommandPalette.score("Décisions", query: "Décisions"))
    }

    func testTheCaseIsStillIgnored() {
        XCTAssertNotNil(CommandPalette.score("Plan du document", query: "PLAN"))
        XCTAssertNotNil(CommandPalette.score("Plan du document", query: "plan"))
    }

    /// Ce qui ne correspond pas ne doit pas se mettre à correspondre : replier
    /// les accents ne doit pas tout rendre équivalent.
    func testWhatDoesNotMatchStillDoesNot() {
        XCTAssertNil(CommandPalette.score("Plan du document", query: "zzz"))
        XCTAssertNil(CommandPalette.score("Décisions", query: "tableau"))
    }

    /// Un début de mot vaut mieux qu'une lettre au milieu : c'est ce qui met
    /// « Plan du document » devant quand on tape « pd ».
    func testAWordStartScoresHigherThanAMiddleLetter() throws {
        let atStart = try XCTUnwrap(CommandPalette.score("Plan du document", query: "pd"))
        let inMiddle = try XCTUnwrap(CommandPalette.score("Ападpd", query: "pd"))
        XCTAssertGreaterThan(atStart, inMiddle)
    }
}
