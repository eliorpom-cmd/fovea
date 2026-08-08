// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// Les blocs qu'on peut insérer au clavier, sans connaître leur syntaxe (§4.5).
///
/// # Pourquoi ce menu n'est pas un confort
///
/// C'est la contrepartie directe du §2.1. Une app qui **masque** les marqueurs
/// doit offrir un autre chemin pour les poser : sans lui, insérer un tableau
/// demanderait de connaître par cœur une syntaxe que l'éditeur vient justement
/// de faire disparaître de l'écran.
///
/// Tout est ici plutôt que dans la vue, et sans AppKit : ce qu'insère chaque
/// entrée est une décision de produit, pas un détail d'interface, et un test
/// doit pouvoir la lire.
enum SlashCommand: String, CaseIterable, Sendable {
    case heading1, heading2, heading3
    case bulletList, numberedList, taskList
    case quote, codeBlock, table, rule

    var title: String {
        switch self {
        case .heading1: "Titre 1"
        case .heading2: "Titre 2"
        case .heading3: "Titre 3"
        case .bulletList: "Liste à puces"
        case .numberedList: "Liste numérotée"
        case .taskList: "Liste de tâches"
        case .quote: "Citation"
        case .codeBlock: "Bloc de code"
        case .table: "Tableau"
        case .rule: "Filet horizontal"
        }
    }

    /// Ce qui s'affiche à droite : la syntaxe posée. Le menu apprend donc le
    /// markdown à qui veut le savoir, au lieu de le cacher pour toujours.
    var hint: String {
        switch self {
        case .heading1: "#"
        case .heading2: "##"
        case .heading3: "###"
        case .bulletList: "-"
        case .numberedList: "1."
        case .taskList: "- [ ]"
        case .quote: ">"
        case .codeBlock: "```"
        case .table: "| |"
        case .rule: "---"
        }
    }

    /// Ce qu'on peut taper pour la trouver, en plus du titre.
    ///
    /// Les mots anglais sont là parce que la moitié des gens qui écrivent du
    /// markdown tapent `/code` ou `/table` sans réfléchir, quelle que soit la
    /// langue de l'interface.
    var keywords: [String] {
        switch self {
        case .heading1: ["titre", "heading", "h1"]
        case .heading2: ["titre", "heading", "h2"]
        case .heading3: ["titre", "heading", "h3"]
        case .bulletList: ["liste", "puce", "list", "bullet"]
        case .numberedList: ["liste", "numero", "ordonnee", "list", "ordered"]
        case .taskList: ["tache", "case", "cocher", "task", "todo", "checkbox"]
        case .quote: ["citation", "quote"]
        case .codeBlock: ["code", "bloc", "block", "pre"]
        case .table: ["tableau", "grille", "table"]
        case .rule: ["filet", "trait", "separateur", "rule", "hr", "separator"]
        }
    }
}

extension SlashCommand {

    /// Les entrées qui correspondent à ce qui a été tapé après le `/`.
    ///
    /// Le score est celui de la palette `⌘K` : même geste, même règle. Taper
    /// `/tb` doit trouver « Tableau », comme `⌘K` trouve « Mode focus » avec
    /// `mdf` — deux filtrages différents dans la même app seraient deux choses
    /// à apprendre au lieu d'une.
    static func matching(_ query: String) -> [SlashCommand] {
        guard !query.isEmpty else { return allCases }
        return allCases
            .compactMap { command -> (SlashCommand, Int)? in
                let candidates = [command.title] + command.keywords
                guard let best = candidates.compactMap({ CommandPalette.score($0, query: query) }).max() else {
                    return nil
                }
                return (command, best)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

extension TypingBehaviour {

    /// Ce que le curseur vient de taper pour ouvrir le menu.
    struct SlashTrigger: Equatable {
        /// La plage à remplacer : le `/` et ce qui a été tapé derrière.
        var range: NSRange
        /// Ce qui suit le `/`, pour filtrer la liste.
        var query: String
    }

    /// Le menu doit-il être ouvert, vu la ligne courante et le curseur ?
    ///
    /// La condition est stricte, et volontairement : **une ligne vide**, un `/`
    /// en tête, et rien d'autre que le mot en cours de frappe. Un `/` au milieu
    /// d'une phrase est une barre oblique, un chemin de fichier ou une date, et
    /// ouvrir un menu dessus rendrait la touche inutilisable.
    ///
    /// La fonction prend **la ligne**, pas le document. C'est délibéré : elle
    /// est appelée à chaque frappe et à chaque déplacement du curseur, et la
    /// première version, qui construisait le tableau UTF-16 du document entier,
    /// aurait à elle seule replacé le cycle de frappe au-dessus du budget du §9
    /// sur un texte long.
    ///
    /// - Parameters:
    ///   - line: la ligne du curseur, terminateur exclu.
    ///   - lineStart: son offset dans le document, pour rendre une plage absolue.
    ///   - caret: le curseur, en offset absolu.
    static func slashTrigger(inLine line: String, lineStart: Int, caret: Int) -> SlashTrigger? {
        let units = Array(line.utf16)
        let offset = caret - lineStart

        let slash = UInt16(UnicodeScalar("/").value)
        guard units.first == slash else { return nil }
        // Le curseur est derrière le `/`, et rien ne le suit sur la ligne : on
        // ouvre un bloc, on ne s'insère pas au milieu d'un texte déjà écrit.
        guard offset > 0, offset == units.count else { return nil }

        let query = String(decoding: units[1...], as: UTF16.self)
        // Un espace ferme le menu : « /note à moi » est du texte.
        guard !query.contains(where: { $0 == " " || $0 == "\t" }) else { return nil }

        return SlashTrigger(range: NSRange(location: lineStart, length: offset), query: query)
    }

    /// L'édition qui remplace le `/query` par le bloc choisi.
    static func insertion(of command: SlashCommand, replacing range: NSRange) -> Edit {
        let (body, caretOffset) = template(for: command)
        return Edit(range: range,
                    replacement: body,
                    caret: range.location + caretOffset,
                    undoName: "Insérer : \(command.title)")
    }

    /// Le texte posé, et où le curseur atterrit dedans.
    ///
    /// Le curseur va **là où on écrit ensuite** : dans le bloc de code et pas
    /// après sa clôture, dans la première cellule du tableau et pas à la ligne
    /// suivante. C'est ce qui fait la différence entre un menu qui aide et un
    /// menu qui laisse du travail.
    private static func template(for command: SlashCommand) -> (String, Int) {
        switch command {
        case .heading1: ("# ", 2)
        case .heading2: ("## ", 3)
        case .heading3: ("### ", 4)
        case .bulletList: ("- ", 2)
        case .numberedList: ("1. ", 3)
        case .taskList: ("- [ ] ", 6)
        case .quote: ("> ", 2)
        case .codeBlock: ("```\n\n```", 4)
        case .rule: ("---\n\n", 5)
        case .table: (
            """
            |  |  |
            |---|---|
            |  |  |
            """, 2)
        }
    }
}
