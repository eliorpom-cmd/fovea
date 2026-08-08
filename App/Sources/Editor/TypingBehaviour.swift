// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import Foundation

/// Ce qui se passe quand on tape (§2.5).
///
/// Un WYSIWYG se juge autant à ce qu'il fait sous les doigts qu'à ce qu'il
/// affiche. Tout ce fichier est **pur** : il prend un texte, une sélection et
/// une touche, et renvoie l'édition à appliquer. Aucun AppKit, donc entièrement
/// testable sans lancer d'interface.
enum TypingBehaviour {

    /// Une édition à appliquer au tampon.
    struct Edit: Equatable {
        var range: NSRange
        var replacement: String
        /// Où poser le curseur ensuite, en offset absolu **après** l'édition.
        var caret: Int
        /// Nom de l'action dans le menu Annuler. `nil` regroupe avec la frappe
        /// en cours plutôt que d'ouvrir sa propre étape.
        var undoName: String?
    }

    // MARK: - Retour à la ligne dans une liste

    /// `⏎` sur un item crée l'item suivant au même niveau. `⏎` sur un item vide
    /// sort de la liste et retire le marqueur (§2.5).
    ///
    /// - Returns: `nil` quand la touche doit garder son comportement habituel.
    static func newline(in text: String, selection: NSRange) -> Edit? {
        guard selection.length == 0 else { return nil }
        let units = Array(text.utf16)
        let line = lineRange(units, containing: selection.location)
        guard let prefix = listPrefix(units, line: line) else { return nil }

        // Un item vide : le marqueur seul, rien derrière. `⏎` en sort.
        let contentIsEmpty = line.location + prefix.length >= line.location + line.length
        if contentIsEmpty {
            return Edit(range: NSRange(location: line.location, length: prefix.length),
                        replacement: "",
                        caret: line.location,
                        undoName: "Sortir de la liste")
        }

        let next = continuation(units, prefix: prefix)
        return Edit(range: NSRange(location: selection.location, length: 0),
                    replacement: "\n" + next,
                    caret: selection.location + 1 + next.utf16.count,
                    undoName: nil)
    }

    /// Le marqueur du prochain item : la même indentation, la même puce, et le
    /// numéro suivant pour une liste ordonnée. Une case cochée repart vide —
    /// personne ne veut créer dix tâches déjà faites.
    private static func continuation(_ units: [UInt16], prefix: NSRange) -> String {
        let raw = String(decoding: units[prefix.location..<(prefix.location + prefix.length)], as: UTF16.self)
        let indent = String(raw.prefix { $0 == " " || $0 == "\t" })
        let body = raw.dropFirst(indent.count)

        if let checkbox = body.range(of: "[ ]") ?? body.range(of: "[x]") ?? body.range(of: "[X]") {
            let bullet = body[body.startIndex..<checkbox.lowerBound]
            return indent + bullet + "[ ] "
        }
        let digits = body.prefix { $0.isNumber }
        if let number = Int(digits), let delimiter = body.dropFirst(digits.count).first {
            return "\(indent)\(number + 1)\(delimiter) "
        }
        return raw
    }

    // MARK: - Indentation

    /// `⇥` et `⇧⇥` dans une liste changent le niveau. Ailleurs, la tabulation
    /// reste une tabulation.
    static func indent(in text: String, selection: NSRange, outdent: Bool) -> Edit? {
        let units = Array(text.utf16)
        let line = lineRange(units, containing: selection.location)
        guard listPrefix(units, line: line) != nil else { return nil }

        if outdent {
            let removable = min(2, leadingSpaces(units, line: line))
            guard removable > 0 else { return nil }
            return Edit(range: NSRange(location: line.location, length: removable),
                        replacement: "",
                        caret: max(line.location, selection.location - removable),
                        undoName: "Désindenter")
        }
        return Edit(range: NSRange(location: line.location, length: 0),
                    replacement: "  ",
                    caret: selection.location + 2,
                    undoName: "Indenter")
    }

    // MARK: - Insérer un lien

