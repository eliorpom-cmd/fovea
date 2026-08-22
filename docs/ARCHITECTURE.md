# Architecture

This document explains **why** the code is built the way it is. The *what*
is readable in the sources; what doesn't show up there are the dead ends
that were avoided.

The spec remains the reference for product decisions. `§n` references
throughout this document point to it.

## Repository layout

```
App/
  Info.plist              markdown document types, imported UTI
  Fovea.entitlements      empty: the app is not sandboxed (§10)
  Sources/
    main.swift            entry point, no xib, no @main
    AppDelegate.swift
    MainMenu.swift        the menu bar, in code
    AppConfig.swift       names and identifiers, in one place
    AppSettings.swift     observable preferences, backed by UserDefaults
    Theme.swift            design tokens (§7)
    Document/             NSDocument, read/write, file fidelity
    Markdown/              parsing — no AppKit import, so it's testable
    Editor/                NSTextView, masking, rendering, decorations, typing
Tests/                    108 tests, including the §9 budgets
scripts/fidelity-check.sh end-to-end fidelity check
project.yml               XcodeGen manifest — source of truth for the project
```

`Fovea.xcodeproj` is **generated and git-ignored**. `project.yml` is what
gets edited, never the project file. After adding a Swift file, rerun
`xcodegen generate`, or the build fails with "cannot find X in scope".

**`Markdown/` contains no `import AppKit`.** That's the layer where range
conversion lives, and it has to be testable without launching the interface.

## The principle that governs everything

> The markdown text is the sole source of truth. It lives in the
> `NSTextContentStorage`. Rendering is **only a layer of attributes**.

The app never builds an intermediate rich document that it would then
re-serialize. Four consequences follow, and they carry the rest of the
design:

- **File fidelity.** Whatever the user hasn't touched comes back byte for
  byte, because there is no code path capable of rewriting it. It's
  structural, not a matter of discipline.
- **Native undo works**, with no custom layer.
- **Source mode is trivial**: the same buffer, without the styling layer.
- **Recognizing constructs while typing needed no code at all.** Typing
  `# ` is enough: the marker is in the text, the parser sees it, rendering
  follows.

## Masking the markers

This is the key feature (§2), and its mechanism comes down to three
attributes:

```swift
storage.addAttributes([
    .font: NSFont.systemFont(ofSize: 0.01),
    .foregroundColor: NSColor.clear,
    .kern: 0,
], range: marker)
```

**Not zero for the size**: `NSFont` accepts it, but TextKit then produces
degenerate metrics and a `NaN` width propagates all the way to the caret
rect. **Kerning must be explicitly reset to zero**: inherited from the
surrounding text, it would make the range a few tenths of a point wide —
enough to visibly shift a heading line.

The other mechanism considered (§3.4) — returning a shorter
`NSTextParagraph` from `NSTextContentStorageDelegate` — **was not
implemented**. It offered only one thing, removing invisible caret
positions, and those don't exist (see below). All that was left was its
cost: making `NSTextLocation` and storage offsets diverge across selection,
clicking, search and accessibility all at once.

### Why there's nothing to intercept on the keyboard

The spec promised to intercept every `NSTextView` movement command to jump
over invisible markers. That turned out to be unnecessary, and the reason
is worth understanding before "fixing" anything here.

A construct is revealed when the caret touches `[start, end]`, **inclusive**
(`RevealPolicy`). Now, any position inside a marker belongs, by
construction, to the range of its own construct. So that construct is
revealed, so its markers are visible:

> **When a marker is hidden, the caret cannot be inside it.**

The choice of inclusive bounds also makes navigation reversible: an arrow
right followed by an arrow left returns exactly to the starting state, which
would not hold with an open interval.

**The reasoning is sound, and it wasn't enough.** "By construction" assumed
that only one construct could win, and the "innermost wins" rule sometimes
picked one that wasn't the marker's — on `***bold***`, where the enclosing
emphasis has no marker of its own but the same length, and on
`[link **bold**](url)`, where the caret touches both the end of the bold run
and the start of `](…)` at once. In both cases the caret ended up inside a
hidden marker. `RevealPolicy` therefore states the invariant first — a
marker that contains the caret is revealed, no matter what — and
`FidelityTests.testNoCaretPositionFallsInsideAHiddenMarker` checks it at
every position of every document in the corpus, which the original test,
limited to a single `**bold**`, could not do.

## `swift-markdown`: three verified facts

Measured against the library, not assumed:

