import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - SkyLight background click (sky_click)
// Chromium, Electron and Catalyst apps ignore a plain CGEvent.postToPid for their web
// content: they hit-test against WindowServer's idea of the active window, so a
// background click at coordinates lands nowhere. The private SkyLight path below posts a
// click those surfaces accept, without activating the target or disturbing the real
// frontmost app.
//
// The event recipe is derived from the MIT-licensed Cua Driver (trycua/cua), cross-checked
// against yabai's SkyLight dynamic-loading practice; see THIRD_PARTY_NOTICES.md. This is
// undocumented ABI, so every symbol is probed at runtime and we fail closed if any is
// missing rather than half-posting a sequence. All of it is confined to this section so a
// future macOS change has exactly one place to review.

// Focus/defocus record understood by SLPSPostEventRecordTo.
func skyActivationRecord(windowId: CGWindowID, focused: Bool) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 0xF8)
    r[0x04] = 0xF8
    r[0x08] = 0x0D
    r[0x3C] = UInt8(truncatingIfNeeded: windowId)
    r[0x3D] = UInt8(truncatingIfNeeded: windowId >> 8)
    r[0x3E] = UInt8(truncatingIfNeeded: windowId >> 16)
    r[0x3F] = UInt8(truncatingIfNeeded: windowId >> 24)
    r[0x8A] = focused ? 0x01 : 0x02
    return r
}

final class SkyLight: @unchecked Sendable {
    static let shared = SkyLight()

    private typealias PostToPidFn = @convention(c) (pid_t, UnsafeMutableRawPointer?) -> Void
    private typealias SetIntFieldFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, Int64) -> Void
    // Cua models this as (CGEventRef, double, double); the scalar form avoids relying on
    // Swift's aggregate CGPoint calling convention.
    private typealias SetWindowLocFn = @convention(c) (UnsafeMutableRawPointer?, Double, Double) -> Void
    private typealias PostRecordFn = @convention(c) (UnsafeRawPointer?, UnsafePointer<UInt8>?) -> Int32
    private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutableRawPointer?) -> Int32

    private let postToPidFn: PostToPidFn?
    private let setIntFieldFn: SetIntFieldFn?
    private let setWindowLocFn: SetWindowLocFn?
    private let postRecordFn: PostRecordFn?
    private let getPSNFn: GetPSNFn?
    let missing: [String]

    var available: Bool { missing.isEmpty }
    var unavailableReason: String {
        missing.isEmpty ? "available" : "missing private symbols: \(missing.joined(separator: ", "))"
    }

    private init() {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_GLOBAL)
        let appSvc = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY | RTLD_GLOBAL)
        func sym<T>(_ h: UnsafeMutableRawPointer?, _ n: String) -> T? {
            guard let h = h, let p = dlsym(h, n) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        postToPidFn = sym(sky, "SLEventPostToPid")
        setIntFieldFn = sym(sky, "SLEventSetIntegerValueField")
        setWindowLocFn = sym(sky, "CGEventSetWindowLocation")
        postRecordFn = sym(sky, "SLPSPostEventRecordTo")
        getPSNFn = sym(appSvc, "GetProcessForPID")

        var m: [String] = []
        if postToPidFn == nil { m.append("SLEventPostToPid") }
        if setIntFieldFn == nil { m.append("SLEventSetIntegerValueField") }
        if setWindowLocFn == nil { m.append("CGEventSetWindowLocation") }
        if postRecordFn == nil { m.append("SLPSPostEventRecordTo") }
        if getPSNFn == nil { m.append("GetProcessForPID") }
        missing = m
    }

    private func ptr(_ e: CGEvent) -> UnsafeMutableRawPointer { Unmanaged.passUnretained(e).toOpaque() }

    func postToPid(_ e: CGEvent, pid: pid_t) { postToPidFn?(pid, ptr(e)) }
    func setField(_ e: CGEvent, _ field: UInt32, _ value: Int64) { setIntFieldFn?(ptr(e), field, value) }
    func setWindowLocation(_ e: CGEvent, _ p: CGPoint) { setWindowLocFn?(ptr(e), p.x, p.y) }

    func psn(forPid pid: pid_t) -> [UInt8]? {
        guard let getPSNFn = getPSNFn else { return nil }
        var out = [UInt8](repeating: 0, count: 8)
        let status = out.withUnsafeMutableBytes { getPSNFn(pid, $0.baseAddress) }
        return status == 0 ? out : nil
    }

    // Only ever sent to the TARGET. We never defocus the real frontmost app: that leaves
    // WindowServer's z-order alone but still fires AppKit resignActive/resignKey and
    // destroys the user's first responder. Synthetic target focus alone is enough.
    func postActivation(psn: [UInt8], windowId: CGWindowID, focused: Bool) -> Bool {
        guard let postRecordFn = postRecordFn else { return false }
        let record = skyActivationRecord(windowId: windowId, focused: focused)
        let status = psn.withUnsafeBytes { p in
            record.withUnsafeBufferPointer { r in postRecordFn(p.baseAddress, r.baseAddress) }
        }
        return status == 0
    }
}

