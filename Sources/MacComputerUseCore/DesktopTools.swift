import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Darwin

// MARK: - Desktop snapshots

/// Desktop coordinates are deliberately independent from app snapshots. A token
/// identifies both the display and the exact display geometry used to produce the
/// screenshot, so a stale or moved display can never receive a global event.
struct DesktopElement {
    let index: Int
    let role: String
    let label: String
    let ownerPID: pid_t
    let frame: CGRect
    let axElement: AXUIElement
}

struct DesktopSnapshot {
    let id: String
    let displayID: CGDirectDisplayID
    let displayBounds: CGRect
    let pixelScale: CGFloat
    let pixelWidth: CGFloat
    let pixelHeight: CGFloat
    let elements: [DesktopElement]
}

var lastDesktopSnapshot: DesktopSnapshot?

func activeDisplayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
    guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
    return Array(displays.prefix(Int(count)))
}

func displayBounds(_ displayID: CGDirectDisplayID) -> CGRect? {
    guard activeDisplayIDs().contains(displayID), CGDisplayIsOnline(displayID) != 0 else { return nil }
    let bounds = CGDisplayBounds(displayID)
    return bounds.width > 0 && bounds.height > 0 ? bounds : nil
}

@available(macOS 14.0, *)
func captureDesktopDisplaySCK(_ displayID: CGDirectDisplayID) -> CGImage? {
    let width = max(1, CGDisplayPixelsWide(displayID))
    let height = max(1, CGDisplayPixelsHigh(displayID))
    return blockingRun(timeout: screenshotCaptureTimeout) { () async throws -> CGImage in
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(
                domain: "maccu.desktop",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Display \(displayID) is not shareable."]
            )
        }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = false
        configuration.scalesToFit = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}

func captureDesktopDisplay(_ displayID: CGDirectDisplayID) -> CGImage? {
    guard #available(macOS 14.0, *) else { return nil }
    return captureDesktopDisplaySCK(displayID)
}

func desktopPoint(x: Double, y: Double, snapshot: DesktopSnapshot) -> CGPoint? {
    guard x.isFinite, y.isFinite,
          x >= 0, y >= 0,
          x < snapshot.pixelWidth, y < snapshot.pixelHeight else { return nil }
    let point = CGPoint(
        x: snapshot.displayBounds.minX + x / snapshot.pixelScale,
        y: snapshot.displayBounds.minY + y / snapshot.pixelScale
    )
    guard snapshot.displayBounds.contains(point) else { return nil }
    return point
}

func desktopSnapshotIsCurrent(_ snapshot: DesktopSnapshot) -> Bool {
    guard let bounds = displayBounds(snapshot.displayID) else { return false }
    return abs(bounds.minX - snapshot.displayBounds.minX) <= 1
        && abs(bounds.minY - snapshot.displayBounds.minY) <= 1
        && abs(bounds.width - snapshot.displayBounds.width) <= 1
        && abs(bounds.height - snapshot.displayBounds.height) <= 1
}

func desktopSnapshot(for token: String) -> DesktopSnapshot? {
    guard let snapshot = lastDesktopSnapshot,
          snapshot.id == token,
          desktopSnapshotIsCurrent(snapshot) else { return nil }
    return snapshot
}

private func desktopAXVisible(_ element: AXUIElement) -> Bool {
    if let visible = axCopy(element, "AXIsVisible") as? Bool, !visible { return false }
    guard let frame = axFrame(element), frame.width > 0, frame.height > 0 else { return false }
    return true
}

private func desktopAXLabel(_ element: AXUIElement) -> String {
    axStr(element, "AXTitle")
        ?? axStr(element, "AXDescription")
        ?? axStr(element, "AXValue")
        ?? axStr(element, "AXRoleDescription")
        ?? ""
}

private func desktopElementIsCurrent(_ element: DesktopElement, in snapshot: DesktopSnapshot) -> Bool {
    guard kill(element.ownerPID, 0) == 0 || errno == EPERM,
          desktopAXVisible(element.axElement),
          let frame = axFrame(element.axElement),
          frame.intersects(snapshot.displayBounds) else {
        return false
    }
    return abs(frame.minX - element.frame.minX) <= 2
        && abs(frame.minY - element.frame.minY) <= 2
        && abs(frame.width - element.frame.width) <= 2
        && abs(frame.height - element.frame.height) <= 2
}

