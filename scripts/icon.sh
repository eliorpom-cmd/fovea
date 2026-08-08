#!/bin/bash
# Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
# Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
#
# Régénère l'icône de l'app depuis son dessin.
#
# L'icône est **produite par du code**, pas par un fichier binaire déposé dans
# le dépôt : elle se relit dans un diff, elle se corrige d'une constante, et
# elle ne demande à personne d'ouvrir un éditeur graphique pour changer une
# opacité. Voir scripts/make-icon.swift.
set -euo pipefail

racine="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sortie="$racine/App/Resources/AppIcon.icns"
travail="$(mktemp -d)/Fovea.iconset"
trap 'rm -rf "$(dirname "$travail")"' EXIT

swift "$racine/scripts/make-icon.swift" "$travail"

mkdir -p "$racine/App/Resources"
iconutil --convert icns --output "$sortie" "$travail"

echo "✓ $(basename "$sortie") — $(du -h "$sortie" | cut -f1)"
