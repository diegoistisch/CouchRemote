#!/usr/bin/env swift
import AppKit
import CoreGraphics

// All dimensions are in pixels in a top-left-origin 1024 × 1024 canvas.
// Shared radii and palette keep the two pictograms in the same family.
enum Metrics {
    static let canvas = 1024
    static let hostBackground = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let hostBackgroundRadius: CGFloat = 185
    static let bodyRadius: CGFloat = 44
    static let insetRadius: CGFloat = 14
    static let hostBody = CGRect(x: 244, y: 310, width: 536, height: 350)
    static let hostStem = CGRect(x: 482, y: 646, width: 60, height: 74)
    static let hostFoot = CGRect(x: 412, y: 706, width: 200, height: 28)
    static let hostFootRadius: CGFloat = 14
    static let tileOrigin = CGPoint(x: 288, y: 354)
    static let tileSize = CGSize(width: 132, height: 117)
    static let tileGap: CGFloat = 26
    static let tileRows = 2
    static let tileColumns = 3
    static let remoteBody = CGRect(x: 362, y: 202, width: 300, height: 620)
    static let trackpad = CGRect(x: 394, y: 234, width: 236, height: 360)
    static let cursor = CGRect(x: 484, y: 386, width: 56, height: 56)
    static let buttonDiameter: CGFloat = 44
    static let buttonCenterY: CGFloat = 700
    static let buttonCentersX: [CGFloat] = [438, 512, 586]
}

enum Palette {
    static let background = color(0x1E2235)
    static let foreground = color(0xF3EEE4)
    static let accent = color(0xFF6A3D)

    private static func color(_ hex: UInt32) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [
            CGFloat((hex >> 16) & 255) / 255,
            CGFloat((hex >> 8) & 255) / 255,
            CGFloat(hex & 255) / 255, 1
        ])!
    }
}

func rounded(_ context: CGContext, _ rect: CGRect, radius: CGFloat, color: CGColor) {
    context.setFillColor(color)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius,
                           cornerHeight: radius, transform: nil))
    context.fillPath()
}

func render(to url: URL, opaque: Bool, draw: (CGContext) -> Void) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // An RGB image without an alpha channel for iOS; premultiplied RGBA for macOS.
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    guard let context = CGContext(data: nil, width: Metrics.canvas, height: Metrics.canvas,
                                  bitsPerComponent: 8, bytesPerRow: Metrics.canvas * 4,
                                  space: space, bitmapInfo: alpha.rawValue) else {
        throw NSError(domain: "IconRendering", code: 1)
    }
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.translateBy(x: 0, y: CGFloat(Metrics.canvas))
    context.scaleBy(x: 1, y: -1)
    draw(context)
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconRendering", code: 2)
    }
    try png.write(to: url, options: .atomic)
}

let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = project.appendingPathComponent("Design/Icons", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

try render(to: output.appendingPathComponent("CouchHost-1024.png"), opaque: false) { context in
    rounded(context, Metrics.hostBackground, radius: Metrics.hostBackgroundRadius, color: Palette.background)
    rounded(context, Metrics.hostStem, radius: Metrics.insetRadius, color: Palette.foreground)
    rounded(context, Metrics.hostFoot, radius: Metrics.hostFootRadius, color: Palette.foreground)
    rounded(context, Metrics.hostBody, radius: Metrics.bodyRadius, color: Palette.foreground)
    for row in 0..<Metrics.tileRows {
        for column in 0..<Metrics.tileColumns {
            let tile = CGRect(
                x: Metrics.tileOrigin.x + CGFloat(column) * (Metrics.tileSize.width + Metrics.tileGap),
                y: Metrics.tileOrigin.y + CGFloat(row) * (Metrics.tileSize.height + Metrics.tileGap),
                width: Metrics.tileSize.width, height: Metrics.tileSize.height)
            rounded(context, tile, radius: Metrics.insetRadius,
                    color: row == 0 && column == 0 ? Palette.accent : Palette.background)
        }
    }
}

try render(to: output.appendingPathComponent("CouchRemote-1024.png"), opaque: true) { context in
    context.setFillColor(Palette.background)
    context.fill(CGRect(x: 0, y: 0, width: Metrics.canvas, height: Metrics.canvas))
    rounded(context, Metrics.remoteBody, radius: Metrics.bodyRadius, color: Palette.foreground)
    rounded(context, Metrics.trackpad, radius: Metrics.insetRadius, color: Palette.background)
    context.setFillColor(Palette.accent)
    context.fillEllipse(in: Metrics.cursor)
    context.setFillColor(Palette.background)
    for centerX in Metrics.buttonCentersX {
        context.fillEllipse(in: CGRect(x: centerX - Metrics.buttonDiameter / 2,
                                      y: Metrics.buttonCenterY - Metrics.buttonDiameter / 2,
                                      width: Metrics.buttonDiameter, height: Metrics.buttonDiameter))
    }
}
print("Created Design/Icons/CouchHost-1024.png and Design/Icons/CouchRemote-1024.png")
