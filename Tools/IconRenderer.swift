// Renders every size the macOS .iconset contract requires.
//
// The icon has no binary source of truth: this file is it. `Scripts/make-icon.sh` regenerates
// the .iconset and the .icns on every build, so the shipped app and the README image can
// never drift apart.
//
// Drawn with AppKit rather than a raw CGBitmapContext: Core Graphics alpha formats do not
// survive the round trip through NSBitmapImageRep in this toolchain, and AppKit's drawing
// path does.
//
// Run: swift Tools/IconRenderer.swift <output-dir>

import AppKit
import Foundation

let canvasSide: CGFloat = 1024

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

func colour(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

/// A macOS-style superellipse. Continuous corner curvature is approximated with a cubic
/// Bézier per corner, which is indistinguishable at icon scale and needs no path library.
func squircle(_ rect: NSRect) -> NSBezierPath {
    let radius = rect.width * 0.2237
    let path = NSBezierPath()
    let k = radius * 0.32

    path.move(to: NSPoint(x: rect.minX + radius, y: rect.maxY))
    path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
    path.curve(to: NSPoint(x: rect.maxX, y: rect.maxY - radius),
               controlPoint1: NSPoint(x: rect.maxX - k, y: rect.maxY),
               controlPoint2: NSPoint(x: rect.maxX, y: rect.maxY - k))
    path.line(to: NSPoint(x: rect.maxX, y: rect.minY + radius))
    path.curve(to: NSPoint(x: rect.maxX - radius, y: rect.minY),
               controlPoint1: NSPoint(x: rect.maxX, y: rect.minY + k),
               controlPoint2: NSPoint(x: rect.maxX - k, y: rect.minY))
    path.line(to: NSPoint(x: rect.minX + radius, y: rect.minY))
    path.curve(to: NSPoint(x: rect.minX, y: rect.minY + radius),
               controlPoint1: NSPoint(x: rect.minX + k, y: rect.minY),
               controlPoint2: NSPoint(x: rect.minX, y: rect.minY + k))
    path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
    path.curve(to: NSPoint(x: rect.minX + radius, y: rect.maxY),
               controlPoint1: NSPoint(x: rect.minX, y: rect.maxY - k),
               controlPoint2: NSPoint(x: rect.minX + k, y: rect.maxY))
    path.close()
    return path
}

/// Always drawn at full size: a small NSImage has no usable backing store for
/// `lockFocus`, and downsampling from 1024 looks better than drawing small directly.
func renderMaster() -> NSImage? {
    let image = NSImage(size: NSSize(width: canvasSide, height: canvasSide))
    image.lockFocus()

    let plate = NSRect(x: 100, y: 100, width: canvasSide - 200, height: canvasSide - 200)
    let platePath = squircle(plate)

    // Background: the app squircle, inset the way macOS leaves breathing room.
    NSGraphicsContext.saveGraphicsState()
    platePath.addClip()
    NSGradient(starting: colour(0x5B4BF5), ending: colour(0x0EA5C8))?
        .draw(in: plate, angle: -50)

    // A shallow top highlight for depth. Subtle enough to vanish at 16px.
    NSGradient(starting: colour(0xFFFFFF, alpha: 0.20), ending: colour(0xFFFFFF, alpha: 0))?
        .draw(in: NSRect(x: plate.minX, y: plate.midY, width: plate.width, height: plate.height / 2),
              angle: 90)

    // The mark is drawn at this scale about the canvas centre. At 1.0 it read as a small
    // blob at 32px; the padding macOS leaves around a real icon does not have to be
    // reproduced as aggressively as the safe area suggests.
    let markScale: CGFloat = 1.14
    let markTransform = NSAffineTransform()
    markTransform.translateX(by: canvasSide / 2, yBy: canvasSide / 2)
    markTransform.scale(by: markScale)
    markTransform.translateX(by: -canvasSide / 2, yBy: -canvasSide / 2)
    markTransform.concat()

    // The mark: a padlock, opened. Lifting a restriction is the whole job.
    //
    // The shackle pivots on the leg that stays seated, so the other leg swings up and clear
    // of the body with a visible gap. Drawing it as a short arc instead — which is the
    // obvious approach — puts both ends within one stroke width of each other and collapses
    // into a lump at 32px.
    let body = NSRect(x: 300, y: 250, width: 424, height: 332)
    colour(0xFFFFFF, alpha: 0.97).setFill()
    NSBezierPath(roundedRect: body, xRadius: 82, yRadius: 82).fill()

    let seat = NSPoint(x: 412, y: 552)   // the leg that stays down
    let radius: CGFloat = 148
    let stroke: CGFloat = 98

    NSGraphicsContext.saveGraphicsState()
    let shackleTransform = NSAffineTransform()
    shackleTransform.translateX(by: seat.x, yBy: seat.y)
    shackleTransform.rotate(byDegrees: 34)
    shackleTransform.concat()
    let shackle = NSBezierPath()
    shackle.appendArc(withCenter: NSPoint(x: radius, y: 0), radius: radius,
                      startAngle: 180, endAngle: 0)
    shackle.lineWidth = stroke
    shackle.lineCapStyle = .round
    colour(0xFFFFFF, alpha: 0.97).setStroke()
    shackle.stroke()
    NSGraphicsContext.restoreGraphicsState()

    // The checkmark is a knockout through the white body down to the gradient beneath, so
    // the 16px silhouette stays one solid mass instead of two colours fighting.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.compositingOperation = .clear
    let check = NSBezierPath()
    check.move(to: NSPoint(x: 388, y: 424))
    check.line(to: NSPoint(x: 470, y: 340))
    check.line(to: NSPoint(x: 640, y: 508))
    check.lineWidth = 86
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.stroke()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    image.unlockFocus()
    return image
}

func downsample(_ master: NSImage, to pixels: Int) -> NSBitmapImageRep? {
    guard let target = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    target.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return target
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: IconRenderer <output-dir>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

guard let master = renderMaster() else {
    FileHandle.standardError.write(Data("failed to render master image\n".utf8))
    exit(1)
}

for variant in variants {
    guard let rep = downsample(master, to: variant.pixels),
          let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent("\(variant.name).png"))
    print("  \(variant.name).png  \(variant.pixels)x\(variant.pixels)")
}
print("wrote \(variants.count) images to \(outputDirectory.path)")
