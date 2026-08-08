# Architecture

Ce document explique **pourquoi** le code est fait comme il est. Le *quoi* se
lit dans les sources ; ce qui ne s'y lit pas, ce sont les impasses évitées.

Le cahier des charges ([`CAHIER-DES-CHARGES.md`](../CAHIER-DES-CHARGES.md))
reste la référence pour les décisions produit. Les renvois `§n` pointent vers
lui.

## Plan du dépôt

```
App/
  Info.plist              types de documents markdown, UTI importé
  Fovea.entitlements      vide : l'app n'est pas sandboxée (§10)
  Sources/
    main.swift            point d'entrée, sans xib et sans @main
    AppDelegate.swift
    MainMenu.swift        la barre de menus, en code
    AppConfig.swift       noms et identifiants, en un seul endroit
    AppSettings.swift     préférences observables, adossées à UserDefaults
    Theme.swift           jetons de design (§7)
    Document/             NSDocument, lecture/écriture, fidélité au fichier
    Markdown/             analyse — aucun import AppKit, donc testable
    Editor/               NSTextView, masquage, rendu, décorations, frappe
Tests/                    108 tests, dont les budgets du §9
scripts/fidelity-check.sh vérification de fidélité de bout en bout
project.yml               manifeste XcodeGen — source de vérité du projet
```

`Fovea.xcodeproj` est **généré et git-ignoré**. On modifie `project.yml`, jamais
le fichier de projet. Après avoir ajouté un fichier Swift, relancer
`xcodegen generate`, sinon la compilation échoue sur « cannot find X in scope ».

**`Markdown/` ne contient aucun `import AppKit`.** C'est la couche où vit la
conversion de plages, et elle doit se tester sans lancer d'interface.

## Le principe qui commande tout

> Le texte markdown est la seule source de vérité. Il vit dans le
> `NSTextContentStorage`. Le rendu n'est **qu'une couche d'attributs**.

L'app ne construit jamais un document riche intermédiaire qu'elle
re-sérialiserait. Quatre conséquences, et elles portent tout le reste :

- **Fidélité au fichier.** Ce que l'utilisateur n'a pas touché ressort octet
  pour octet, parce qu'il n'y a aucun chemin de code capable de le réécrire.
  C'est structurel, pas disciplinaire.
- **L'annulation native fonctionne**, sans couche maison.
- **Le mode source est trivial** : le même tampon, sans la couche de style.
- **La reconnaissance à la frappe n'a demandé aucun code.** Taper `# ` suffit :
  le marqueur est dans le texte, le parseur le voit, le rendu suit.

## Le masquage des marqueurs

C'est la fonction clé (§2), et son mécanisme tient en trois attributs :

```swift
storage.addAttributes([
    .font: NSFont.systemFont(ofSize: 0.01),
    .foregroundColor: NSColor.clear,
    .kern: 0,
], range: marker)
```

**Pas zéro pour la taille** : `NSFont` l'accepte, mais TextKit produit alors des
métriques dégénérées et une largeur `NaN` se propage jusqu'au rect du curseur.
**Le crénage doit être remis explicitement à zéro** : hérité du texte porteur,
il rendrait la plage large de quelques dixièmes de point — assez pour décaler
visiblement une ligne de titre.

L'autre mécanisme envisagé (§3.4) — renvoyer un `NSTextParagraph` plus court
depuis `NSTextContentStorageDelegate` — **n'a pas été implémenté**. Il
n'apportait qu'une chose, supprimer les positions de curseur invisibles, et
celles-ci n'existent pas (voir ci-dessous). Il ne restait que ses coûts : faire
diverger `NSTextLocation` et les offsets de stockage dans la sélection, le clic,
la recherche et l'accessibilité à la fois.

### Pourquoi il n'y a rien à intercepter au clavier

Le cahier des charges promettait d'intercepter toutes les commandes de
déplacement de `NSTextView` pour sauter les marqueurs invisibles. C'était
inutile, et la raison mérite d'être comprise avant de « corriger » quoi que ce
soit ici.

