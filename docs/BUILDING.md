# Construire Fovea

## Prérequis

- macOS 15 ou ultérieur, sur un Mac Apple Silicon — l'app est **arm64
  uniquement**
- Xcode 16 ou ultérieur, avec le SDK macOS 15
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) : `brew install xcodegen`

## Compiler

```bash
xcodegen generate
xcodebuild -project Fovea.xcodeproj -scheme Fovea -configuration Release build
```

Le produit sort dans le `BUILT_PRODUCTS_DIR` que `xcodebuild -showBuildSettings`
indique.

> **`Fovea.xcodeproj` est généré et git-ignoré.** On modifie `project.yml`,
> jamais le fichier de projet. **Relancer `xcodegen generate` après avoir ajouté
> un fichier Swift**, sinon la compilation échoue sur « cannot find X in scope »
> — c'est le premier réflexe à avoir devant cette erreur.

## Tester

```bash
xcodebuild -project Fovea.xcodeproj -scheme Fovea -destination 'platform=macOS' test
```

Les tests tournent en **Debug**, et c'est délibéré : `@testable import` exige
`ENABLE_TESTABILITY`, que le Release ne porte pas. Les budgets de performance
mesurés dans cette configuration sont donc pessimistes — les tenir en Debug
garantit de les tenir en Release.

Un seul fichier de tests :

```bash
xcodebuild -project Fovea.xcodeproj -scheme Fovea -destination 'platform=macOS' \
  -only-testing:FoveaTests/PerformanceTests test
```

## Vérifier la fidélité au fichier

```bash
scripts/fidelity-check.sh document-un.md document-deux.md
```

Le script copie les fichiers dans un dépôt git jetable, les ouvre dans l'app,
les enregistre, et vérifie que `git diff` est vide. Il pilote l'app réelle,
donc il couvre `NSDocument` et l'enregistrement automatique, que les tests
unitaires ne peuvent pas atteindre.

Il demande l'autorisation d'automatiser « System Events » à la première
exécution — c'est l'envoi de `⌘S`.

## Zéro avertissement

`SWIFT_TREAT_WARNINGS_AS_ERRORS` est posé **sur la cible**, pas sur le projet.
Au niveau projet, le drapeau atteindrait aussi les dépendances SwiftPM, qui
compilent avec `-suppress-warnings` ; les deux ensemble sont une erreur dure du
compilateur.

## Signature

L'app est signée **ad hoc** et `ENABLE_HARDENED_RUNTIME` est à `NO` : le
runtime durci n'est requis que pour la notarisation Apple, qui demande un compte
développeur payant. Passer les deux le jour où ce compte existe.

Conséquence : au premier lancement, macOS affiche l'avertissement habituel pour
une app non notarisée. Clic droit → Ouvrir.

## Dépannage

**« cannot find X in scope » sur un fichier qui existe** — `xcodegen generate`
n'a pas été relancé après l'ajout du fichier.

**Un test reste bloqué sans jamais rendre la main** — vérifier qu'il ne lit pas
un dossier protégé par TCC (`~/Documents`, `~/Bureau`, `~/Téléchargements`).
Depuis un bundle de test, l'autorisation ne peut pas s'afficher et l'appel
attend indéfiniment. Voir la fin de [ARCHITECTURE.md](ARCHITECTURE.md).

**La frappe devient lente sur un gros document** — vérifier qu'aucun appel à
`applyColumnLayout()` n'a été ajouté dans le cycle de frappe : réécrire
`textContainerInset` invalide la mise en page de tout le document.
