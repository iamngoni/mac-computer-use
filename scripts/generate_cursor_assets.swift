#!/usr/bin/env swift
//
// Generates the automation cursor art in Assets/VirtualCursor.
//
//   swift scripts/generate_cursor_assets.swift [output-directory]
//
// The pointer is a compact, rounded, stemless arrowhead with a cyan-to-lavender
// gradient and a white border, drawn as vector geometry so the 1x/2x/3x exports
// stay crisp. It is original artwork authored in this repository.
//
// Writes cursor-pointer{,@2x,@3x}.png and cursor-pulse{,@2x,@3x}.png, plus a
// high-resolution cursor-pointer-master.png (source art, not bundled at runtime).
//
// Keep `canvas` and `hotspot` in sync with AutomationCursorAssets in
// Sources/MacComputerUseCore/Overlay.swift; the script prints the hotspot.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry (points, origin top-left)

let canvas = CGSize(width: 28, height: 28)
/// Where the sharp apex of the arrow sits inside the canvas. The remaining
/// margin leaves room for the border, the baked shadow and the runtime glow.
let apexOrigin = CGPoint(x: 5, y: 5)
let borderWidth: CGFloat = 0.9
/// Overall size knob for the arrow; the margin around it stays fixed.
let arrowScale: CGFloat = 1.12

struct Corner {
    let point: CGPoint
    let radius: CGFloat
}

/// Arrow outline relative to the apex, before corner rounding. The short
/// notch replaces the classic stem so the pointer stays compact.
let corners: [Corner] = [
    Corner(point: CGPoint(x: 0.0, y: 0.0), radius: 1.7),     // apex (hotspot)
    Corner(point: CGPoint(x: 15.6, y: 4.2), radius: 1.7),    // right wing
    Corner(point: CGPoint(x: 9.2, y: 8.2), radius: 0.9),     // notch (concave)
    Corner(point: CGPoint(x: 5.6, y: 14.8), radius: 1.7),    // tail
]

func outline() -> CGPath {
    let points = corners.map {
        CGPoint(x: apexOrigin.x + $0.point.x * arrowScale, y: apexOrigin.y + $0.point.y * arrowScale)
    }
    let path = CGMutablePath()
    let last = points[points.count - 1]
    path.move(to: CGPoint(x: (last.x + points[0].x) / 2, y: (last.y + points[0].y) / 2))
    for index in points.indices {
        path.addArc(
            tangent1End: points[index],
            tangent2End: points[(index + 1) % points.count],
            radius: corners[index].radius * arrowScale
        )
    }
    path.closeSubpath()
    return path
}

/// The visible apex after rounding: the arc's nearest point to the sharp
/// vertex, which sits `r / sin(theta / 2) - r` along the bisector.
func hotspot() -> CGPoint {
    let apex = corners[0].point
    let toRight = CGVector(dx: corners[1].point.x - apex.x, dy: corners[1].point.y - apex.y)
    let toTail = CGVector(dx: corners[3].point.x - apex.x, dy: corners[3].point.y - apex.y)
    let lengthRight = hypot(toRight.dx, toRight.dy)
    let lengthTail = hypot(toTail.dx, toTail.dy)
    let unitRight = CGVector(dx: toRight.dx / lengthRight, dy: toRight.dy / lengthRight)
    let unitTail = CGVector(dx: toTail.dx / lengthTail, dy: toTail.dy / lengthTail)
    let halfAngle = acos(unitRight.dx * unitTail.dx + unitRight.dy * unitTail.dy) / 2
    let radius = corners[0].radius * arrowScale
    let inset = radius / sin(halfAngle) - radius
    var bisector = CGVector(dx: unitRight.dx + unitTail.dx, dy: unitRight.dy + unitTail.dy)
    let bisectorLength = hypot(bisector.dx, bisector.dy)
    bisector = CGVector(dx: bisector.dx / bisectorLength, dy: bisector.dy / bisectorLength)
    return CGPoint(
        x: apexOrigin.x + apex.x * arrowScale + bisector.dx * inset,
        y: apexOrigin.y + apex.y * arrowScale + bisector.dy * inset
    )
}

// MARK: - Rendering

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(scale: CGFloat) -> CGContext {
    let width = Int((canvas.width * scale).rounded())
    let height = Int((canvas.height * scale).rounded())
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    // Draw in points with a top-left origin.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: scale, y: -scale)
    return context
}

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            alpha,
        ]
    )!
}

func renderPointer(scale: CGFloat) -> CGImage {
    let context = makeContext(scale: scale)
    let path = outline()

    // White border with a soft baked shadow so the pointer still reads on
    // white and very light backgrounds. Shadow parameters are in device
    // pixels, not points, so they scale by hand.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -0.7 * scale),
        blur: 1.5 * scale,
        color: CGColor(colorSpace: colorSpace, components: [0.04, 0.05, 0.16, 0.30])!
    )
    context.setFillColor(rgb(0xFFFFFF))
    context.setStrokeColor(rgb(0xFFFFFF))
    context.setLineWidth(borderWidth * 2)
    context.setLineJoin(.round)
    context.addPath(path)
    context.drawPath(using: .fillStroke)
    context.restoreGState()

    // Gradient body, clipped to the arrow.
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgb(0x00C6FF), rgb(0x4E8DFF), rgb(0xA98BFF)] as CFArray,
        locations: [0, 0.5, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: apexOrigin.x, y: apexOrigin.y),
        end: CGPoint(x: apexOrigin.x + 15.6 * arrowScale, y: apexOrigin.y + 14.8 * arrowScale),
        options: [.drawsAfterEndLocation]
    )
    // A faint top-edge sheen keeps the small body from looking flat.
    let sheen = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgb(0xFFFFFF, alpha: 0.26), rgb(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: apexOrigin.x + 6, y: apexOrigin.y),
        end: CGPoint(x: apexOrigin.x + 6, y: apexOrigin.y + 7),
        options: []
    )
    context.restoreGState()

    return context.makeImage()!
}

/// Retained only so the asset loader keeps finding its pair of images; the
/// renderer no longer draws it.
func renderPulse(scale: CGFloat) -> CGImage {
    let context = makeContext(scale: scale)
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [rgb(0x00C2FF, alpha: 0.30), rgb(0x00C2FF, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
    context.drawRadialGradient(
        gradient,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: canvas.width / 2,
        options: []
    )
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("cannot create \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("cannot write \(url.path)")
    }
}

// MARK: - Main

let scriptURL = URL(fileURLWithPath: #filePath)
let outputDirectory: URL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : scriptURL.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Assets/VirtualCursor", isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for (suffix, scale) in [("", CGFloat(1)), ("@2x", 2), ("@3x", 3)] {
    writePNG(renderPointer(scale: scale), to: outputDirectory.appendingPathComponent("cursor-pointer\(suffix).png"))
    writePNG(renderPulse(scale: scale), to: outputDirectory.appendingPathComponent("cursor-pulse\(suffix).png"))
}
writePNG(renderPointer(scale: 40), to: outputDirectory.appendingPathComponent("cursor-pointer-master.png"))

let spot = hotspot()
print("canvas: \(canvas.width) x \(canvas.height) pt")
print(String(format: "hotspot: (%.2f, %.2f) pt from the top-left", spot.x, spot.y))
print("wrote cursor art to \(outputDirectory.path)")
