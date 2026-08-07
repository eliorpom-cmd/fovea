---
title: Démonstration
date: 2026-08-07
---

# Fovea

Un éditeur markdown **WYSIWYG** natif pour macOS. Le formatage se voit
*immédiatement*, sans vue de code ni panneau d'aperçu.

## Ce que ça change

Quand le curseur n'est pas dans une construction, ses marqueurs disparaissent.
Dès qu'il la touche, ils réapparaissent en gris pâle — et le mot reste gras
pendant qu'ils reviennent. C'est ~~toute~~ la fonction clé de l'app.

> La fidélité au fichier est la seconde promesse : ce qui n'a pas été touché
> ressort octet pour octet.

### Une liste

- Le texte markdown est la seule source de vérité
- Le rendu n'est qu'une couche d'attributs
- Les diffs `git` restent propres

1. Analyse par `swift-markdown`
2. Conversion des plages UTF-8 vers UTF-16
3. Pose des attributs

- [ ] Tableaux éditables
- [x] Masquage des marqueurs

Du code inline comme `NSTextLayoutManager`, et un bloc :

```swift
static let hiddenFontSize: CGFloat = 0.01
```

Un lien vers [le dépôt](https://github.com/byelior/fovea) et un renvoi[^1].

---

[^1]: Les notes de bas de page ne sont pas parsées par swift-markdown.
