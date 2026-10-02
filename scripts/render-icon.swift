#!/usr/bin/env swift
// Renders the MenuBarIcon template PNGs into App/Assets.xcassets/MenuBarIcon.imageset.
// Design (18×18 pt): 5 vertical capsule bars, black on transparent, centered.
// Bar width 2 pt, gap 1.5 pt, heights 6/13/9/13/6 pt; fully rounded ends.
// Usage: swift scripts/render-icon.swift   (run from repo root)

import AppKit

let ptSize: CGFloat = 18
let barWidth: CGFloat = 2
let gap: CGFloat = 1.5
let heights: [CGFloat] = [6, 13, 9, 13, 6]

func fillCapsule(_ rect: CGRect, in ctx: CGContext) {
    let radius = min(rect.width, rect.height) / 2
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
}

func drawMenuBar(size: CGFloat, ctx: CGContext) {
    let s = size / ptSize
    let groupW = 5 * barWidth + 4 * gap
    var x = (ptSize - groupW) / 2 * s
    NSColor.black.setFill()
    for h in heights {
        let y = (ptSize - h) / 2 * s
        fillCapsule(CGRect(x: x, y: y, width: barWidth * s, height: h * s), in: ctx)
        x += (barWidth + gap) * s
    }
}

func writePNG(size: Int, draw: (CGContext) -> Void, to url: URL) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let nsctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("bitmap rep failed")
    }
    let ctx = nsctx.cgContext
    draw(ctx)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let set = root.appendingPathComponent("App/Assets.xcassets/MenuBarIcon.imageset")
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
try writePNG(size: 18, draw: { drawMenuBar(size: 18, ctx: $0) },
             to: set.appendingPathComponent("menubar-icon.png"))
try writePNG(size: 36, draw: { drawMenuBar(size: 36, ctx: $0) },
             to: set.appendingPathComponent("menubar-icon@2x.png"))
print("wrote MenuBarIcon.imageset PNGs (18px, 36px)")
