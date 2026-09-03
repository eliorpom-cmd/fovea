# Security policy

## Supported versions

Fovea has not had a tagged release yet. Until it does, the supported version
is the tip of `main`.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting:
[Report a vulnerability](https://github.com/eliorpom-cmd/fovea/security/advisories/new).
It is private to the maintainer until an advisory is published.

Expect an acknowledgement within a week. This is a single-maintainer project
with no paid support behind it, so please be patient with the timeline — the
report will be taken seriously regardless.

## Threat model

Fovea is an offline document editor. It makes no network requests, has no
account, no telemetry and no updater. That removes most of the usual attack
surface, and leaves three areas worth reporting:

- **Untrusted document parsing.** Fovea opens files it did not write. A
  crash, a hang, an out-of-bounds read or unbounded memory growth triggered
  by a crafted `.md` file is a valid report. The parsing layer is
  `App/Sources/Markdown/`.
- **Path handling for images.** Image links are resolved relative to the
  document ([§4.4](docs/PRINCIPLES.md#44-images)). Anything that makes Fovea
  read a file outside what the user opened — path traversal, a symlink
  followed where it shouldn't be — is a valid report.
- **Data loss.** A file coming back changed after an open-and-save is not
  strictly a vulnerability, but it is treated with the same urgency. See the
  fidelity section of [CONTRIBUTING.md](CONTRIBUTING.md).

Known and accepted, so not worth reporting:

- **The app is not sandboxed** ([§10](docs/PRINCIPLES.md#10-distribution)).
  Reading images relative to the document requires it, and the sandbox would
  impose security-scoped bookmarks for no benefit outside the App Store.
- **The app is not notarized**, and is signed ad hoc. Notarization requires a
  paid Apple developer account. macOS will warn on first launch; that is
  expected.
- **Raw HTML in a document is never interpreted** — it is displayed
  literally, by design ([§6](docs/PRINCIPLES.md#6-states-and-edge-cases)).
  Reports that it "should" render are feature requests, not vulnerabilities.
