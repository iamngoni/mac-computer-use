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

// char -> (keycode, needsShift) for US layout. Real keystrokes are accepted by fields
// (e.g. browser omniboxes) that ignore unicode-string injection.
let charKeyMap: [Character: (CGKeyCode, Bool)] = {
    var m: [Character: (CGKeyCode, Bool)] = [:]
    let letters: [Character: CGKeyCode] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46]
    for (ch, code) in letters { m[ch] = (code, false); if let up = ch.uppercased().first { m[up] = (code, true) } }
    let digits: [Character: CGKeyCode] = ["1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29]
    for (ch, code) in digits { m[ch] = (code, false) }
    let shifted: [Character: CGKeyCode] = ["!":18,"@":19,"#":20,"$":21,"%":23,"^":22,"&":26,"*":28,"(":25,")":29]
    for (ch, code) in shifted { m[ch] = (code, true) }
    m[" "] = (49, false); m["\t"] = (48, false); m["\n"] = (36, false); m["\r"] = (36, false)
    m["-"] = (27, false); m["_"] = (27, true); m["="] = (24, false); m["+"] = (24, true)
    m["["] = (33, false); m["{"] = (33, true); m["]"] = (30, false); m["}"] = (30, true)
    m["\\"] = (42, false); m["|"] = (42, true); m[";"] = (41, false); m[":"] = (41, true)
    m["'"] = (39, false); m["\""] = (39, true); m[","] = (43, false); m["<"] = (43, true)
    m["."] = (47, false); m[">"] = (47, true); m["/"] = (44, false); m["?"] = (44, true)
    m["`"] = (50, false); m["~"] = (50, true)
    return m
}()

func typeText(_ s: String, pid: pid_t) {
    for ch in s {
        if cancelFlag.value { return }
        if let (code, shift) = charKeyMap[ch] {
            let flags: CGEventFlags = shift ? .maskShift : []
            if let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) { d.flags = flags; postEvent(d, pid: pid) }
            if let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) { u.flags = flags; postEvent(u, pid: pid) }
        } else {
            let str = String(ch)
            if let d = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) { var u = Array(str.utf16); d.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u); postEvent(d, pid: pid) }
            if let u = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) { var u16 = Array(str.utf16); u.keyboardSetUnicodeString(stringLength: u16.count, unicodeString: &u16); postEvent(u, pid: pid) }
        }
        usleep(7_000)
    }
}
let keyMap: [String: CGKeyCode] = [
    "return":36,"enter":36,"tab":48,"space":49,"delete":51,"backspace":51,"escape":53,"esc":53,
    "left":123,"right":124,"down":125,"up":126,"home":115,"end":119,"pageup":116,"pagedown":121,
    "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111,
    "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,
    "y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46,
    "1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25,"0":29,
    "minus":27,"equal":24,"comma":43,"period":47,"slash":44,"semicolon":41,"grave":50
]

func desktopKeySpecIsKnown(_ spec: String) -> Bool {
    let parts = spec.lowercased().split(separator: "+").map(String.init)
    guard let keyName = parts.last, keyMap[keyName] != nil else { return false }
    let modifiers = Set(["cmd", "command", "super", "meta", "shift", "ctrl", "control", "alt", "option", "opt"])
    return parts.dropLast().allSatisfy { modifiers.contains($0) }
}

func pressKeyCombo(_ spec: String, pid: pid_t) -> Bool {
    let parts = spec.lowercased().split(separator: "+").map(String.init)
    guard let keyName = parts.last, let code = keyMap[keyName] else { return false }
    var flags = CGEventFlags()
    for m in parts.dropLast() {
        switch m { case "cmd","command","super","meta": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift); case "ctrl","control": flags.insert(.maskControl)
        case "alt","option","opt": flags.insert(.maskAlternate); default: break }
    }
    if let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) { d.flags = flags; postEvent(d, pid: pid) }
    usleep(20_000)
    if let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) { u.flags = flags; postEvent(u, pid: pid) }
    return true
}

func desktopPressKeyCombo(_ spec: String) -> Bool {
    let parts = spec.lowercased().split(separator: "+").map(String.init)
    guard let keyName = parts.last, let code = keyMap[keyName] else { return false }
    let modifierMap: [String: (CGKeyCode, CGEventFlags)] = [
        "cmd": (55, .maskCommand), "command": (55, .maskCommand),
        "super": (55, .maskCommand), "meta": (55, .maskCommand),
        "shift": (56, .maskShift), "ctrl": (59, .maskControl),
        "control": (59, .maskControl), "alt": (58, .maskAlternate),
        "option": (58, .maskAlternate), "opt": (58, .maskAlternate),
    ]
    let modifiers = parts.dropLast().compactMap { modifierMap[$0] }
    guard modifiers.count == parts.count - 1 else { return false }
    let source = CGEventSource(stateID: .hidSystemState)
    guard let source else { return false }
    func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) -> Bool {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return false }
        event.flags = flags
        tagDesktopEvent(event)
        event.post(tap: .cghidEventTap)
        return true
    }
    var flags = CGEventFlags()
    for (modifierCode, modifierFlag) in modifiers {
        flags.insert(modifierFlag)
        guard postKey(modifierCode, down: true, flags: flags) else { return false }
    }
    guard postKey(code, down: true, flags: flags) else { return false }
    usleep(20_000)
    guard postKey(code, down: false, flags: flags) else { return false }
    for (modifierCode, modifierFlag) in modifiers.reversed() {
        flags.remove(modifierFlag)
        guard postKey(modifierCode, down: false, flags: flags) else { return false }
    }
    return true
}
