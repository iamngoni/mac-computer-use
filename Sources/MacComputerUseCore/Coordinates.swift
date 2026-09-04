import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - Coordinate conversion (Quartz top-left  <->  Cocoa bottom-left)
func primaryScreen() -> NSScreen { NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first ?? NSScreen.main! }
func quartzPointToCocoa(_ point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
    CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
}
func quartzPointToCocoa(_ point: CGPoint) -> CGPoint {
    quartzPointToCocoa(point, primaryDisplayHeight: primaryScreen().frame.height)
}
func quartzRectToCocoa(_ rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
    CGRect(
        x: rect.minX,
        y: primaryDisplayHeight - rect.maxY,
        width: rect.width,
        height: rect.height
    )
}
func quartzRectToCocoa(_ rect: CGRect) -> CGRect {
    quartzRectToCocoa(rect, primaryDisplayHeight: primaryScreen().frame.height)
}
