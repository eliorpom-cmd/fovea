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
        /// Longueur de la sélection à laisser après l'édition. Zéro — le cas
        /// courant — pose un simple curseur ; c'est l'encadrement d'une
        /// sélection qui a besoin de la conserver.
        var selectionLength: Int = 0
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

        // **Devant le marqueur, `⏎` reste un `⏎`.**
        //
        // Le curseur peut se poser au tout début de la ligne — la règle de
        // révélation le laisse entrer dans le `- `, et `⌘←` l'y envoie. La
        // continuation s'appliquait quand même : on obtenait `- - item`, une
        // puce ajoutée devant celle qu'on n'avait pas quittée. Ce qu'on veut là
        // est une ligne vide au-dessus, c'est-à-dire le comportement ordinaire.
        guard selection.location >= line.location + prefix.length else { return nil }

        // Un item vide : le marqueur seul, rien derrière. `⏎` en sort.
        //
        // **Retirer le marqueur ne suffit pas à sortir.** La ligne devenue vide
        // reste collée à l'item précédent, et le premier mot tapé ensuite est
        // une *continuation paresseuse* au sens de CommonMark : `- item\ntexte`
        // range `texte` **dans** la puce. On croyait avoir quitté la liste,
        // le fichier disait le contraire, et le prouvait dès qu'on le rouvrait
        // ailleurs. Il faut donc laisser une ligne vide au-dessus — sauf s'il y
        // en a déjà une, ou si l'item était la première ligne du document.
        let contentIsEmpty = line.location + prefix.length >= line.location + line.length
        if contentIsEmpty {
            let separator = needsBlankLineAbove(units, line: line) ? "\n" : ""
            return Edit(range: NSRange(location: line.location, length: prefix.length),
                        replacement: separator,
                        caret: line.location + separator.utf16.count,
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

    // MARK: - Paires automatiques

    /// Les paires posées à la frappe.
    ///
    /// L'apostrophe `'` en est **volontairement absente**. En français elle est
    /// une lettre du mot — *l'app*, *aujourd'hui* — et aucun garde-fou ne
    /// rattrape une paire posée là : MarkText s'en sort avec « pas après un
    /// caractère alphanumérique », ce qui laisse encore passer *'Bonjour*. Le
    /// coût d'y renoncer est nul, celui de se tromper est une frappe corrigée
    /// à chaque mot.
    static let pairs: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"",
        "*": "*", "_": "_", "`": "`", "~": "~",
    ]

    /// Les marqueurs markdown parmi les paires : ceux qui ne doivent jamais
    /// s'ouvrir au milieu d'un mot, sans quoi `2*3` pose une étoile fantôme et
    /// `snake_case` passe en italique.
    private static let markdownPairs: Set<Character> = ["*", "_", "`", "~"]

    /// Les caractères que retaper fait **franchir** au lieu de doubler.
    private static let steppedOver: Set<Character> = [")", "]", "}", "\"", "*", "_", "`", "~"]

    /// Ce qui peut suivre le curseur sans empêcher la pose d'une fermeture.
    /// Une paire ouverte au milieu d'un mot serait presque toujours fausse.
    private static let permissiveNeighbours: Set<Character> = [")", "]", "}", "\"", ",", ";", ":", ".", "!", "?", "…", "»"]

    /// Ce que la frappe d'un caractère doit produire, quand ce n'est pas
    /// simplement lui-même.
    ///
    /// Trois gestes en un, dans cet ordre :
    ///
    /// 1. **entourer** — avec du texte sélectionné, taper `(` ou `*` encadre
    ///    la sélection au lieu de l'effacer. La sélection est conservée sur le
    ///    même texte, ce qui permet d'enchaîner `*` puis `*` pour passer de
    ///    l'italique au gras ;
    /// 2. **franchir** — retaper la fermeture qui est déjà à droite du curseur
    ///    avance au lieu d'en écrire une seconde ;
    /// 3. **poser la fermeture**, si et seulement si elle ne coupe pas un mot.
    ///
    /// - Parameter insideCode: le curseur est dans du code, bloc ou `code` en
    ///   ligne. Les marqueurs markdown n'y ont aucun sens ; les parenthèses,
    ///   si.
    /// - Returns: `nil` quand la touche doit s'insérer normalement.
    static func autoPair(typing character: Character, in text: String,
                         selection: NSRange, insideCode: Bool) -> Edit? {
        let units = Array(text.utf16)
        guard selection.location >= 0, selection.upperBound <= units.count else { return nil }
        let forbidden = insideCode && markdownPairs.contains(character)

        if selection.length > 0 {
            guard let closing = pairs[character], !forbidden else { return nil }
            return Edit(range: selection,
                        replacement: String(character) + slice(units, selection) + String(closing),
                        caret: selection.location + 1,
                        undoName: "Entourer",
                        selectionLength: selection.length)
        }

        let caret = selection.location
        let next = caret < units.count ? symbol(units[caret]) : nil
        let previous = caret > 0 ? symbol(units[caret - 1]) : nil

        // Un marqueur markdown ouvre-t-il, ou vient-il refermer ?
        //
        // La question ne se règle pas sur le caractère précédent : dans
        // `**gras|**` comme dans `du *|*`, taper `*` voit la même chose autour
        // du curseur. Ce qui les sépare est le mot **avant la série de
        // marqueurs** — `gras` d'un côté, une espace de l'autre. On remonte
        // donc la série avant de juger.
        let isMarkdown = markdownPairs.contains(character)
        var opens = true
        if isMarkdown {
            var start = caret
            while start > 0, symbol(units[start - 1]) == character { start -= 1 }
            if let before = start > 0 ? symbol(units[start - 1]) : nil, before.isLetter || before.isNumber {
                opens = false
            }
        }

        if let next, next == character, steppedOver.contains(character), !(isMarkdown && opens) {
            return Edit(range: NSRange(location: caret, length: 0), replacement: "",
                        caret: caret + 1, undoName: nil)
        }

        guard let closing = pairs[character], !forbidden, previous != "\\", opens else { return nil }
        // La fermeture qu'on vient de poser compte comme une frontière : c'est
        // ce qui permet à `*` puis `*` de donner `**|**` plutôt que de buter
        // sur son propre voisin.
        guard next == nil || next!.isWhitespace || next! == character
                || permissiveNeighbours.contains(next!) else { return nil }

        return Edit(range: NSRange(location: caret, length: 0),
                    replacement: String(character) + String(closing),
                    caret: caret + 1, undoName: nil)
    }

    /// `⌫` entre les deux moitiés d'une paire les efface toutes les deux.
    ///
    /// Sans ça, revenir sur une parenthèse qu'on n'a pas voulue laisse sa
    /// jumelle orpheline — et c'est le reproche le plus courant fait aux
    /// éditeurs qui apparient sans savoir défaire.
    static func deletingPair(in text: String, selection: NSRange) -> Edit? {
        guard selection.length == 0, selection.location > 0 else { return nil }
        let units = Array(text.utf16)
        guard selection.location < units.count,
              let opener = symbol(units[selection.location - 1]),
              let closing = pairs[opener],
              symbol(units[selection.location]) == closing else { return nil }
        return Edit(range: NSRange(location: selection.location - 1, length: 2), replacement: "",
                    caret: selection.location - 1, undoName: nil)
    }

    /// Le caractère d'une unité UTF-16, quand elle en est un à elle seule.
    /// Une moitié de paire de substitution ne peut être aucun de nos
    /// délimiteurs, tous ASCII : la rendre `nil` suffit.
    private static func symbol(_ unit: UInt16) -> Character? {
        guard let scalar = UnicodeScalar(unit) else { return nil }
        return Character(scalar)
    }

    // MARK: - Encadrement par un raccourci

    /// `⌘B`, `⌘I` et compagnie : entoure la sélection, ou **retire** le
    /// formatage s'il est déjà là (§2.5).
    static func wrap(_ text: String, selection: NSRange, with marker: String) -> Edit {
        let units = Array(text.utf16)
        let markerUnits = Array(marker.utf16)
        let length = markerUnits.count

        // Déjà encadré : on retire, plutôt que d'empiler un second niveau.
        //
        // # Ce que la comparaison seule ne voyait pas
        //
        // Elle regardait les `length` signes de chaque côté et s'arrêtait là.
        // Autour de `**mot**`, `⌘I` y lisait donc un `*` à gauche et un `*` à
        // droite — les moitiés intérieures du gras — concluait « déjà en
        // italique » et **retirait le gras** : `⌘B` puis `⌘I` donnait `*mot*`
        // au lieu de `***mot***`. Le geste le plus courant du menu Format
        // détruisait ce que le geste précédent venait de poser.
        //
        // Ce qui décide, c'est donc la **longueur de la série** d'étoiles, pas
        // ses premiers signes : deux étoiles sont du gras, trois sont les deux
        // à la fois, et une série d'une autre longueur n'est pas la nôtre.
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: selection.upperBound, length: length)
        if before.location >= 0, after.upperBound <= units.count,
           slice(units, before) == marker, slice(units, after) == marker,
           encloses(units, selection, marker: marker, length: length) {
            let whole = NSRange(location: before.location, length: length * 2 + selection.length)
            return Edit(range: whole,
                        replacement: slice(units, selection),
                        caret: before.location,
                        undoName: "Retirer le formatage",
                        selectionLength: selection.length)
        }

        let inner = slice(units, selection)
        return Edit(range: selection,
                    replacement: marker + inner + marker,
                    // Sur un curseur seul, on se place **entre** les marqueurs :
                    // l'utilisateur a demandé du gras pour écrire en gras, pas
                    // pour poser deux étoiles et chercher où taper.
                    //
                    // Avec une sélection, elle est **conservée sur le même
                    // texte** — comme le fait déjà la frappe d'un `*` sur une
                    // sélection (voir `autoPair`). Sans ça, `⌘B` puis `⌘I`
                    // était impossible : la première touche défaisait la
                    // sélection dont la seconde avait besoin, et les deux
                    // chemins vers le même geste ne se comportaient pas pareil.
                    caret: selection.location + length,
                    undoName: "Formater",
                    selectionLength: selection.length)
    }

    /// La série de marqueurs qui entoure la sélection est-elle bien **celle
    /// qu'on retire**, et non une plus longue dont elle ne serait qu'un bout ?
    ///
    /// Deux longueurs valent le retrait :
    ///
    /// - `length` exactement — `*mot*` pour `⌘I`, `**mot**` pour `⌘B` ;
    /// - trois, pour la famille de l'étoile : `***mot***` porte le gras **et**
    ///   l'italique, et chacun des deux raccourcis doit pouvoir en retirer sa
    ///   part sans emporter l'autre.
    ///
    /// Toute autre longueur veut dire que la sélection est bordée par un
    /// format différent : on empile alors, ce qui est le geste demandé.
    private static func encloses(_ units: [UInt16], _ selection: NSRange,
                                 marker: String, length: Int) -> Bool {
        guard let symbol = marker.utf16.first else { return false }
        var leading = 0
        while selection.location - leading - 1 >= 0,
              units[selection.location - leading - 1] == symbol { leading += 1 }
        var trailing = 0
        while selection.upperBound + trailing < units.count,
              units[selection.upperBound + trailing] == symbol { trailing += 1 }

        guard leading == trailing else { return false }
        let combinable = marker.allSatisfy { $0 == "*" || $0 == "_" }
        return leading == length || (combinable && leading == 3 && length < 3)
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

    /// La ligne au-dessus porte-t-elle du texte ?
    ///
    /// Vrai seulement s'il y en a une **et** qu'elle n'est pas déjà blanche :
    /// c'est exactement le cas où sortir d'une liste doit insérer une ligne
    /// vide pour couper la continuation paresseuse.
    private static func needsBlankLineAbove(_ units: [UInt16], line: NSRange) -> Bool {
        guard line.location > 0 else { return false }
        let previous = lineRange(units, containing: line.location - 1)
        let space = UInt16(UnicodeScalar(" ").value)
        let tab = UInt16(UnicodeScalar("\t").value)
        return (0..<previous.length).contains {
            let unit = units[previous.location + $0]
            return unit != space && unit != tab
        }
    }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }

    private static func slice(_ units: [UInt16], _ range: NSRange) -> String {
        guard range.location >= 0, range.upperBound <= units.count, range.length >= 0 else { return "" }
        return String(decoding: units[range.location..<range.upperBound], as: UTF16.self)
    }
}
