// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Le socle commun des panneaux ancrés au curseur.
///
/// # Pourquoi un socle
///
/// Le menu slash était le premier ; le sélecteur de langage et le damier de
/// tableau sont les suivants, et il y en aura d'autres — barre de sélection,
/// bulle de lien, outils de tableau. Écrire quatre fois le même panneau, c'est
/// se garantir quatre comportements légèrement différents au clavier et à la
/// fermeture. Tout ce qui suit est donc décidé **une fois**.
///
/// # Le contrat, en trois règles
///
/// 1. **Il ne prend jamais le focus.** `nonactivatingPanel`, `canBecomeKey`
///    à `false` : le curseur reste dans le texte, la frappe continue d'aller
///    dans le tampon, et le panneau se contente de suivre. C'est ce qui permet
///    de taper `/tab` et de voir la liste se réduire sans jamais changer de
///    mode.
/// 2. **Les touches lui arrivent par la vue de texte.** Puisqu'il n'est pas
///    fenêtre clé, il ne reçoit rien du système : `EditorTextView.keyDown` lui
///    transmet les flèches, `⏎` et `⎋`.
/// 3. **Il s'ancre sur un rectangle en coordonnées écran** — celui du curseur,
///    obtenu par `firstRect(forCharacterRange:)` — et bascule au-dessus de la
///    ligne quand il n'y a plus de place en dessous.
@MainActor
class FloatingPanel: NSPanel {

    /// La vue floutée qui porte le contenu. Les sous-classes y ajoutent la leur.
    let container = NSVisualEffectView()

    init(width: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isMovable = false
        hidesOnDeactivate = true

        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        contentView = container
    }

    /// Il ne devient jamais clé : c'est tout le principe. Sans ce `false`, le
    /// curseur quitterait le texte à l'ouverture.
    override var canBecomeKey: Bool { false }

    var isOpen: Bool { isVisible }

    /// Pose le panneau sous le curseur, ou au-dessus s'il déborde de l'écran.
    ///
    /// - Parameter caretRect: la position du curseur **en coordonnées écran**.
    func present(size: NSSize, caretRect: NSRect, over host: NSWindow?) {
        // Sous la ligne courante, décalé d'un cheveu : posé dessus, le panneau
        // masquerait le mot qu'on est en train de taper.
        var origin = NSPoint(x: caretRect.minX, y: caretRect.minY - size.height - 6)
        if let screen = host?.screen ?? NSScreen.main {
            if origin.y < screen.visibleFrame.minY {
                origin.y = caretRect.maxY + 6
            }
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8),
                           screen.visibleFrame.maxX - size.width - 8)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)

        if !isVisible {
            host?.addChildWindow(self, ordered: .above)
            orderFront(nil)
        }
    }

    func dismiss() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
