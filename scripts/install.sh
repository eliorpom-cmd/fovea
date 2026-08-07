#!/bin/bash
#
# Compile Fovea en Release et l'installe dans /Applications.
#
#   usage : scripts/install.sh
#
# L'app est signée **ad hoc** : au premier lancement, macOS affiche
# l'avertissement des apps non notarisées. Clic droit → Ouvrir, une fois.
# Voir docs/BUILDING.md.
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

command -v xcodegen >/dev/null || { echo "xcodegen manquant : brew install xcodegen" >&2; exit 1; }

echo "▸ Génération du projet"
xcodegen generate >/dev/null

echo "▸ Compilation (Release)"
xcodebuild -project Fovea.xcodeproj -scheme Fovea -configuration Release \
           -destination 'platform=macOS' build >/dev/null

BUILT="$(xcodebuild -project Fovea.xcodeproj -scheme Fovea -configuration Release \
          -showBuildSettings 2>/dev/null | grep -m1 " BUILT_PRODUCTS_DIR" | sed 's/.*= //')/Fovea.app"
[ -d "$BUILT" ] || { echo "Fovea.app introuvable après compilation" >&2; exit 1; }

DEST="/Applications/Fovea.app"

# Quitter l'instance en cours : remplacer un bundle sous les pieds d'un
# processus vivant le laisse dans un état incohérent.
if pgrep -x Fovea >/dev/null; then
    echo "▸ Fermeture de l'instance en cours"
    osascript -e 'tell application "Fovea" to quit' 2>/dev/null || pkill -x Fovea || true
    sleep 1
fi

echo "▸ Installation dans $DEST"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"

# La signature ad hoc est refaite après la copie : `cp` ne préserve pas
# toujours les attributs étendus, et une signature cassée bloque le lancement.
codesign --force --deep --sign - "$DEST" 2>/dev/null || true

# Sans ce recensement, LaunchServices peut mettre plusieurs minutes à voir la
# nouvelle version — et « Ouvrir avec » proposerait encore l'ancienne.
echo "▸ Recensement auprès de LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST" 2>/dev/null || true

echo
echo "✓ Fovea est installée."
echo
echo "  Au premier lancement, macOS avertira qu'elle n'est pas notarisée :"
echo "  clic droit sur l'app → Ouvrir. Une seule fois."
echo
echo "  Fovea proposera alors de devenir l'éditeur Markdown par défaut."
echo "  L'entrée reste disponible dans le menu Fovea."
echo
open "$DEST"