private let desktopInteractiveRoles: Set<String> = [
    "AXMenuBarItem", "AXMenuItem", "AXMenuButton", "AXButton", "AXCheckBox", "AXPopUpButton",
    "AXComboBox", "AXRadioButton", "AXSlider", "AXTabButton",
]

private func desktopAXRoots() -> [(AXUIElement, pid_t)] {
    guard AXIsProcessTrusted() else { return [] }
    var roots: [(AXUIElement, pid_t)] = []
    var seen = Set<String>()

    func add(_ root: AXUIElement, ownerPID: pid_t) {
        let key = "\(ownerPID)-\(String(describing: root))"
        if seen.insert(key).inserted { roots.append((root, ownerPID)) }
    }

    if let frontmost = NSWorkspace.shared.frontmostApplication {
        let pid = frontmost.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        if let menuBar = axElement(app, "AXMenuBar") { add(menuBar, ownerPID: pid) }
        if let extras = axElement(app, "AXExtrasMenuBar") { add(extras, ownerPID: pid) }
    }

    // Menu extras can be owned by SystemUIServer, ControlCenter, or a third-party
    // accessory app such as Montr. Include every live app's menu roots; discovery
    // remains bounded later and normal app-scoped resolution is unchanged.
    for application in NSWorkspace.shared.runningApplications where processIsAlive(application.processIdentifier) {
        let pid = application.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        for attribute in ["AXMenuBar", "AXExtrasMenuBar"] {
            if let root = axElement(app, attribute) { add(root, ownerPID: pid) }
        }
    }
    return roots
}

private func collectDesktopElements(
    for displayBounds: CGRect,
    maxElements: Int = 256
) -> [DesktopElement] {
    var elements: [DesktopElement] = []
    var visited = Set<String>()

    func walk(_ element: AXUIElement, ownerPID: pid_t, depth: Int) {
        guard elements.count < maxElements, depth <= 12, desktopAXVisible(element) else { return }
        guard let frame = axFrame(element), frame.intersects(displayBounds) else { return }
        let role = axStr(element, "AXRole") ?? "AXUnknown"
        let actions = axActions(element)
        if desktopInteractiveRoles.contains(role), actions.contains("AXPress") || role == "AXMenuButton" {
            let identity = "\(ownerPID)|\(role)|\(frame.minX)|\(frame.minY)|\(desktopAXLabel(element))"
            if visited.insert(identity).inserted {
                elements.append(
                    DesktopElement(
                        index: elements.count,
                        role: role,
                        label: desktopAXLabel(element),
                        ownerPID: ownerPID,
                        frame: frame,
                        axElement: element
                    )
                )
            }
        }
        for child in axArr(element, "AXChildren") {
            walk(child, ownerPID: ownerPID, depth: depth + 1)
            if elements.count >= maxElements { break }
        }
    }

    for (root, ownerPID) in desktopAXRoots() {
        walk(root, ownerPID: ownerPID, depth: 0)
        if elements.count >= maxElements { break }
    }
    return elements
}

private func desktopJSONFrame(_ frame: CGRect) -> [String: Double] {
    [
        "x": Double(frame.minX),
        "y": Double(frame.minY),
        "width": Double(frame.width),
        "height": Double(frame.height),
    ]
}

private func desktopSnapshotPayload(_ snapshot: DesktopSnapshot) -> [String: Any] {
    [
        "snapshot_id": snapshot.id,
        "display_id": Int(snapshot.displayID),
        "display_bounds": desktopJSONFrame(snapshot.displayBounds),
        "pixel_width": Int(snapshot.pixelWidth),
        "pixel_height": Int(snapshot.pixelHeight),
        "elements": snapshot.elements.map {
            [
                "element_index": $0.index,
                "role": $0.role,
                "label": $0.label,
                "owner_pid": Int($0.ownerPID),
                "frame": desktopJSONFrame($0.frame),
            ] as [String: Any]
        },
    ]
}

