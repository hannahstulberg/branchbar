#!/usr/bin/env swift
// Render the BranchBar app icon master (1024x1024 PNG) with AppKit.
//
//   swift scripts/render-icon.swift Resources/icon-1024.png
//
// No build step and no SwiftPM target: this file is run directly by the swift
// interpreter, which is why it lives in scripts/ and not Sources/.
//
// Deterministic by construction — every value below is a literal, nothing reads
// the clock, the display profile, or the environment. Rerunning the script
// produces byte-identical PNG output, so `git status` stays clean unless the
// artwork actually changed.
//
// Geometry follows Apple's Big Sur app-icon grid: a 1024 canvas with the
// squircle inset to 824x824 (100 pt margin) and a 185.4 pt corner radius,
// which is 22.5% of the shape's edge. The symbol is sized against the full
// canvas (55%) so it stays legible at the 16 pt end of the iconset — the size
// Finder's Get Info panel and the sidebar actually draw.

import AppKit
import Foundation

// MARK: - Parameters

let canvas: CGFloat = 1024
let shapeInset: CGFloat = 100          // Big Sur grid: 824x824 shape on a 1024 canvas
let cornerRadius: CGFloat = 185.4      // 22.5% of the 824 pt shape edge
let symbolFraction: CGFloat = 0.55     // symbol spans 55% of the full canvas
let symbolName = "arrow.triangle.branch"

// Deep indigo -> teal. Both stops are dark enough that the white symbol holds
// contrast at 16 pt, and far enough apart in hue to stay readable in a grayscale
// row of Finder icons.
let gradientTop = NSColor(srgbRed: 0.239, green: 0.208, blue: 0.639, alpha: 1)    // #3D35A3
let gradientBottom = NSColor(srgbRed: 0.043, green: 0.510, blue: 0.518, alpha: 1) // #0B8284

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/icon-1024.png"

// MARK: - Bitmap context

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas),
    pixelsHigh: Int(canvas),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: Int(canvas) * 4,
    bitsPerPixel: 32
) else {
    FileHandle.standardError.write(Data("render-icon: could not allocate a 1024x1024 bitmap\n".utf8))
    exit(1)
}

guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write(Data("render-icon: could not bind a graphics context to the bitmap\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

// MARK: - Background squircle

let shapeRect = NSRect(
    x: shapeInset,
    y: shapeInset,
    width: canvas - shapeInset * 2,
    height: canvas - shapeInset * 2
)
let squircle = NSBezierPath(roundedRect: shapeRect, xRadius: cornerRadius, yRadius: cornerRadius)

// Drop shadow under the whole shape, the way macOS icons sit on a light Finder
// background. Subtle: it must not read as a halo at 32 pt.
NSGraphicsContext.saveGraphicsState()
let shapeShadow = NSShadow()
shapeShadow.shadowOffset = NSSize(width: 0, height: -10)
shapeShadow.shadowBlurRadius = 26
shapeShadow.shadowColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
shapeShadow.set()
NSColor.black.setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
squircle.addClip()
if let gradient = NSGradient(starting: gradientTop, ending: gradientBottom) {
    // Top-left to bottom-right, so the indigo corner sits opposite the teal one.
    gradient.draw(in: shapeRect, angle: -55)
}

// Soft top highlight for depth. Alpha is low enough that it survives the 16 pt
// downsample as a gentle sheen rather than a visible band.
if let sheen = NSGradient(
    starting: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
    ending: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)
) {
    let sheenRect = NSRect(
        x: shapeRect.minX,
        y: shapeRect.midY,
        width: shapeRect.width,
        height: shapeRect.height / 2
    )
    sheen.draw(in: sheenRect, angle: -90)
}
NSGraphicsContext.restoreGraphicsState()

// Hairline inner stroke so the shape keeps an edge against a dark desktop.
NSGraphicsContext.saveGraphicsState()
let rim = NSBezierPath(
    roundedRect: shapeRect.insetBy(dx: 2, dy: 2),
    xRadius: cornerRadius - 2,
    yRadius: cornerRadius - 2
)
rim.lineWidth = 4
NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14).setStroke()
rim.stroke()
NSGraphicsContext.restoreGraphicsState()

// MARK: - Symbol

let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 512, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))

guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "BranchBar")?
    .withSymbolConfiguration(symbolConfiguration) else {
    NSGraphicsContext.restoreGraphicsState()
    FileHandle.standardError.write(Data("render-icon: SF Symbol \(symbolName) is unavailable\n".utf8))
    exit(1)
}

// Scale the rendered symbol so its longest edge is exactly symbolFraction of the
// canvas, then center it on the canvas (not the shape — they share a center).
let target = canvas * symbolFraction
let natural = symbol.size
let scale = target / max(natural.width, natural.height)
let drawnSize = NSSize(width: natural.width * scale, height: natural.height * scale)
let symbolRect = NSRect(
    x: (canvas - drawnSize.width) / 2,
    y: (canvas - drawnSize.height) / 2,
    width: drawnSize.width,
    height: drawnSize.height
)

NSGraphicsContext.saveGraphicsState()
let symbolShadow = NSShadow()
symbolShadow.shadowOffset = NSSize(width: 0, height: -8)
symbolShadow.shadowBlurRadius = 22
symbolShadow.shadowColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.32)
symbolShadow.set()
symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()

// MARK: - Write

guard let png = rep.representation(using: .png, properties: [.interlaced: false]) else {
    FileHandle.standardError.write(Data("render-icon: PNG encoding failed\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath)
do {
    try png.write(to: url, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("render-icon: could not write \(outputPath): \(error)\n".utf8))
    exit(1)
}

print("wrote \(outputPath) (\(Int(canvas))x\(Int(canvas)), \(png.count) bytes)")