    /// Pose `[texte](url)` autour de la sélection.
    ///
    /// L'URL vient du presse-papier quand il en contient une : c'est le geste
    /// réel — on copie une adresse dans un navigateur, on revient, on
    /// sélectionne le mot. Sinon les parenthèses sont laissées vides et le
    /// curseur atterrit dedans, là où il ne reste qu'à coller.
    ///
    /// Sans sélection, le curseur va **entre les crochets** : on écrit d'abord
    /// le texte, l'adresse ensuite.
    static func link(in text: String, selection: NSRange, url: String?) -> Edit {
        let units = Array(text.utf16)
        let label = selection.length > 0 && selection.upperBound <= units.count
            ? slice(units, selection)
            : ""
        let destination = url ?? ""
        // Le curseur va là où il reste quelque chose à écrire : le texte s'il
        // manque, l'adresse si elle manque, et après le lien quand il est
        // complet — le seul cas où l'on peut reprendre sa phrase.
        let caret = switch (label.isEmpty, destination.isEmpty) {
        case (true, _):      selection.location + 1
        case (false, true):  selection.location + label.utf16.count + 3
        case (false, false): selection.location + label.utf16.count + destination.utf16.count + 4
        }

        return Edit(range: selection,
                    replacement: "[\(label)](\(destination))",
                    caret: caret,
                    undoName: "Insérer un lien")
    }

    /// Le presse-papier contient-il quelque chose qui ressemble à une adresse ?
    ///
    /// Volontairement littéral : un schéma, ou un `www.`. Deviner plus large
    /// ferait coller n'importe quelle phrase copiée entre les parenthèses d'un
    /// lien, ce qui est plus pénible à défaire qu'à taper.
    static func looksLikeURL(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("www.")
    }

    // MARK: - Cocher une tâche

    /// Coche ou décoche la case d'un item de tâche.
    ///
    /// # Pourquoi c'est une fonction et pas une ligne de vue
    ///
    /// La case est **dessinée** : elle n'existe nulle part dans le fichier, où
    /// il n'y a que `- [ ] `. Cliquer dessus ne peut donc pas « cocher » quoi
    /// que ce soit — il faut réécrire un caractère du tampon, au bon endroit,
    /// dans la pile d'annulation, sans déplacer le curseur.
    ///
    /// Un seul signe change, jamais la ligne entière : `[x]` est rendu par un
    /// `x` minuscule, mais un `[X]` déjà écrit se décoche sans être normalisé —
    /// le §5 vaut aussi pour ce que l'app modifie elle-même.
    ///
    /// - Parameters:
    ///   - marker: le marqueur de l'item, `- [ ] ` d'un seul tenant.
    ///   - caret: la sélection courante, rendue telle quelle : cocher une tâche
    ///     ne doit pas faire sauter le curseur ailleurs dans le document.
    static func toggleTask(in text: String, marker: NSRange, caret: Int) -> Edit? {
        let units = Array(text.utf16)
        guard marker.location >= 0, marker.upperBound <= units.count, marker.length >= 3 else { return nil }

        let open = UInt16(UnicodeScalar("[").value)
        let close = UInt16(UnicodeScalar("]").value)
        for index in marker.location..<(marker.upperBound - 2)
        where units[index] == open && units[index + 2] == close {
            let isChecked = units[index + 1] == UInt16(UnicodeScalar("x").value)
                || units[index + 1] == UInt16(UnicodeScalar("X").value)
            return Edit(range: NSRange(location: index + 1, length: 1),
                        replacement: isChecked ? " " : "x",
                        caret: caret,
                        undoName: isChecked ? "Décocher la tâche" : "Cocher la tâche")
        }
        return nil
    }

    // MARK: - Reconnaissance à la frappe

