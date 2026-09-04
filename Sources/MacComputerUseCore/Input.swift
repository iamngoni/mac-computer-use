import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - Input synthesis (background-capable)
// Every synthesized event requires an already-resolved process. App-scoped tools never
// post to the global HID tap, so they cannot move or click the user's hardware pointer.
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
