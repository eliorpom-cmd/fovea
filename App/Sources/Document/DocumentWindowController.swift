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
        editor.scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            editor.scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            editor.scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            editor.scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content

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

    /// `NSWindowController` n'hérite pas de la validation : sans cette
    /// conformité, l'entrée de menu resterait grisée alors que l'action existe.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSourceMode(_:)) {
            menuItem.title = editor.isSourceMode ? "Masquer la source" : "Afficher la source"
            return true
        }
        return true
    }
}
