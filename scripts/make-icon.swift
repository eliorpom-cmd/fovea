#!/usr/bin/env swift
// Fovea — éditeur markdown WYSIWYG natif. Copyright (C) 2026 Elior Pommier.
// Sous licence GNU AGPL v3 ou ultérieure. Voir LICENSE.
//
// Dessine l'icône de l'app et écrit un .iconset prêt pour `iconutil`.
//
// # Le motif
//
// La *fovea centralis* est la zone de la rétine où la vision est la plus nette ;
// l'acuité s'effondre dès qu'on s'en éloigne. L'icône est cela, littéralement :
// des lignes de texte, celle du milieu franche, les autres s'effaçant vers les
// bords. C'est aussi le programme de l'app — mettre le texte au point et faire
// disparaître le reste (§7).
//
// Monochrome, comme tout le reste : la hiérarchie vient du contraste, jamais de
// la teinte.

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <dossier.iconset>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1])

// MARK: - Dessin

/// Les lignes de « texte », en fraction de la zone utile.
///
/// Les longueurs sont irrégulières : un paragraphe de vraie prose ne se termine
/// pas au cordeau, et des barres toutes égales donneraient un code-barres.
let lines: [(y: CGFloat, width: CGFloat)] = [
    (0.06, 0.78),
    (0.20, 0.92),
    (0.34, 0.66),
    (0.50, 1.00),   // la ligne nette, au centre optique
    (0.66, 0.72),
    (0.80, 0.90),
    (0.94, 0.54),
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    // Le fond suit la grille d'Apple : l'art occupe 824 points sur 1024, et le
    // rayon des angles vaut 185,4 à cette échelle. Hors de cette grille, l'icône
    // paraît trop grosse ou trop petite à côté de celles du système.
    let scale = size / 1024
    let inset = 100 * scale
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = 185.4 * scale

    let background = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1).setFill()
    background.fill()

    // Les barres sont rognées par la plaque : celles du haut et du bas
    // dépasseraient sinon des angles arrondis.
    NSGraphicsContext.saveGraphicsState()
    background.addClip()

    let column = plate.insetBy(dx: plate.width * 0.17, dy: plate.height * 0.17)
    let barHeight = column.height * 0.075
    let barRadius = barHeight / 2

    for line in lines {
        // L'opacité s'effondre avec la distance au centre, comme l'acuité
        // visuelle hors de la fovéa. La courbe est quadratique : linéaire, la
        // chute se voyait à peine.
        let distance = abs(line.y - 0.5) * 2
        let sharpness = max(0.10, 1 - distance * distance * 1.15)

        let width = column.width * line.width
        let y = column.maxY - column.height * line.y - barHeight / 2
        let bar = NSRect(x: column.minX, y: y, width: width, height: barHeight)

        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: sharpness).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barRadius, yRadius: barRadius).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return image
}

// MARK: - Écriture du .iconset

/// Les tailles exigées par `iconutil`. En manquer une fait échouer la
/// conversion, sans dire laquelle.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for variant in variants {
    let image = drawIcon(size: CGFloat(variant.pixels))
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("échec du rendu de \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: output.appendingPathComponent(variant.name))
}

print("✓ \(variants.count) images écrites dans \(output.lastPathComponent)")