Une construction se révèle quand le curseur touche `[début, fin]`, **bornes
comprises** (`RevealPolicy`). Or toute position située dans un marqueur
appartient, par construction, à l'intervalle de sa propre construction. Donc
cette construction est révélée, donc ses marqueurs sont visibles :

> **Quand un marqueur est masqué, le curseur ne peut pas s'y trouver.**

Le choix de bornes inclusives rend aussi la navigation réversible : une flèche
droite suivie d'une flèche gauche ramène exactement à l'état de départ, ce qui
serait faux avec un intervalle ouvert.

**Le raisonnement est juste et il ne suffisait pas.** « Par construction »
supposait qu'une seule construction puisse gagner, et la règle « la plus
intérieure gagne » en désignait parfois une qui n'était pas celle du marqueur —
sur `***gras***`, où l'emphase enveloppante n'a aucun marqueur mais la même
longueur, et sur `[lien **gras**](url)`, où le curseur touche la fin du gras et
le début du `](…)` en même temps. Dans les deux cas le curseur se retrouvait
dans un marqueur masqué. `RevealPolicy` pose donc l'invariant en premier — un
marqueur qui contient le curseur est révélé, quoi qu'il arrive — et
`FidelityTests.testNoCaretPositionFallsInsideAHiddenMarker` le vérifie sur
chaque position de chaque document du corpus, ce que le test d'origine, limité à
un seul `**gras**`, ne pouvait pas faire.

## `swift-markdown` : trois faits vérifiés

Mesurés sur la bibliothèque, pas supposés :

| | |
|---|---|
| Les colonnes sont des **octets UTF-8** | `NSTextStorage` indexe en UTF-16 → `SourcePositionMap` |
| La borne haute est **exclusive** | elle se transpose telle quelle en `NSRange` |
| Les **notes de bas de page ne sont pas parsées** | `[^1]` ressort en `Text` → passe maison (`Footnotes`) |

Le premier point est le piège du §3.3. Une conversion naïve désaligne tous les
attributs dès la première lettre accentuée, c'est-à-dire dès la première phrase
écrite en français. `SourcePositionMapTests` couvre l'accentué, l'emoji, le CJK
et les accents combinants.

Tables GFM, listes de tâches et texte barré, en revanche, sont bien exposés.

## Ce qui est dessiné plutôt qu'écrit

Masquer `- ` fait disparaître le tiret mais ne fait apparaître aucune puce. Or
le principe ci-dessus interdit d'insérer le moindre caractère : un `•` ajouté au
texte se retrouverait dans le fichier.

`EditorDecorations` dessine donc **derrière le texte** ce que les marqueurs
représentent : puces et numéros, cases à cocher, barre de citation, filet
horizontal, fond des blocs de code. Ces marques n'existent nulle part dans le
document, au même titre qu'un curseur.

**Une marque dessinée remplace une source masquée**, donc elle s'efface dès que
cette source revient. C'est la règle, et elle manquait : sous le curseur, un
item de liste affichait `• - Un item`, la puce de l'éditeur juste à côté du
tiret du fichier, et le filet horizontal barrait ses `---` redevenus visibles.
Seules la barre de citation et le fond des blocs de code y échappent — ils ne
remplacent rien, ils cadrent un bloc, et ce bloc existe aussi sous le curseur.

Trois pièges y ont coûté du temps :

- **Un retrait est nécessaire.** `headIndent` seul ne décale que les lignes de
  continuation ; la première restait à la marge et la puce, dessinée à sa
  gauche, tombait à une abscisse négative — donc hors de la vue.
- **`NSTextView` est une vue retournée.** Un tracé lu « vers le haut » y dessine
  à l'envers : la première coche était un chevron.
