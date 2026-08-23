# Fovea

A native macOS markdown reader you can also write in, where **formatting is
visible immediately** — no code view, no preview pane.

The name comes from the *fovea centralis*, the area of the retina where
vision is sharpest. That's the app's whole program: bring the text into focus
and let everything else disappear.

## What it's for

You double-click a `.md` in the Finder. It opens instantly, rendered. You
read it, fix a line, close it.

That's the whole job. Fovea is the tool you reach for **for forty seconds** —
the one that makes a markdown file behave like a document instead of a wall
of asterisks.

**It is not where you keep your notes.** Obsidian is very good at that, and
Fovea doesn't try to compete with it: it has no vault, no graph, no
backlinks, no plugins, and it will never ask you to open a folder. It opens a
file. If you're writing at length, write in Obsidian. If you just need to
read or fix one file, this opens faster than anything with a vault to load.

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

## What it does

**Reads everything.** Headings, bold, italic, strikethrough, inline code,
links, blockquotes, bulleted and numbered lists, task lists, horizontal
rules, code blocks with syntax highlighting for eleven languages, YAML front
matter, footnotes, inline images, and tables as an aligned grid. All six
heading levels render; the menu offers the first three, which are the ones
that differ in size.

**Writes the simple things.** Type the markers and they fold away as soon as
the caret leaves. `⏎` continues a list and exits it on an empty item, `⇥`/`⇧⇥` change the level, `⌘B`/`⌘I`/`⌘⇧X`/`⌘⇧K` wrap or remove
formatting, `⌘⌃0..3` change the heading level, `⌘K` inserts a link from the
pasteboard. Clicking a checkbox checks it — `⌘⏎` from the keyboard. `(`
closes itself, and `⇥` steps out of the pair.

**`⌥⌘S` shows the raw markdown**, the safety net. And for anything more
elaborate than the list above — restructuring a table, writing a long
document — that's the way through: put the caret in a table and its `|` come
back, to be edited as the plain text they are.

`⌘V` converts rich text pasted from a browser into markdown, `⌘⇧V` pastes
plain. `⌘F` uses the native find bar, spell checking is the system's.
Opening, saving, tabs, Open Recent, Time Machine versions, session
restoration and iCloud Drive all come from `NSDocument`. Four settings, and
no window for them: appearance, body font, code font and `⌘+`/`⌘−`, in the
View menu. The fonts open the system font panel.

Installs as the system's default Markdown editor.

## What it deliberately doesn't do

No export, no PDF, no printing, no share sheet. No vault, no tags, no
backlinks, no plugins. No focus mode, no typewriter mode, no word count. No
font importing. No command palette, no insertion menu, no panels of any kind:
you write markdown, or you press `⌥⌘S` and write it with the syntax showing.
No editing inside the table grid — the source is right there under the caret.

Each of these existed at some point and was removed. They come back one at a
time if enough people ask, and not before: the app that opens in two seconds
is the app that has little to load.

## What's not there yet

**VoiceOver still reads the hidden syntax.** The semantic roles exist and
interface elements carry them, but the text buffer itself is read as-is:
macOS doesn't consult the string's attributes for accessibility. The detail,
and why the obvious workaround is worse than the problem, is in §8 of the
spec.

Also missing: **notarization**, which requires a paid developer account, and
a **built-in updater**.

## Weight

1.7 MB on disk, one process, about 30 MB of memory with a document open, and
355 ms from double-click to a window on an M1 Pro — where TextEdit takes 400 ms
opening the same file. Apple silicon only.

## Install

```bash
scripts/install.sh
```

Builds in Release, installs into `/Applications`, registers the app with
LaunchServices and launches it. On first launch, macOS warns that it isn't
notarized — right-click the app → Open, once.

Fovea then offers to become the default Markdown editor: `.md`, `.markdown`
and `.mdown` files will open with a double-click. The option stays available
in the Fovea menu.

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

223 tests, including the performance budgets, which **fail** if they're
exceeded: 8 ms per keystroke at 10,000 words, 16 ms at 100,000, 500 ms to
first display. They run in Debug, the least favorable configuration.

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