// Raw private CGEvent fields used by the Chromium-compatible path.
private enum SkyField {
    static let gesturePhase: UInt32 = 0
    static let clickState: UInt32 = 1
    static let buttonNumber: UInt32 = 3
    static let subtype: UInt32 = 7
    static let targetPID: UInt32 = 40
    static let windowNumber: UInt32 = 51
    static let clickGroupID: UInt32 = 58
    static let windowUnderPointer: UInt32 = 91
    static let handlingWindowUnderPointer: UInt32 = 92
}

struct SkyStep { let type: CGEventType; let onTarget: Bool; let clickState: Int64; let phase: Int64; let delay: TimeInterval }

// Fixed dispatch policy, not a retry ladder: a move, an off-window primer down/up that
// gets the renderer's attention, then the real click at phase 3.
func skyClickRecipe(clickCount: Int) -> [SkyStep] {
    var steps: [SkyStep] = [
        SkyStep(type: .mouseMoved,     onTarget: true,  clickState: 0, phase: 2, delay: 0.015),
        SkyStep(type: .leftMouseDown,  onTarget: false, clickState: 1, phase: 1, delay: 0.001),
        SkyStep(type: .leftMouseUp,    onTarget: false, clickState: 1, phase: 2, delay: 0.100),
    ]
    for i in 1...clickCount {
        steps.append(SkyStep(type: .leftMouseDown, onTarget: true, clickState: Int64(i), phase: 3, delay: 0.001))
        steps.append(SkyStep(type: .leftMouseUp,   onTarget: true, clickState: Int64(i), phase: 3, delay: i < clickCount ? 0.080 : 0))
    }
    return steps
}

let skyClickLock = NSLock()

