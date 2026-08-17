// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Un bandeau **non bloquant**, en haut de la colonne de texte (§6).
///
/// # Pourquoi un bandeau et pas une alerte
///
/// Trois états du §6 doivent être dits sans interrompre : un document
/// volumineux, un encodage qui sera converti, un fichier en lecture seule.
/// Aucun des trois n'appelle une décision immédiate — ce sont des faits à
/// connaître, pas des questions. Une alerte modale obligerait à cliquer avant
/// d'écrire, pour une information qu'on veut simplement avoir vue.
///
/// Il se referme d'un clic et ne revient pas pour le même document. Le §7 veut
/// que l'app disparaisse : un bandeau permanent serait exactement le chrome
/// qu'on cherche à éviter.
@MainActor
final class DocumentBanner: NSView {

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    /// Contrainte de hauteur : zéro quand il n'y a rien à dire.
    private var heightConstraint: NSLayoutConstraint!

    private static let visibleHeight: CGFloat = 34

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyLayerBackground(Theme.NS.fillQuaternary)

        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.NS.labelSecondary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Fermer")
        closeButton.contentTintColor = Theme.NS.labelTertiary
        closeButton.target = self
        closeButton.action = #selector(dismiss)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setAccessibilityLabel("Fermer le bandeau")

        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = Theme.NS.separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(closeButton)
        addSubview(separator)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.s16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor,
                                            constant: -Theme.Space.s12),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.s12),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("aucune vue ne vient d'un xib") }

    /// Même raison que dans le plan : voir `applyLayerBackground(_:)`.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLayerBackground(Theme.NS.fillQuaternary)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyLayerBackground(Theme.NS.fillQuaternary)
    }

    var isShowing: Bool { !isHidden }

    /// Affiche les messages, joints. Rien à dire referme le bandeau.
    func show(_ messages: [String]) {
        let text = messages.filter { !$0.isEmpty }.joined(separator: "  ·  ")
        guard !text.isEmpty else {
            dismiss()
            return
        }
        label.stringValue = text
        setAccessibilityLabel(text)
        isHidden = false
        heightConstraint.constant = Self.visibleHeight
        // §8 : le bandeau apparaît quand même si les animations sont réduites,
        // il ne glisse simplement pas.
        Accessibility.animate(0.18) { superview?.layoutSubtreeIfNeeded() }
    }

    @objc func dismiss() {
        guard !isHidden else { return }
        heightConstraint.constant = 0
        // `isHidden` est posé **à la fin**, pas avant : appliqué tout de suite,
        // il faisait disparaître le bandeau d'un coup et l'animation qui suit
        // repliait une vue déjà invisible. Le bandeau sautait au lieu de se
        // refermer, et le glissement écrit juste au-dessus ne se voyait jamais.
        Accessibility.animate(0.18) { superview?.layoutSubtreeIfNeeded() } completion: {
            MainActor.assumeIsolated { [weak self] in
                // Un `show` a pu passer entre-temps : on ne masque que ce qui
                // est bien resté replié.
                guard let self, heightConstraint.constant == 0 else { return }
                isHidden = true
            }
        }
    }
}

// MARK: - Les messages du §6

extension DocumentBanner {

    /// Ce qu'il y a à dire d'un document à son ouverture, ou rien.
    ///
    /// La fonction est pure et rendue publique pour être testée : ce sont des
    /// phrases que l'utilisateur lira, et leur exactitude compte autant que
    /// celle du code qui les déclenche.
    nonisolated static func messages(byteCount: Int,
                                     encoding: String.Encoding,
                                     isWritable: Bool) -> [String] {
        var result: [String] = []

        if !isWritable {
            // §6 : le document s'ouvre et reste modifiable en mémoire. Ce qui
            // ne marchera pas, c'est l'enregistrement — et il vaut mieux
            // l'apprendre avant d'écrire trois pages.
            result.append("Fichier en lecture seule. Utilisez « Enregistrer sous… » "
                          + "pour conserver vos modifications.")
        }
        if byteCount > 1_000_000 {
            // L'app ne bascule jamais toute seule (§6) : elle informe.
            result.append("Document volumineux. Le mode source (⌥⌘S) sera plus fluide.")
        }
        if encoding != .utf8 {
            result.append("Fichier lu en \(name(of: encoding)). Il sera converti "
                          + "en UTF-8 à l'enregistrement.")
        }
        return result
    }

    private nonisolated static func name(of encoding: String.Encoding) -> String {
        switch encoding {
        case .windowsCP1252: "Windows-1252"
        case .isoLatin1: "ISO-8859-1"
        case .utf16LittleEndian, .utf16BigEndian, .utf16: "UTF-16"
        case .macOSRoman: "Mac OS Roman"
        default: "un autre encodage"
        }
    }
}
