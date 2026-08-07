#!/bin/bash
#
# Vérifie la promesse du §5 du cahier des charges de bout en bout, avec l'app
# réelle et non avec des tests unitaires : ouvrir un document, l'enregistrer
# sans y toucher, et constater que `git diff` est **vide**.
#
# Les tests unitaires (`FidelityTests`) couvrent la chaîne lecture → analyse →
# rendu → écriture sur un corpus versionné. Ce script couvre ce qu'ils ne
# peuvent pas atteindre : NSDocument, l'enregistrement automatique en place, et
# des documents réels que personne n'a écrits pour être testés.
#
#   usage : scripts/fidelity-check.sh fichier.md [fichier.md …]
#
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$(xcodebuild -project "$REPO/Fovea.xcodeproj" -scheme Fovea -showBuildSettings 2>/dev/null \
        | grep -m1 " BUILT_PRODUCTS_DIR" | sed 's/.*= //')/Fovea.app"

if [ ! -d "$APP" ]; then
    echo "Fovea.app introuvable. Lancer d'abord : xcodebuild -scheme Fovea build" >&2
    exit 1
fi
if [ $# -eq 0 ]; then
    echo "usage : $0 fichier.md [fichier.md …]" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for source in "$@"; do
    cp "$source" "$WORK/"
done

# Un dépôt git jetable : c'est `git diff` qui juge, comme dans la vraie vie.
git -C "$WORK" init -q
git -C "$WORK" add -A
git -C "$WORK" -c user.email=fidelity@local -c user.name=fidelity commit -qm base

pkill -x Fovea 2>/dev/null || true
sleep 1

for file in "$WORK"/*; do
    [ -f "$file" ] || continue
    open -a "$APP" "$file"
    sleep 3
    # ⌘S. L'enregistrement automatique en place n'écrit pas tant que rien n'a
    # changé ; on force donc l'écriture pour que le test ait un sens.
    osascript -e 'tell application "System Events" to keystroke "s" using command down' >/dev/null 2>&1 || true
    sleep 2
done

sleep 1
pkill -x Fovea 2>/dev/null || true

if git -C "$WORK" diff --quiet; then
    echo "✓ Fidélité tenue : aucun octet modifié sur $# document(s)."
else
    echo "✗ Le fichier a été modifié :"
    git -C "$WORK" diff --stat
    git -C "$WORK" diff | head -60
    exit 1
fi
