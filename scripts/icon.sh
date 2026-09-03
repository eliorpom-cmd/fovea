#!/bin/bash
# Fovea — native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
# Licensed under the GNU GPL v3 or later. See LICENSE.
#
# Renders design/Fovea.icon into App/Resources/AppIcon.icns.
#
#   usage: scripts/icon.sh [light]
#
# # Why a rendered .icns rather than the .icon itself
#
# Xcode can compile an Icon Composer document straight into the bundle, and
# the icon then switches appearance at runtime. It also costs **1.5 MB** of
# asset catalogue, against 434 KB for this .icns — on an app that argues for
# itself by weighing nothing, and whose icon is monochrome to begin with.
#
# So the document stays the source, and what ships is one rendered appearance
# with the Liquid Glass treatment baked into the pixels. `actool` does the
# rendering, which is the same code path Xcode would have used.
#
# # Why the detour through actool
#
# `actool`'s own .icns output only carries the 16 and 128 point sizes — it is
# a fallback, not a deliverable. The 1024 render is therefore extracted and
# resampled into a full iconset for `iconutil`.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
appearance="${1:-dark}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# actool derives the icon name from the file name, so the copy it compiles has
# to keep it — hence a directory of its own rather than a renamed document.
mkdir -p "$work/src" "$work/out" "$work/Fovea.iconset"
cp -R "$root/design/Fovea.icon" "$work/src/Fovea.icon"

# One appearance ships, so the chosen one is promoted into the default slot:
# actool renders that, and the specializations it would otherwise pick between
# are irrelevant to a .icns, which has no notion of appearance.
python3 - "$work/src/Fovea.icon/icon.json" "$appearance" <<'PYTHON'
import json, sys

path, appearance = sys.argv[1], sys.argv[2]
icon = json.load(open(path))

def promote(specializations):
    if appearance == "light":
        chosen = next(s for s in specializations if "appearance" not in s)
    else:
        chosen = next(s for s in specializations if s.get("appearance") == appearance)
    return [{"value": chosen["value"]}]

icon["fill-specializations"] = promote(icon["fill-specializations"])
for layer in icon["groups"][0]["layers"]:
    layer["fill-specializations"] = promote(layer["fill-specializations"])

json.dump(icon, open(path, "w"), indent=2)
PYTHON

xcrun actool --compile "$work/out" \
    --app-icon Fovea \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --output-partial-info-plist "$work/partial.plist" \
    "$work/src/Fovea.icon" > /dev/null

sips -s format png -Z 1024 "$work/out/Fovea.icns" --out "$work/1024.png" > /dev/null

# The ten sizes iconutil demands. A missing one fails the conversion without
# saying which.
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
            512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
    sips -s format png -Z "${spec%%:*}" "$work/1024.png" \
        --out "$work/Fovea.iconset/${spec##*:}.png" > /dev/null
done

iconutil --convert icns --output "$root/App/Resources/AppIcon.icns" "$work/Fovea.iconset"

printf '✓ %s appearance → App/Resources/AppIcon.icns (%s)\n' \
    "$appearance" "$(du -h "$root/App/Resources/AppIcon.icns" | cut -f1)"
