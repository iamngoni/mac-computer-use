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
