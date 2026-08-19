// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
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
        menu.addItem(item("Settings…", #selector(AppCommands.showSettings(_:)), ","))
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
        menu.addItem(.separator())

        let export = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        exportMenu.addItem(item("PDF…", #selector(AppCommands.exportPDF(_:))))
        exportMenu.addItem(item("Standalone HTML…", #selector(AppCommands.exportHTML(_:))))
        export.submenu = exportMenu
        menu.addItem(export)

        menu.addItem(.separator())
        // Sharing is a system affordance: the sheet it opens is macOS's own,
        // with Mail, Messages, AirDrop and everything else the user has
        // installed. Writing it ourselves would be both more work and less
        // complete.
        menu.addItem(item("Share…", #selector(AppCommands.shareDocument(_:))))
        menu.addItem(.separator())
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

        // §4.6: in practice the most used export. It deserves the shortcut
        // next to ⌘C, not an entry lost in a submenu.
        let copyRich = item("Copy as Rich Text", #selector(AppCommands.copyAsRichText(_:)), "c")
        copyRich.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(copyRich)

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

        // `⌘K` is already the command palette (§4.5, decision settled in §12).
        // The link therefore takes the `⌘⌥K` variant instead of contesting the
        // key: with two entries on the same shortcut, the first one in menu
        // order wins, and the loser becomes a shortcut that doesn't work
        // without anything saying so.
        let link = item("Link…", #selector(AppCommands.insertLink(_:)), "k")
        link.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(link)

        // A grid picker instead of a fixed 3 × 3: the shape of the table is
        // the first thing one knows, and the last thing one likes to correct.
        //
        // ⌥⌘T, not ⌘⇧T — the one MarkText uses: Fovea's windows accept native
        // tabs, and macOS already attaches "Show Tab Bar" to that shortcut.
        // The duplicate would have produced a shortcut that doesn't work
        // without anything saying so, exactly like the ⌘K of the Link menu.
        // `insertMarkdownTable`, not `insertTable`: **`NSTextView` already has
        // an `insertTable:`**, its rich-text table-insertion action. The text
        // view is the first responder, so it answered first — and since it's
        // `isRichText = false`, it refused the action. The "Table…" entry
        // stayed grayed out and ⌥⌘T did nothing, with nothing explaining why:
        // the window controller, which does know how to open it, was never
        // reached. The grid picker only ever existed through `/tab`.
        let table = item("Table…", #selector(AppCommands.insertMarkdownTable(_:)), "t")
        table.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(table)

        let task = item("Toggle Task", #selector(AppCommands.toggleTaskAtCaret(_:)), "\r")
        menu.addItem(task)
        menu.addItem(.separator())

        // ⌘⌃1..6 for heading levels, ⌘⌃0 to go back to Body.
        let paragraph = item("Body", #selector(AppCommands.setHeadingLevel(_:)), "0")
        paragraph.keyEquivalentModifierMask = [.command, .control]
        paragraph.tag = 0
        menu.addItem(paragraph)
        for level in 1...6 {
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

        // §4.2: the safety net. It deserves a one-handed shortcut.
        //
        // **⌥⌘S, not ⌘/.** The slash isn't in the same place from one
        // keyboard layout to another: on a French keyboard it requires a
        // shift, so macOS remaps the equivalent to `⇧⌘:` — which is what the
        // menu displayed, while the palette and the README advertised `⌘/`.
        // And neither combination triggered anything, while `⌘K` went through
        // the same path: a key equivalent based on punctuation doesn't
        // survive a layout change.
        //
        // A letter, by contrast, is in the same place everywhere. "S" as in
        // source.
        let source = item("Show Source", #selector(AppCommands.toggleSourceMode(_:)), "s")
        source.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(source)
        menu.addItem(.separator())

        let outline = item("Document Outline", #selector(AppCommands.toggleOutline(_:)), "0")
        outline.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(outline)

        menu.addItem(item("Command Palette", #selector(AppCommands.showCommandPalette(_:)), "k"))
        menu.addItem(.separator())

        menu.addItem(item("Focus Mode", #selector(AppCommands.toggleFocusMode(_:))))
        menu.addItem(item("Typewriter Mode", #selector(AppCommands.toggleTypewriterMode(_:))))
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

    // MARK: - A command's real shortcut

    /// A command's shortcut **exactly as the menu bar carries it**.
    ///
    /// # Why this isn't a hand-written string
    ///
    /// The palette used to display its shortcuts hardcoded: `"⌘/"`, `"⌘⌥0"`,
    /// `"⌘⌃1"`. But macOS remaps key equivalents based on punctuation or a
    /// digit according to the keyboard layout: on a French keyboard, the same
    /// command shows up as `⇧⌘:` or `⌥⌘à`. The palette was therefore the only
    /// place in the app that displays shortcuts, and the only one that got it
    /// wrong.
    ///
    /// A single place decides now, and it's the one that triggers them.
    static func shortcut(for action: Selector, tag: Int? = nil) -> String {
        guard let item = item(for: action, tag: tag, in: NSApp.mainMenu) else { return "" }
        guard !item.keyEquivalent.isEmpty else { return "" }

        // The order follows the interface guidelines: control, option, shift,
        // command. Reading it any other way stands out immediately.
        var result = ""
        let flags = item.keyEquivalentModifierMask
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.option) { result += "⌥" }
        if flags.contains(.shift) { result += "⇧" }
        if flags.contains(.command) { result += "⌘" }

        switch item.keyEquivalent {
        case "\r": result += "⏎"
        case "\t": result += "⇥"
        case "\u{8}": result += "⌫"
        case "\u{1b}": result += "⎋"
        default: result += item.keyEquivalent.uppercased()
        }
        return result
    }

    private static func item(for action: Selector, tag: Int?, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for entry in menu.items {
            if entry.action == action, tag == nil || entry.tag == tag { return entry }
            if let found = item(for: action, tag: tag, in: entry.submenu) { return found }
        }
        return nil
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
