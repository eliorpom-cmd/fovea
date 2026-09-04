# Design principles

The rules the code answers to. Comments throughout the sources cite them by
number — `§3.1`, `§5`, `§9` — because a rule stated once and referenced from
the twenty places that depend on it is cheaper than the same paragraph
repeated twenty times.

This document is the current state, not a history. Where a rule was revised
against the running app, the revision is what's written here, and
[ARCHITECTURE.md](ARCHITECTURE.md) explains what was tried first and why it
gave way.

---

## 1. What the app is

Fovea opens one markdown file, renders it, and lets you fix a line. That's
the whole job.

It is not a note-taking app. No vault, no library, no folder to open, no
sidebar listing anything. It has no opinion about where your files live, and
it never asks.

Every feature is measured against the forty seconds between a double-click
in the Finder and closing the window again. A feature that doesn't earn its
place in those forty seconds doesn't ship, and several that had shipped were
removed once measured that way.

---

## 2. The key function: hybrid WYSIWYG

This is the app's reason to exist, and the place where every competitor
differs from every other. It is specified down to the character.

### 2.1 The rule

> A markdown marker is **masked** by default, and **revealed** when the caret
> or the selection touches the construct it belongs to.

Masked means: zero width on screen, and **still present in the file and in
the edit buffer**. Nothing is ever removed from the text.

Revealed means: shown at normal size, in a muted tint (`label/tertiary`),
without the text it wraps changing style. The word stays bold while its `**`
come back.

### 2.2 The scope of the reveal

The detail that separates a calm editor from a nervous one.

