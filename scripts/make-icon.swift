#!/usr/bin/env swift
import AppKit

// Generates Packaging/Upkeep.icns — a brand-gradient squircle with a white sync-arrows glyph,
// matching the in-app MUKBrandIcon. Run: swift scripts/make-icon.swift
let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let iconsetDir = "\(root)/Packaging/Upkeep.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let accent = NSColor(srgbRed: 0.10, green: 0.62, blue: 0.55, alpha: 1)
let accentSecondary = NSColor(srgbRed: 0.30, green: 0.80, blue: 0.60, alpha: 1)

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let side = CGFloat(pixels)
    let margin = side * 0.06
    let rect = NSRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin)
    let radius = rect.width * 0.2237  // Apple continuous-corner ratio

    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: accent, ending: accentSecondary)!.draw(in: rect, angle: -55)
    NSGraphicsContext.restoreGraphicsState()

    let symbolConfig = NSImage.SymbolConfiguration(pointSize: side * 0.46, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
        .withSymbolConfiguration(symbolConfig)
    {
        let symbolSize = symbol.size
        let symbolRect = NSRect(
            x: (side - symbolSize.width) / 2,
            y: (side - symbolSize.height) / 2,
            width: symbolSize.width, height: symbolSize.height)
        symbol.draw(in: symbolRect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let rep = renderIcon(pixels: variant.pixels)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(variant.name).png"))
}

print("Wrote \(iconsetDir)")