private func desktopSnapshotText(_ snapshot: DesktopSnapshot) -> String {
    let lines = snapshot.elements.map {
        let label = $0.label.isEmpty ? "" : " \"\($0.label)\""
        return "[\($0.index)] \($0.role)\(label) owner_pid=\($0.ownerPID) frame=(\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width)),\(Int($0.frame.height)))"
    }
    let header = "Desktop snapshot token: \(snapshot.id)\nDisplay ID: \(snapshot.displayID)\nScreenshot: \(Int(snapshot.pixelWidth))x\(Int(snapshot.pixelHeight)) px. x,y for desktop_click are screenshot pixels relative to this display.\nIndexed visible menu/status elements (\(snapshot.elements.count)):"
    return header + (lines.isEmpty ? "\n(none; Accessibility permission may be required)" : "\n" + lines.joined(separator: "\n"))
}

func toolGetDesktopState(_ args: [String: Any]) -> [String: Any] {
    guard #available(macOS 14.0, *) else {
        return toolText("get_desktop_state requires macOS 14 or later for desktop capture.", isError: true)
    }
    let displayID: CGDirectDisplayID
    if args["display_id"] != nil {
        guard let value = strictJSONInteger(args["display_id"]), value > 0,
              let parsed = CGDirectDisplayID(exactly: value) else {
            return toolText("display_id must be a positive integer display ID.", isError: true)
        }
        displayID = parsed
    } else {
        displayID = CGMainDisplayID()
    }
    guard let bounds = displayBounds(displayID) else {
        return toolText("Display \(displayID) is not active. Call get_desktop_state without display_id or use an active display ID.", isError: true)
    }
    guard screenRecordingGranted() else {
        return toolText("Desktop screenshot unavailable: enable mac-computer-use in System Settings > Privacy & Security > Screen Recording.", isError: true)
    }
    guard let image = captureDesktopDisplay(displayID), let png = boundedPNG(image) else {
        return toolText("Desktop screenshot could not be captured for display \(displayID).", isError: true)
    }

    let snapshot = DesktopSnapshot(
        id: "desktop-\(UUID().uuidString)",
        displayID: displayID,
        displayBounds: bounds,
        pixelScale: CGFloat(png.width) / bounds.width,
        pixelWidth: CGFloat(png.width),
        pixelHeight: CGFloat(png.height),
        elements: collectDesktopElements(for: bounds)
    )
    lastDesktopSnapshot = snapshot
    let payload = desktopSnapshotPayload(snapshot)
    let content: [[String: Any]] = [
        ["type": "image", "data": png.data.base64EncodedString(), "mimeType": "image/png"],
        ["type": "text", "text": desktopSnapshotText(snapshot)],
    ]
    return ["content": content, "isError": false, "structuredContent": payload]
}

func desktopActionShapeIsValid(_ args: [String: Any]) -> Bool {
    let hasIndex = args.keys.contains("element_index")
    let hasX = args.keys.contains("x")
    let hasY = args.keys.contains("y")
    return hasIndex ? (!hasX && !hasY) : (hasX && hasY)
}

private func desktopClickPoint(
    args: [String: Any],
    snapshot: DesktopSnapshot
) -> (point: CGPoint, element: DesktopElement?)? {
    if args.keys.contains("element_index") {
        guard let index = strictJSONInteger(args["element_index"]), index >= 0,
              let element = snapshot.elements.first(where: { $0.index == index }) else { return nil }
        return (point: CGPoint(x: element.frame.midX, y: element.frame.midY), element: element)
    }
    guard let x = strictJSONDouble(args["x"]), let y = strictJSONDouble(args["y"]),
          let point = desktopPoint(x: x, y: y, snapshot: snapshot) else { return nil }
    return (point: point, element: nil)
}