| | |
|---|---|
| Columns are **UTF-8 bytes** | `NSTextStorage` indexes in UTF-16 → `SourcePositionMap` |
| The upper bound is **exclusive** | it transposes as-is into `NSRange` |
| **Footnotes are not parsed** | `[^1]` comes out as `Text` → handled by our own pass (`Footnotes`) |

The first point is the pitfall in §3.3. A naive conversion misaligns every
attribute from the first accented letter onward — in other words, from the
first sentence written in a language that uses accents. `SourcePositionMapTests`
covers accented characters, emoji, CJK and combining accents.

GFM tables, task lists and strikethrough text, by contrast, are exposed
correctly.

## What's drawn instead of written

Masking `- ` makes the dash disappear but doesn't make any bullet appear.
The principle above forbids inserting a single character: a `•` added to the
text would end up in the file.

`EditorDecorations` therefore draws **behind the text** what the markers
represent: bullets and numbers, checkboxes, the blockquote bar, the
horizontal rule, code block backgrounds. These marks exist nowhere in the
document, the same way a caret doesn't.

**A drawn mark replaces a masked source**, so it disappears as soon as that
source comes back. That's the rule, and it was missing at first: under the
caret, a list item showed `• - An item`, the editor's bullet right next to
the file's dash, and the horizontal rule struck through its `---` once they
became visible again. Only the blockquote bar and the code block background
are exempt — they don't replace anything, they frame a block, and that block
also exists under the caret.

Three pitfalls cost time here:

- **An indent is required.** `headIndent` alone only shifts continuation
  lines; the first line stayed at the margin, and the bullet, drawn to its
  left, landed at a negative x-coordinate — off the visible view.
- **`NSTextView` is a flipped view.** A path drawn "upward" ends up drawn
  upside down: the first checkmark was a chevron.
- **Two coordinate spaces get mixed up.** `boundingFrame` returns
  **container** coordinates, which are offset by `textContainerOrigin` to
  paint in the **view**; but the column width stays in container
  coordinates. Anything that spans the column — horizontal rule, table
  rules, code block backgrounds — was computed as
  `columnWidth - frame.minX * 2`, mixing the two and so counting the
  centering margin twice. In a 1512-point window with a 612-point column,
  that width came out to **−288**: rules and backgrounds were drawn
  reversed, entirely inside the left margin. The bug stayed invisible in the
  default window, narrow enough that the count stayed positive — the kind
  of bug you only see in full screen. `DecorationPainter` now receives the
  column's left edge and computes the indent relative to it.

The horizontal rule is the only marker masked **without** width reduction
(`MarkerMask.hideKeepingMetrics`): since the whole line is syntax, masking
it normally would collapse its height, leaving the rule with nowhere to
draw.

## Tables: a grid built out of kerning

The spec (§2.6) called for a genuinely editable grid, with a
`firstResponder` per cell, and planned a fallback in advance. **The fallback
is what shipped, and it turned out better than the original target.** An
editor inside the editor would have required keeping two undo stacks in
sync, a selection that stops at the table's edges, and a `⌘F` that can't
enter it. Here there is still only ever one buffer.

The mechanism is the masking mechanism, pushed one step further. Each `|` is
masked, but is given **a computed advance** — the kerning needed for the
next cell to land on its column (`MarkerMask.hide(in:range:advance:)`). The
source's padding spaces are reduced to zero: it's the grid that spaces
things out, not the author. The `|---|` line is masked entirely and its
height reduced to the space of a rule, which `DecorationPainter` draws
there.

**The grid is for reading; editing happens in the source.** Put the caret
in a table and the whole block reveals: the `|` come back and the table is
edited as the plain text it is, exactly as a code fence behaves. Nothing had
to be written for that — a table's `revealScope` is `.wholeBlock`, so the
reveal engine already does it.

Fovea did once write into the grid directly, with the `|` never reappearing.
That bought a nicer gesture and cost a second editor: the caret could land
inside a masked marker, which §2.3's proof relies on never happening, so
every caret move had to be corrected after the fact, `⌫` at a cell boundary
had to be intercepted, and the invisible `|---|` row had to track its column
across arrow-downs. Several hundred lines to make a construct comfortable
that nobody reaches for in the forty seconds this app is open. It was
removed with the scope reduction.

Three things worth knowing:

- **Widths are measured, not counted.** `**Heading**` renders six characters
  shorter than its source; a column sized on character count would be six
  too wide. `applyTable` therefore runs **after** inline marker masking, and
  measures the actual rendered width.
- **Geometry is read from the source, not from the tree.** cmark renders
  neither the `|` nor the delimiter row — it consumes them — and those are
  exactly the characters that need masking. `MarkdownTable.scan` picks them
  out by hand, applying the GFM rule: cell splitting happens **before**
  inline parsing, so a `|` inside a code span still splits the row.
