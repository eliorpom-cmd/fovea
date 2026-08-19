# Fovea

A native macOS markdown editor where **formatting is visible immediately**,
with no code view and no preview pane.

The name comes from the *fovea centralis*, the area of the retina where
vision is sharpest. That's the app's whole program: bring the text into focus
and let everything else disappear.

> **Status: under construction.** The core works — see "What works" below.
> Images, editable tables and export aren't there yet.

## Why

The market splits into three camps, and each fails on one axis:

| | Native | WYSIWYG | Minimal |
|---|---|---|---|
| **iA Writer** | yes | **no** — markers stay visible | yes |
| **Typora, Marktext** | **no** — Electron | yes | medium |
| **Obsidian** | **no** — Electron | partial | **no** |
| **Bear** | yes | yes, but proprietary format | yes |

Fovea targets the empty cell: pure AppKit, markers that disappear, `.md`
files on disk that stay readable by anything else.

## The two promises

**Formatting is visible.** Markdown markers are invisible by default and
reappear, in pale gray, as soon as the caret touches the construct they
belong to. The word stays bold while its `**` come back. A `#`, `>` or
line-start `-`, though, waits for the caret to reach the start of the line:
without that, moving down through a document would make every heading and
list item you pass through flash.

**The file doesn't move.** Whatever you haven't touched comes back byte for
byte. `*` never becomes `_`, list indentation is never recalculated, a
Windows file's line endings stay as they are. Your `git diff` only contains
what you actually wrote.

This second promise isn't a matter of discipline: the app never writes from
a syntax tree, so it is **structurally incapable** of reformatting anything
you haven't edited.

## What works

- Headings, bold, italic, strikethrough, inline code, links, blockquotes,
  bulleted and numbered lists, task lists, horizontal rules, code blocks,
  YAML front matter, footnotes
- Syntax highlighting for eleven languages, monochrome by default, real
  colors as an option, **with zero dependencies**
- `⏎` continues a list and exits it on an empty item, `⇥`/`⇧⇥` change the
  level, `⌘B`/`⌘I`/`⌘⇧X`/`⌘⇧K` wrap or remove formatting, `⌘⌃0..6` change the
  heading level, `⌘⌥K` inserts a link using the pasteboard's address
- Clicking a task's checkbox checks it — `⌘⏎` from the keyboard — and a
  completed task dims
- `⌘V` converts rich text pasted from a browser into markdown, `⌘⇧V` pastes
  as plain text
- `⌥⌘S` switches the whole document to raw markdown — the safety net
- Opening, saving, tabs, Open Recent, Time Machine versions, session
  restoration and iCloud Drive, via `NSDocument`
- `⌘F` with the native find bar, system spell checking
- Focus mode — everything dims except the current sentence or paragraph —
  and typewriter mode, both optional: normal scrolling is the default
- Unobtrusive statistics: words, characters, reading time, with an optional
  session goal. Markdown syntax isn't counted
- Settings window: theme, body and code font from those installed, size,
  line spacing, column width in characters
- Images rendered inline, drag-and-drop from the Finder and image pasting:
  the file is copied next to the document and the link is written as a
  relative path
- Standalone HTML export — a single file, images included — paginated PDF
  export, and `⌘⇧C` which puts rich text on the pasteboard
- Document outline (`⌘⌥0`): the whole structure, hierarchical and clickable
- Command palette (`⌘K`): commands **and** document headings in the same
  list, filtered by subsequence — "mdf" finds "Focus Mode"
- **Editable tables in place**: aligned columns, `:--`/`:-:`/`--:`
  alignments respected, bold header row, subtle rules. **You write into the
  grid without ever seeing the `|`**: `⇥` moves to the next cell and selects
  its content, `⏎` moves down a row and creates one at the end, `⌫` at the
  start of a cell moves back instead of breaking the column. A malformed
  table, or one too wide for the column, stays displayed exactly as written
- **Slash menu**: a `/` starting a word offers blocks — heading, list, task,
  blockquote, code, table, horizontal rule — and **shows the syntax it
  inserts**. Essential when markers are hidden. Attached to a character it
  does nothing: `https://` and `12/03` stay as they are
- **Font import**: drop an `.otf` or `.ttf` file and it becomes available
  only in Fovea. Your system fonts are never touched, and removing it is one
  click
- Installs as the system's default Markdown editor

## What's not there yet

**VoiceOver still reads the hidden syntax.** The semantic roles exist and
interface elements carry them, but the text buffer itself is read as-is:
macOS doesn't consult the string's attributes for accessibility. The detail,
and why the obvious workaround is worse than the problem, is in §8 of the
spec.

Also missing: **notarization**, which requires a paid developer account, and
a **built-in updater**.

## Install

```bash
scripts/install.sh
```

Builds in Release, installs into `/Applications`, registers the app with
LaunchServices and launches it. On first launch, macOS warns that it isn't
notarized — right-click the app → Open, once.

Fovea then offers to become the default Markdown editor: `.md`, `.markdown`
and `.mdown` files will open with a double-click. The option stays available
in the Fovea menu and in Settings › About.

## Build

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Fovea.xcodeproj -scheme Fovea -configuration Release build
```

See [docs/BUILDING.md](docs/BUILDING.md).

## Test

```bash
xcodebuild -project Fovea.xcodeproj -scheme Fovea -destination 'platform=macOS' test
```

133 tests, including the performance budgets, which **fail** if they're
exceeded. They run in Debug, the least favorable configuration.

To check file fidelity on real documents:

```bash
scripts/fidelity-check.sh my-document.md
```

The script opens each file in the app, saves it without touching it, and
judges the result on a `git diff`.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — why the code is built the way it
  is, and the dead ends avoided.
- [Building](docs/BUILDING.md)

## License

GNU AGPL v3 or later. See [LICENSE](LICENSE).
