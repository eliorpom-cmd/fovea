// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
import XCTest
@testable import Fovea

/// The slash menu's filtering (§4.5).
///
/// It's an approximate search: a few letters typed in order, not the exact
/// title. What matters is that it finds what's being aimed at without
/// requiring it to be spelled correctly.
final class SubsequenceMatchTests: XCTestCase {

    /// **Accents must not be a barrier to entry.**
    ///
    /// The comparison used to run on a plain `lowercased()`: in an app
    /// whose titles are accented as often as not, it required typing the
    /// exact accent — that is, already knowing what was being searched for.
    func testAccentsAreNotRequiredToFindATitle() {
        XCTAssertNotNil(SubsequenceMatch.score("Order a café", query: "cafe"))
        XCTAssertNotNil(SubsequenceMatch.score("Write my résumé", query: "resume"))
        XCTAssertNotNil(SubsequenceMatch.score("Stay naïve", query: "naive"))
        XCTAssertNotNil(SubsequenceMatch.score("Meet Zoë", query: "zoe"))
    }

    /// And the reverse: typing the accent must still work.
    func testTypingTheAccentStillWorks() {
        XCTAssertNotNil(SubsequenceMatch.score("Order a café", query: "café"))
        XCTAssertNotNil(SubsequenceMatch.score("Meet Zoë", query: "Zoë"))
    }

    func testTheCaseIsStillIgnored() {
        XCTAssertNotNil(SubsequenceMatch.score("Code Block", query: "CODE"))
        XCTAssertNotNil(SubsequenceMatch.score("Code Block", query: "code"))
    }

    /// What doesn't match must not start matching: folding accents must not
    /// make everything equivalent.
    func testWhatDoesNotMatchStillDoesNot() {
        XCTAssertNil(SubsequenceMatch.score("Code Block", query: "zzz"))
        XCTAssertNil(SubsequenceMatch.score("Résumé", query: "table"))
    }

    /// A word start is worth more than a letter in the middle: it's what
    /// puts "Print Document" ahead when typing "pd".
    func testAWordStartScoresHigherThanAMiddleLetter() throws {
        let atStart = try XCTUnwrap(SubsequenceMatch.score("Print Document", query: "pd"))
        let inMiddle = try XCTUnwrap(SubsequenceMatch.score("Ападpd", query: "pd"))
        XCTAssertGreaterThan(atStart, inMiddle)
    }
}
