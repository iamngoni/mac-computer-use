import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - Screenshot
// Window captures go through ScreenCaptureKit on macOS 14+: it hands back an in-memory
// CGImage for one window, so there are no temp files, occluding windows are irrelevant,
// and a desktop-independent filter never sees our overlay — no hide/show dance needed.
// Older systems fall back to shelling out to `screencapture`, which does need it.

let screenshotMaxPNGBytes = 900_000
let screenshotMaxDimension: CGFloat = 1280
let screenshotMinScale: CGFloat = 0.25
let screenshotCaptureTimeout: TimeInterval = 8

func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }

func backingScale(forQuartzRect r: CGRect) -> CGFloat {
    let cocoa = quartzRectToCocoa(r)
    return NSScreen.screens.first(where: { $0.frame.intersects(cocoa) })?.backingScaleFactor
        ?? NSScreen.main?.backingScaleFactor ?? 1
}

@available(macOS 14.0, *)
func captureWindowSCK(_ windowId: CGWindowID, bounds: CGRect) -> CGImage? {
    let scale = backingScale(forQuartzRect: bounds)
    let w = max(1, Int((bounds.width * scale).rounded()))
    let h = max(1, Int((bounds.height * scale).rounded()))
    return blockingRun(timeout: screenshotCaptureTimeout) { () async throws -> CGImage in
        let content = try await SCShareableContent.current
        guard let win = content.windows.first(where: { $0.windowID == windowId }) else {
            throw NSError(domain: "maccu", code: 1, userInfo: [NSLocalizedDescriptionKey: "window \(windowId) not shareable"])
        }
        let cfg = SCStreamConfiguration()
        cfg.width = w; cfg.height = h
        cfg.showsCursor = false
        cfg.scalesToFit = false
        cfg.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: win)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

func captureWindowCLI(_ windowId: CGWindowID) -> CGImage? {
    OverlayController.shared.hideForCapture()
    defer { OverlayController.shared.showAfterCapture() }
    usleep(60_000)
    let tmp = NSTemporaryDirectory() + "maccu-w-\(UUID().uuidString).png"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", "\(windowId)", tmp]
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: tmp) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// Capture a specific window by id — works even when the window is occluded or in the
// background, so we can inspect an app without bringing it to the front.
func captureWindow(_ windowId: CGWindowID, bounds: CGRect) -> CGImage? {
    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess(); return nil }
    if #available(macOS 14.0, *), let img = captureWindowSCK(windowId, bounds: bounds) { return img }
    return captureWindowCLI(windowId)
}

func pngData(_ image: CGImage) -> Data? {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

func resizedImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let h = max(1, Int((CGFloat(image.height) * scale).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

// Shrink until the PNG fits the byte budget. A full-res Retina window capture is several
// MB of base64 straight into the model's context; this keeps it bounded. Returns the
// final pixel size too, so the caller can derive the true pixel<->point scale.
func boundedPNG(_ image: CGImage) -> (data: Data, width: Int, height: Int)? {
    guard image.width > 0, image.height > 0 else { return nil }
    var scale = min(1, screenshotMaxDimension / CGFloat(max(image.width, image.height)))
    if scale >= 1, let d = pngData(image), d.count <= screenshotMaxPNGBytes {
        return (d, image.width, image.height)
    }
    var best: (data: Data, width: Int, height: Int)?
    while scale >= screenshotMinScale {
        guard let r = resizedImage(image, scale: scale), let d = pngData(r) else { break }
        best = (d, r.width, r.height)
        if d.count <= screenshotMaxPNGBytes { return best }
        scale *= 0.85
    }
    if best == nil, let d = pngData(image) { best = (d, image.width, image.height) }
    return best
}
