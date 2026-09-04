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
func quartzPointToCocoa(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryScreen().frame.height - p.y) }
func quartzRectToCocoa(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryScreen().frame.height - r.maxY, width: r.width, height: r.height) }
