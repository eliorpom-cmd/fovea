// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU GPL v3 or later. See LICENSE.
import AppKit

// Explicit entry point, without a xib and without `@main`.
//
// A document-based app without a MainMenu.xib must build its menu itself,
// and do so before `run()` — otherwise the first display happens without a
// menu bar. The top-level code of `main.swift` is already `@MainActor`, so
// everything that follows runs on the main thread without annotation.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.mainMenu = MainMenu.build()
application.run()
