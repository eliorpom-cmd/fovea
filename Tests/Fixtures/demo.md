---
title: Demo
date: 2026-08-07
---

# Fovea

A native **WYSIWYG** markdown editor for macOS. Formatting is visible
*immediately*, with no source view and no preview pane.

## What that changes

When the caret isn't inside a construct, its markers disappear.
As soon as it touches one, they reappear in pale gray, and the word stays bold
while they come back. That's ~~the whole~~ a key feature of the app.

> Fidelity to the file is the second promise: whatever wasn't touched
> comes back out byte for byte.

### A list

- The markdown text is the only source of truth
- The rendering is just a layer of attributes
- `git` diffs stay clean

1. Parsing by `swift-markdown`
2. Converting ranges from UTF-8 to UTF-16
3. Applying attributes

- [ ] Editable tables
- [x] Marker masking

Inline code like `NSTextLayoutManager`, and a block:

```swift
static let hiddenFontSize: CGFloat = 0.01
```

A link to [the repository](https://github.com/byelior/fovea) and a footnote reference[^1].

---

[^1]: Footnotes aren't parsed by swift-markdown.