- **Deux repères de coordonnées se mélangent.** `boundingFrame` rend des
  coordonnées du **conteneur**, qu'on décale de `textContainerOrigin` pour
  peindre dans la **vue** ; mais la largeur de colonne, elle, reste celle du
  conteneur. Tout ce qui s'étend sur la colonne — filet horizontal, filets de
  tableau, fond des blocs de code — se calculait `columnWidth - frame.minX * 2`
  en mélangeant les deux, donc en comptant deux fois la marge de centrage. Dans
  une fenêtre de 1512 points avec une colonne de 612, cette largeur valait
  **−288** : les filets et les fonds se dessinaient à l'envers, entièrement dans
  la marge gauche. Le défaut restait invisible dans la fenêtre par défaut, assez
  étroite pour que le compte reste positif — c'est le genre de bug qu'on ne voit
  qu'en plein écran. `DecorationPainter` reçoit maintenant le bord gauche de la
  colonne et calcule le retrait par rapport à lui.

Le filet horizontal est le seul marqueur masqué **sans** réduction de largeur
(`MarkerMask.hideKeepingMetrics`) : toute la ligne étant syntaxe, la masquer
normalement ferait s'effondrer sa hauteur, et le filet n'aurait plus où se
dessiner.

## Les tableaux : une grille faite de crénage

Le cahier des charges (§2.6) visait une grille réellement éditable, avec un
`firstResponder` par cellule, et armait d'avance un repli. **C'est le repli qui
est en place, et il s'est révélé meilleur que la cible.** Un éditeur dans
l'éditeur aurait imposé deux piles d'annulation à tenir synchrones, une
sélection qui s'arrête aux bords du tableau et un `⌘F` qui n'y entre pas. Ici
il n'y a toujours qu'un seul tampon.

Le mécanisme est celui du masquage, poussé d'un cran. Chaque `|` est masqué,
mais reçoit **une avance calculée** — le crénage qu'il faut pour que la cellule
suivante tombe sur sa colonne (`MarkerMask.hide(in:range:advance:)`). Les
blancs de remplissage de la source passent à zéro : c'est la grille qui espace,
plus l'auteur. La ligne `|---|` est masquée entière et sa hauteur réduite à la
place d'un filet, que `DecorationPainter` y trace.

Trois choses valent d'être sues :

- **Les largeurs sont mesurées, pas comptées.** `**Titre**` rend six signes de
  moins que sa source ; une colonne calculée sur les signes serait large de six
  de trop. `applyTable` tourne donc **après** le masquage des marqueurs inline,
  et mesure le rendu réel.
- **La géométrie est lue dans la source, pas dans l'arbre.** cmark ne rend ni
  les `|` ni la ligne de délimitation — qu'il consomme — et ce sont exactement
  les caractères à masquer. `MarkdownTable.scan` les relève à la main, en
  appliquant la règle de GFM : la découpe en cellules a lieu **avant** l'analyse
  inline, donc un `|` dans un `code span` coupe quand même.
- **Deux cas renoncent à la grille** : un tableau malformé, et un tableau plus
  large que la colonne. Dans les deux, la source reste affichée telle quelle.
  Le garde-fou (`fitsAsGrid`) est lu au même endroit par le rendu et par les
  décorations, sans quoi les filets se dessineraient autour d'un tableau qui
  n'a pas de grille.

## Performance : ce qui a été mesuré

Les budgets du §9 étaient **tous** dépassés à la première mesure. `PerformanceTests`
les tient maintenant, en **Debug** — la configuration la plus défavorable.

| Mesure | Avant | Après | Budget |
|---|---|---|---|
| Cycle de frappe, 10 000 mots | 88,5 ms | 3,5 ms | 8 ms |
| Cycle de frappe, 100 000 mots | 1 129 ms | 12 ms | 16 ms |
| Déplacement du curseur, 100 000 mots | 3,3 ms | 0,1 ms | 1 ms |
| Premier affichage, 100 000 mots | 1 052 ms | 190 ms | 500 ms |

Quatre causes, trouvées en mesurant :

**1. Analyse et rendu portaient sur le document entier à chaque touche.**
`IncrementalParse` ne reprend que le bloc édité, avec un bloc de marge de chaque
côté — un titre `setext` est souligné par la ligne d'après, une liste dont on
retire la ligne vide fusionne avec la suivante. `IncrementalParseTests` vérifie
la seule propriété qui compte : *incrémental == complet*.

