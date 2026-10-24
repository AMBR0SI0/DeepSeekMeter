// Builds docs/logo.png — the app icon plus a wordmark — from docs/icon.png.
// Usage: swift Scripts/make-logo.swift

import AppKit

let canvas = NSSize(width: 1280, height: 480)
let iconSide: CGFloat = 352
let iconInset: CGFloat = 64
let textX = iconInset + iconSide + 56

let image = NSImage(size: canvas)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}
context.clear(CGRect(origin: .zero, size: canvas))

// A solid slate panel keeps the white wordmark readable on a light README
// without relying on the reader's colour scheme.
let panel = NSBezierPath(
    roundedRect: NSRect(origin: .zero, size: canvas).insetBy(dx: 12, dy: 12),
    xRadius: 56,
    yRadius: 56
)
NSGradient(
    starting: NSColor(red: 0.098, green: 0.114, blue: 0.149, alpha: 1),
    ending: NSColor(red: 0.043, green: 0.051, blue: 0.067, alpha: 1)
)?.draw(in: panel, angle: -90)

for (path, fallback) in [
    ("docs/icon.png", "Resources/AppIcon.icns"),
] {
    if let icon = NSImage(contentsOfFile: path) {
        icon.draw(in: NSRect(x: iconInset, y: iconInset, width: iconSide, height: iconSide))
        break
    }
    if let icon = NSImage(contentsOfFile: fallback) {
        icon.draw(in: NSRect(x: iconInset, y: iconInset, width: iconSide, height: iconSide))
        break
    }
}

let base = NSFont.systemFont(ofSize: 132, weight: .bold)
let titleFont = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 132) ?? base
let taglineFont = NSFont.systemFont(ofSize: 38, weight: .medium)

let title = NSAttributedString(string: "Token Meter", attributes: [
    .font: titleFont,
    .foregroundColor: NSColor.white,
    .kern: -2,
])
title.draw(at: NSPoint(x: textX, y: 232))

let tagline = NSAttributedString(string: "usage & spend for any LLM endpoint", attributes: [
    .font: taglineFont,
    .foregroundColor: NSColor(white: 0.72, alpha: 1),
])
tagline.draw(at: NSPoint(x: textX + 4, y: 170))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("could not encode PNG")
}
try png.write(to: URL(fileURLWithPath: "docs/logo.png"))
print("wrote docs/logo.png")
