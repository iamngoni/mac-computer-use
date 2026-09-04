import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - Snapshot context (screenshot pixel space <-> screen points)
// The screenshot handed to the model is a *window crop*, possibly downscaled, while AX
// frames are global screen points. Every coordinate we print or accept is in screenshot
// pixels; this is the only place that translation lives.
struct SnapshotContext {
    let pid: pid_t
    let appLabel: String
    let windowId: CGWindowID
    let windowBounds: CGRect   // Quartz screen points
    let pixelScale: CGFloat    // screenshot pixels per screen point
    let pixelWidth: CGFloat
    let pixelHeight: CGFloat
}
var lastSnapshot: SnapshotContext?

func pixelToScreen(_ p: CGPoint, _ ctx: SnapshotContext) -> CGPoint {
    CGPoint(x: ctx.windowBounds.minX + p.x / ctx.pixelScale,
            y: ctx.windowBounds.minY + p.y / ctx.pixelScale)
}
func screenToPixel(_ p: CGPoint, _ ctx: SnapshotContext) -> CGPoint {
    CGPoint(x: (p.x - ctx.windowBounds.minX) * ctx.pixelScale,
            y: (p.y - ctx.windowBounds.minY) * ctx.pixelScale)
}

func inputPoint(x: Double, y: Double, context: SnapshotContext) -> CGPoint? {
    guard x.isFinite, y.isFinite,
          x >= 0, y >= 0,
          x < context.pixelWidth, y < context.pixelHeight else {
        return nil
    }
    return pixelToScreen(CGPoint(x: x, y: y), context)
}

func inputScreenPointIsAuthorized(_ point: CGPoint, context: SnapshotContext) -> Bool {
    let pixel = screenToPixel(point, context)
    return pixel.x.isFinite && pixel.y.isFinite
        && pixel.x >= 0 && pixel.y >= 0
        && pixel.x < context.pixelWidth && pixel.y < context.pixelHeight
}

func authorizedSnapshot(forPid pid: pid_t) -> SnapshotContext? {
    guard let snapshot = lastSnapshot, snapshot.pid == pid,
          let candidate = windowCandidates(forPid: pid).first(where: {
              $0.id == snapshot.windowId
          }),
          abs(candidate.bounds.minX - snapshot.windowBounds.minX) <= 2,
          abs(candidate.bounds.minY - snapshot.windowBounds.minY) <= 2,
          abs(candidate.bounds.width - snapshot.windowBounds.width) <= 2,
          abs(candidate.bounds.height - snapshot.windowBounds.height) <= 2,
          accessibilityWindow(
              matching: candidate,
              in: AXUIElementCreateApplication(pid)
          ) != nil else {
        return nil
    }
    return snapshot
}
