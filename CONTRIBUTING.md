# Contributing to Fovea

Thank you for looking. Two minutes of reading here will save you an
afternoon of work that gets declined.

## The scope policy — read this first

Fovea is defined as much by what was taken out of it as by what it does.
Export, PDF, the share sheet, the command palette, the slash menu,
the document outline, focus mode, typewriter mode, the word count, font
importing, editable tables, coloured code and the settings window **all
shipped at some point, and were all removed**. The list in the README under
"What it deliberately doesn't do" is not a roadmap of things not yet built.
It is a record of decisions. Printing went out with the exports and came
back on its own (November 2026), because it was the one missed in daily use;
it draws with the editor's renderer and adds no export code.

The reason is a measurement, not a taste: the app opens in 355 ms because it
has almost nothing to load, and every feature is weighed against the forty
seconds between a double-click in the Finder and closing the window again.

So:

> **Open an issue before writing a feature.** A feature pull request that
> arrives without a prior discussion will most likely be declined, and that
> is a waste of your time.

Things that are always welcome, no discussion needed:

- **Fidelity failures.** A file that doesn't come back byte for byte after
  an open-and-save is the most serious class of bug this app has. See below
  for how to report one.
- **Crashes**, hangs, and anything that loses data.
- **Performance regressions** against the budgets in
  [§9](docs/PRINCIPLES.md#9-performance-budgets).
- **Accessibility improvements**, especially anything that makes progress on
  the VoiceOver shortfall documented in
  [§8](docs/PRINCIPLES.md#8-accessibility).
- **Rendering bugs** — a construct in
  [§2.4](docs/PRINCIPLES.md#24-the-rendering-table) that renders wrongly.
- Typos and documentation fixes.

## Before you write code

Read [docs/PRINCIPLES.md](docs/PRINCIPLES.md) and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Between them they cover the
rules the code answers to and the dead ends already explored — several
plausible-looking approaches have been tried and reverted, and they are
written down so nobody has to spend that week twice.

The two rules that will get a patch rejected fastest:

1. **Never write from an AST.** The markdown text is the sole source of
   truth ([§3.1](docs/PRINCIPLES.md#31-the-principle-that-governs-everything)).
   Rendering is a layer of attributes over the source, never a
   transformation of it.
2. **Rendering never inserts a character into the buffer.** Bullets,
   checkboxes, table rules and images are drawn, never typed.

## Setting up

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Fovea.xcodeproj -scheme Fovea -configuration Release build
```

`Fovea.xcodeproj` is **generated and git-ignored**. `project.yml` is the
source of truth — edit that, never the project file, and rerun
`xcodegen generate` after adding a Swift file or the build fails with
"cannot find X in scope".

Full details, including the troubleshooting list, in
[docs/BUILDING.md](docs/BUILDING.md).

## Tests

```bash
xcodebuild -project Fovea.xcodeproj -scheme Fovea -destination 'platform=macOS' test
```

All 224 must pass. The performance tests are budgets that **fail** when
exceeded; they run in Debug, deliberately, because that is the least
favourable configuration.

New behaviour needs a test. The parsing layer (`App/Sources/Markdown/`)
imports no AppKit precisely so that it can be tested without launching an
interface — put logic there when you can.

For a change that touches reading or writing files, also run the end-to-end
fidelity check against real documents of your own:

```bash
scripts/fidelity-check.sh my-document.md
```

## Code style

Match the surrounding code. Concretely:

- **Comments in English**, and they explain *why*, not *what*. The existing
  comments are unusually dense and that is deliberate: a comment that
  records why an approach was rejected is worth more than one restating the
  line below it.
- Cite the principle you are implementing by number — `§5`, `§3.1` — the way
  the existing code does.
- Warnings are errors (`SWIFT_TREAT_WARNINGS_AS_ERRORS`), and strict
  concurrency is on. Both must stay that way.
- Every new file carries the licence header:

  ```swift
  // Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
  // Licensed under the GNU GPL v3 or later. See LICENSE.
  ```

## Reporting a fidelity bug

This is the one worth spelling out, because a good report makes it fixable
in minutes:

1. The **exact input file**, or the smallest excerpt that still reproduces
   it. Attach it rather than pasting, so line endings and trailing spaces
   survive.
2. The `git diff` after opening and saving it without typing anything.
3. Your macOS version.

`⌥⌘S` shows the raw markdown, which is the fastest way to tell a rendering
bug from a file bug.

## Licence

Fovea is GNU GPL v3 or later. By contributing you agree that your
contribution is licensed under the same terms. There is no CLA.
