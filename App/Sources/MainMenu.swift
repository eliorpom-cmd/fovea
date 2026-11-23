// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import AppKit

/// The menu bar, built in code rather than in a MainMenu.xib.
///
/// A xib would be a second place where shortcuts live, invisible in code
/// review and unreadable in a diff. Here everything is readable, and actions
/// that aren't wired up disable themselves: AppKit grays out an item whose
/// selector nobody in the responder chain implements.
@MainActor
enum MainMenu {

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(), title: AppConfig.name))
        main.addItem(submenu(fileMenu(), title: "File"))
        main.addItem(submenu(editMenu(), title: "Edit"))
        main.addItem(submenu(formatMenu(), title: "Format"))
        main.addItem(submenu(viewMenu(), title: "View"))
        main.addItem(submenu(windowMenu(), title: "Window"))
        return main
    }

    // MARK: - Fovea

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("About \(AppConfig.name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Open Markdown Files with \(AppConfig.name)",
                          #selector(AppCommands.makeDefaultMarkdownEditor(_:))))
        menu.addItem(.separator())

        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())

        menu.addItem(item("Hide \(AppConfig.name)", #selector(NSApplication.hide(_:)), "h"))
        let hideOthers = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(AppConfig.name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    // MARK: - File

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))

        // **No recent documents submenu here.** The `NSRecentDocumentsMenu`
        // title only works for a menu loaded from a nib: built by hand, the
        // submenu stayed empty forever. macOS, on its own, injects "Open
        // Recent" into the File menu of a document-based app — just like
        // "Rename…" and "Revert To" right below it. Adding a second one
        // produced two neighboring entries, one of which opened nothing.

        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(NSDocument.save(_:)), "s"))

        let saveAs = item("Save As…", #selector(NSDocument.saveAs(_:)), "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(saveAs)

        menu.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))

        // Printing came back on its own, without the exports it left with:
        // see `DocumentPrinting`. "Save as PDF" lives in the print panel.
        menu.addItem(.separator())
        let pageSetup = item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p")
        pageSetup.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pageSetup)
        menu.addItem(item("Print…", #selector(NSDocument.printDocument(_:)), "p"))
        return menu
    }

    // MARK: - Edit

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        let redo = item("Redo", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())

        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        let pastePlain = item("Paste and Match Style", #selector(AppCommands.pastePlainText(_:)), "v")
        pastePlain.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pastePlain)

        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())

        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu()
        // The `tag` values are `NSTextFinder`'s contract: they're how it
        // distinguishes "find" from "next" or "replace".
        findMenu.addItem(finder("Find…", tag: NSTextFinder.Action.showFindInterface.rawValue, key: "f"))
        findMenu.addItem(finder("Find Next", tag: NSTextFinder.Action.nextMatch.rawValue, key: "g"))
        let previous = finder("Find Previous", tag: NSTextFinder.Action.previousMatch.rawValue, key: "g")
        previous.keyEquivalentModifierMask = [.command, .shift]
        findMenu.addItem(previous)
        findMenu.addItem(finder("Find and Replace…", tag: NSTextFinder.Action.showReplaceInterface.rawValue, key: "f",
                                modifiers: [.command, .option]))
        find.submenu = findMenu
        menu.addItem(find)

        return menu
    }

    // MARK: - Format

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        menu.addItem(item("Bold", #selector(AppCommands.toggleBold(_:)), "b"))
        menu.addItem(item("Italic", #selector(AppCommands.toggleItalic(_:)), "i"))

        let strike = item("Strikethrough", #selector(AppCommands.toggleStrikethrough(_:)), "x")
        strike.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(strike)

        let inlineCode = item("Code", #selector(AppCommands.toggleInlineCode(_:)), "k")
        inlineCode.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(inlineCode)

        // **`⌘K`, the shortcut everyone already has in their fingers.** It
        // belonged to the command palette, which took it because it was the
        // busier surface; the link made do with `⌘⌥K`. With the palette gone
        // the key is free, and it goes to the thing every other app binds it
        // to — Slack, Notion, Bear, every browser's address bar.
        menu.addItem(item("Link…", #selector(AppCommands.insertLink(_:)), "k"))

        let task = item("Toggle Task", #selector(AppCommands.toggleTaskAtCaret(_:)), "\r")
        menu.addItem(task)
        menu.addItem(.separator())

        // **Three levels offered, six still read.** A file that uses `#####`
        // renders it, and source mode writes any level by hand. But past the
        // third, the heading is carried by weight alone — an h5 and an h6 are
        // the same size as the body text around them — and nobody reaches for
        // one in a file they opened to fix a line.
        //
        // ⌘⌃1..3 for the levels, ⌘⌃0 to go back to Body.
        let paragraph = item("Body", #selector(AppCommands.setHeadingLevel(_:)), "0")
        paragraph.keyEquivalentModifierMask = [.command, .control]
        paragraph.tag = 0
        menu.addItem(paragraph)
        for level in 1...3 {
            let heading = item("Heading \(level)", #selector(AppCommands.setHeadingLevel(_:)), "\(level)")
            heading.keyEquivalentModifierMask = [.command, .control]
            heading.tag = level
            menu.addItem(heading)
        }
        return menu
    }

    // MARK: - View

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")

        // **The settings live here, and nowhere else.**
        //
        // Appearance, the two fonts and the size were a window of their own;
        // four settings do not earn a window. This is also where macOS puts
        // them in every app that has them, and `⌘+`/`⌘−` are already in the
        // reader's fingers from every browser they use.
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu()
        for value in AppSettings.Appearance.allCases {
            let entry = item(value.label, #selector(AppCommands.setAppearance(_:)))
            entry.representedObject = value.rawValue
            appearanceMenu.addItem(entry)
        }
        appearance.submenu = appearanceMenu
        menu.addItem(appearance)
        menu.addItem(.separator())

        menu.addItem(item("Body Font…", #selector(AppCommands.chooseBodyFont(_:))))
        menu.addItem(item("Code Font…", #selector(AppCommands.chooseCodeFont(_:))))

        // `+` and not `=`: macOS draws the equals key as ⌘+ in the menu and
        // accepts both, which is the behaviour every browser has.
        menu.addItem(item("Bigger", #selector(AppCommands.increaseTextSize(_:)), "+"))
        menu.addItem(item("Smaller", #selector(AppCommands.decreaseTextSize(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(AppCommands.resetTextSize(_:)), "0"))
        menu.addItem(.separator())

        // §4.2: the safety net. It deserves a one-handed shortcut.
        //
        // **⌥⌘S, not ⌘/.** The slash isn't in the same place from one
        // keyboard layout to another: on a French keyboard it requires a
        // shift, so macOS remaps the equivalent to `⇧⌘:` — which is what the
        // menu displayed, while the README advertised `⌘/`. Neither
        // combination triggered anything: a key equivalent based on
        // punctuation doesn't survive a layout change.
        //
        // A letter, by contrast, is in the same place everywhere. "S" as in
        // source.
        let source = item("Show Source", #selector(AppCommands.toggleSourceMode(_:)), "s")
        source.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(source)
        menu.addItem(.separator())

        let fullScreen = item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreen)
        return menu
    }

    // MARK: - Window

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = menu
        return menu
    }

    // MARK: - Factories

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

/// The selectors for Fovea's own commands.
///
/// This protocol is never adopted: it exists only to give `#selector` a
/// symbol to reference, without forcing `MainMenu` to know the classes that
/// will respond. Actions travel up the responder chain, and the menu grays
/// itself out wherever nobody responds.
@MainActor
@objc protocol AppCommands {
    func makeDefaultMarkdownEditor(_ sender: Any?)
    func setAppearance(_ sender: Any?)
    func chooseBodyFont(_ sender: Any?)
    func chooseCodeFont(_ sender: Any?)
    func increaseTextSize(_ sender: Any?)
    func decreaseTextSize(_ sender: Any?)
    func resetTextSize(_ sender: Any?)
    func pastePlainText(_ sender: Any?)
    func toggleBold(_ sender: Any?)
    func toggleItalic(_ sender: Any?)
    func toggleStrikethrough(_ sender: Any?)
    func toggleInlineCode(_ sender: Any?)
    func insertLink(_ sender: Any?)
    func toggleTaskAtCaret(_ sender: Any?)
    func setHeadingLevel(_ sender: Any?)
    func toggleSourceMode(_ sender: Any?)
}
