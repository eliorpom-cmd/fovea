// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// La barre de menus, construite en code plutôt que dans un MainMenu.xib.
///
/// Un xib serait un second endroit où vivent les raccourcis, invisible en
/// revue de code et impossible à relire dans un diff. Ici tout est lisible, et
/// les actions non câblées se désactivent d'elles-mêmes : AppKit grise un
/// élément dont personne dans la chaîne de répondeurs n'implémente le sélecteur.
@MainActor
enum MainMenu {

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(), title: AppConfig.name))
        main.addItem(submenu(fileMenu(), title: "Fichier"))
        main.addItem(submenu(editMenu(), title: "Édition"))
        main.addItem(submenu(formatMenu(), title: "Format"))
        main.addItem(submenu(viewMenu(), title: "Présentation"))
        main.addItem(submenu(windowMenu(), title: "Fenêtre"))
        return main
    }

    // MARK: - Fovea

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("À propos de \(AppConfig.name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Réglages…", #selector(AppCommands.showSettings(_:)), ","))
        menu.addItem(item("Ouvrir les Markdown avec \(AppConfig.name)",
                          #selector(AppCommands.makeDefaultMarkdownEditor(_:))))
        menu.addItem(.separator())

        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())

        menu.addItem(item("Masquer \(AppConfig.name)", #selector(NSApplication.hide(_:)), "h"))
        let hideOthers = item("Masquer les autres", #selector(NSApplication.hideOtherApplications(_:)), "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(item("Tout afficher", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quitter \(AppConfig.name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    // MARK: - Fichier

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "Fichier")
        menu.addItem(item("Nouveau", #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item("Ouvrir…", #selector(NSDocumentController.openDocument(_:)), "o"))

        // **Pas de sous-menu des documents récents ici.** Le contrat du titre
        // « NSRecentDocumentsMenu » ne vaut que pour un menu chargé depuis un
        // nib : construit à la main, le sous-menu restait vide pour toujours.
        // macOS, lui, injecte tout seul « Ouvrir l'élément récent » dans le menu
        // Fichier d'une app à documents — comme « Renommer… » et « Revenir à »
        // juste en dessous. En ajouter un deuxième donnait deux entrées voisines
        // dont une ne s'ouvrait sur rien.

        menu.addItem(.separator())
        menu.addItem(item("Fermer", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Enregistrer", #selector(NSDocument.save(_:)), "s"))

        let saveAs = item("Enregistrer sous…", #selector(NSDocument.saveAs(_:)), "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(saveAs)

        menu.addItem(item("Rétablir la version enregistrée", #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(.separator())

        let export = NSMenuItem(title: "Exporter", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        exportMenu.addItem(item("PDF…", #selector(AppCommands.exportPDF(_:))))
        exportMenu.addItem(item("HTML autonome…", #selector(AppCommands.exportHTML(_:))))
        export.submenu = exportMenu
        menu.addItem(export)

        menu.addItem(.separator())
        // Le partage est une affordance système : la feuille qu'il ouvre est
        // celle de macOS, avec Mail, Messages, AirDrop et tout ce que
        // l'utilisateur y a installé. L'écrire nous-mêmes serait à la fois plus
        // long et moins complet.
        menu.addItem(item("Partager…", #selector(AppCommands.shareDocument(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Imprimer…", #selector(NSDocument.printDocument(_:)), "p"))
        return menu
    }

    // MARK: - Édition

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Édition")
        menu.addItem(item("Annuler", Selector(("undo:")), "z"))
        let redo = item("Rétablir", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())

        menu.addItem(item("Couper", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copier", #selector(NSText.copy(_:)), "c"))

        // §4.6 : en pratique l'export le plus utilisé. Il mérite le raccourci
        // voisin de ⌘C, pas une entrée perdue dans un sous-menu.
        let copyRich = item("Copier en texte riche", #selector(AppCommands.copyAsRichText(_:)), "c")
        copyRich.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(copyRich)

        menu.addItem(item("Coller", #selector(NSText.paste(_:)), "v"))
        let pastePlain = item("Coller sans mise en forme", #selector(AppCommands.pastePlainText(_:)), "v")
        pastePlain.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pastePlain)

        menu.addItem(item("Tout sélectionner", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())

        let find = NSMenuItem(title: "Rechercher", action: nil, keyEquivalent: "")
        let findMenu = NSMenu()
        // Les `tag` sont le contrat de `NSTextFinder` : c'est par eux qu'il
        // distingue « rechercher » de « suivant » ou « remplacer ».
        findMenu.addItem(finder("Rechercher…", tag: NSTextFinder.Action.showFindInterface.rawValue, key: "f"))
        findMenu.addItem(finder("Suivant", tag: NSTextFinder.Action.nextMatch.rawValue, key: "g"))
        let previous = finder("Précédent", tag: NSTextFinder.Action.previousMatch.rawValue, key: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(previous)
        findMenu.addItem(finder("Remplacer…", tag: NSTextFinder.Action.showReplaceInterface.rawValue, key: "f",
                                modifiers: [.command, .option]))
        find.submenu = findMenu
        menu.addItem(find)

        return menu
    }

    // MARK: - Format

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.addItem(item("Gras", #selector(AppCommands.toggleBold(_:)), "b"))
        menu.addItem(item("Italique", #selector(AppCommands.toggleItalic(_:)), "i"))

        let strike = item("Barré", #selector(AppCommands.toggleStrikethrough(_:)), "x")
        strike.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(strike)

        let inlineCode = item("Code", #selector(AppCommands.toggleInlineCode(_:)), "k")
        inlineCode.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(inlineCode)

        // `⌘K` est déjà la palette de commandes (§4.5, décision actée §12). Le
        // lien prend donc la variante `⌘⌥K` plutôt que de se disputer la touche :
        // deux entrées sur le même raccourci, c'est la première dans l'ordre des
        // menus qui gagne, et le perdant devient un raccourci qui ne marche pas
        // sans que rien ne le dise.
        let link = item("Lien…", #selector(AppCommands.insertLink(_:)), "k")
        link.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(link)

        // Le damier plutôt qu'un 3 × 3 imposé : la forme du tableau est la
        // première chose qu'on sait, et la dernière qu'on aime corriger.
        //
        // ⌥⌘T et non ⌘⇧T — celui de MarkText : les fenêtres de Fovea acceptent
        // les onglets natifs, et macOS y attache déjà « Afficher la barre
        // d'onglets ». Le doublon aurait donné un raccourci qui ne marche pas
        // sans que rien ne le dise, exactement comme le ⌘K du menu Lien.
        // `insertMarkdownTable` et non `insertTable` : **`NSTextView` possède
        // déjà un `insertTable:`**, son action d'insertion de tableau en texte
        // riche. La vue de texte est le premier répondeur, elle répondait donc
        // la première — et comme elle est en `isRichText = false`, elle
        // refusait l'action. L'entrée « Tableau… » restait grisée et ⌥⌘T ne
        // faisait rien, sans que rien ne l'explique : le contrôleur de fenêtre,
        // qui sait pourtant l'ouvrir, n'était jamais atteint. Le damier
        // n'existait qu'au travers de `/tab`.
        let table = item("Tableau…", #selector(AppCommands.insertMarkdownTable(_:)), "t")
        table.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(table)

        let task = item("Cocher la tâche", #selector(AppCommands.toggleTaskAtCaret(_:)), "\r")
        menu.addItem(task)
        menu.addItem(.separator())

        // ⌘⌃1..6 pour les niveaux de titre, ⌘⌃0 pour revenir au paragraphe.
        let paragraph = item("Paragraphe", #selector(AppCommands.setHeadingLevel(_:)), "0")
        paragraph.keyEquivalentModifierMask = [.command, .control]
        paragraph.tag = 0
        menu.addItem(paragraph)
        for level in 1...6 {
            let heading = item("Titre \(level)", #selector(AppCommands.setHeadingLevel(_:)), "\(level)")
            heading.keyEquivalentModifierMask = [.command, .control]
            heading.tag = level
            menu.addItem(heading)
        }
        return menu
    }

    // MARK: - Présentation

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "Présentation")

        // §4.2 : le filet de sécurité. Il mérite un raccourci d'une seule main.
        menu.addItem(item("Afficher la source", #selector(AppCommands.toggleSourceMode(_:)), "/"))
        menu.addItem(.separator())

        let outline = item("Plan du document", #selector(AppCommands.toggleOutline(_:)), "0")
        outline.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(outline)

        menu.addItem(item("Palette de commandes", #selector(AppCommands.showCommandPalette(_:)), "k"))
        menu.addItem(.separator())

        menu.addItem(item("Mode focus", #selector(AppCommands.toggleFocusMode(_:))))
        menu.addItem(item("Machine à écrire", #selector(AppCommands.toggleTypewriterMode(_:))))
        menu.addItem(.separator())

        let fullScreen = item("Activer le mode plein écran", #selector(NSWindow.toggleFullScreen(_:)), "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreen)
        return menu
    }

    // MARK: - Fenêtre

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Fenêtre")
        menu.addItem(item("Réduire", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Tout ramener au premier plan", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = menu
        return menu
    }

    // MARK: - Fabriques

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    private static func finder(_ title: String, tag: Int, key: String,
                               modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title,
                                  action: #selector(NSTextView.performTextFinderAction(_:)),
                                  keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.tag = tag
        return menuItem
    }
}

/// Les sélecteurs des commandes propres à Fovea.
///
/// Ce protocole n'est jamais adopté : il n'existe que pour donner à `#selector`
/// un symbole à référencer, sans forcer `MainMenu` à connaître les classes qui
/// répondront. Les actions remontent la chaîne de répondeurs, et le menu se
/// grise tout seul là où personne ne répond.
@MainActor
@objc protocol AppCommands {
    func showSettings(_ sender: Any?)
    func makeDefaultMarkdownEditor(_ sender: Any?)
    func shareDocument(_ sender: Any?)
    func exportPDF(_ sender: Any?)
    func exportHTML(_ sender: Any?)
    func copyAsRichText(_ sender: Any?)
    func pastePlainText(_ sender: Any?)
    func toggleBold(_ sender: Any?)
    func toggleItalic(_ sender: Any?)
    func toggleStrikethrough(_ sender: Any?)
    func toggleInlineCode(_ sender: Any?)
    func insertLink(_ sender: Any?)
    func insertMarkdownTable(_ sender: Any?)
    func toggleTaskAtCaret(_ sender: Any?)
    func setHeadingLevel(_ sender: Any?)
    func toggleSourceMode(_ sender: Any?)
    func toggleOutline(_ sender: Any?)
    func showCommandPalette(_ sender: Any?)
    func toggleFocusMode(_ sender: Any?)
    func toggleTypewriterMode(_ sender: Any?)
}
