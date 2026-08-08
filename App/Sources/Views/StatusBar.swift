// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// La barre d'état : mots, signes, temps de lecture (§4.5).
///
/// Elle occupe le coin bas-droit et **s'efface quand la souris n'est pas
/// dessus**. Le §7 demande que l'app disparaisse ; un compteur permanent dans
/// le champ de vision est exactement le genre de chrome qui empêche d'oublier
/// qu'on écrit dans un logiciel.
final class StatusBar: NSView {

    private let label = NSTextField(labelWithString: "")
    private var isHovered = false
    private var goalProgress: Double = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // **Le fond de la page, pas une capsule.** La barre flotte au-dessus de
        // la colonne : dans une fenêtre étroite, une ligne longue passait
        // dessous et les deux textes se superposaient, illisibles. Peindre le
        // fond de la page rend la barre opaque là où elle recouvre quelque
        // chose, et parfaitement invisible partout ailleurs — c'est-à-dire
        // presque toujours.
        layer?.backgroundColor = Theme.NS.window.cgColor
        layer?.cornerRadius = Theme.Radius.control

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = Theme.NS.labelTertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.s10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
        addTrackingArea(tracking)
        alphaValue = 0.55
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) n'est pas utilisé : aucune vue ne vient d'un xib") }

    // MARK: - Contenu

    func update(_ statistics: WritingModes.Statistics, goal: Int, isSelection: Bool) {
        let words = statistics.words
        var parts: [String] = []

        if goal > 0 {
            parts.append("\(words) / \(goal) mots")
            goalProgress = min(1, Double(words) / Double(goal))
        } else {
            parts.append(words == 1 ? "1 mot" : "\(words) mots")
            goalProgress = 0
        }
        parts.append(statistics.characters == 1 ? "1 signe" : "\(statistics.characters) signes")
        if statistics.readingMinutes > 0 {
            parts.append("\(statistics.readingMinutes) min de lecture")
        }
        // Une sélection change le sens des chiffres : le dire évite de croire
        // que le document a rétréci.
        if isSelection { parts.append("sélection") }

        label.stringValue = parts.joined(separator: "  ·  ")
        needsDisplay = true
    }

    // MARK: - Apparence

    /// Le fond est résolu à la pose : un passage en mode sombre ne le met pas à
    /// jour tout seul, et la barre resterait blanche sur une page noire.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.NS.window.cgColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard goalProgress > 0 else { return }
        // L'objectif de session se rend par un simple filet sous le texte.
        // Sans célébration ni confettis (§4.5) : on écrit, on ne joue pas.
        let width = bounds.width * goalProgress
        let rule = NSRect(x: 0, y: 0, width: width, height: 1.5)
        Theme.NS.labelTertiary.setFill()
        rule.fill()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        animateAlpha()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        animateAlpha()
    }

    private func animateAlpha() {
        let target = isHovered ? 1.0 : 0.55
        // « Réduire les animations » est un besoin, pas une préférence (§8) :
        // l'état change, seul le mouvement disparaît.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = target
        }
    }
}
