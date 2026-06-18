#!/usr/bin/env swift
// Renders the Hansel app icon (rounded square with gradient, breadcrumb trail,
// and a bold "H") at all standard macOS iconset sizes, then shells out to iconutil
// to build Resources/AppIcon.icns.
//
// Run:  swift scripts/make_icon.swift
//
// The theme: warm amber → red gradient, white breadcrumb dots, white "H".
// Hansel leaves breadcrumbs — so does this time tracker.

import AppKit
import Foundation

let iconsetDir = "build/AppIcon.iconset"
let icnsPath = "Resources/AppIcon.icns"

// Standard Apple iconset sizes: (pixels, filename).
let sizes: [(Int, String)] = [
    (16,  "icon_16x16.png"),
    (32,  "icon_16x16@2x.png"),
    (32,  "icon_32x32.png"),
    (64,  "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

try? FileManager.default.removeItem(atPath: iconsetDir)
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for (size, filename) in sizes {
    guard let data = renderIconPNG(size: size) else {
        fputs("Failed rendering size \(size)\n", stderr); exit(1)
    }
    let path = "\(iconsetDir)/\(filename)"
    try data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(size)x\(size))")
}

// Build the .icns package.
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    fputs("iconutil failed with status \(process.terminationStatus)\n", stderr); exit(1)
}
print("built \(icnsPath)")

// MARK: - Rendering

func renderIconPNG(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx

    let s = CGFloat(size)
    let corner = s * 0.22   // Big-Sur-ish rounding

    // Clip to rounded rect — everything after this is masked to the squircle.
    let mask = NSBezierPath(
        roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
        xRadius: corner, yRadius: corner
    )
    mask.addClip()

    // Gradient background (warm amber → red, top-left to bottom-right).
    let gradient = NSGradient(colors: [
        NSColor(red: 0.97, green: 0.67, blue: 0.36, alpha: 1),
        NSColor(red: 0.87, green: 0.33, blue: 0.23, alpha: 1)
    ])!
    gradient.draw(in: NSRect(x: 0, y: 0, width: s, height: s), angle: -40)

    // Breadcrumb trail — four white dots along the bottom third.
    NSColor(white: 1, alpha: 0.9).setFill()
    let dotDiameter = s * 0.06
    let dotY = s * 0.22
    for fraction in [0.22, 0.37, 0.53, 0.70] {
        let x = s * CGFloat(fraction)
        let dot = NSBezierPath(ovalIn: NSRect(
            x: x - dotDiameter / 2,
            y: dotY - dotDiameter / 2,
            width: dotDiameter,
            height: dotDiameter
        ))
        dot.fill()
    }

    // "H" letter centered, slightly above the dots.
    let fontSize = s * 0.58
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .shadow: shadow
    ]
    let letter = NSAttributedString(string: "H", attributes: attrs)
    let letterSize = letter.size()
    letter.draw(at: NSPoint(
        x: (s - letterSize.width) / 2,
        y: (s - letterSize.height) / 2 + s * 0.06   // lift above the crumbs
    ))

    return rep.representation(using: .png, properties: [:])
}
