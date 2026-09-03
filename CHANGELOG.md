# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Version `0.1.0` in `project.yml`, not yet tagged or released. Build from
source — see [BUILDING.md](docs/BUILDING.md).

### Added

- Hybrid WYSIWYG rendering: markdown markers are masked by default and
  revealed when the caret touches the construct they belong to.
- Byte-for-byte file fidelity. Whatever isn't edited comes back unchanged —
  line endings, marker style and list indentation included.
- Reading support for headings, bold, italic, strikethrough, inline code,
  links, blockquotes, bulleted, numbered and task lists, horizontal rules,
  fenced code blocks with monochrome highlighting for eleven languages, YAML
  front matter, footnotes, inline images, and GFM tables as an aligned grid.
- Writing shortcuts: list continuation and exit, level changes, `⌘B`/`⌘I`/
  `⌘⇧X`/`⌘⇧K`, `⌘⌃0..3` for heading levels, `⌘K` for a link from the
  pasteboard, auto-pairing.
- `⌥⌘S` source mode, the safety net.
- Rich-text paste converted to markdown on `⌘V`, plain paste on `⌘⇧V`.
- Reading position restored when a document is reopened.
- Four settings in the View menu: appearance, body font, code font, and text
  size.
- Installs itself as the system's default Markdown editor.
- 224 tests, including performance budgets that fail when exceeded: 8 ms per
  keystroke at 10,000 words, 16 ms at 100,000, 500 ms to first display.

### Removed

Each of these shipped and was then taken out. They are listed because the
removals are the design, not an accident — see the scope policy in
[CONTRIBUTING.md](CONTRIBUTING.md).

- Export to PDF, HTML, print, share sheet and rich text.
- The command palette, the slash menu, and every floating panel.
- The document outline.
- Focus mode, typewriter mode, and the statistics bar.
- Font importing and the font library.
- Editing inside the table grid; the grid is now read-only and the source
  reveals itself under the caret.
- Colour syntax highlighting and the language picker.
- Image drag-and-drop.
- The settings window, replaced by four items in the View menu.

### Changed

- Line-start markers (`#`, `>`, `-`) now reveal themselves when the caret
  reaches the start of the line rather than anywhere on it, with a latch
  holding the reveal for as long as the caret stays on the line. Moving down
  through a document no longer makes every heading and list item flash.
- The build is Apple silicon only, dead-code stripped and symbol stripped:
  5.0 MB became 1.7 MB.
- Licensed under the GNU GPL v3 or later (previously AGPL v3).

### Known limitations

- **VoiceOver still reads the hidden syntax.** The semantic roles exist, but
  macOS does not consult the string's attributes for accessibility. See
  [§8](docs/PRINCIPLES.md#8-accessibility).
- **Not notarized.** Requires a paid Apple developer account. macOS warns on
  first launch; right-click → Open, once.
- **No built-in updater.**
