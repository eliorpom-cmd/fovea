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
        // Sans cela, une zone de suivi posée avec `.mouseMoved` ne reçoit
        // rien : AppKit ne *produit* les événements de déplacement que pour
        // les fenêtres qui les acceptent, et le défaut est `false`. Le damier
        // s'annonce « on survole, on voit la grille se remplir, on clique » —
        // le survol ne remplissait rien.
        acceptsMouseMovedEvents = true

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
        // **Un rectangle nul n'est pas une position, c'est une absence de
        // réponse.** `firstRect(forCharacterRange:)` en rend un quand aucune
        // session de saisie n'est en cours — c'est le cas quand la commande
        // vient de la barre de menus. Le calcul qui suit le prenait au mot :
        // l'origine tombait à zéro, le repli vers le haut la ramenait au ras du
        // bord, et le panneau se posait dans le coin bas-gauche de l'écran, à
        // moitié sous le Dock. Techniquement affiché, introuvable en pratique.
        //
        // On ne devine pas la position à sa place : on prend le tiers supérieur
        // de la fenêtre, là où le regard est déjà.
        let anchor = caretRect == .zero ? fallbackAnchor(size: size, in: host) : caretRect

        // **Il rétrécit avant de basculer.**
        //
        // La règle était « pas la place en dessous, on passe au-dessus ». Le
        // panneau se posait alors **par-dessus les lignes qu'on vient
        // d'écrire** : dans une fenêtre de 520 points de haut, ouvrir le menu en
        // bas de page masquait les huit lignes précédentes, c'est-à-dire la
        // liste qu'on était en train de continuer.
        //
        // Un menu ancré au curseur se lit sous le curseur. Quand la place
        // manque, ce qu'il faut réduire est sa hauteur — il défile — pas le
        // texte qu'il cache. On ne bascule que lorsqu'il ne reste même plus de
        // quoi montrer trois entrées.
        var height = size.height
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - height - 6)

        if let screen = host?.screen ?? NSScreen.main {
            let floor = screen.visibleFrame.minY + 8
            let roomBelow = anchor.minY - 6 - floor
            let roomAbove = screen.visibleFrame.maxY - 8 - (anchor.maxY + 6)

            if origin.y < floor {
                if roomBelow >= Self.minimumShrunkHeight {
                    height = min(height, roomBelow)
                    origin.y = anchor.minY - height - 6
                } else {
                    height = min(height, max(Self.minimumShrunkHeight, roomAbove))
                    origin.y = anchor.maxY + 6
                }
            }
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8),
                           screen.visibleFrame.maxX - size.width - 8)
        }
        setFrame(NSRect(origin: origin, size: NSSize(width: size.width, height: max(1, height))),
                 display: true)

        if !isVisible {
            host?.addChildWindow(self, ordered: .above)
            orderFront(nil)
        }
    }

    /// En dessous de quoi rétrécir ne sert plus à rien : trois entrées.
    private static let minimumShrunkHeight: CGFloat = 90

    /// Où poser un panneau qui n'a pas de curseur où s'accrocher : au tiers
    /// supérieur de la fenêtre, centré. Ce n'est pas la position du curseur,
    /// mais c'est sous les yeux et dans le document — ce qu'un coin d'écran
    /// n'est pas.
    private func fallbackAnchor(size: NSSize, in host: NSWindow?) -> NSRect {
        guard let frame = host?.frame else {
            let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            return NSRect(x: screen.midX - size.width / 2, y: screen.midY, width: 1, height: 1)
        }
        return NSRect(x: frame.midX - size.width / 2,
                      y: frame.minY + frame.height * 2 / 3,
                      width: 1, height: 1)
    }

    func dismiss() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
