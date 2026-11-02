#!/usr/bin/env swift
// Generates the UltraDic app icon (asset catalog PNGs, AppIcon.icns) and the
// menu bar template icon. Original artwork: a rounded square with a sound
// wave of five bars. Run from the repo root: swift scripts/generate-icon.swift
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("BlitztextMac/Resources")
let iconset = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")

// Relative bar heights of the wave (0...1), left to right.
let barHeights: [CGFloat] = [0.30, 0.55, 0.85, 0.55, 0.30]

func makeContext(_ pixels: Int) -> CGContext {
    CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func write(_ ctx: CGContext, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func drawBars(_ ctx: CGContext, in rect: CGRect, color: CGColor) {
    let count = CGFloat(barHeights.count)
    let barWidth = rect.width / (count * 2 - 1)
    ctx.setFillColor(color)
    for (i, h) in barHeights.enumerated() {
        let height = rect.height * h
        let bar = CGRect(
            x: rect.minX + CGFloat(i) * barWidth * 2,
            y: rect.midY - height / 2,
            width: barWidth, height: height
        )
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.fillPath()
    }
}

func appIcon(pixels: Int) -> CGContext {
    let ctx = makeContext(pixels)
    let s = CGFloat(pixels)
    // macOS icon grid: artwork fills 80% of the canvas.
    let body = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let radius = body.width * 0.225
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let colors = [
        CGColor(red: 0.36, green: 0.22, blue: 0.86, alpha: 1),
        CGColor(red: 0.09, green: 0.10, blue: 0.30, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: []
    )
    ctx.restoreGState()
    let wave = body.insetBy(dx: body.width * 0.24, dy: body.height * 0.16)
    drawBars(ctx, in: wave, color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    return ctx
}

func menuBarIcon(pixels: Int) -> CGContext {
    // Template image: black shape on transparent, macOS tints it.
    let ctx = makeContext(pixels)
    let s = CGFloat(pixels)
    drawBars(ctx, in: CGRect(x: s * 0.14, y: s * 0.12, width: s * 0.72, height: s * 0.76), color: CGColor(gray: 0, alpha: 1))
    return ctx
}

// Asset catalog: file name -> pixel size (see Contents.json).
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_64x64", 64), ("icon_64x64@2x", 128), ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ("icon_1024x1024", 1024),
]
for (name, px) in sizes {
    write(appIcon(pixels: px), to: iconset.appendingPathComponent("\(name).png"))
}
write(menuBarIcon(pixels: 18), to: resources.appendingPathComponent("menubar_icon.png"))
write(menuBarIcon(pixels: 36), to: resources.appendingPathComponent("menubar_icon@2x.png"))

// AppIcon.icns via iconutil.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("UltraDic.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let icnsNames: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in icnsNames {
    write(appIcon(pixels: px), to: tmp.appendingPathComponent("\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: tmp)
print("Icon generated (iconutil exit \(p.terminationStatus))")
