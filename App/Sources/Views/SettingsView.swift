// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import SwiftUI
import AppKit

/// La fenêtre de réglages (§4.7).
///
/// En SwiftUI, hébergée dans une fenêtre AppKit : c'est le seul endroit de
/// l'app où SwiftUI est le bon outil — des formulaires, pas de texte à mettre
/// en page. L'éditeur, lui, reste en AppKit pur.
///
/// Trois onglets, et rien de plus. Un réglage qu'on ne sait pas où ranger est
/// presque toujours un réglage qui n'aurait pas dû exister.
struct SettingsView: View {

    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            AppearanceSettings(settings: settings)
                .tabItem { Label("Apparence", systemImage: "textformat") }
            EditingSettings(settings: settings)
                .tabItem { Label("Édition", systemImage: "pencil.line") }
            AboutSettings()
                .tabItem { Label("À propos", systemImage: "info.circle") }
        }
        // Taille fixe, et non intrinsèque : `NSHostingController` ne remonte
        // pas la hauteur d'un `Form` imbriqué dans un `TabView`, et la fenêtre
        // s'ouvrait écrasée sur ses onglets. Une fenêtre de réglages a de toute
        // façon une bonne taille et une seule.
        .frame(width: 480, height: 560)
    }
}

// MARK: - Apparence

private struct AppearanceSettings: View {
    @Bindable var settings: AppSettings
    /// Incrémenté à chaque import ou retrait, pour que les listes se
    /// reconstruisent : la bibliothèque vit sur le disque, pas dans un modèle
    /// observable.
    @State private var fontLibraryVersion = 0

