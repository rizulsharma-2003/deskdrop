#!/usr/bin/env swift
// Renders the DeskDrop app icon and menu bar glyph into the asset catalog.
//
// Usage: swift scripts/generate-icons.swift DeskDrop/Assets.xcassets
//
// The icon is drawn with CoreGraphics so it stays reproducible and vector-crisp at
// every size: two minimal Mac displays, a document travelling between them on an
// arc, and a short motion trail.

import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icons.swift <path/to/Assets.xcassets>\n".utf8))
    exit(64)
}
let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

// MARK: - Helpers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

func quadPoint(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
    let u = 1 - t
    return CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
                   y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
}

func render(size: Int, draw: (CGContext, CGFloat) -> Void) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    let scale = CGFloat(size) / 1024
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx, scale)
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - App icon (drawn on a 1024 canvas, origin bottom-left)

func drawDisplay(_ ctx: CGContext, center: CGPoint, lit: Bool) {
    let screen = CGRect(x: center.x - 130, y: center.y - 90, width: 260, height: 180)
    let screenPath = CGPath(roundedRect: screen, cornerWidth: 26, cornerHeight: 26, transform: nil)

    // Stand: neck + base.
    let neck = CGRect(x: center.x - 20, y: screen.minY - 44, width: 40, height: 48)
    let base = CGRect(x: center.x - 70, y: screen.minY - 58, width: 140, height: 16)
    ctx.setFillColor(color(lit ? 0x8E97B0 : 0x5A6175))
    ctx.fill(neck)
    ctx.addPath(CGPath(roundedRect: base, cornerWidth: 8, cornerHeight: 8, transform: nil))
    ctx.fillPath()

    // Bezel.
    ctx.addPath(screenPath)
    ctx.setFillColor(color(lit ? 0xDCE3F5 : 0x8A93AA))
    ctx.fillPath()

    // Screen.
    let inner = screen.insetBy(dx: 12, dy: 12)
    let innerPath = CGPath(roundedRect: inner, cornerWidth: 16, cornerHeight: 16, transform: nil)
    ctx.saveGState()
    ctx.addPath(innerPath)
    ctx.clip()
    let colors: [CGColor] = lit
        ? [color(0x3F7BFF), color(0x8B5CFF)]
        : [color(0x252A38), color(0x1A1E29)]
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: inner.minX, y: inner.maxY), end: CGPoint(x: inner.maxX, y: inner.minY), options: [])
    if lit {
        // Soft landing glow in the middle of the receiving screen.
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: inner.midX, y: inner.midY + 10), startRadius: 0,
                               endCenter: CGPoint(x: inner.midX, y: inner.midY + 10), endRadius: 90, options: [])
    }
    ctx.restoreGState()
}

