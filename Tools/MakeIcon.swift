// Draws Alarm.iconset offscreen so the repo doesn't have to carry binary art.
// Run via `swift Tools/MakeIcon.swift <output.iconset>`; build.sh then hands the
// result to iconutil. Cached — this only runs when AppIcon.icns is missing.

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Alarm.iconset"
let outputURL = URL(fileURLWithPath: outputPath)

func drawIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // Rounded-square plate with a dusk gradient.
    let inset = size * 0.075
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(
        roundedRect: plate, xRadius: size * 0.205, yRadius: size * 0.205
    )
    NSGradient(
        colors: [
            NSColor(srgbRed: 0.29, green: 0.20, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 0.85, green: 0.29, blue: 0.38, alpha: 1),
        ]
    )?.draw(in: path, angle: -90)

    // Clock face at 7:30 — the script's default alarm time.
    let center = NSPoint(x: size / 2, y: size / 2)
    let radius = size * 0.255
    NSColor.white.setStroke()

    let ring = NSBezierPath(ovalIn: NSRect(
        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2
    ))
    ring.lineWidth = size * 0.042
    ring.stroke()

    func hand(degreesFromTwelve: Double, length: CGFloat, width: CGFloat) {
        let angle = CGFloat(degreesFromTwelve * .pi / 180)
        let hand = NSBezierPath()
        hand.move(to: center)
        hand.line(to: NSPoint(
            x: center.x + CGFloat(sin(angle)) * length,
            y: center.y + CGFloat(cos(angle)) * length
        ))
        hand.lineWidth = width
        hand.lineCapStyle = .round
        hand.stroke()
    }
    hand(degreesFromTwelve: 225, length: radius * 0.52, width: size * 0.042)  // hour
    hand(degreesFromTwelve: 180, length: radius * 0.74, width: size * 0.034)  // minute

    return rep.representation(using: .png, properties: [:])
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
for variant in variants {
    guard let data = drawIcon(pixels: variant.pixels) else {
        FileHandle.standardError.write(Data("could not render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputURL.appendingPathComponent("\(variant.name).png"))
}
