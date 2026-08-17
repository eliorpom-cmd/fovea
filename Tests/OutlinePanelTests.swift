// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import XCTest
import AppKit
@testable import Fovea

/// Le plan du document (§4.5).
///
/// C'est une liste de titres, donc du texte lu par-dessus l'épaule : elle doit
/// se lire comme le document, pas comme sa source.
@MainActor
final class OutlinePanelTests: XCTestCase {

    private func title(of source: String) -> String {
        let spans = MarkdownParser.parse(source).spans
        let heading = spans.first { if case .heading = $0.kind { return true } else { return false } }
        guard let heading else { return "" }
        return OutlinePanel.plainText(of: heading.content, spans: spans, text: source as NSString)
    }

    /// Le plan montrait la source : les `**` d'un titre s'y lisaient tels
    /// quels, dans le seul endroit de l'app qui les laissait voir — et dans un
    /// panneau étroit, ils mangent la place du texte qu'on cherche.
    func testAHeadingLosesItsInlineMarkers() {
        XCTAssertEqual(title(of: "## 2. Les tâches — dans **2 — Notes de réunion**\n"),
                       "2. Les tâches — dans 2 — Notes de réunion")
        XCTAssertEqual(title(of: "### Les tableaux — dans **3 — Doc** ou **6 — Tableaux**\n"),
                       "Les tableaux — dans 3 — Doc ou 6 — Tableaux")
        XCTAssertEqual(title(of: "# Du *italique* et du `code`\n"), "Du italique et du code")
    }

    /// Un lien garde son libellé, pas son adresse : c'est ce qu'on lit à
    /// l'écran.
    func testALinkKeepsOnlyItsLabel() {
        XCTAssertEqual(title(of: "## Voir [le guide](https://exemple.fr) ici\n"),
                       "Voir le guide ici")
    }

    /// Un titre sans rien à retirer ne doit pas être abîmé au passage.
    func testAPlainHeadingIsUntouched() {
        XCTAssertEqual(title(of: "# Ce qu'il y a à tester\n"), "Ce qu'il y a à tester")
        XCTAssertEqual(title(of: "## 4. Les liens\n"), "4. Les liens")
    }

    /// La liste des marqueurs, sortie de la fonction pour n'être calculée
    /// qu'une fois par document, doit donner **exactement** le même texte.
    ///
    /// C'est le seul enjeu de l'optimisation : le plan se reconstruit à chaque
    /// frappe, et refiltrer toutes les constructions par titre était
    /// quadratique. Un titre en bas d'un long document passe désormais par une
    /// dichotomie ; s'il en sortait un mot de moins, ça se verrait ici.
    func testThePrecomputedMarkersGiveTheSameTitles() {
        let source = """
        # Un *premier* titre

        Du texte avec du **gras** et un [lien](https://exemple.fr) au milieu.

        ## Le **deuxième**, plus bas

        Encore du texte, du `code` et de l'*italique* pour intercaler.

        ### Un `troisième` tout en bas
        """
        let text = source as NSString
        let spans = MarkdownParser.parse(source).spans
        let markers = OutlinePanel.inlineMarkers(of: spans)

        let headings = spans.filter { if case .heading = $0.kind { return true } else { return false } }
        XCTAssertEqual(headings.count, 3)
        for heading in headings {
            XCTAssertEqual(OutlinePanel.plainText(of: heading.content, markers: markers, text: text),
                           OutlinePanel.plainTextByScan(of: heading.content, spans: spans, text: text))
        }
    }
}