    var body: some View {
        Form {
            Section {
                Picker("Thème", selection: $settings.appearance) {
                    ForEach(AppSettings.Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Texte") {
                FontPicker(title: "Police du corps", selection: $settings.bodyFontName,
                           monospaced: false, libraryVersion: fontLibraryVersion)
                FontPicker(title: "Police du code", selection: $settings.monoFontName,
                           monospaced: true, libraryVersion: fontLibraryVersion)

                // Une taille en points ne dit rien à personne ; ce qu'on juge,
                // c'est le résultat. Le pas de 1 pt suffit — un demi-point ne
                // se voit pas et double le nombre de crans à parcourir.
                LabeledContent("Taille") {
                    HStack {
                        Slider(value: $settings.bodySize, in: 11...32, step: 1)
                        Text("\(Int(settings.bodySize)) pt")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                LabeledContent("Interlignage") {
                    HStack {
                        Slider(value: $settings.lineHeightMultiple, in: 1.0...2.2, step: 0.05)
                        Text(String(format: "%.2f", settings.lineHeightMultiple))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                // Mesurée en signes, pas en points : c'est la grandeur qui a du
                // sens en lecture, et elle suit le choix de police.
                LabeledContent("Largeur de colonne") {
                    HStack {
                        Slider(value: .init(get: { Double(settings.columnWidthInCharacters) },
                                            set: { settings.columnWidthInCharacters = Int($0) }),
                               in: 50...100, step: 1)
                        Text("\(settings.columnWidthInCharacters) signes")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 74, alignment: .trailing)
                    }
                }
            }

            FontLibrarySection(version: $fontLibraryVersion,
                               bodyFontName: $settings.bodyFontName,
                               monoFontName: $settings.monoFontName)

            Section("Blocs de code") {
                Toggle("Coloration en couleurs", isOn: $settings.colorfulCodeBlocks)
                Text("Sans cette option, la coloration passe par la graisse et l'opacité. "
                     + "C'est le seul endroit de l'app où la couleur est autorisée.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Édition

private struct EditingSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Écriture") {
                Toggle("Mode focus", isOn: $settings.focusMode)
                if settings.focusMode {
                    Picker("Garder en évidence", selection: $settings.focusUnit) {
                        ForEach(AppSettings.FocusUnit.allCases) { Text($0.label).tag($0) }
                    }
                }
                Toggle("Machine à écrire", isOn: $settings.typewriterMode)
                Text("La ligne active reste à hauteur fixe et le texte défile dessous. "
                     + "Désactivé, le défilement est celui de n'importe quelle app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Statistiques") {
                Toggle("Afficher les statistiques", isOn: $settings.showStatistics)
                if settings.showStatistics {
                    LabeledContent("Objectif de session") {
                        HStack {
                            TextField("", value: $settings.sessionWordGoal, format: .number)
                                .labelsHidden()
                                .frame(width: 70)
                            Text(settings.sessionWordGoal == 0 ? "aucun" : "mots")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Markdown") {
                Toggle("Reconnaître les constructions à la frappe", isOn: $settings.markdownShortcutsWhileTyping)
                Text("« - » continue la liste au retour à la ligne, ⇥ change le niveau.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Menu d'insertion sur « / »", selection: $settings.slashMenuScope) {
                    ForEach(AppSettings.SlashMenuScope.allCases) { Text($0.label).tag($0) }
                }
                Text("Un « / » propose les blocs : titre, liste, citation, code, tableau, "
                     + "filet. Il n'ouvre le menu que s'il commence un mot, jamais collé à "
                     + "un caractère — « https:// » et « 12/03 » restent ce qu'ils sont.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                LabeledContent("Dossier des images") {
                    TextField("", text: $settings.assetsFolderName)
                        .labelsHidden()
                        .frame(width: 140)
                }
                Text("Les images déposées y sont copiées, à côté du document, "
                     + "et référencées en chemin relatif.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - À propos

private struct AboutSettings: View {
    @State private var isDefaultHandler = DefaultHandler.isDefault

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppConfig.name).font(.title2.weight(.semibold))
                        Text("Version \(AppConfig.version) (\(AppConfig.build))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Fichiers Markdown") {
                    if isDefaultHandler {
                        Label("Ouverts avec \(AppConfig.name)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Utiliser \(AppConfig.name) par défaut") {
                            Task {
                                await DefaultHandler.makeDefault()
                                isDefaultHandler = DefaultHandler.isDefault
                            }
                        }
                    }
                }
            }

            Section {
                Link("Code source et signalements", destination: AppConfig.repositoryURL)
                Text("GNU AGPL v3 ou ultérieure. Analyse markdown par swift-markdown (Apple), "
                     + "sous licence Apache 2.0.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Choix de police

/// Un sélecteur de police qui ne propose que ce qui a un sens ici.
///
/// La liste complète des polices installées compte des centaines d'entrées,
/// dont les dingbats et les alphabets non latins. On ne montre que les familles
/// **lisibles pour du texte suivi**, et pour le code, que les chasses fixes.
///
/// Les polices apportées par l'utilisateur (§4.7) sont présentées **en tête**,
/// avant les installées : quelqu'un qui prend la peine d'en déposer une la
/// cherchera en premier, pas au milieu de trois cents familles système.
private struct FontPicker: View {
    let title: String
    @Binding var selection: String?
    let monospaced: Bool
    /// Change quand une police est importée ou retirée, pour reconstruire la
    /// liste sans relancer l'app.
    var libraryVersion: Int = 0

    var body: some View {
        Picker(title, selection: $selection) {
            Text(monospaced ? "SF Mono (système)" : "SF Pro (système)").tag(String?.none)
            if !imported.isEmpty {
                Divider()
                ForEach(imported, id: \.self) { family in
                    Text(family).tag(String?.some(family))
                }
            }
            Divider()
            ForEach(installed, id: \.self) { family in
                Text(family).tag(String?.some(family))
            }
        }
        .id(libraryVersion)
    }

    private var imported: [String] {
        FontLibrary.importedFamilies().filter(isSuitable)
    }

    private var installed: [String] {
        let added = Set(imported)
        return NSFontManager.shared.availableFontFamilies
            .filter { !added.contains($0) && isSuitable($0) }
            .sorted()
    }

    private func isSuitable(_ family: String) -> Bool {
        // Les familles à nom préfixé d'un point sont internes au système ; les
        // proposer n'apporterait que de la confusion.
        guard !family.hasPrefix(".") else { return false }
        guard let font = NSFont(name: family, size: 12) else { return false }
        return monospaced ? font.isFixedPitch : true
    }
}

// MARK: - Bibliothèque de polices

/// Déposer un fichier `.otf` ou `.ttf`, et le retirer.
///
/// Le retrait est offert ici parce que la portée `.process` le rend
/// **réversible sans trace** : la police n'a jamais été installée dans le
/// système, la retirer est supprimer un fichier. C'est ce qui permet d'essayer
/// une police sans conséquence.
private struct FontLibrarySection: View {
    @Binding var version: Int
    @Binding var bodyFontName: String?
    @Binding var monoFontName: String?
    @State private var failure: String?

    var body: some View {
        Section("Vos polices") {
            let families = FontLibrary.importedFamilies()
            if families.isEmpty {
                Text("Aucune police importée. Les fichiers déposés ici ne sont "
                     + "disponibles que dans Fovea : votre système n'est pas touché.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(families, id: \.self) { family in
                    HStack {
                        Text(family)
                        Spacer()
                        Button("Retirer") { remove(family) }
                            .buttonStyle(.link)
                    }
                }
            }

            Button("Importer une police…") { pick() }

            if let failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FontLibrary.acceptedContentTypes
        panel.allowsMultipleSelection = true
        panel.message = "Les polices sont copiées dans Fovea, pas installées dans le système."
        guard panel.runModal() == .OK else { return }

        failure = nil
        for url in panel.urls {
            do {
                try FontLibrary.importFont(at: url)
            } catch {
                failure = error.localizedDescription
            }
        }
        version += 1
    }

    private func remove(_ family: String) {
        // Une police retirée ne doit pas rester sélectionnée : le texte
        // retomberait sur la police système sans que le réglage le dise.
        if bodyFontName == family { bodyFontName = nil }
        if monoFontName == family { monoFontName = nil }
        FontLibrary.remove(family: family)
        version += 1
    }
}

// MARK: - Fenêtre

/// La fenêtre de réglages, en un seul exemplaire.
@MainActor
final class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()

    private convenience init() {
        let hosting = NSHostingController(rootView: SettingsView(settings: .shared))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Réglages"
        window.styleMask = [.titled, .closable]
        // Une fenêtre de réglages qui reste ouverte derrière l'éditeur brouille
        // le retour au texte ; celle-ci se referme et se rouvre à l'identique.
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