| Construct | Revealed scope |
|---|---|
| **Inline** (`**`, `*`, `` ` ``, `~~`, `[text](url)`) | The **innermost** construct containing the caret, and only that one. |
| **Line-start marker** (`#`, `>`, `-`, `1.`, `- [ ]`) | Revealed when the caret **lands on the line on purpose** — a click, a horizontal move — or touches the prefix, bounds included; then held for as long as it stays on the line. |
| **Fenced block** (` ``` `, YAML front matter `---`) | Both fences revealed together as soon as the caret is inside. |
| **Attachment** (image, table) | See §2.6 — the view is replaced by its source. |

The middle row first read "anywhere on the line". That is the simplest rule
to state and was the most unpleasant to use: a level-2 heading's `## ` is
some forty points wide, and **every press of the down arrow** made every
heading, list item and quote it passed through jump and settle. So the rule
became: the prefix reveals itself when you go and get it, at the start of the
line.

Which was right about the arrow keys and wrong about everything else. An
alpha tester reading a README reported that the syntax "only shows on double
click" — and that was precisely true, for a reason nobody had foreseen:
double-clicking the first word of a heading selects it, which puts the caret
at the end of the `## `, the one position on that line touching the marker. A
single click anywhere else on the same line showed nothing, and nothing said
why.

**What the rule was protecting was vertical navigation, and only that.** It
now says so: `↑`, `↓`, page and document moves reveal nothing, so reading a
document still never makes it move. A click, or a horizontal move, is a
deliberate arrival on one line — and that line shows what it is made of.

The **latch** is what holds it: once the prefix is revealed, it stays revealed
for as long as the caret is on the line. Without it, the first letter typed
after the `⏎` that continues a list would shift the line at the worst possible
moment. The state is therefore no longer a pure function of position — it
depends on how the caret got there — but only in the direction that
**removes** movement.

**One inline element is revealed at a time.** The paragraph never turns into
syntax soup.

### 2.3 Invisible caret positions

The fear: if the `**` have zero width but still exist in the buffer, the
right arrow crossing them would look like a dropped keystroke — the caret
would not move on screen.

**It does not happen**, and the reason is mechanical rather than careful. A
zero-width run is not a position the layout can place a caret in, so the
selection machinery steps over the pair in one move. The invariant the rest
of the code relies on is therefore: **no caret position ever falls inside a
masked marker**. [ARCHITECTURE.md](ARCHITECTURE.md) has the proof and the
test that guards it.

### 2.4 The rendering table

| Element | Caret outside | Caret inside |
|---|---|---|
| `# Heading` … `###### Heading` | Text at the level's size, `semibold`; a hairline closes `#` and `##` | `#` revealed in `label/tertiary` |
| `**bold**` | `semibold` | `**` revealed |
| `*italic*` / `_italic_` | Italic | Marker revealed, in its original form (`*` stays `*`) |
| `` `code` `` | Mono, `fill/quaternary` background, horizontal padding | Backticks revealed |
| `~~struck~~` | Struck through | `~~` revealed |
| `[text](url)` | Underlined text, `⌘`-click follows it: a URL to the system, a relative path to the file next to the document, `#anchor` to that heading in the page | `[`, `]`, `(url)` revealed |
| `https://…` written bare | Underlined and followed like any other link | Nothing to reveal: the address is the text |
| `![alt](path)` | Rendered image (§2.6) | Markdown source in place of the image |
| `> quote` | Vertical rule at the left, `label/secondary`, indented | `>` revealed |
| `- item` / `1. item` | `•` bullet or number, indented per level | Source marker revealed |
| `- [ ]` / `- [x]` | Clickable checkbox | Source revealed |
| `---` alone on its line | Horizontal `separator` rule | The dashes revealed |
| ` ```lang ` … ` ``` ` | Mono block, `fill/quaternary` background, highlighting (§4.3) | Fences and language revealed |
| `\| a \| b \|` (GFM) | Grid (§2.6) | Aligned source |
| `[^1]` and its definition | Clickable superscript, jumps to the definition | Source revealed |
| YAML front matter | Folded to one "Metadata (n fields)" line | Unfolded in mono, `---` revealed |
| Raw inline HTML | **Shown as-is**, muted mono. Never interpreted, never swallowed | idem |

Revealing `## ` pushes the heading text two characters to the right. The
original answer was a permanent gutter to the left of every heading, with the
hashes drawn into it. What shipped instead is §2.2: the shift happens when a
line is aimed at, once, and never while passing through — the same problem
solved by the rule rather than by the layout, and it costs a state variable
instead of a permanent gutter down the whole body text.

The hairline under `#` and `##` is not decoration. It is what says, without a
word being read, where one section ends — every preview of the same file draws
it, and a long README without it reads as one undivided block. It is drawn,
never written: §3.1 forbids adding the character it would take.

### 2.5 Typing behaviour

A WYSIWYG is judged as much by what it does while you type as by what it
shows. Type the markers and they fold away as soon as the caret leaves.

`⏎` continues a list and exits it on an empty item. `⇥`/`⇧⇥` change the
level. `⌘B`/`⌘I`/`⌘⇧X`/`⌘⇧K` wrap the selection, or unwrap it when it is
already formatted. `⌘⌃0..3` change the heading level. `⌘K` inserts a link
from the pasteboard. `(` closes itself and `⇥` steps out of the pair.

**No typographic substitution**, including macOS's own: no smart quotes, no
em dash for `--`, no ellipsis for `...`. What you typed is what the file
gets — §5 covers what the app itself writes, too.

The pasteboard is examined in a fixed order, richest first: `⌘V` converts
rich text pasted from a browser into markdown, `⌘⇧V` pastes plain.

### 2.6 Non-text blocks

**Images** render inline, bounded to the column width. A missing one gets an
outlined frame carrying the path rather than a gap. An animated GIF shows its
first frame only, with an indicator: animation in an editor is a permanent
CPU cost for nothing.

**Tables** render as a grid, each column drawn from the edge its `|:--|:-:|--:|`
row declares — the colons used to be validated and then dropped, which made
the same file say two different things depending on where it was opened. The
grid is **read-only**. Putting
the caret in a table brings its `|` back, to be edited as the plain text they
are. An editable grid shipped once and was removed: it needed a second
editing model, a second undo path and a second selection model, for a
construct the source handles in one keystroke. A table the parser refuses is
shown in the fixed-pitch font so its columns still line up — never a guess at
the intent.

---

## 3. Architecture

### 3.1 The principle that governs everything

> **The markdown text is the sole source of truth.** It lives in the
> `NSTextContentStorage`. The app never builds an intermediate rich document
> that it would then re-serialize.

Rendering is **only a layer of attributes and masking** applied on top of the
source text. The corollary is a hard rule: **rendering never inserts a single
character into the buffer.** A bullet, a checkbox, a table rule and an image
are all drawn, never typed.

Four consequences, all good:

- **Fidelity to the file** (§5). What the user hasn't touched comes back byte
  for byte, so `git diff` stays clean.
- **`NSTextView`'s native undo works**, with no homegrown layer.
- **Source mode (§4.2) is trivial**: the same buffer, minus the style layer.
- **There is no "conversion loss"** possible, since there is no conversion.

### 3.2 The stack

AppKit and `NSDocument`, `NSTextView` on **TextKit 2**, and
[swift-markdown](https://github.com/apple/swift-markdown) for the AST.

**macOS 15 minimum.** The core of this app *is* TextKit 2, and TextKit 2
carries fragment and attachment bugs on earlier systems that would need
manual workarounds throughout.

### 3.3 The rendering pipeline

```
keystroke
  │
  ├─► NSTextStorage modified (the source text, never altered by rendering)
  │
  ├─► reparse of the touched range ───► swift-markdown AST with SourceRange
  │
  ├─► SourceRange (line, column, UTF-8 bytes)
  │        → NSRange (UTF-16 offsets)          ◄── the pitfall, below
  │
  ├─► style attributes and masked ranges applied
  │
  └─► TextKit 2 lays out the viewport
```

**The conversion pitfall.** `swift-markdown` gives positions in line/column
counted in **UTF-8 bytes**. `NSTextStorage` indexes in **UTF-16 units**. An
accent is 2 bytes and 1 unit; an emoji, 4 bytes and 2 units. A naive
conversion misaligns every attribute from the first accented letter onward.
It needs a per-line index table, rebuilt on reparse. **Non-negotiable, and
covered by tests** over a corpus containing accented text, emoji and CJK.

**Incremental reparse.** Reparsing 100,000 words on every keystroke will not
hold. Only the **block** containing the edit is reparsed — blocks being
delimited by blank lines — widening to the whole document only when the edit
introduces or removes a block-structuring character (` ``` `, `|`, `---`,
`>`) that can change the meaning of everything after it.

### 3.4 The technical bet: masking the markers

The point that decided whether the app could exist at all. Two mechanisms
were possible, neither of them a path Apple has marked out.

**Mechanism A — zero-width rendering.** The markers stay in the buffer *and*
in the display string, but carry attributes that make them invisible and
zero-width.

**Mechanism B — a display string shorter than the source**, with a mapping
between the two.

**A shipped.** It keeps one string and one set of indices, so nothing has to
be mapped, and the §2.3 invariant falls out of it rather than being
maintained. B would have meant a second coordinate system in every feature
that touches a range, which is all of them.

---

## 4. Functional scope

### 4.1 Markdown supported

**CommonMark** — ATX headings, bold, italic, inline code, indented and fenced
code blocks, nested bulleted and numbered lists, blockquotes, links, images,
horizontal rules, hard line breaks.

**GFM** — tables and the alignment their delimiter row declares, `- [ ]` task
lists, strikethrough, autolinks — bare addresses included.

**Extensions** — `[^1]` footnotes, YAML front matter. Front matter is
detected ahead of the parser; cmark doesn't know it. Footnotes and bare
addresses are found the same way, by a scan of our own: `cmark-gfm` has both
extensions, `swift-markdown` exposes neither, and both patterns are
unambiguous enough to read by hand.

**Out of scope:** LaTeX, Mermaid, `[[wiki]]` links, Obsidian callouts,
Kramdown `{: attributes}`, definition lists.

### 4.2 Source mode

`⌥⌘S` switches the whole document to raw markdown — monospace, unstyled,
fully editable. Press it again and the rendering comes back, caret kept where
it was.

This is the safety net: when a rendering looks wrong, you can see what is
actually in the file instead of doubting the app. It is also the first
diagnostic tool in any bug report.

### 4.3 Code blocks

Syntax highlighting is **monochrome**, always — four categories told apart by
weight and opacity (keyword, string, comment, literal), which is ample for
the ten-line snippet a prose document contains. Colour in code blocks shipped
as a setting once and was removed: §7 allows exactly one coloured object on
screen, and it is the user's images.

The engine is **homegrown rules over a closed set of languages** (`swift`,
`js`, `ts`, `python`, `bash`, `json`, `html`, `css`, `yaml`, `md`, `sql`).
**No dependency**: not Highlightr, which bundles JavaScriptCore to run
highlight.js, and not tree-sitter, which means compiling C grammars. An
unknown language renders as uncoloured mono. Never an error, never an empty
block.

### 4.4 Images

Rendered in the flow (§2.6), resolved **relative to the document**. Relative
and not absolute is what lets the folder be moved, committed or sent without
anything breaking — which is the whole point, and the reason the app is not
sandboxed (§10).

### 4.7 Settings

**Four, and no window for them**: appearance, body font, code font, and text
size. They live in the View menu, and the fonts open the system font panel.

A settings window shipped, grew to three tabs, and was deleted. Four
preferences do not need a window, and the window was one more thing to load
before the caret appears.

No font importing: the system's installed fonts are the choice.

---

## 5. The file

This chapter exists because **the file will outlive the app.**

| Subject | Rule |
|---|---|
| **Type** | UTI `net.daringfireball.markdown`. Read: `.md`, `.markdown`, `.mdown`, `.mkd`, `.mdtext`, `.txt`. Written: `.md`. |
| **Encoding** | Read as UTF-8, falling back to detection if that fails. Written **UTF-8 without BOM, always.** |
| **Line endings** | **The file's own are preserved.** A CRLF file stays CRLF. A new file: LF. |
| **Trailing spaces** | Never stripped — two of them at end of line are a hard break in markdown. |
| **Normalization** | **None.** `*` never becomes `_`, `#` never becomes `===`, list indentation is never recalculated. |
| **Saving** | `NSDocument` autosave in place. Time Machine versions and session restoration come free. |
| **iCloud Drive** | Free with `NSDocument`. Nothing to write. |
| **Changed underneath** | `NSFilePresenter`: silent reload when the document is unmodified, otherwise an alert. |

**The non-normalization rule is the app's central promise**, and it is kept
by the architecture of §3.1 rather than by discipline: since the app never
writes from an AST, it is structurally incapable of reformatting what the
user hasn't touched.

The rule applies to what the app writes itself, too: a checkbox toggled from
the keyboard keeps the file's own `[X]` casing.

---

## 6. States and edge cases

Each has a defined behaviour. None of them is allowed to be a default state.

| Case | Behaviour |
|---|---|
| **Empty document** | A caret, the text column, and nothing else. No welcome screen, no template, no suggestion. |
| **Unclosed code block** | *The most frequent case.* While the block is unclosed **and the caret is inside it**, the rest of the document keeps its rendering and only the opening line is marked. The block swallows what follows only once closed, or once the caret leaves. |
| **Malformed table** | No grid. The source stays displayed in the fixed-pitch font. Intent is never guessed. |
| **Missing image** | An outlined frame carrying the path and "Image not found". |
| **Huge image** | Bounded to the column width. |
| **Animated GIF** | First frame only, with an indicator. |
| **Raw HTML in the text** | Shown literally, muted mono. **Never interpreted.** |
| **Unrecognized markdown** | Shown as-is. An element that isn't understood is never hidden: hiding text you failed to read is making it disappear. |
| **Read-only file** | Opens, stays editable in memory, warns on save and offers "Save As". |
| **Binary file renamed `.md`** | Null bytes detected, clean refusal, honest message. Not a megabyte of gibberish. |
| **Non-UTF-8 encoding** | Opened with the detected encoding, with a banner: converted to UTF-8 on save. |
| **Switching to source mode with a selection** | The selection is kept, but extended to the markers of its constructs. |

The three states worth communicating — a converted encoding, a read-only
file, a reload from disk — are shown in a banner that fades out. §7 wants the
app to disappear; a permanent banner would be exactly the chrome it forbids.

---

## 7. Design

**Strictly monochrome, unapologetically native macOS.** Hierarchy comes from
contrast, weight, size and space; never from hue.

**The app must disappear.** No sidebar, no tool rail, a near-empty window
bar. In full screen, nothing should be left but the text column on the window
background.

**The only coloured object allowed is the user's own content** — their
images. Nothing else in the interface gets a hue.

| Element | Setting |
|---|---|
| Body font | **SF Pro** by default, free choice after that (§4.7) |
| Code font | SF Mono |
| Column width | Measured in characters, ~68 |
| Line spacing | 1.5 |
| Margins | Generous and symmetrical, column centred in the window |
| Caret | Thin, system blink, `label/primary` |
| Revealed markers | `label/tertiary` — present, never loud |

The tokens live in `Theme.swift`, and nothing outside it names a colour.

---

## 8. Accessibility

§2 creates an accessibility problem most WYSIWYG editors ignore: **if the
`##` are invisible on screen, they are still read out by VoiceOver, where
they mean nothing.**

**This is not solved, and the shortfall is deliberate.** The semantic roles
exist and interface elements carry them; the text buffer itself is still read
as-is, because macOS does not consult the string's attributes for
accessibility. The workaround available — maintaining a second, parallel
accessible string — costs a second source of truth, which §3.1 exists to
forbid, and it would go stale on exactly the edits where it matters most.
[ARCHITECTURE.md](ARCHITECTURE.md) has the detail.

What *is* held:

- **Every function reachable from the keyboard.** A function that only exists
  with a mouse doesn't exist. Clicking a checkbox is convenience; `⌘⏎` is the
  interface.
- **Reduce Motion respected.** The banner still appears, it simply doesn't
  animate.
- **Dynamic Type and contrast** from the system, through the semantic
  colours.

Masked markers stay below the accessibility threshold deliberately: they are
zero-width by construction, not merely faint.

---

## 9. Performance budgets

Numbers, so they are measurable, and measured by tests that **fail** when
exceeded rather than by hope.

| Measure | Budget |
|---|---|
| Keystroke → display, 10,000-word document | **< 8 ms** (one frame at 120 Hz) |
| Same, 100,000-word document | < 16 ms |
| Open and first display, 100,000 words | < 500 ms |
| Memory, 100,000-word document | < 200 MB |
| Cold launch to caret | < 400 ms |

TextKit 2 lays out by viewport, so scrolling was never the worry. **The real
cost is the reparse** (§3.3), and it is the thing instrumented first.

The budgets are measured in **Debug**, the least favourable configuration:
`@testable import` requires `ENABLE_TESTABILITY`, which Release doesn't
carry. Holding them in Debug guarantees they hold in Release.

---

## 10. Distribution

| Subject | Decision |
|---|---|
| **Licence** | Open source, GNU GPL v3 or later |
| **Distribution** | Build from source; GitHub Releases when there is something to release |
| **Signing** | Ad hoc, `ENABLE_HARDENED_RUNTIME: NO`. Flips to Developer ID and notarization the day the paid account exists. |
| **Sandbox** | **No.** Reading images relative to the document requires it. The sandbox would impose security-scoped bookmarks for zero benefit outside the App Store. |
| **Architecture** | arm64 only |
| **Price** | Free |

The accepted consequence: no Mac App Store. Going there would require the
sandbox, and therefore reworking asset handling entirely. That is a decision
to retake, not a setting to flip.
