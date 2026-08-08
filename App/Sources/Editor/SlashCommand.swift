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
        /// Vrai quand du texte précède le `/` sur la ligne : le bloc inséré doit
        /// alors commencer par un retour, sinon il se collerait à la phrase en
        /// cours et ne serait pas un bloc du tout.
        var startsNewLine = false
    }

    /// Le menu doit-il être ouvert, vu la ligne courante et le curseur ?
    ///
    /// # Ce qui décide, c'est ce qui précède le `/`
    ///
    /// La première version n'ouvrait le menu que sur une **ligne vide**, par
    /// crainte qu'un `/` au milieu d'une phrase — `https://`, `/Users/`,
    /// `12/03`, `et/ou` — rende la touche inutilisable. La crainte est fondée,
    /// mais la condition était trop large : elle privait du menu exactement les
    /// gens à qui il sert, ceux qui ne connaissent pas la syntaxe qu'on leur a
    /// masquée et qui ne devineront jamais qu'il faut d'abord une ligne vide.
    ///
    /// Le bon discriminant est plus étroit : **le `/` doit ouvrir un mot**,
    /// c'est-à-dire être en début de ligne ou précédé d'un blanc. Les quatre cas
    /// redoutés ont tous un caractère collé devant le `/` et sont donc écartés
    /// par la même règle, sans rien coûter au reste.
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
    ///   - scope: le réglage §4.7 — jamais, en début de ligne seulement, partout.
    static func slashTrigger(inLine line: String, lineStart: Int, caret: Int,
                             scope: AppSettings.SlashMenuScope) -> SlashTrigger? {
        guard scope != .off else { return nil }
        let units = Array(line.utf16)
        let offset = caret - lineStart
        guard offset > 0, offset <= units.count else { return nil }

        // Le curseur doit être en bout de ligne. Le menu accompagne la frappe ;
        // s'ouvrir au milieu d'un texte déjà écrit laisserait la fin de la
        // phrase derrière le bloc inséré, dans la dernière cellule d'un tableau
        // ou après une clôture de code.
        guard offset == units.count else { return nil }

        // Le `/` qui a ouvert : le dernier avant le curseur, sans blanc entre
        // les deux — ce qu'il y a derrière est la recherche en cours.
        let slash = UInt16(UnicodeScalar("/").value)
        var start = offset - 1
        while start >= 0, !isBlank(units[start]), units[start] != slash { start -= 1 }
        guard start >= 0, units[start] == slash else { return nil }

        // La règle qui rend la touche `/` de nouveau utilisable pour ce qu'elle
        // est : collée à un caractère, elle n'ouvre rien.
        if start > 0, !isBlank(units[start - 1]) { return nil }
        if scope == .lineStart, start != 0 { return nil }

        let query = String(decoding: units[(start + 1)..<offset], as: UTF16.self)
        return SlashTrigger(range: NSRange(location: lineStart + start, length: offset - start),
                            query: query,
                            startsNewLine: units[..<start].contains { !isBlank($0) })
    }

    private static func isBlank(_ unit: UInt16) -> Bool {
        unit == UInt16(UnicodeScalar(" ").value) || unit == UInt16(UnicodeScalar("\t").value)
    }

    /// L'édition qui remplace le `/query` par le bloc choisi.
    static func insertion(of command: SlashCommand, replacing trigger: SlashTrigger) -> Edit {
        let (body, caretOffset) = template(for: command)
        // Un bloc posé à la suite d'une phrase commence à la ligne. Le blanc
        // laissé devant le retour est sans effet en markdown, et le retirer
        // toucherait à un texte que l'utilisateur n'a pas demandé qu'on touche.
        let lead = trigger.startsNewLine ? "\n" : ""
        return Edit(range: trigger.range,
                    replacement: lead + body,
                    caret: trigger.range.location + lead.utf16.count + caretOffset,
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
