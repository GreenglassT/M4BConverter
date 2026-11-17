#!/usr/bin/env swift
//  Draws the app icon and writes AppIcon.icns.
//
//      swift Scripts/make-icon.swift
//
//  Vector-drawn rather than an exported bitmap: every size is rendered from the same
//  code, so the 16pt icon in the Finder sidebar is composed for 16pt instead of being
//  a downscale of 1024 with the detail turned to mush. It also means the icon is
//  reviewable as a diff.

import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? FileManager.default.currentDirectoryPath)

// MARK: - Drawing

/// A superellipse, the shape macOS uses for app icons. A plain rounded rectangle is
/// visibly wrong beside real icons in the Dock — the curvature is continuous here,
/// not an arc spliced onto a straight edge.
func squirclePath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let n = 5.0                               // superellipse exponent
    let steps = 720
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// One book: a rounded spine, optionally leaning, with a band near the top the way a
/// cloth binding carries a label. The band is dropped below 64pt — at 32pt it is a
/// smear across the spine rather than a detail.
func drawBook(_ ctx: CGContext, x: CGFloat, width: CGFloat, height: CGFloat,
              baseline: CGFloat, lean: CGFloat, size: CGFloat, alpha: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: x + width / 2, y: baseline)
    ctx.rotate(by: lean)
    ctx.translateBy(x: -width / 2, y: 0)

    let body = CGRect(x: 0, y: 0, width: width, height: height)
    let radius = width * 0.22
    ctx.setFillColor(CGColor(gray: 1, alpha: alpha))
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius,
                       transform: nil))
    ctx.fillPath()

    if size >= 64 {
        let band = CGRect(x: 0, y: height * 0.70, width: width, height: height * 0.075)
        ctx.setBlendMode(.destinationOut)
        ctx.addPath(CGPath(roundedRect: band, cornerWidth: 0, cornerHeight: 0, transform: nil))
        ctx.fillPath()
        ctx.setBlendMode(.normal)
    }
    ctx.restoreGState()
}

func drawIcon(size: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Full bleed, deliberately. macOS 26 (Tahoe) wraps a legacy .icns in the system's own
    // icon shape, so an icon that draws its own squircle with a margin — the pre-Tahoe
    // convention — comes out as a small squircle inset inside Apple's, double-framed and
    // shrunken. Verified by asking NSWorkspace what it resolved for the built bundle: the
    // margined version returned my art sitting on a grey plate.
    //
    // Drawing edge to edge lets Tahoe's mask define the silhouette. The superellipse is
    // still drawn underneath so that on an older macOS, which does no masking, the icon
    // has a proper shape instead of a hard square.
    let plate = CGRect(x: 0, y: 0, width: size, height: size)
    // Grown 2% past the canvas. Tahoe composites a legacy icns *over* a grey plate rather
    // than masking to it, so the shape still has to be drawn: expanding to 9% made the art
    // effectively square and the plate showed through all four corners, which looks worse
    // than the thin bezel this leaves. Shipping Tahoe's own .icon format is the only way to
    // lose the plate entirely, and that needs Icon Composer.
    let shape = squirclePath(in: plate.insetBy(dx: -size * 0.02, dy: -size * 0.02))

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    // Warm amber to deep orange: paper and lamplight rather than another blue dev tool,
    // and dark enough at the bottom to carry white at 16pt.
    let colors = [CGColor(red: 0.98, green: 0.71, blue: 0.31, alpha: 1),
                  CGColor(red: 0.85, green: 0.33, blue: 0.11, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.minY),
                           options: [])
    ctx.restoreGState()

    // Books on a shelf — the same idea as the empty state's `books.vertical`, so the
    // icon and the window agree about what this app is.
    //
    // Two compositions, not one drawing scaled down. At 16pt the four-book version
    // collapsed into an orange smudge: the gaps fell below a pixel and the books merged.
    // The small one spends its ~10 usable pixels on three fat bars with real gaps, which
    // still reads as books on a shelf at Finder-sidebar size.
    let w = plate.width
    let baseline = plate.minY + plate.height * 0.235
    let shelfWidth: CGFloat
    let shelfThickness: CGFloat

    if size <= 32 {
        drawBook(ctx, x: plate.minX + w * 0.250, width: w * 0.150, height: plate.height * 0.46,
                 baseline: baseline, lean: 0, size: size, alpha: 1.0)
        drawBook(ctx, x: plate.minX + w * 0.425, width: w * 0.150, height: plate.height * 0.57,
                 baseline: baseline, lean: 0, size: size, alpha: 1.0)
        drawBook(ctx, x: plate.minX + w * 0.600, width: w * 0.150, height: plate.height * 0.49,
                 baseline: baseline, lean: 0, size: size, alpha: 1.0)
        shelfWidth = 0.545
        shelfThickness = 0.060
    } else {
        drawBook(ctx, x: plate.minX + w * 0.245, width: w * 0.115, height: plate.height * 0.44,
                 baseline: baseline, lean: 0, size: size, alpha: 0.92)
        drawBook(ctx, x: plate.minX + w * 0.385, width: w * 0.130, height: plate.height * 0.53,
                 baseline: baseline, lean: 0, size: size, alpha: 1.0)
        drawBook(ctx, x: plate.minX + w * 0.545, width: w * 0.115, height: plate.height * 0.47,
                 baseline: baseline, lean: 0, size: size, alpha: 0.92)
        // The leaning one keeps the row from reading as a bar chart.
        drawBook(ctx, x: plate.minX + w * 0.690, width: w * 0.110, height: plate.height * 0.45,
                 baseline: baseline, lean: -0.20, size: size, alpha: 0.85)
        shelfWidth = 0.600
        shelfThickness = 0.035
    }

    // The shelf they stand on, which also reads as an underline at small sizes.
    let shelf = CGRect(x: plate.midX - w * shelfWidth / 2,
                       y: baseline - plate.height * (shelfThickness + 0.017),
                       width: w * shelfWidth, height: plate.height * shelfThickness)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.addPath(CGPath(roundedRect: shelf, cornerWidth: shelf.height / 2,
                       cornerHeight: shelf.height / 2, transform: nil))
    ctx.fillPath()

    return ctx.makeImage()!
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString,
                                                    1, nil) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 2) }
}

let iconset = root.appendingPathComponent("Scripts/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The set macOS expects; iconutil rejects an iconset that is missing any of them.
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    try write(drawIcon(size: size), to: iconset.appendingPathComponent("\(name).png"))
}
print("wrote \(variants.count) sizes to \(iconset.path)")