**2. La première règle de découpage ne servait jamais.** Elle retombait sur
l'analyse complète dès qu'un bloc de code voisinait la portée ; sur un document
en contenant tous les six paragraphes, l'incrémental ne s'appliquait pas une
seule fois. Ce qui compte est que l'édition soit **dans** un bloc de code, pas à
côté. Un bloc voisin est simplement absorbé dans la portée, jamais coupé en deux.

**3. Chaque flèche du clavier balayait toutes les constructions.** `SpanIndex`
les cherche par dichotomie, en séparant les **courtes** — inline et portée
ligne, nombreuses mais bornées — des **longues** — blocs de code et tableaux,
rares, balayés. La liste est maintenue triée par `splice` pour que l'index
n'ait rien à trier.

**4. L'ouverture analysait 600 pages avant de peindre.** `setText` en fait juste
assez pour le premier écran et termine au tour de boucle suivant.

Un piège vaut d'être connu : **ne jamais appeler `applyColumnLayout()` depuis le
cycle de frappe.** Réécrire `textContainerInset` invalide la mise en page de tout
le document.

## Accessibilité : ce que le SDK interdit

Le §8 du cahier des charges promettait que les plages masquées porteraient un
`accessibilityLabel` vide, pour que VoiceOver ne lise pas « dièse dièse espace
Architecture ». **C'est impossible**, et l'en-tête du SDK le dit :

```c
// NSAccessibilityConstants.h, ligne 133
NSAccessibilityAttributedStringForRangeParameterizedAttribute;
//(NSAttributedString *) - does _not_ use attributes from Appkit/AttributedString.h
```

Les attributs posés dans `NSTextStorage` — dont `foveaMasked` — ne sont jamais
consultés par la couche d'accessibilité : elle interroge la vue, pas la chaîne.

Le seul contournement serait de redéfinir `accessibilityAttributedString(for:)`
pour rendre une chaîne **plus courte** que la plage demandée. On retomberait
exactement sur le mécanisme B écarté au jalon 0 : dès que les longueurs
divergent, la correspondance entre position lue et position réelle est rompue,
et c'est le curseur de VoiceOver qui se met à mentir.

Ce qui est fait, et testé : `Accessibility` est le point d'entrée unique des
réglages système ; les rôles sémantiques ne contiennent jamais de syntaxe ; le
plan, la palette et le menu slash les portent réellement, là où
`accessibilityLabel` fonctionne ; la mise en page tient de 11 à 32 points.

## Contraintes à garder en tête

- **macOS 15** minimum. Pas macOS 13 comme TBD : le cœur de cette app *est*
  TextKit 2, et Ventura y traîne des défauts de fragments et d'attachements
  qu'il faudrait contourner à la main.
- **Swift 6, concurrence stricte**, avertissements traités en erreurs.
  `EditorTypography` et `FontCache` sont `@MainActor` parce qu'ils résolvent des
  `NSFont` ; AppKit n'est pas thread-safe et un verrou se paierait à chaque
  caractère rendu.
- `NSDocument.read(from:ofType:)` et `data(ofType:)` sont déclarés `nonisolated`
  par AppKit. Fovea garde `canConcurrentlyReadDocuments` et
  `canAsynchronouslyWrite` à `false`, ce qui garantit le thread principal :
  `MainActor.assumeIsolated` y est l'affirmation exacte de ce qui est vrai, et
  lèvera une erreur bruyante si quelqu'un active l'un des deux drapeaux.
- **Non sandboxée** (§10) : lire les images relatives à côté du document et
  enregistrer des polices l'exigent.
- **arm64 uniquement.**

## Un piège des tests

Un test qui parcourt `~/Documents` avec `FileManager` **bloque indéfiniment**
dans un bundle de test : le dossier est protégé par TCC, l'hôte de test attend
une autorisation qui ne peut pas s'afficher, et `xcodebuild` ne rend jamais la
main. La vérification de fidélité sur de vrais documents passe donc par
[`scripts/fidelity-check.sh`](../scripts/fidelity-check.sh), qui pilote l'app
elle-même et juge sur un `git diff`.
