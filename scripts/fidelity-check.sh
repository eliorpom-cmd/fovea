#!/bin/bash
# Fovea — native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
# Licensed under the GNU GPL v3 or later. See LICENSE.
#
# Checks the §5 promise end to end, with the real app rather
# than unit tests: open a document, save it without touching it, and check
# that `git diff` is **empty**.
#
# The unit tests (`FidelityTests`) cover the read → parse → render → write
# chain on a versioned corpus. This script covers what they can't reach:
# NSDocument, autosave in place, and real documents nobody wrote to be
# tested.
#
#   usage: scripts/fidelity-check.sh file.md [file.md …]
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(xcodebuild -project "$REPO/Fovea.xcodeproj" -scheme Fovea -showBuildSettings 2>/dev/null \
        | grep -m1 " BUILT_PRODUCTS_DIR" | sed 's/.*= //')/Fovea.app"

if [ ! -d "$APP" ]; then
    echo "Fovea.app not found. Run first: xcodebuild -scheme Fovea build" >&2
    exit 1
fi
if [ $# -eq 0 ]; then
    echo "usage: $0 file.md [file.md …]" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for source in "$@"; do
    cp "$source" "$WORK/"
done

# A disposable git repository: `git diff` is the judge, just like in real life.
git -C "$WORK" init -q
git -C "$WORK" add -A
git -C "$WORK" -c user.email=fidelity@local -c user.name=fidelity commit -qm base

pkill -x Fovea 2>/dev/null || true
sleep 1

for file in "$WORK"/*; do
    [ -f "$file" ] || continue
    open -a "$APP" "$file"
    sleep 3
    # ⌘S. Autosave in place doesn't write as long as nothing changed, so the
    # write is forced here for the check to mean anything.
    osascript -e 'tell application "System Events" to keystroke "s" using command down' >/dev/null 2>&1 || true
    sleep 2
done

sleep 1
pkill -x Fovea 2>/dev/null || true

if git -C "$WORK" diff --quiet; then
    echo "✓ Fidelity held: no byte changed across $# document(s)."
else
    echo "✗ The file was modified:"
    git -C "$WORK" diff --stat
    git -C "$WORK" diff | head -60
    exit 1
fi
