#!/usr/bin/env swift
// Renders brand assets into docs/brand/.
// Fonts are loaded from App/Fonts/ via CTFontManagerRegisterFontsForURL.
// Usage: swift scripts/render-brand.swift   (run from repo root)

import AppKit
import CoreText

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outDir = root.appendingPathComponent("docs/brand")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: Fonts

func registerFont(_ name: String) {
    let url = root.appendingPathComponent("App/Fonts/\(name)")
    var error: Unmanaged<CFError>?
    guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
        fatalError("failed to register font \(name): \(String(describing: error))")
    }
}

for f in ["InstrumentSerif-Regular.ttf", "GeistMono-Regular.ttf", "GeistMono-Medium.ttf"] {
    registerFont(f)
}

func font(_ name: String, _ size: CGFloat) -> NSFont {
    guard let f = NSFont(name: name, size: size) else {
        fatalError("font \(name) not available after registration")
    }
    return f
}

// MARK: Palette

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let colBg = rgb(0x0B0B0C)
let colCream = rgb(0xF4EFE6)
let colSignal = rgb(0xFF5B2E)
let colSecondary = NSColor.white.withAlphaComponent(0.62)
let colDotOff = NSColor.white.withAlphaComponent(0.09)

// MARK: Mark

let markHeights: [CGFloat] = [200, 440, 280, 440, 200]   // points, on the 480×440 mark grid
let markBarW: CGFloat = 64, markPitch: CGFloat = 104

func drawMark(centerX: CGFloat, centerY: CGFloat, scale: CGFloat, ctx: CGContext) {
    let groupW = 5 * markBarW + 4 * (markPitch - markBarW)
    var x = centerX - groupW * scale / 2
    for (i, h) in markHeights.enumerated() {
        let rect = CGRect(x: x, y: centerY - h * scale / 2,
                          width: markBarW * scale, height: h * scale)
        (i == 2 ? colSignal : colCream).setFill()
        let r = min(rect.width, rect.height) / 2
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.fillPath()
        x += markPitch * scale
    }
}

// MARK: Dot-matrix wave
// 25 cols × 7 rows; y = A·sin(πx)·sin(2π·1.6x − φ); echo strand opposite phase 0.6× at 35%.
// Off dots drawn at white 9%. Centre 3 columns of the main strand in signal.

func drawDotWave(cx: CGFloat, cy: CGFloat, width: CGFloat,
                 dot: CGFloat, vPitch: CGFloat,
                 phase: CGFloat, amplitude: CGFloat, rows: Int = 7, drawOff: Bool = true,
                 ctx: CGContext) {
    let cols = 25
    let hPitch = width / CGFloat(cols - 1)
    for c in 0 ..< cols {
        let x = CGFloat(c) / CGFloat(cols - 1)
        let yMain = amplitude * sin(.pi * x) * sin(2 * .pi * 1.6 * x - phase)
        let yEcho = amplitude * 0.6 * sin(.pi * x) * sin(2 * .pi * 1.6 * x - phase + .pi)
        let rowMain = Int((yMain * CGFloat(rows - 1) / 2).rounded())
        let rowEcho = Int((yEcho * CGFloat(rows - 1) / 2).rounded())
        for r in -(rows / 2) ... (rows / 2) {
            let px = cx - width / 2 + CGFloat(c) * hPitch - dot / 2
            let py = cy - CGFloat(r) * vPitch - dot / 2
            let rect = CGRect(x: px, y: py, width: dot, height: dot)
            if r == rowMain {
                (abs(c - 12) <= 1 ? colSignal : colCream).setFill()
            } else if r == rowEcho {
                colCream.withAlphaComponent(0.35).setFill()
            } else if drawOff {
                colDotOff.setFill()
            } else {
                continue
            }
            ctx.fillEllipse(in: rect)
        }
    }
}

// MARK: Text helpers

