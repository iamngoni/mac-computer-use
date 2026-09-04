import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - Accessibility helpers
func axCopy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var v: AnyObject?; return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}
func axElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
    guard let value = axCopy(el, attr), CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeBitCast(value, to: AXUIElement.self)
}
func axStr(_ el: AXUIElement, _ attr: String) -> String? { axCopy(el, attr) as? String }
func axArr(_ el: AXUIElement, _ attr: String) -> [AXUIElement] { (axCopy(el, attr) as? [AXUIElement]) ?? [] }
func axFrame(_ el: AXUIElement) -> CGRect? {
    guard let posV = axCopy(el, "AXPosition"), let sizeV = axCopy(el, "AXSize") else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    let pok = AXValueGetValue(posV as! AXValue, .cgPoint, &p)
    let sok = AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
    return (pok && sok) ? CGRect(origin: p, size: s) : nil
}
func axActions(_ el: AXUIElement) -> [String] {
    var names: CFArray?; return AXUIElementCopyActionNames(el, &names) == .success ? ((names as? [String]) ?? []) : []
}
