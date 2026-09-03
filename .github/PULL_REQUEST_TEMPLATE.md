<!--
If this pull request adds a feature and there is no issue behind it that has
already been answered, please stop and open one first. See the scope policy
in CONTRIBUTING.md. Bug fixes, fidelity fixes, tests and documentation need
no prior discussion.
-->

## What this changes

<!-- One or two sentences. What behaviour is different afterwards? -->

## Why

<!--
The reasoning, not the diff — the diff is right there. If you rejected
another approach along the way, say which and why: that is the part worth
keeping, and it belongs in a comment in the code as much as here.
-->

Closes #

## Checks

- [ ] `xcodegen generate` rerun if a file was added
- [ ] All 224 tests pass, performance budgets included
- [ ] New behaviour has a test — in `App/Sources/Markdown/` where the logic
      allows, since that layer imports no AppKit and tests without an
      interface
- [ ] Zero warnings (they are errors)
- [ ] New files carry the licence header
- [ ] Comments are in English, and explain *why*
- [ ] The markdown text is still the sole source of truth: nothing writes
      from an AST, and rendering inserts no character into the buffer

## For a change that touches reading or writing files

- [ ] `scripts/fidelity-check.sh` run against real documents
