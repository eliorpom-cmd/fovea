# Fovea

Un éditeur markdown macOS natif où **le formatage se voit immédiatement**, sans
vue de code ni panneau d'aperçu.

Le nom vient de la *fovea centralis*, la zone de la rétine où la vision est la
plus nette. C'est le programme de l'app : mettre le texte au point et faire
disparaître le reste.

> **État : en construction.** Le cœur fonctionne — voir « Ce qui marche » plus
> bas. Les images, les tableaux éditables et l'export ne sont pas encore là.

## Pourquoi

Le marché se répartit en trois camps, et chacun échoue sur un axe :

| | Natif | WYSIWYG | Minimal |
|---|---|---|---|
| **iA Writer** | oui | **non** — les marqueurs restent visibles | oui |
| **Typora, Marktext** | **non** — Electron | oui | moyen |
| **Obsidian** | **non** — Electron | partiel | **non** |
| **Bear** | oui | oui, mais format propriétaire | oui |

Fovea vise la case vide : AppKit pur, marqueurs qui disparaissent, fichiers
`.md` sur disque qui restent lisibles par n'importe quoi d'autre.

## Les deux promesses

**Le formatage se voit.** Les marqueurs markdown sont invisibles par défaut et
réapparaissent, en gris pâle, dès que le curseur touche la construction à
laquelle ils appartiennent. Le mot reste gras pendant que ses `**` reviennent.
Un `#`, un `>` ou un `-` de début de ligne, eux, attendent qu'on aille les
chercher au début de la ligne : sans ça, descendre dans un document ferait
sauter chaque titre et chaque item qu'on traverse.

**Le fichier ne bouge pas.** Ce que vous n'avez pas touché ressort octet pour
octet. `*` ne devient jamais `_`, l'indentation des listes n'est jamais
recalculée, les fins de ligne d'un fichier Windows le restent. Vos `git diff`
ne contiennent que ce que vous avez écrit.

Cette seconde promesse n'est pas une question de discipline : l'app n'écrit
jamais depuis un arbre de syntaxe, elle est donc **structurellement incapable**
de reformater ce que vous n'avez pas édité.

## Ce qui marche

- Titres, gras, italique, barré, code inline, liens, citations, listes à puces
  et numérotées, listes de tâches, filets horizontaux, blocs de code, front
  matter YAML, notes de bas de page
- Coloration des blocs de code sur onze langages, monochrome par défaut, vraies
  couleurs en option, **sans aucune dépendance**
- `⏎` continue la liste et en sort sur un item vide, `⇥`/`⇧⇥` changent le
  niveau, `⌘B`/`⌘I`/`⌘⇧X`/`⌘⇧K` encadrent ou retirent le formatage, `⌘⌃0..6`
  changent le niveau de titre, `⌘⌥K` pose un lien avec l'adresse du
  presse-papier
- Un clic sur la case d'une tâche la coche — `⌘⏎` au clavier —, et une tâche
  faite s'atténue
- `⌘V` convertit le texte riche collé depuis un navigateur en markdown,
  `⌘⇧V` colle en texte brut
- `⌘/` bascule tout le document en markdown brut — le filet de sécurité
- Ouverture, enregistrement, onglets, Récents, versions Time Machine,
  restauration de session et iCloud Drive, par `NSDocument`
- `⌘F` avec le chercheur natif, correction orthographique système
- Mode focus — tout s'atténue sauf la phrase ou le paragraphe courant — et
  mode machine à écrire, tous deux optionnels : le défilement normal est le défaut
- Statistiques discrètes : mots, signes, temps de lecture, avec objectif de
  session facultatif. La syntaxe markdown n'y est pas comptée
- Fenêtre de réglages : thème, police du corps et du code parmi celles
  installées, taille, interlignage, largeur de colonne en signes
- Images rendues dans le flux, glisser-déposer depuis le Finder et collage
  d'images : le fichier est copié à côté du document et le lien écrit en
  chemin relatif
- Export HTML autonome — un seul fichier, images comprises — export PDF
  paginé, et `⌘⇧C` qui met du texte riche dans le presse-papier
- Plan du document (`⌘⌥0`) : toute la structure, hiérarchisée, cliquable
- Palette de commandes (`⌘K`) : les commandes **et** les titres du document
  dans la même liste, filtrés par sous-séquence — « mdf » trouve « Mode focus »
- **Tableaux en grille** : colonnes alignées, alignements `:--`/`:-:`/`--:`
  respectés, en-tête en gras, filets discrets. Le curseur entre dans le tableau
  et la source à pipes réapparaît. Un tableau malformé, ou trop large pour la
  colonne, reste affiché tel qu'il est écrit
- **Menu slash** : un `/` qui commence un mot propose les blocs — titre, liste,
  tâche, citation, code, tableau, filet — et **affiche la syntaxe qu'il pose**.
  Indispensable quand les marqueurs sont cachés. Collé à un caractère il ne fait
  rien : `https://` et `12/03` restent ce qu'ils sont
- **Import de polices** : déposez un `.otf` ou un `.ttf`, il n'est disponible
  que dans Fovea. Votre système n'est jamais touché, et le retrait est un clic
- S'installe comme éditeur Markdown par défaut du système

## Ce qui n'est pas encore là

**VoiceOver lit encore la syntaxe masquée.** Les rôles sémantiques existent et
les éléments d'interface les portent, mais le tampon de texte, lui, est lu tel
quel : macOS ne consulte pas les attributs de la chaîne pour l'accessibilité.
Le détail, et pourquoi le contournement évident est pire que le mal, sont dans
le §8 du cahier des charges.

Reste aussi : la **notarisation**, qui demande un compte développeur payant,
et l'**updater intégré**.

## Installer

```bash
scripts/install.sh
```

Compile en Release, installe dans `/Applications`, recense l'app auprès de
LaunchServices et la lance. Au premier démarrage, macOS avertit qu'elle n'est
pas notarisée — clic droit sur l'app → Ouvrir, une seule fois.

Fovea propose alors de devenir l'éditeur Markdown par défaut : les `.md`,
`.markdown` et `.mdown` s'ouvriront d'un double-clic. L'entrée reste disponible
dans le menu Fovea et dans Réglages › À propos.

## Construire

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project Fovea.xcodeproj -scheme Fovea -configuration Release build
```

Voir [docs/BUILDING.md](docs/BUILDING.md).

## Tester

```bash
xcodebuild -project Fovea.xcodeproj -scheme Fovea -destination 'platform=macOS' test
```

133 tests, dont les budgets de performance, qui **échouent** s'ils sont
dépassés. Ils tournent en Debug, la configuration la plus défavorable.

Pour vérifier la fidélité au fichier sur de vrais documents :

```bash
scripts/fidelity-check.sh mon-document.md
```

Le script ouvre chaque fichier dans l'app, l'enregistre sans y toucher, et juge
sur un `git diff`.

## Documentation

- [Cahier des charges](CAHIER-DES-CHARGES.md) — les décisions produit et leur
  raison. Révisé au fil des mesures : le §2.3 et le §3.4 portent la trace de ce
  que le prototype a corrigé.
- [Architecture](docs/ARCHITECTURE.md) — pourquoi le code est fait comme il est,
  et les impasses évitées.
- [Construire](docs/BUILDING.md)

## Licence

GNU AGPL v3 ou ultérieure. Voir [LICENSE](LICENSE).
