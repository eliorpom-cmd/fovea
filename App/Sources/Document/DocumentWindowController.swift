// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// La fenêtre d'édition.
///
/// Elle est aussi vide que possible : pas de barre d'outils, pas de barre
/// latérale, un titre transparent. C'est l'application directe du §7 — l'app
/// doit disparaître, il ne doit rester que la colonne de texte.
final class DocumentWindowController: NSWindowController {

    let editor = EditorController()
    private let statusBar = StatusBar()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)

        // Le titre est masqué mais la barre reste : elle porte les boutons de
        // fenêtre et le glisser-déposer du document. La rendre transparente
        // laisse le texte défiler derrière, ce qui est exactement l'effet
        // recherché.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.NS.window
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 420, height: 320)
        window.isMovableByWindowBackground = false

        self.init(window: window)
        window.delegate = self

        // La colonne de texte est centrée, donc sa marge dépend de la largeur
        // disponible. `windowDidResize` ne suffit pas : au premier affichage il
        // n'a pas encore été appelé et la vue de défilement n'a pas sa taille
        // définitive, ce qui laissait le texte collé à gauche. Le recalcul est
        // donc rattaché à la mise en page de la vue elle-même.
        let content = LayoutObservingView()
        content.onLayout = { [weak editor] in editor?.applyColumnLayout() }
        content.addSubview(editor.scrollView)
        content.addSubview(statusBar)
        editor.scrollView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editor.scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            editor.scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            editor.scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            // Flottante au-dessus du texte, dans le coin bas-droit : elle ne
            // vole pas de place à la colonne, et s'efface quand la souris est
            // ailleurs.
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.Space.s16),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Theme.Space.s12),
            statusBar.heightAnchor.constraint(equalToConstant: 20),
        ])
        window.contentView = content

        editor.onSelectionChanged = { [weak self] in self?.refreshStatistics() }
        refreshStatistics()

        // Le premier répondeur doit être la vue de texte dès l'ouverture : dans
        // une app d'écriture, le curseur clignote avant que la main ne quitte
        // le clavier.
        window.makeFirstResponder(editor.textView)
        windowFrameAutosaveName = "FoveaDocumentWindow"
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        editor.applyColumnLayout()
    }

    /// Rafraîchit la barre d'état.
    ///
    /// Appelée à chaque changement de sélection **et** à chaque frappe. Le
    /// comptage exclut la syntaxe markdown, donc il parcourt le document : sur
    /// un très gros texte, ce serait le seul coût restant dans le cycle de
    /// frappe. La barre étant masquable, on ne paie que si elle est affichée.
    func refreshStatistics() {
        guard AppSettings.shared.showStatistics else {
            statusBar.isHidden = true
            return
        }
        statusBar.isHidden = false
        statusBar.update(editor.statistics,
                         goal: AppSettings.shared.sessionWordGoal,
                         isSelection: editor.textView.selectedRange().length > 0)
    }
}

/// Une vue qui prévient quand elle vient d'être mise en page.
///
/// `NSViewController.viewDidLayout` ferait le même travail, mais imposerait un
/// contrôleur de vue entier pour une seule ligne de rappel.
private final class LayoutObservingView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - NSWindowDelegate

extension DocumentWindowController: NSWindowDelegate {
}

// MARK: - Commandes de la barre de menus

extension DocumentWindowController: NSMenuItemValidation {

    @objc func toggleSourceMode(_ sender: Any?) {
        editor.toggleSourceMode()
    }

    @objc func toggleBold(_ sender: Any?) { editor.wrapSelection(with: "**") }
    @objc func toggleItalic(_ sender: Any?) { editor.wrapSelection(with: "*") }
    @objc func toggleStrikethrough(_ sender: Any?) { editor.wrapSelection(with: "~~") }
    @objc func toggleInlineCode(_ sender: Any?) { editor.wrapSelection(with: "`") }

    @objc func setHeadingLevel(_ sender: Any?) {
        // Le niveau voyage dans le `tag` de l'entrée de menu : six entrées, une
        // seule action, et le raccourci ⌘⌃n reste lisible dans le menu.
        guard let item = sender as? NSMenuItem else { return }
        editor.setHeadingLevel(item.tag)
    }

    @objc func toggleFocusMode(_ sender: Any?) {
        AppSettings.shared.focusMode.toggle()
    }

    @objc func toggleTypewriterMode(_ sender: Any?) {
        AppSettings.shared.typewriterMode.toggle()
    }

    // MARK: - Exports (§4.6)

    @objc func copyAsRichText(_ sender: Any?) {
        guard let rich = MarkdownExport.richText(from: editor.text, documentURL: editor.documentURL),
              let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Le RTF **et** le texte brut : une app qui ne sait pas lire le premier
        // doit trouver le second plutôt que de coller un presse-papier vide.
        pasteboard.declareTypes([.rtf, .string], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString(rich.string, forType: .string)
    }

    @objc func pastePlainText(_ sender: Any?) {
        editor.textView.pastePlainText(sender)
    }

    @objc func exportHTML(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (documentName as NSString).deletingPathExtension + ".html"
        panel.message = "Un seul fichier, images comprises."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let html = MarkdownExport.html(from: editor.text,
                                       title: (documentName as NSString).deletingPathExtension,
                                       documentURL: editor.documentURL)
        try? Data(html.utf8).write(to: url)
    }

    @objc func exportPDF(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (documentName as NSString).deletingPathExtension + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportPDF(to: url)
    }

    /// Produit le PDF depuis une vue de rendu **jetable**, sans le chrome de
    /// l'éditeur et tous marqueurs masqués (§4.6).
    ///
    /// Imprimer la vue d'édition elle-même donnerait sa largeur de colonne, sa
    /// couleur de fond et son curseur. La pagination est confiée à
    /// `NSPrintOperation` : découper à la main produirait des paragraphes
    /// coupés en deux au bas des pages.
    private func exportPDF(to url: URL) {
        guard let rich = MarkdownExport.richText(from: editor.text, documentURL: editor.documentURL) else {
            return
        }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)   // A4 à 72 ppp
        info.topMargin = 64; info.bottomMargin = 64
        info.leftMargin = 64; info.rightMargin = 64
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let printable = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: printable, height: 100))
        view.textStorage?.setAttributedString(rich)
        view.isEditable = false
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
    }

    private var documentName: String {
        (document as? NSDocument)?.displayName ?? "Document"
    }

    @objc func openRepository(_ sender: Any?) {
        NSWorkspace.shared.open(AppConfig.repositoryURL)
    }

    /// `NSWindowController` n'hérite pas de la validation : sans cette
    /// conformité, les entrées resteraient grisées alors que les actions
    /// existent. C'est aussi ici que les états cochés se mettent à jour.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSourceMode(_:)):
            menuItem.title = editor.isSourceMode ? "Masquer la source" : "Afficher la source"

        case #selector(toggleFocusMode(_:)):
            menuItem.state = AppSettings.shared.focusMode ? .on : .off

        case #selector(toggleTypewriterMode(_:)):
            menuItem.state = AppSettings.shared.typewriterMode ? .on : .off

        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)),
             #selector(toggleStrikethrough(_:)), #selector(toggleInlineCode(_:)),
             #selector(setHeadingLevel(_:)):
            // Le mode source montre le fichier tel qu'il est : y appliquer un
            // formatage par raccourci reviendrait à écrire des étoiles à
            // l'aveugle dans du texte brut.
            return !editor.isSourceMode

        default:
            break
        }
        return true
    }
}