- **Two cases fall back to source**: a malformed table, and a table wider
  than the column. In both, the source is shown as-is. The guard
  (`fitsAsGrid`) is read at the same place by rendering and by decorations,
  or rules would be drawn around a table that has no grid.

## Performance: what was measured

The §9 budgets were **all** exceeded on the first measurement.
`PerformanceTests` now holds them, in **Debug** — the least favorable
configuration.

| Measurement | Before | After | Budget |
|---|---|---|---|
| Typing cycle, 10,000 words | 88.5 ms | 3.5 ms | 8 ms |
| Typing cycle, 100,000 words | 1,129 ms | 12 ms | 16 ms |
| Caret movement, 100,000 words | 3.3 ms | 0.1 ms | 1 ms |
| First render, 100,000 words | 1,052 ms | 190 ms | 500 ms |

Four causes, found by measuring:

**1. Parsing and rendering covered the entire document on every keystroke.**
`IncrementalParse` now reparses only the edited block, with a margin block
on each side — a `setext` heading is underlined by the line after it, a
list that loses a blank line merges with the next one. `IncrementalParseTests`
checks the one property that matters: *incremental == full*.

**2. The first splitting rule never actually applied.** It fell back to a
full parse as soon as a code block neighbored the edited range; on a
document containing one every six paragraphs, the incremental path never
triggered once. What matters is whether the edit is **inside** a code
block, not next to it. A neighboring block is simply absorbed into the
range, never split in two.

**3. Every arrow key press scanned every construct.** `SpanIndex` looks them
up by binary search, separating the **short** ones — inline and
line-scoped, numerous but bounded — from the **long** ones — code blocks and
tables, rare, scanned linearly. The list is kept sorted via `splice` so the
index never has to sort anything itself.

**4. Opening a file parsed 600 pages before painting anything.** `setText`
now does just enough for the first screen and finishes on the next run loop
turn.

One pitfall is worth knowing: **never call `applyColumnLayout()` from the
typing cycle.** Rewriting `textContainerInset` invalidates the layout of the
entire document.

## Accessibility: what the SDK forbids

§8 of the spec promised that masked ranges would carry an empty
`accessibilityLabel`, so VoiceOver wouldn't read "hash hash space
Architecture". **That's impossible**, and the SDK header says so:

```c
// NSAccessibilityConstants.h, line 133
NSAccessibilityAttributedStringForRangeParameterizedAttribute;
//(NSAttributedString *) - does _not_ use attributes from Appkit/AttributedString.h
```

The attributes set on `NSTextStorage` — including `foveaMasked` — are never
consulted by the accessibility layer: it queries the view, not the string.

The only workaround would be to override `accessibilityAttributedString(for:)`
to return a string **shorter** than the requested range. That lands right
back on mechanism B, ruled out at milestone 0: as soon as lengths diverge,
the correspondence between the position read and the actual position
breaks, and VoiceOver's cursor starts lying.

What is done, and tested: `Accessibility` is the single entry point for
system settings; semantic roles never contain syntax; the
interface carries them, where `accessibilityLabel` actually works; the layout holds from 11 to 32 points.

## Constraints to keep in mind

- **macOS 15** minimum. Not macOS 13 like TBD: the core of this app *is*
  TextKit 2, and Ventura carries fragment and attachment bugs that would
  need manual workarounds.
- **Swift 6, strict concurrency**, warnings treated as errors.
  `EditorTypography` and `FontCache` are `@MainActor` because they resolve
  `NSFont` values; AppKit isn't thread-safe and a lock would cost something
  on every character rendered.
- `NSDocument.read(from:ofType:)` and `data(ofType:)` are declared
  `nonisolated` by AppKit. Fovea keeps `canConcurrentlyReadDocuments` and
  `canAsynchronouslyWrite` at `false`, which guarantees the main thread:
  `MainActor.assumeIsolated` is there the exact assertion of what's true,
  and will raise a loud error if either flag ever gets turned on.
- **Not sandboxed** (§10): reading images relative to the document requires
  it.
- **arm64 only.**

## A testing pitfall

A test that walks `~/Documents` with `FileManager` **hangs indefinitely**
inside a test bundle: the folder is protected by TCC, the test host waits
for a permission prompt that cannot appear, and `xcodebuild` never gets
control back. Fidelity checks on real documents therefore go through
[`scripts/fidelity-check.sh`](../scripts/fidelity-check.sh), which drives
the app itself and judges the result on a `git diff`.