func drawText(_ s: String, font f: NSFont, color: NSColor,
              tracking: CGFloat = 0, centerX: CGFloat, baselineY: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: f, .foregroundColor: color, .kern: tracking * f.pointSize,
    ]
    let str = NSAttributedString(string: s, attributes: attrs)
    let w = str.size().width
    str.draw(at: NSPoint(x: centerX - w / 2, y: baselineY))
}

// MARK: PNG writer

func writePNG(w: Int, h: Int, draw: (CGContext) -> Void, to url: URL) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let nsctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("bitmap rep failed")
    }
    NSGraphicsContext.current = nsctx
    draw(nsctx.cgContext)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: Banner (1280×640 logical; also rendered at 2x)

func drawBanner(size: CGSize, scale: CGFloat, ctx: CGContext) {
    let W = size.width, H = size.height
    let cx = W / 2
    // background
    colBg.setFill()
    ctx.fill(CGRect(origin: .zero, size: size))

    // dot-matrix wave motif along the bottom
    drawDotWave(cx: cx, cy: 150 * scale, width: 620 * scale,
                dot: 5 * scale, vPitch: 9 * scale,
                phase: 0.9, amplitude: 1.0, ctx: ctx)

    // wordmark — Instrument Serif
    let wordmarkFont = font("Instrument Serif", 150 * scale)
    let wordmarkBaseline = H * 0.40
    drawText("Hush", font: wordmarkFont,
             color: rgb(0xF2F0EC), tracking: -0.02, centerX: cx, baselineY: wordmarkBaseline)

    // mark above wordmark — bottom of the mark clears the wordmark's
    // ascender top by ~two bar-widths
    let markScale = 0.30 * scale
    let markHalf = 440 * markScale / 2
    let markCenterY = wordmarkBaseline + wordmarkFont.ascender + 28 * scale + markHalf
    drawMark(centerX: cx, centerY: markCenterY, scale: markScale, ctx: ctx)
    if scale == 1 {
        print("mark bottom \(Int(markCenterY - markHalf)), wordmark ascender top \(Int(wordmarkBaseline + wordmarkFont.ascender)) (ascender \(wordmarkFont.ascender))")
    }

    // tagline — SF Pro
    drawText("Speak into any app. Nothing leaves your Mac.",
             font: NSFont.systemFont(ofSize: 26 * scale),
             color: colSecondary, centerX: cx, baselineY: H * 0.335)

    // readout row — Geist Mono uppercase, +0.06em tracking
    drawText("ON-DEVICE · ENGLISH + BAHASA INDONESIA · MACOS",
             font: font("Geist Mono Medium", 15 * scale),
             color: rgb(0xF2F0EC).withAlphaComponent(0.85),
             tracking: 0.06, centerX: cx, baselineY: H * 0.13)
}

try writePNG(w: 1280, h: 640, draw: { drawBanner(size: CGSize(width: 1280, height: 640), scale: 1, ctx: $0) },
             to: outDir.appendingPathComponent("banner.png"))
try writePNG(w: 2560, h: 1280, draw: { drawBanner(size: CGSize(width: 2560, height: 1280), scale: 2, ctx: $0) },
             to: outDir.appendingPathComponent("banner@2x.png"))

// MARK: hush-mark-512.png (mark on transparent)

try writePNG(w: 512, h: 512, draw: { ctx in
    ctx.clear(CGRect(x: 0, y: 0, width: 512, height: 512))
    drawMark(centerX: 256, centerY: 256, scale: 1.0, ctx: ctx)
}, to: outDir.appendingPathComponent("hush-mark-512.png"))

// MARK: hush-app-icon-1024.png (squircle approx + gradient + mark)

try writePNG(w: 1024, h: 1024, draw: { ctx in
    ctx.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let path = CGPath(roundedRect: rect, cornerWidth: 230, cornerHeight: 230, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [rgb(0x26262A).cgColor, rgb(0x0E0E10).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
    drawMark(centerX: 512, centerY: 512, scale: 1.0, ctx: ctx)
    ctx.restoreGState()
}, to: outDir.appendingPathComponent("hush-app-icon-1024.png"))

print("wrote banner.png, banner@2x.png, hush-mark-512.png, hush-app-icon-1024.png to docs/brand/")