func toolDesktopClick(_ args: [String: Any]) -> [String: Any] {
    guard strictJSONBoolean(args["allow_global_input"]) == true else {
        return toolText("desktop_click requires allow_global_input: true.", isError: true)
    }
    guard let token = args["snapshot_id"] as? String, !token.isEmpty else {
        return toolText("desktop_click needs a snapshot_id from get_desktop_state.", isError: true)
    }
    guard desktopActionShapeIsValid(args) else {
        return toolText("desktop_click requires either element_index or both x and y, but not both.", isError: true)
    }
    let count: Int
    if args["click_count"] != nil {
        guard let value = strictJSONInteger(args["click_count"]), (1...3).contains(value) else {
            return toolText("click_count must be an integer between 1 and 3.", isError: true)
        }
        count = value
    } else { count = 1 }
    let buttonName: String
    if args["mouse_button"] != nil {
        guard let value = args["mouse_button"] as? String,
              ["left", "right", "middle"].contains(value) else {
            return toolText("mouse_button must be left, right, or middle.", isError: true)
        }
        buttonName = value
    } else { buttonName = "left" }
    guard let snapshot = desktopSnapshot(for: token) else {
        return toolText("desktop_click needs a fresh get_desktop_state snapshot; the token is stale or unknown.", isError: true)
    }
    guard let target = desktopClickPoint(args: args, snapshot: snapshot) else {
        return toolText("desktop_click target must be a visible indexed element or finite x,y inside the display screenshot.", isError: true)
    }
    guard snapshot.displayBounds.contains(target.point) else {
        return toolText("desktop_click target is outside the captured display.", isError: true)
    }
    let button: CGMouseButton = buttonName == "right" ? .right : (buttonName == "middle" ? .center : .left)
    return controlled("Clicking desktop", appName: "Desktop", targetQuartz: target.element?.frame) {
        guard let lease = GlobalInputLease.acquire() else {
            return toolText("Another desktop action is using global input; retry when it finishes.", isError: true)
        }
        defer { lease.release() }

        if let element = target.element, !desktopElementIsCurrent(element, in: snapshot) {
            return toolText("Desktop element [\(element.index)] is stale; run get_desktop_state again.", isError: true)
        }
        if let element = target.element, button == .left, count == 1,
           axActions(element.axElement).contains("AXPress"),
           AXUIElementPerformAction(element.axElement, "AXPress" as CFString) == .success {
            return toolText("Pressed desktop element [\(element.index)] via AXPress (owner_pid=\(element.ownerPID)).")
        }
        for clickIndex in 1...count {
            if cancelFlag.value { return toolText("Cancelled (Esc).") }
            OverlayController.shared.moveCursorQuartz(target.point)
            OverlayController.shared.flashClickQuartz(target.point)
            guard desktopMouseClick(target.point, button: button, clickState: clickIndex) else {
                return toolText("Desktop click could not be delivered.", isError: true)
            }
            usleep(40_000)
        }
        return toolText("Clicked desktop \(buttonName) x\(count) at screenshot pixel (\(Int((target.point.x - snapshot.displayBounds.minX) * snapshot.pixelScale)),\(Int((target.point.y - snapshot.displayBounds.minY) * snapshot.pixelScale))).")
    }
}

func toolDesktopPressKey(_ args: [String: Any]) -> [String: Any] {
    guard strictJSONBoolean(args["allow_global_input"]) == true else {
        return toolText("desktop_press_key requires allow_global_input: true.", isError: true)
    }
    guard let token = args["snapshot_id"] as? String, !token.isEmpty else {
        return toolText("desktop_press_key needs a snapshot_id from get_desktop_state.", isError: true)
    }
    guard let key = args["key"] as? String, !key.isEmpty else {
        return toolText("desktop_press_key needs a non-empty key.", isError: true)
    }
    guard desktopSnapshot(for: token) != nil else {
        return toolText("desktop_press_key needs a fresh get_desktop_state snapshot; the token is stale or unknown.", isError: true)
    }
    guard desktopKeySpecIsKnown(key) else {
        return toolText("Unknown key: \(key).", isError: true)
    }
    return controlled("Pressing desktop key", appName: "Desktop") {
        guard let lease = GlobalInputLease.acquire() else {
            return toolText("Another desktop action is using global input; retry when it finishes.", isError: true)
        }
        defer { lease.release() }
        guard desktopPressKeyCombo(key) else {
            return toolText("Desktop key could not be delivered.", isError: true)
        }
        return toolText("Pressed desktop key \(key).")
    }
}
