#!/usr/bin/env swift
// Fovea — a native WYSIWYG markdown editor. Copyright (C) 2026 Elior Pommier.
// Licensed under the GNU AGPL v3 or later. See LICENSE.
//
// Draws the app icon and writes a .iconset ready for `iconutil`.
//
// # The pattern
//
// The *fovea centralis* is the area of the retina where vision is sharpest;
// acuity collapses as soon as you move away from it. The icon is that,
// literally: lines of text, the middle one sharp, the others fading toward
// the edges. It's also the app's whole program — bring the text into focus
// and let everything else disappear (§7).
//
// Monochrome, like everything else: hierarchy comes from contrast, never
// from hue.

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <folder.iconset>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1])

// MARK: - Drawing

/// The "text" lines, as a fraction of the usable area.
///
/// The lengths are irregular: a paragraph of real prose doesn't end on a
/// straight edge, and bars of equal length would look like a barcode.
let lines: [(y: CGFloat, width: CGFloat)] = [
    (0.06, 0.78),
    (0.20, 0.92),
    (0.34, 0.66),
    (0.50, 1.00),   // the sharp line, at the optical center
    (0.66, 0.72),
    (0.80, 0.90),
    (0.94, 0.54),
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    // The background follows Apple's grid: the artwork occupies 824 points
    // out of 1024, and the corner radius is 185.4 at that scale. Outside
    // this grid, the icon looks too big or too small next to system ones.
    let scale = size / 1024
    let inset = 100 * scale
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = 185.4 * scale

    let background = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
    NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1).setFill()
    background.fill()

    // The bars are clipped to the plate: the top and bottom ones would
    // otherwise stick out past the rounded corners.
    NSGraphicsContext.saveGraphicsState()
    background.addClip()

    let column = plate.insetBy(dx: plate.width * 0.17, dy: plate.height * 0.17)
    let barHeight = column.height * 0.075
    let barRadius = barHeight / 2

    for line in lines {
        // Opacity collapses with distance from the center, like visual
        // acuity outside the fovea. The curve is quadratic: linear, the
        // falloff was barely visible.
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

// MARK: - Writing the .iconset

/// The sizes required by `iconutil`. Missing one fails the conversion,
/// without saying which one.
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
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: output.appendingPathComponent(variant.name))
}

print("✓ \(variants.count) images written to \(output.lastPathComponent)")
