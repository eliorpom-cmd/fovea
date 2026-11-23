# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Version `0.1.0` in `project.yml`, not yet tagged or released. Build from
source — see [BUILDING.md](docs/BUILDING.md).

### Added

- Printing (`⌘P`, and Page Setup on `⇧⌘P`): the document as it reads on
  screen — markers hidden, bullets, checkboxes, tables, code backgrounds —
  on white paper whatever the system appearance, at a paper-sized body
  font, with page breaks that never cut a line. "Save as PDF" is the print
  panel's own button.
- Hybrid WYSIWYG rendering: markdown markers are masked by default and
  revealed when the caret touches the construct they belong to. A line-start
  marker — `#`, `>`, `-` — also reveals itself when the caret **lands on its
  line on purpose**, by a click or a horizontal move; vertical navigation
  still reveals nothing, so reading a document never makes it move.
- Byte-for-byte file fidelity. Whatever isn't edited comes back unchanged —
  line endings, marker style and list indentation included.
- Reading support for headings, bold, italic, strikethrough, inline code,
  links, blockquotes, bulleted, numbered and task lists, horizontal rules,
  fenced code blocks with monochrome highlighting for eleven languages, YAML
  front matter, footnotes, inline images, and GFM tables as a grid that keeps
  the alignment declared by its `|:--|:-:|--:|` row.
- A hairline under level-1 and level-2 headings, the one every markdown
  preview draws.
- Links are followed on `⌘`-click wherever they lead: an absolute address to
  the browser, a relative path to the file sitting next to the document, an
  `#anchor` to that heading in the open document. Addresses written bare,
  without any markdown around them, are links too.
- Writing shortcuts: list continuation and exit, level changes, `⌘B`/`⌘I`/
  `⌘⇧X`/`⌘⇧K`, `⌘⌃0..3` for heading levels, `⌘K` for a link from the
  pasteboard, auto-pairing.
- `⌥⌘S` source mode, the safety net.
- Rich-text paste converted to markdown on `⌘V`, plain paste on `⌘⇧V`.
- Reading position restored when a document is reopened.
- Four settings in the View menu: appearance, body font, code font, and text
  size.
- Installs itself as the system's default Markdown editor.
- 248 tests, including performance budgets that fail when exceeded: 8 ms per
  keystroke at 10,000 words, 16 ms at 100,000, 500 ms to first display.

### Removed

Each of these shipped and was then taken out. They are listed because the
removals are the design, not an accident — see the scope policy in
[CONTRIBUTING.md](CONTRIBUTING.md).

- Export to PDF, HTML, share sheet and rich text. (Printing came back on
  its own, without the HTML writer: see Added.)
- The command palette, the slash menu, and every floating panel.
- The document outline.
- Focus mode, typewriter mode, and the statistics bar.
- Font importing and the font library.
- Editing inside the table grid; the grid is now read-only and the source
  reveals itself under the caret.
- Colour syntax highlighting and the language picker.
- Image drag-and-drop.
- The settings window, replaced by four items in the View menu.

### Fixed

- A list item that wraps has its bullet, number or checkbox on its first
  line, not its last.
- A nested list item with children of its own is drawn at its own level,
  not its parent's.
- A list inside a blockquote is indented past the quote's bar instead of
  drawing its bullets on it.
- A table stops at the right edge of the text instead of one line padding
  past it.

### Changed

- Line-start markers (`#`, `>`, `-`) now reveal themselves when the caret
  reaches the start of the line rather than anywhere on it, with a latch
  holding the reveal for as long as the caret stays on the line. Moving down
  through a document no longer makes every heading and list item flash.
- The build is Apple silicon only, dead-code stripped and symbol stripped:
  5.0 MB became 1.7 MB.
- The app icon is redrawn in **Icon Composer** and gets the macOS 26 Liquid
  Glass treatment. The document lives in `design/Fovea.icon`; `scripts/icon.sh`
  renders it into the `.icns` that ships, which keeps the look without the
  1.5 MB asset catalogue that compiling the document into the bundle would
  cost. The app goes from 1.7 MB to **1.9 MB**, and the icon no longer follows
  the system appearance — see `design/README.md` for that trade.
- Licensed under the GNU GPL v3 or later (previously AGPL v3).

### Known limitations

- **VoiceOver still reads the hidden syntax.** The semantic roles exist, but
  macOS does not consult the string's attributes for accessibility. See
  [§8](docs/PRINCIPLES.md#8-accessibility).
- **Not notarized.** Requires a paid Apple developer account. macOS warns on
  first launch; right-click → Open, once.
- **No built-in updater.**
