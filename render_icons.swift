#!/usr/bin/env swift
// Renders gh-badge icon assets from the Octicons mark-github SVG.
// Usage: swift render_icons.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let glyphDir = root.appendingPathComponent("Support/Glyph", isDirectory: true)
let appIconDir = root.appendingPathComponent("Support/AppIcon.iconset", isDirectory: true)
let svgURL = glyphDir.appendingPathComponent("mark-github-24.svg")
let svgWhiteURL = glyphDir.appendingPathComponent("mark-github-24-white.svg")

try! FileManager.default.createDirectory(at: appIconDir, withIntermediateDirectories: true)

guard let cat = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write("could not load SVG\n".data(using: .utf8)!)
    exit(1)
}
// The base SVG has no `fill`, so NSImage renders it black regardless of the
// current drawing color. The white variant bakes fill="#fff" into the path.
guard let whiteCat = NSImage(contentsOf: svgWhiteURL) else {
    FileHandle.standardError.write("could not load white SVG\n".data(using: .utf8)!)
    exit(1)
}

func renderPNG(size: CGFloat, draw: (NSRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.rounded()),
        pixelsHigh: Int(size.rounded()),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Start fully transparent; fill backgrounds explicitly where wanted.
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: size, height: size).fill()
    draw(NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// The SVG viewBox is 24x24 with the cat filling most of it (slight padding).
// Drawing the full SVG into a square canvas therefore yields a well-padded glyph.
func drawCat(in rect: NSRect) {
    cat.draw(in: rect)
}

func drawWhiteCat(in rect: NSRect) {
    whiteCat.draw(in: rect)
}

// MARK: - Menu bar glyphs (template, monochrome black)

let menuBarSizes: [(name: String, px: CGFloat)] = [
    ("MenuBarGlyph.png", 18),
    ("MenuBarGlyph@2x.png", 36),
]
for (name, px) in menuBarSizes {
    let data = renderPNG(size: px) { rect in drawCat(in: rect) }
    let url = glyphDir.appendingPathComponent(name)
    try! data.write(to: url)
    print("wrote \(url.path) (\(px)x\(px))")
}

// MARK: - App icon (white cat on GitHub-dark rounded square)

let bg = NSColor(calibratedRed: 0x24 / 255.0, green: 0x29 / 255.0, blue: 0x2F / 255.0, alpha: 1.0) // #24292F
let iconSizes: [CGFloat] = [16, 32, 64, 128, 256, 512, 1024]

for size in iconSizes {
    // Continuous-corner squircle approximating the macOS icon shape.
    let cornerRadius = size * 0.2237
    let data = renderPNG(size: size) { rect in
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        bg.setFill()
        path.fill()
        // Inner content ~65% of the canvas, centered.
        let inner = size * 0.65
        let catRect = NSRect(
            x: (size - inner) / 2,
            y: (size - inner) / 2,
            width: inner,
            height: inner
        )
        drawWhiteCat(in: catRect)
    }
    let name = size == 1024 ? "icon_512x512@2x.png" : "icon_\(Int(size))x\(Int(size)).png"
    try! data.write(to: appIconDir.appendingPathComponent(name))
    print("wrote \(name) (\(Int(size))px)")
}
print("done")
