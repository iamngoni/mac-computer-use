import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - Input synthesis (background-capable)
// App-scoped synthesized events require an already-resolved process and never post
// to the global HID tap, so they cannot move or click the user's hardware pointer.
let desktopSyntheticEventUserData: Int64 = 0x4D41434355444553 // "MACCUDES"

func postEvent(_ event: CGEvent, pid: pid_t) { event.postToPid(pid) }

func mouseClick(
    _ pt: CGPoint,
    button: CGMouseButton,
    count: Int,
    pid: pid_t,
    authorize: () -> Bool
) -> Bool {
    let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp)
        : (button == .center ? (.otherMouseDown, .otherMouseUp) : (.leftMouseDown, .leftMouseUp))
    for i in 1...max(1, count) {
        if cancelFlag.value || !authorize() { return false }
        OverlayController.shared.flashClickQuartz(pt)
        if let e = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: pt, mouseButton: button) { e.setIntegerValueField(.mouseEventClickState, value: Int64(i)); postEvent(e, pid: pid) }
        if let e = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: pt, mouseButton: button) { e.setIntegerValueField(.mouseEventClickState, value: Int64(i)); postEvent(e, pid: pid) }
        usleep(40_000)
    }
    return true
}
func mouseMoveTo(_ pt: CGPoint, pid: pid_t) { if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) { postEvent(e, pid: pid) } }

// Desktop actions are the explicit opt-in exception to the app-scoped policy above.
// They use the HID event tap, and are tagged so the overlay's physical-Esc
// cancellation monitor does not mistake a synthetic desktop Escape for a user
// cancellation request.
private func tagDesktopEvent(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: desktopSyntheticEventUserData)
}

func desktopMouseClick(
    _ point: CGPoint,
    button: CGMouseButton,
    clickState: Int
) -> Bool {
    let source = CGEventSource(stateID: .hidSystemState)
    let downType: CGEventType = button == .right ? .rightMouseDown
        : (button == .center ? .otherMouseDown : .leftMouseDown)
    let upType: CGEventType = button == .right ? .rightMouseUp
        : (button == .center ? .otherMouseUp : .leftMouseUp)
    guard let down = CGEvent(
        mouseEventSource: source,
        mouseType: downType,
        mouseCursorPosition: point,
        mouseButton: button
    ), let up = CGEvent(
        mouseEventSource: source,
        mouseType: upType,
        mouseCursorPosition: point,
        mouseButton: button
    ) else { return false }
    down.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    up.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    tagDesktopEvent(down)
    tagDesktopEvent(up)
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    return true
}

// Keystrokes are resolved through the user's current keyboard layout (KeyboardLayout.swift,
// KeySpec.swift); keycodes are physical positions, so a US table types the wrong characters
// and turns shortcuts into other shortcuts (cmd+a became cmd+q on AZERTY).
func typeText(_ s: String, pid: pid_t) {
    // Read the layout once per call. If it cannot be read, every character goes through
    // unicode injection rather than a guessed keycode.
    let layout = try? KeyboardLayoutCache.system.layoutMap(holding: [])
    for ch in s {
        if cancelFlag.value { return }
        switch typingStep(for: ch, layout: layout) {
        case .key(let stroke):
            if let d = CGEvent(keyboardEventSource: nil, virtualKey: stroke.keyCode, keyDown: true) { d.flags = stroke.flags; postEvent(d, pid: pid) }
            if let u = CGEvent(keyboardEventSource: nil, virtualKey: stroke.keyCode, keyDown: false) { u.flags = stroke.flags; postEvent(u, pid: pid) }
        case .unicode(let str):
            if let d = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) { var u = Array(str.utf16); d.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u); postEvent(d, pid: pid) }
            if let u = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) { var u16 = Array(str.utf16); u.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16); postEvent(u, pid: pid) }
        }
        usleep(7_000)
    }
}

func desktopKeySpecIsKnown(_ spec: String) -> Bool {
    keySpecProblem(spec) == nil
}

/// Resolves `spec` on the current layout and delivers it to `pid`. On failure nothing is sent.
@discardableResult
func sendKeyCombo(_ spec: String, pid: pid_t) -> Result<KeyCombo, KeySpecError> {
    let combo: KeyCombo
    do {
        combo = try parseKeySpec(spec, layout: KeyboardLayoutCache.system)
    } catch let error as KeySpecError {
        return .failure(error)
    } catch {
        return .failure(.malformed(spec: spec))
    }
    let flags = combo.flags
    if let d = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: true) { d.flags = flags; postEvent(d, pid: pid) }
    usleep(20_000)
    if let u = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: false) { u.flags = flags; postEvent(u, pid: pid) }
    return .success(combo)
}

func pressKeyCombo(_ spec: String, pid: pid_t) -> Bool {
    if case .success = sendKeyCombo(spec, pid: pid) { return true }
    return false
}

func desktopPressKeyCombo(_ spec: String) -> Bool {
    guard let combo = try? parseKeySpec(spec, layout: KeyboardLayoutCache.system) else { return false }
    let source = CGEventSource(stateID: .hidSystemState)
    guard let source else { return false }
    func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) -> Bool {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return false }
        event.flags = flags
        tagDesktopEvent(event)
        event.post(tap: .cghidEventTap)
        return true
    }
    // Modifiers the layout needs for the character (e.g. Shift for "+" on US) are pressed
    // physically too, after the spec's own modifiers.
    var flags = CGEventFlags()
    for modifier in combo.modifiers {
        flags.insert(modifier.flag)
        guard postKey(modifier.keyCode, down: true, flags: flags) else { return false }
    }
    guard postKey(combo.keyCode, down: true, flags: flags) else { return false }
    usleep(20_000)
    guard postKey(combo.keyCode, down: false, flags: flags) else { return false }
    for modifier in combo.modifiers.reversed() {
        flags.remove(modifier.flag)
        guard postKey(modifier.keyCode, down: false, flags: flags) else { return false }
    }
    return true
}
