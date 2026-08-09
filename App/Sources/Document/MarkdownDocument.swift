// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

/// Le document.
///
/// `NSDocument` fournit gratuitement ⌘O, ⌘S, les Récents, l'enregistrement
/// automatique en place, les versions Time Machine, la restauration de session
/// et iCloud Drive. Rien de tout cela n'est réécrit ici : ce fichier ne
/// s'occupe que de ce qui est propre au markdown, c'est-à-dire la fidélité au
/// fichier promise au §5.
final class MarkdownDocument: NSDocument {

    /// Le texte, en LF en mémoire. C'est la seule source de vérité (§3.1).
    private(set) var text: String = ""

    /// Le style de fin de ligne trouvé à l'ouverture, restitué tel quel à
    /// l'enregistrement.
    private var lineEnding: TextFile.LineEnding = .default

    /// L'encodage lu. Fovea écrit toujours en UTF-8 ; ce champ ne sert qu'à
    /// prévenir quand une conversion aura lieu (§6).
    private(set) var sourceEncoding: String.Encoding = .utf8

    private weak var editor: EditorController?

    override class var autosavesInPlace: Bool { true }

    /// « Enregistrer sous » déplace le document : les images en chemin relatif
    /// se résolvent alors ailleurs, et l'éditeur doit le savoir.
    ///
    /// `fileURL` est déclaré `nonisolated` par AppKit et peut changer depuis la
    /// coordination de fichiers ; on repasse donc explicitement sur le thread
    /// principal plutôt que d'affirmer qu'on y est déjà.
    override var fileURL: URL? {
        didSet {
            let url = fileURL
            Task { @MainActor [weak self] in self?.editor?.documentURL = url }
        }
    }

    // MARK: - Lecture et écriture

    // `read` et `data` sont déclarés `nonisolated` par AppKit, parce qu'un
    // document *peut* être lu ou écrit hors du thread principal. Fovea ne le
    // demande jamais : `canConcurrentlyReadDocuments(ofType:)` et
    // `canAsynchronouslyWrite(to:ofType:for:)` gardent leur valeur par défaut,
    // `false`, et AppKit garantit alors le thread principal. `assumeIsolated`
    // est donc l'affirmation exacte de ce qui est vrai — et il lèvera une
    // erreur bruyante le jour où quelqu'un activera l'un des deux drapeaux.

    override func read(from data: Data, ofType typeName: String) throws {
        let contents = try TextFile.read(data)
        MainActor.assumeIsolated {
            text = contents.text
            lineEnding = contents.lineEnding
            sourceEncoding = contents.sourceEncoding
            editor?.setText(text)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        MainActor.assumeIsolated {
            // Le tampon de l'éditeur fait foi s'il existe : c'est lui que
            // l'utilisateur voit, et `text` ne le suit qu'au moment d'enregistrer.
            if let editor { text = editor.text }
            return TextFile.write(text: text, lineEnding: lineEnding)
        }
    }

    // MARK: - Fenêtre

    override func makeWindowControllers() {
        let controller = DocumentWindowController()
        addWindowController(controller)
        editor = controller.editor
        controller.editor.documentURL = fileURL
        controller.editor.setText(text)
        // Les états du §6 se disent à l'ouverture, une fois, sans interrompre.
        controller.banner.show(DocumentBanner.messages(byteCount: text.utf8.count,
                                                       encoding: sourceEncoding,
                                                       isWritable: isWritable))

        controller.editor.onTextChanged = { [weak self, weak controller] in
            // `updateChangeCount` est ce qui allume la pastille du bouton de
            // fermeture et déclenche l'enregistrement automatique.
            self?.updateChangeCount(.changeDone)
            controller?.refreshStatistics()
        }
    }

    /// Le fichier peut-il être réécrit ?
    ///
    /// Un nouveau document sans emplacement l'est par définition : il n'y a
    /// encore rien à écraser, et « Enregistrer » ouvrira un sélecteur.
    private var isWritable: Bool {
        guard let fileURL else { return true }
        return FileManager.default.isWritableFile(atPath: fileURL.path)
    }

    // MARK: - Le fichier change sous nos pieds (§5)

    /// Un `.md` est rarement seul : un `git checkout`, un dossier synchronisé,
    /// un autre éditeur ouvert en parallèle, et le fichier bouge pendant qu'on
    /// le regarde. Sans cette veille, la fenêtre continue d'afficher une
    /// version morte — et le prochain enregistrement l'écrase en silence.
    ///
    /// `NSDocument` est déjà un `NSFilePresenter` : la coordination de fichiers
    /// nous prévient toute seule, il ne manquait que la réaction.
    ///
    /// Deux cas, et un seul est automatique :
    ///
    /// - **rien de modifié ici** → on recharge sans rien demander. C'est le cas
    ///   courant, et une alerte n'y apporterait qu'un clic ;
    /// - **des modifications non enregistrées** → on ne touche à rien, on le
    ///   dit. Écraser le travail de quelqu'un pour afficher celui d'un autre
    ///   outil serait le pire des deux mondes ; `NSDocument` posera de son côté
    ///   la question au moment d'enregistrer.
    override nonisolated func presentedItemDidChange() {
        super.presentedItemDidChange()
        Task { @MainActor [weak self] in self?.fileChangedOnDisk() }
    }

    @MainActor private func fileChangedOnDisk() {
        guard let url = fileURL, let type = fileType else { return }

        // Notre propre écriture repasse par ici : la date connue est alors
        // déjà la bonne, et il n'y a rien à recharger.
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        guard let modified, let known = fileModificationDate, modified > known else { return }

        guard !isDocumentEdited else {
            windowControllers.compactMap { ($0 as? DocumentWindowController)?.banner }.forEach {
                $0.show(["Le fichier a changé sur le disque. Vos modifications en cours sont "
                         + "conservées : elles seront proposées à l'enregistrement."])
            }
            return
        }

        // Le curseur est rendu à sa place. Le document a changé ailleurs, pas
        // sous les doigts : le renvoyer en tête serait une perte gratuite.
        let caret = editor?.textView.selectedRange()
        try? revert(toContentsOf: url, ofType: type)
        if let caret, let editor {
            let length = editor.textView.textStorage?.length ?? 0
            editor.textView.setSelectedRange(NSRange(location: min(caret.location, length), length: 0))
        }
    }

    // MARK: - Type de fichier

    /// Fovea écrit toujours du markdown, même quand elle a ouvert un `.txt`
    /// (§5). Sans cette redirection, « Enregistrer sous » proposerait de
    /// réenregistrer en texte brut le document que l'utilisateur vient
    /// d'écrire en markdown.
    override func fileNameExtension(forType typeName: String,
                                    saveOperation: NSDocument.SaveOperationType) -> String? {
        AppConfig.defaultExtension
    }
}