    /// Les constructions reconnues quand on tape l'espace qui suit leur
    /// marqueur : `# `, `- `, `> `, `1. `.
    ///
    /// Il n'y a en réalité **rien à faire** : le marqueur est déjà dans le
    /// texte, le parseur le voit, et le rendu suit au prochain cycle. Cette
    /// fonction n'existe que pour dire lesquelles sont reconnues — et pour que
    /// le test le vérifie plutôt que de le supposer.
    ///
    /// C'est un bénéfice direct du §3.1 : quand le texte source est la source
    /// de vérité, la « reconnaissance à la frappe » n'est pas une
    /// fonctionnalité, c'est une conséquence.
    static func recognizesConstruct(onLine line: String) -> Bool {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if trimmed.hasPrefix("> ") { return true }
        if let first = trimmed.first, "-*+".contains(first), trimmed.dropFirst().hasPrefix(" ") { return true }
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }
            return hashes.count <= 6 && trimmed.dropFirst(hashes.count).hasPrefix(" ")
        }
        let digits = trimmed.prefix { $0.isNumber }
        if !digits.isEmpty {
            let rest = trimmed.dropFirst(digits.count)
            if let delimiter = rest.first, delimiter == "." || delimiter == ")" {
                return rest.dropFirst().hasPrefix(" ")
            }
        }
        return false
    }

    // MARK: - Encadrement par un raccourci

    /// `⌘B`, `⌘I` et compagnie : entoure la sélection, ou **retire** le
    /// formatage s'il est déjà là (§2.5).
    static func wrap(_ text: String, selection: NSRange, with marker: String) -> Edit {
        let units = Array(text.utf16)
        let markerUnits = Array(marker.utf16)
        let length = markerUnits.count

        // Déjà encadré : on retire, plutôt que d'empiler un second niveau.
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: selection.upperBound, length: length)
        if before.location >= 0, after.upperBound <= units.count,
           slice(units, before) == marker, slice(units, after) == marker {
            let whole = NSRange(location: before.location, length: length * 2 + selection.length)
            return Edit(range: whole,
                        replacement: slice(units, selection),
                        caret: before.location + selection.length,
                        undoName: "Retirer le formatage")
        }

        let inner = slice(units, selection)
        return Edit(range: selection,
                    replacement: marker + inner + marker,
                    // Sur un curseur seul, on se place **entre** les marqueurs :
                    // l'utilisateur a demandé du gras pour écrire en gras, pas
                    // pour poser deux étoiles et chercher où taper.
                    caret: selection.location + length + selection.length,
                    undoName: "Formater")
    }

    /// Change le niveau d'un titre, ou le retire quand `level` vaut 0.
    static func setHeadingLevel(_ level: Int, in text: String, selection: NSRange) -> Edit {
        let units = Array(text.utf16)
        let line = lineRange(units, containing: selection.location)
        let existing = headingPrefix(units, line: line)
        let replacement = level == 0 ? "" : String(repeating: "#", count: level) + " "
        let delta = replacement.utf16.count - existing
        return Edit(range: NSRange(location: line.location, length: existing),
                    replacement: replacement,
                    caret: max(line.location, selection.location + delta),
                    undoName: level == 0 ? "Paragraphe" : "Titre \(level)")
    }

    // MARK: - Analyse de ligne

    /// La plage de la ligne contenant `location`, terminateur exclu.
    static func lineRange(_ units: [UInt16], containing location: Int) -> NSRange {
        let newline = UInt16(UnicodeScalar("\n").value)
        var start = min(location, units.count)
        while start > 0, units[start - 1] != newline { start -= 1 }
        var end = start
        while end < units.count, units[end] != newline { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Le marqueur d'item de liste en tête de ligne, indentation et case à
    /// cocher comprises.
    static func listPrefix(_ units: [UInt16], line: NSRange) -> NSRange? {
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        let bullets: Set<UInt16> = [UInt16(UnicodeScalar("-").value),
                                    UInt16(UnicodeScalar("*").value),
                                    UInt16(UnicodeScalar("+").value)]
        var offset = 0
        while offset < line.length, units[line.location + offset] == space || units[line.location + offset] == tab {
            offset += 1
        }
        guard offset < line.length else { return nil }

        let first = units[line.location + offset]
        if bullets.contains(first) {
            offset += 1
        } else if isDigit(first) {
            while offset < line.length, isDigit(units[line.location + offset]) { offset += 1 }
            guard offset < line.length else { return nil }
            let delimiter = units[line.location + offset]
            guard delimiter == UInt16(UnicodeScalar(".").value)
                    || delimiter == UInt16(UnicodeScalar(")").value) else { return nil }
            offset += 1
        } else {
            return nil
        }

        // L'espace qui suit le marqueur en fait partie. Sans lui, `-texte` — qui
        // n'est pas une liste — serait pris pour un item.
        guard offset < line.length, units[line.location + offset] == space else { return nil }
        offset += 1

        // La case à cocher est indissociable de la puce : `- [x] ` d'un tenant.
        if offset + 2 < line.length,
           units[line.location + offset] == UInt16(UnicodeScalar("[").value),
           units[line.location + offset + 2] == UInt16(UnicodeScalar("]").value) {
            offset += 3
            if offset < line.length, units[line.location + offset] == space { offset += 1 }
        }
        return NSRange(location: line.location, length: offset)
    }

    private static func headingPrefix(_ units: [UInt16], line: NSRange) -> Int {
        let hash = UInt16(UnicodeScalar("#").value)
        let space = UInt16(UnicodeScalar(" ").value)
        var offset = 0
        while offset < line.length, units[line.location + offset] == hash, offset < 6 { offset += 1 }
        guard offset > 0 else { return 0 }
        if offset < line.length, units[line.location + offset] == space { offset += 1 }
        return offset
    }

    private static func leadingSpaces(_ units: [UInt16], line: NSRange) -> Int {
        let space = UInt16(UnicodeScalar(" ").value)
        var count = 0
        while count < line.length, units[line.location + count] == space { count += 1 }
        return count
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    private static func slice(_ units: [UInt16], _ range: NSRange) -> String {
        guard range.location >= 0, range.upperBound <= units.count, range.length >= 0 else { return "" }
        return String(decoding: units[range.location..<range.upperBound], as: UTF16.self)
    }
}
