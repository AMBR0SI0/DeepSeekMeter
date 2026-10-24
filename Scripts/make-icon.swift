// Renders the app icon: a rounded slate tile with a three-quarter usage ring.
// Usage: swift Scripts/make-icon.swift <output.png> (1024×1024)

import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let side = 1024
let canvas = CGFloat(side)
let center = CGPoint(x: canvas / 2, y: canvas / 2)

guard let context = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("could not create bitmap context")
}

context.setAllowsAntialiasing(true)
context.interpolationQuality = .high

// Tile
let tile = CGRect(x: 88, y: 88, width: canvas - 176, height: canvas - 176)
let shape = CGPath(roundedRect: tile, cornerWidth: 214, cornerHeight: 214, transform: nil)

context.saveGState()
context.addPath(shape)
context.clip()

let slate = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.098, green: 0.114, blue: 0.149, alpha: 1),
        CGColor(red: 0.043, green: 0.051, blue: 0.067, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    slate,
    start: CGPoint(x: 0, y: canvas),
    end: CGPoint(x: 0, y: 0),
    options: []
)

// Track
let radius: CGFloat = 268
let ring: CGFloat = 92
context.setLineWidth(ring)
context.setLineCap(.round)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
context.strokePath()

// Three-quarter arc, blue into violet
let arc = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [
        CGColor(red: 0.40, green: 0.62, blue: 1.00, alpha: 1),
        CGColor(red: 0.72, green: 0.45, blue: 1.00, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
context.saveGState()
context.addRect(tile)
context.clip()
context.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: -.pi / 4, clockwise: true)
context.replacePathWithStrokedPath()
context.clip()
context.drawLinearGradient(
    arc,
    start: CGPoint(x: tile.minX, y: tile.maxY),
    end: CGPoint(x: tile.maxX, y: tile.minY),
    options: []
)
context.restoreGState()

// Specular edge
context.setLineWidth(3)
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
context.addPath(shape)
context.strokePath()

context.restoreGState()

guard let image = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try data.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
