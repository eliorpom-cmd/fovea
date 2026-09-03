#!/bin/bash
# Fovea — native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
# Licensed under the GNU GPL v3 or later. See LICENSE.
#
# Regenerates the app icon from its drawing.
#
# The icon is **produced by code**, not by a binary file checked into the
# repository: it can be read in a diff, it can be fixed by changing a
# constant, and it doesn't ask anyone to open a graphics editor to change an
# opacity. See scripts/make-icon.swift.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$root/App/Resources/AppIcon.icns"
work="$(mktemp -d)/Fovea.iconset"
trap 'rm -rf "$(dirname "$work")"' EXIT

swift "$root/scripts/make-icon.swift" "$work"

mkdir -p "$root/App/Resources"
iconutil --convert icns --output "$output" "$work"

echo "✓ $(basename "$output") — $(du -h "$output" | cut -f1)"
