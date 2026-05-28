#!/usr/bin/env swift
// tools/generate-app-icon.swift
//
// Renders the BlueX app icon at 1024×1024 to a PNG. Coordinates with the rest
// of the app's palette: dark navy background, hate-red and counter-green strokes
// crossing into an "X" with a light center node where the two meet — a literal
// glyph for what the tool does (classify speech into hate / counter / neutral).
//
// Usage: swift tools/generate-app-icon.swift <output.png>

import AppKit

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: swift generate-app-icon.swift <output.png>\n", stderr); exit(1)
}
let outPath = CommandLine.arguments[1]

let size = 1024
let s = CGFloat(size)

guard let bmp = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { fputs("failed to allocate bitmap\n", stderr); exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
let ctx = NSGraphicsContext.current!.cgContext

// MARK: Background — dark navy rounded square
let corner: CGFloat = 200
ctx.setFillColor(red: 0.078, green: 0.110, blue: 0.224, alpha: 1.0)
let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                cornerWidth: corner, cornerHeight: corner, transform: nil)
ctx.addPath(bg); ctx.fillPath()

// Soft inner highlight at the top — gives the navy some depth.
if let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.16, green: 0.22, blue: 0.36, alpha: 0.55),
        CGColor(red: 0.07, green: 0.10, blue: 0.20, alpha: 0.0),
    ] as CFArray,
    locations: [0.0, 1.0]
) {
    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: s/2, y: s),
        end: CGPoint(x: s/2, y: 0),
        options: []
    )
    ctx.restoreGState()
}

// MARK: Two crossing strokes forming the "X"
let inset: CGFloat = 230
let strokeWidth: CGFloat = 140
ctx.setLineCap(.round)
ctx.setLineWidth(strokeWidth)

// Red stroke: top-left → bottom-right (in CG: high y → low y)
ctx.setStrokeColor(red: 0.937, green: 0.267, blue: 0.267, alpha: 1.0)
ctx.move(to: CGPoint(x: inset,       y: s - inset))
ctx.addLine(to: CGPoint(x: s - inset, y: inset))
ctx.strokePath()

// Green stroke: top-right → bottom-left
ctx.setStrokeColor(red: 0.133, green: 0.773, blue: 0.369, alpha: 1.0)
ctx.move(to: CGPoint(x: s - inset, y: s - inset))
ctx.addLine(to: CGPoint(x: inset,    y: inset))
ctx.strokePath()

// MARK: Center "analysis node" — light, sits on top of the crossing
let nodeR: CGFloat = 130
ctx.setFillColor(red: 0.886, green: 0.910, blue: 0.941, alpha: 1.0)
ctx.fillEllipse(in: CGRect(x: s/2 - nodeR, y: s/2 - nodeR, width: nodeR * 2, height: nodeR * 2))

// Small inner accent — the navy color, like a pupil
let pupilR: CGFloat = 46
ctx.setFillColor(red: 0.078, green: 0.110, blue: 0.224, alpha: 1.0)
ctx.fillEllipse(in: CGRect(x: s/2 - pupilR, y: s/2 - pupilR, width: pupilR * 2, height: pupilR * 2))

NSGraphicsContext.restoreGraphicsState()

guard let pngData = bmp.representation(using: .png, properties: [:]) else {
    fputs("failed to encode PNG\n", stderr); exit(1)
}
try! pngData.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
