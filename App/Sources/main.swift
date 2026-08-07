// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
import AppKit

// Point d'entrée explicite, sans xib et sans `@main`.
//
// Une app à documents sans MainMenu.xib doit construire son menu elle-même, et
// le faire avant `run()` — sinon le premier affichage se fait sans barre de
// menus. Le code de haut niveau de `main.swift` est déjà `@MainActor`, donc
// tout ce qui suit est sur le thread principal sans annotation.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.mainMenu = MainMenu.build()
application.run()