func skyClick(screenPoint: CGPoint, ctx: SnapshotContext, clickCount: Int) -> String? {
    let spi = SkyLight.shared
    guard spi.available else { return "sky_click unavailable: \(spi.unavailableReason)" }
    guard (1...2).contains(clickCount) else { return "sky_click supports click_count 1 or 2." }

    let bounds = ctx.windowBounds
    let windowPoint = CGPoint(x: screenPoint.x - bounds.minX, y: screenPoint.y - bounds.minY)
    guard bounds.width > 0, bounds.height > 0,
          windowPoint.x >= 0, windowPoint.y >= 0,
          windowPoint.x <= bounds.width, windowPoint.y <= bounds.height else {
        return "sky_click target is outside the snapshot window bounds."
    }
    guard inputScreenPointIsCurrentlyAuthorized(screenPoint, context: ctx) else {
        return "sky_click target window is stale, off-screen, or no longer owned by \(ctx.appLabel). Run get_app_state again."
    }
    guard let source = CGEventSource(stateID: .hidSystemState) else { return "sky_click could not create an event source." }

    skyClickLock.lock()
    defer { skyClickLock.unlock() }

    let groupId = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)
    let primer = CGPoint(x: -1, y: -1)

    // Give the target a synthetic active state only if it isn't already frontmost.
    var focusPSN: [UInt8]?
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != ctx.pid {
        guard let psn = spi.psn(forPid: ctx.pid) else { return "sky_click could not resolve pid \(ctx.pid) to a PSN." }
        guard spi.postActivation(psn: psn, windowId: ctx.windowId, focused: true) else {
            return "sky_click synthetic target-focus event failed."
        }
        focusPSN = psn
        Thread.sleep(forTimeInterval: 0.040)
    }

    var deliveryError: String?
    for step in skyClickRecipe(clickCount: clickCount) {
        let pt = step.onTarget ? screenPoint : primer
        let local = step.onTarget ? windowPoint : primer
        if step.onTarget, step.type == .leftMouseDown,
           !inputScreenPointIsCurrentlyAuthorized(screenPoint, context: ctx) {
            deliveryError = "sky_click snapshot became stale before delivery. Run get_app_state again."
            break
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: step.type, mouseCursorPosition: pt, mouseButton: .left) else { continue }
        spi.setField(e, SkyField.gesturePhase, step.phase)
        spi.setField(e, SkyField.clickState, step.clickState)
        spi.setField(e, SkyField.buttonNumber, 0)
        spi.setField(e, SkyField.subtype, 3)
        spi.setField(e, SkyField.targetPID, Int64(ctx.pid))
        spi.setField(e, SkyField.windowNumber, Int64(ctx.windowId))
        spi.setField(e, SkyField.clickGroupID, groupId)
        spi.setField(e, SkyField.windowUnderPointer, Int64(ctx.windowId))
        spi.setField(e, SkyField.handlingWindowUnderPointer, Int64(ctx.windowId))
        spi.setWindowLocation(e, local)
        // Both channels deliberately: SkyLight reaches Chromium/Catalyst, the public path
        // keeps AppKit compatibility.
        spi.postToPid(e, pid: ctx.pid)
        e.postToPid(ctx.pid)
        if step.delay > 0 { Thread.sleep(forTimeInterval: step.delay) }
    }

    if let psn = focusPSN {
        // SkyLight delivery is async; hold the synthetic active state long enough for
        // Chromium's renderer hop to consume the final mouse-up.
        Thread.sleep(forTimeInterval: 0.100)
        _ = spi.postActivation(psn: psn, windowId: ctx.windowId, focused: false)
        Thread.sleep(forTimeInterval: 0.040)
    }
    return deliveryError
}

func skyScroll(screenPoint: CGPoint, ctx: SnapshotContext, dx: Int32, dy: Int32) -> String? {
    let spi = SkyLight.shared
    guard spi.available else { return "background scroll unavailable: \(spi.unavailableReason)" }
    guard inputScreenPointIsCurrentlyAuthorized(screenPoint, context: ctx) else {
        return "Background scroll target is stale, off-screen, or no longer owned by \(ctx.appLabel). Run get_app_state again."
    }
    let bounds = ctx.windowBounds
    let windowPoint = CGPoint(x: screenPoint.x - bounds.minX, y: screenPoint.y - bounds.minY)
    guard windowPoint.x >= 0, windowPoint.y >= 0,
          windowPoint.x <= bounds.width, windowPoint.y <= bounds.height else {
        return "Background scroll target is outside the snapshot window bounds."
    }
    guard let source = CGEventSource(stateID: .hidSystemState),
          let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
          ) else {
        return "Background scroll could not create an event."
    }

    skyClickLock.lock()
    defer { skyClickLock.unlock() }

    var focusPSN: [UInt8]?
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != ctx.pid {
        guard let psn = spi.psn(forPid: ctx.pid) else {
            return "Background scroll could not resolve pid \(ctx.pid) to a PSN."
        }
        guard spi.postActivation(psn: psn, windowId: ctx.windowId, focused: true) else {
            return "Background scroll synthetic target-focus event failed."
        }
        focusPSN = psn
        Thread.sleep(forTimeInterval: 0.040)
    }
    defer {
        if let psn = focusPSN {
            _ = spi.postActivation(psn: psn, windowId: ctx.windowId, focused: false)
            Thread.sleep(forTimeInterval: 0.040)
        }
    }

    guard inputScreenPointIsCurrentlyAuthorized(screenPoint, context: ctx) else {
        return "Background scroll snapshot became stale before delivery. Run get_app_state again."
    }
    event.location = screenPoint
    spi.setField(event, SkyField.targetPID, Int64(ctx.pid))
    spi.setField(event, SkyField.windowNumber, Int64(ctx.windowId))
    spi.setField(event, SkyField.windowUnderPointer, Int64(ctx.windowId))
    spi.setField(event, SkyField.handlingWindowUnderPointer, Int64(ctx.windowId))
    spi.setWindowLocation(event, windowPoint)
    spi.postToPid(event, pid: ctx.pid)
    event.postToPid(ctx.pid)
    Thread.sleep(forTimeInterval: 0.060)
    return nil
}