func drawDocument(_ ctx: CGContext, center: CGPoint, angle: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    let w: CGFloat = 156, h: CGFloat = 196, fold: CGFloat = 46
    let path = CGMutablePath()
    path.move(to: CGPoint(x: -w / 2 + 18, y: -h / 2))
    path.addLine(to: CGPoint(x: w / 2 - 18, y: -h / 2))
    path.addQuadCurve(to: CGPoint(x: w / 2, y: -h / 2 + 18), control: CGPoint(x: w / 2, y: -h / 2))
    path.addLine(to: CGPoint(x: w / 2, y: h / 2 - fold))
    path.addLine(to: CGPoint(x: w / 2 - fold, y: h / 2))
    path.addLine(to: CGPoint(x: -w / 2 + 18, y: h / 2))
    path.addQuadCurve(to: CGPoint(x: -w / 2, y: h / 2 - 18), control: CGPoint(x: -w / 2, y: h / 2))
    path.addLine(to: CGPoint(x: -w / 2, y: -h / 2 + 18))
    path.addQuadCurve(to: CGPoint(x: -w / 2 + 18, y: -h / 2), control: CGPoint(x: -w / 2, y: -h / 2))
    path.closeSubpath()

    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x3D8BFF, 0.55))
    ctx.addPath(path)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Folded corner.
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: w / 2 - fold, y: h / 2))
    corner.addLine(to: CGPoint(x: w / 2 - fold, y: h / 2 - fold + 8))
    corner.addQuadCurve(to: CGPoint(x: w / 2 - fold + 8, y: h / 2 - fold), control: CGPoint(x: w / 2 - fold, y: h / 2 - fold))
    corner.addLine(to: CGPoint(x: w / 2, y: h / 2 - fold))
    corner.closeSubpath()
    ctx.addPath(corner)
    ctx.setFillColor(color(0xC9D3EA))
    ctx.fillPath()

    // Content lines.
    ctx.setFillColor(color(0x4C8DFF, 0.9))
    for (i, width) in [96.0, 78.0, 88.0].enumerated() {
        let y = CGFloat(30 - i * 34)
        ctx.addPath(CGPath(roundedRect: CGRect(x: -w / 2 + 28, y: y - 7, width: width, height: 14),
                           cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.fillPath()
    }
    ctx.restoreGState()
}

func drawAppIcon(_ ctx: CGContext) {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // Drop shadow under the squircle.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x10131A))
    ctx.fillPath()
    ctx.restoreGState()

    // Charcoal body with soft ambient light.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [color(0x262B3A), color(0x0C0E14)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let ambient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                             colors: [color(0x4C8DFF, 0.22), color(0x4C8DFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(ambient, startCenter: CGPoint(x: 724, y: 380), startRadius: 0,
                           endCenter: CGPoint(x: 724, y: 380), endRadius: 420, options: [])
    let violet = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [color(0x8B5CFF, 0.16), color(0x8B5CFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(violet, startCenter: CGPoint(x: 300, y: 820), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 820), endRadius: 380, options: [])

    let left = CGPoint(x: 300, y: 330)
    let right = CGPoint(x: 724, y: 330)
    drawDisplay(ctx, center: left, lit: false)
    drawDisplay(ctx, center: right, lit: true)

    // Motion trail along the throw arc.
    let start = CGPoint(x: 300, y: 450)
    let control = CGPoint(x: 512, y: 905)
    let end = CGPoint(x: 724, y: 450)
    let fileT: CGFloat = 0.56
    let steps = 72
    for i in 0..<steps {
        let t = lerp(0.04, fileT - 0.08, CGFloat(i) / CGFloat(steps - 1))
        let p = quadPoint(start, control, end, t)
        let k = CGFloat(i) / CGFloat(steps - 1)
        let radius = lerp(4, 20, k)
        let c = k < 0.5
            ? color(0x3DD6F5, lerp(0.05, 0.30, k * 2))
            : color(0x4C8DFF, lerp(0.30, 0.60, (k - 0.5) * 2))
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    }
    // Faint remainder of the path toward the destination.
    ctx.setStrokeColor(color(0xFFFFFF, 0.16))
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [2, 22])
    let remainder = CGMutablePath()
    remainder.move(to: quadPoint(start, control, end, fileT + 0.1))
    for i in 1...20 {
        remainder.addLine(to: quadPoint(start, control, end, lerp(fileT + 0.1, 0.97, CGFloat(i) / 20)))
    }
    ctx.addPath(remainder)
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    drawDocument(ctx, center: quadPoint(start, control, end, fileT), angle: -0.2)

    // Hairline highlight around the squircle.
    ctx.restoreGState()
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

// MARK: - Menu bar template glyph (black on transparent, drawn on a 1024 canvas)

func drawMenuBarGlyph(_ ctx: CGContext) {
    ctx.setFillColor(color(0x000000))
    ctx.setStrokeColor(color(0x000000))
    // Document, tilted, in the upper right.
    ctx.saveGState()
    ctx.translateBy(x: 600, y: 560)
    ctx.rotate(by: -0.22)
    let w: CGFloat = 380, h: CGFloat = 480, fold: CGFloat = 120
    let doc = CGMutablePath()
    doc.move(to: CGPoint(x: -w / 2, y: -h / 2 + 50))
    doc.addQuadCurve(to: CGPoint(x: -w / 2 + 50, y: -h / 2), control: CGPoint(x: -w / 2, y: -h / 2))
    doc.addLine(to: CGPoint(x: w / 2 - 50, y: -h / 2))
    doc.addQuadCurve(to: CGPoint(x: w / 2, y: -h / 2 + 50), control: CGPoint(x: w / 2, y: -h / 2))
    doc.addLine(to: CGPoint(x: w / 2, y: h / 2 - fold))
    doc.addLine(to: CGPoint(x: w / 2 - fold, y: h / 2))
    doc.addLine(to: CGPoint(x: -w / 2 + 50, y: h / 2))
    doc.addQuadCurve(to: CGPoint(x: -w / 2, y: h / 2 - 50), control: CGPoint(x: -w / 2, y: h / 2))
    doc.closeSubpath()
    ctx.addPath(doc)
    ctx.setLineWidth(64)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // Motion streaks trailing down-left.
    ctx.setLineCap(.round)
    ctx.setLineWidth(64)
    for (i, len) in [250.0, 170.0, 100.0].enumerated() {
        let y = 520 - CGFloat(i) * 150
        let x = 330 - CGFloat(i) * 40
        ctx.move(to: CGPoint(x: x, y: y))
        ctx.addLine(to: CGPoint(x: x - len, y: y - len * 0.42))
        ctx.strokePath()
    }
}

// MARK: - Write assets

func write(_ data: Data, to url: URL) {
    do { try data.write(to: url, options: .atomic) } catch {
        FileHandle.standardError.write(Data("failed writing \(url.path): \(error)\n".utf8))
        exit(1)
    }
}

let iconSet = assets.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
let iconSpecs: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var iconEntries: [String] = []
for spec in iconSpecs {
    let pixels = spec.points * spec.scale
    let name = "icon_\(spec.points)x\(spec.points)\(spec.scale == 2 ? "@2x" : "").png"
    write(render(size: pixels) { ctx, _ in drawAppIcon(ctx) }, to: iconSet.appendingPathComponent(name))
    iconEntries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(spec.scale)x",
          "size" : "\(spec.points)x\(spec.points)"
        }
    """)
}
write(Data("""
{
  "images" : [
\(iconEntries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

""".utf8), to: iconSet.appendingPathComponent("Contents.json"))

let menuSet = assets.appendingPathComponent("MenuBarIcon.imageset", isDirectory: true)
try? FileManager.default.createDirectory(at: menuSet, withIntermediateDirectories: true)
write(render(size: 18) { ctx, _ in drawMenuBarGlyph(ctx) }, to: menuSet.appendingPathComponent("menubar.png"))
write(render(size: 36) { ctx, _ in drawMenuBarGlyph(ctx) }, to: menuSet.appendingPathComponent("menubar@2x.png"))
write(Data("""
{
  "images" : [
    { "filename" : "menubar.png", "idiom" : "universal", "scale" : "1x" },
    { "filename" : "menubar@2x.png", "idiom" : "universal", "scale" : "2x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}

""".utf8), to: menuSet.appendingPathComponent("Contents.json"))

// A large preview for documentation.
let preview = assets.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/images", isDirectory: true)
try? FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
write(render(size: 512) { ctx, _ in drawAppIcon(ctx) }, to: preview.appendingPathComponent("icon-preview.png"))

print("Wrote app icon, menu bar glyph and preview into \(assets.path)")
