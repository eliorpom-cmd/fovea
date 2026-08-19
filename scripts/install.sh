#!/bin/bash
#
# Builds Fovea in Release and installs it into /Applications.
#
#   usage: scripts/install.sh
#
# The app is signed **ad hoc**: on first launch, macOS shows the warning for
# non-notarized apps. Right-click → Open, once.
# See docs/BUILDING.md.
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen" >&2; exit 1; }

echo "▸ Generating the project"
xcodegen generate >/dev/null

echo "▸ Building (Release)"
xcodebuild -project Fovea.xcodeproj -scheme Fovea -configuration Release \
           -destination 'platform=macOS' build >/dev/null

BUILT="$(xcodebuild -project Fovea.xcodeproj -scheme Fovea -configuration Release \
          -showBuildSettings 2>/dev/null | grep -m1 " BUILT_PRODUCTS_DIR" | sed 's/.*= //')/Fovea.app"
[ -d "$BUILT" ] || { echo "Fovea.app not found after building" >&2; exit 1; }

DEST="/Applications/Fovea.app"

# Quit the running instance: replacing a bundle out from under a live process
# leaves it in an inconsistent state.
if pgrep -x Fovea >/dev/null; then
    echo "▸ Closing the running instance"
    osascript -e 'tell application "Fovea" to quit' 2>/dev/null || pkill -x Fovea || true
    sleep 1
fi

echo "▸ Installing into $DEST"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

# The ad hoc signature is redone after the copy: `cp` doesn't always preserve
# extended attributes, and a broken signature blocks launch.
codesign --force --deep --sign - "$DEST" 2>/dev/null || true

# Without this registration, LaunchServices can take several minutes to see
# the new version — and "Open With" would still offer the old one.
echo "▸ Registering with LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST" 2>/dev/null || true

echo
echo "✓ Fovea is installed."
echo
echo "  On first launch, macOS will warn that it isn't notarized:"
echo "  right-click the app → Open. Once."
echo
echo "  Fovea will then offer to become the default Markdown editor."
echo "  The option stays available in the Fovea menu."
echo
open "$DEST"
