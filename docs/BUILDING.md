# Building Fovea

## Requirements

- macOS 15 or later, on an Apple Silicon Mac — the app is **arm64 only**
- Xcode 16 or later, with the macOS 15 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build

```bash
xcodegen generate
xcodebuild -project Fovea.xcodeproj -scheme Fovea -configuration Release build
```

The product lands in the `BUILT_PRODUCTS_DIR` reported by
`xcodebuild -showBuildSettings`.

> **`Fovea.xcodeproj` is generated and git-ignored.** `project.yml` is what
> gets edited, never the project file. **Rerun `xcodegen generate` after
> adding a Swift file**, or the build fails with "cannot find X in scope" —
> that's the first thing to check whenever this error shows up.

## Test

```bash
xcodebuild -project Fovea.xcodeproj -scheme Fovea -destination 'platform=macOS' test
```

Tests run in **Debug**, deliberately: `@testable import` requires
`ENABLE_TESTABILITY`, which Release doesn't carry. The performance budgets
measured in this configuration are therefore pessimistic — holding them in
Debug guarantees they hold in Release.

A single test file:

```bash
xcodebuild -project Fovea.xcodeproj -scheme Fovea -destination 'platform=macOS' \
  -only-testing:FoveaTests/PerformanceTests test
```

## Checking file fidelity

```bash
scripts/fidelity-check.sh document-one.md document-two.md
```

The script copies the files into a disposable git repository, opens them in
the app, saves them, and checks that `git diff` is empty. It drives the
real app, so it covers `NSDocument` and autosave, which unit tests cannot
reach.

It asks for permission to automate "System Events" on first run — that's
what sends `⌘S`.

## Zero warnings

`SWIFT_TREAT_WARNINGS_AS_ERRORS` is set **on the target**, not on the
project. At the project level, the flag would also reach the SwiftPM
dependencies, which compile with `-suppress-warnings`; the two together
would be a hard compiler error.

## Signing

The app is signed **ad hoc**, and `ENABLE_HARDENED_RUNTIME` is `NO`: the
hardened runtime is only required for Apple notarization, which requires a
paid developer account. Both settings can flip the day that account exists.

Consequence: on first launch, macOS shows the usual warning for a
non-notarized app. Right-click → Open.

## Troubleshooting

**"cannot find X in scope" on a file that exists** — `xcodegen generate`
wasn't rerun after the file was added.

**A test hangs without ever returning control** — check that it isn't
reading a TCC-protected folder (`~/Documents`, `~/Desktop`, `~/Downloads`).
From inside a test bundle, the permission prompt cannot appear and the call
waits forever. See the end of [ARCHITECTURE.md](ARCHITECTURE.md).

**Typing gets slow on a large document** — check that no call to
`applyColumnLayout()` was added to the typing cycle: rewriting
`textContainerInset` invalidates the layout of the entire document.
