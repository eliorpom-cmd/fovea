# Design sources

## `Fovea.icon`

The app icon, as an [Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
document — `icon.json` plus four SVGs, all of it readable in a diff. Open it
with Icon Composer (it ships inside Xcode).

Nothing here is compiled into the app. `scripts/icon.sh` renders this document
into `App/Resources/AppIcon.icns`, and that is what ships:

```bash
scripts/icon.sh          # dark appearance, the one that ships
scripts/icon.sh light
```

### Why a rendered `.icns` and not the document itself

Xcode compiles an `.icon` straight into the bundle, and the icon then switches
with the system appearance. It also costs **1.5 MB** of asset catalogue
against 434 KB for the `.icns` — it renders every size across every appearance,
and the app goes from 1.9 MB to 2.9 MB. On an app whose argument for itself is
that it weighs nothing, and whose icon is monochrome in the first place, a
megabyte to switch between two greys is not a trade worth making.

So one appearance ships, with the Liquid Glass treatment baked into the pixels
by the same `actool` Xcode would have used. What it gives up is the runtime
switch; what it keeps is the look.

### The four layers

The *fovea centralis* is the part of the retina where vision is sharpest, and
acuity collapses as soon as you move away from it. The icon is that, literally:
lines of text, the middle one sharp, the others fading toward the edges.

| Layer | Bars | Opacity |
| --- | --- | --- |
| `Fovea` | the centre line, full width | 1.0 |
| `Parafovea` | the two adjacent | 0.882 |
| `Perifovea` | the two next out | 0.586 |
| `Periphery` | the two outermost | 0.109 |

The falloff is quadratic — linear, it was barely visible. Line lengths are
irregular on purpose: a paragraph of real prose doesn't end on a straight edge,
and bars of equal length read as a barcode.

**The opacity has to live in each layer's `fill`, not in the SVG.** Any `fill`
on a layer repaints its shapes and flattens their own opacity to 1, so a single
layer can carry the gradient *or* per-appearance colour, never both. That is
the whole reason there are four layers rather than one — and the reason not to
touch the *Fill* control in Icon Composer's inspector without setting the alpha
along with the colour.

### Colours

| | Plate | Text |
| --- | --- | --- |
| Light | `#F5F5F7` | `#1A1A1C` |
| Dark | `#1A1A1C` | white |
| Tinted | — | white |

Monochrome, like the rest of the app: hierarchy comes from contrast, never from
hue ([§7](../docs/PRINCIPLES.md#7-design)).