func skyDrag(
    from start: CGPoint,
    to end: CGPoint,
    ctx: SnapshotContext,
    onMove: (CGPoint) -> Void
) -> String? {
    let spi = SkyLight.shared
    guard spi.available else { return "background drag unavailable: \(spi.unavailableReason)" }
    guard inputScreenPointIsCurrentlyAuthorized(start, context: ctx),
          inputScreenPointIsCurrentlyAuthorized(end, context: ctx) else {
        return "Background drag target is stale, off-screen, or no longer owned by \(ctx.appLabel). Run get_app_state again."
    }
    let bounds = ctx.windowBounds
    func contains(_ point: CGPoint) -> Bool {
        point.x >= bounds.minX && point.y >= bounds.minY
            && point.x <= bounds.maxX && point.y <= bounds.maxY
    }
    guard contains(start), contains(end) else {
        return "Background drag endpoints must be inside the snapshot window bounds."
    }
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        return "Background drag could not create an event source."
    }

    skyClickLock.lock()
    defer { skyClickLock.unlock() }

    var focusPSN: [UInt8]?
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != ctx.pid {
        guard let psn = spi.psn(forPid: ctx.pid) else {
            return "Background drag could not resolve pid \(ctx.pid) to a PSN."
        }
        guard spi.postActivation(psn: psn, windowId: ctx.windowId, focused: true) else {
            return "Background drag synthetic target-focus event failed."
        }
        focusPSN = psn
        Thread.sleep(forTimeInterval: 0.040)
    }
    defer {
        if let psn = focusPSN {
            _ = spi.postActivation(psn: psn, windowId: ctx.windowId, focused: false)
            Thread.sleep(forTimeInterval: 0.040)
        }
    }

    let groupID = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)
    func post(_ type: CGEventType, at point: CGPoint) -> Bool {
        if type != .leftMouseUp,
           !inputScreenPointIsCurrentlyAuthorized(point, context: ctx) {
            return false
        }
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return false }
        let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        spi.setField(event, SkyField.gesturePhase, 3)
        spi.setField(event, SkyField.clickState, 1)
        spi.setField(event, SkyField.buttonNumber, 0)
        spi.setField(event, SkyField.subtype, 3)
        spi.setField(event, SkyField.targetPID, Int64(ctx.pid))
        spi.setField(event, SkyField.windowNumber, Int64(ctx.windowId))
        spi.setField(event, SkyField.clickGroupID, groupID)
        spi.setField(event, SkyField.windowUnderPointer, Int64(ctx.windowId))
        spi.setField(event, SkyField.handlingWindowUnderPointer, Int64(ctx.windowId))
        spi.setWindowLocation(event, local)
        spi.postToPid(event, pid: ctx.pid)
        event.postToPid(ctx.pid)
        onMove(point)
        return true
    }

    guard post(.leftMouseDown, at: start) else {
        return "Background drag snapshot became stale before mouse-down. Run get_app_state again."
    }
    Thread.sleep(forTimeInterval: 0.060)
    var current = start
    let steps = 22
    for index in 1...steps {
        if cancelFlag.value {
            _ = post(.leftMouseUp, at: current)
            return "Drag cancelled."
        }
        let progress = Double(index) / Double(steps)
        current = CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
        guard post(.leftMouseDragged, at: current) else {
            _ = post(.leftMouseUp, at: current)
            return "Background drag snapshot became stale during delivery. Run get_app_state again."
        }
        Thread.sleep(forTimeInterval: 0.009)
    }
    guard post(.leftMouseUp, at: end) else {
        return "Background drag could not create mouse-up."
    }
    Thread.sleep(forTimeInterval: 0.060)
    return nil
}
