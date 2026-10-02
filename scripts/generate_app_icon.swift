#!/usr/bin/env swift
//
// Builds the app icon in Assets/AppIcon from its Icon Composer document.
//
//   swift scripts/generate_app_icon.swift
//
// Assets/AppIcon/AppIcon.icon holds the source: one full-bleed 1024 px layer
// (Assets/art.png) made for this project. The script writes:
//
//   Assets.car         the .icon compiled by actool (Xcode 26 or later); macOS
//                      26+ masks and lights it like a native icon
//   AppIcon-1024.png   the art masked to the classic rounded square on Apple's
//                      1024 pt grid (824 pt body) with the standard shadow
//   AppIcon.icns       that master at every size from 16 pt to 512 pt @2x, for
//                      macOS 13-15

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outputDirectory = repo.appendingPathComponent("Assets/AppIcon")
let iconDocument = outputDirectory.appendingPathComponent("AppIcon.icon")
let sourceURL = iconDocument.appendingPathComponent("Assets/art.png")

let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
/// Exponent of the superellipse that approximates Apple's continuous-corner
/// icon shape.
let squircleExponent: CGFloat = 5

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func squirclePath(in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / squircleExponent)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / squircleExponent)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func makeContext(size: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("could not create a \(size) px context") }
    context.interpolationQuality = .high
    return context
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("could not write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
}

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("could not read \(sourceURL.path)")
}

// Compose the 1024 px master: shadowed body, then the clipped art, then a
// faint top-lit rim so the edge holds on light and dark backgrounds.
let master = makeContext(size: Int(canvas))
let shape = squirclePath(in: body)
master.saveGState()
master.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.32))
master.addPath(shape)
master.setFillColor(CGColor(srgbRed: 0.05, green: 0.07, blue: 0.17, alpha: 1))
master.fillPath()
master.restoreGState()

master.saveGState()
master.addPath(shape)
master.clip()
master.draw(art, in: body)
master.restoreGState()

master.saveGState()
master.addPath(shape)
master.setLineWidth(4)
master.replacePathWithStrokedPath()
master.clip()
let rim = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0.04)] as CFArray,
    locations: [0, 1]
)!
master.drawLinearGradient(rim, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
master.restoreGState()

guard let composed = master.makeImage() else { fail("could not compose the icon") }
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
writePNG(composed, to: outputDirectory.appendingPathComponent("AppIcon-1024.png"))

// Render every iconset size from the master and pack them with iconutil.
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let context = makeContext(size: pixels)
        context.draw(composed, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = context.makeImage() else { fail("could not render \(pixels) px") }
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        writePNG(image, to: iconset.appendingPathComponent(name))
    }
}

func run(_ executable: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

let icns = outputDirectory.appendingPathComponent("AppIcon.icns")
let packed = run("/usr/bin/iconutil", ["--convert", "icns", "--output", icns.path, iconset.path])
try? FileManager.default.removeItem(at: iconset)
guard packed else { fail("iconutil failed") }
print("Wrote \(icns.path)")

// Compile the Icon Composer document. actool also emits a small .icns; the
// one above is kept instead because it carries every size.
let compiled = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).actool")
try? FileManager.default.removeItem(at: compiled)
try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: compiled) }
guard run("/usr/bin/xcrun", [
    "actool", iconDocument.path,
    "--compile", compiled.path,
    "--platform", "macosx",
    "--minimum-deployment-target", "13.0",
    "--app-icon", "AppIcon",
    "--output-partial-info-plist", compiled.appendingPathComponent("partial.plist").path,
]) else { fail("actool could not compile \(iconDocument.path); it needs Xcode 26 or later") }
let car = outputDirectory.appendingPathComponent("Assets.car")
try? FileManager.default.removeItem(at: car)
try FileManager.default.copyItem(at: compiled.appendingPathComponent("Assets.car"), to: car)
print("Wrote \(car.path)")
