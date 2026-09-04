import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - Tools
func ensureTrusted() -> Bool { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }

func toolListApps() -> [String: Any] {
    let apps = runningApps().map { "- \($0.localizedName ?? "?")  [\($0.bundleIdentifier ?? "")] pid=\($0.processIdentifier)\($0.isActive ? " (active)" : "")" }
    return toolText("Running apps:\n" + apps.joined(separator: "\n"))
}
func toolGetAppState(_ args: [String: Any]) -> [String: Any] {
    let appSpec = (args["app"] as? String) ?? ""
    guard let app = resolveApp(appSpec) else { return toolText("App not found: \(appSpec). Try list_apps.", isError: true) }
    // Do NOT activate — we inspect in the background. AX reads the tree regardless of
    // focus; the screenshot is captured by window id so it works even when occluded.
    if !AXIsProcessTrusted() { _ = ensureTrusted(); return toolText("Not Accessibility-trusted yet. Enable mac-computer-use in System Settings > Privacy & Security > Accessibility, then retry.", isError: true) }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    let window: AXUIElement? = (axCopy(axApp, "AXFocusedWindow") as! AXUIElement?) ?? (axCopy(axApp, "AXMainWindow") as! AXUIElement?) ?? axArr(axApp, "AXWindows").first
    guard let win = window else { return toolText("No window found for \(appSpec). The app may have no open window.", isError: true) }

    let maxNodes = max(1, (args["max_tree_nodes"] as? Int) ?? 1200)
    let maxDepth = max(1, (args["max_tree_depth"] as? Int) ?? 64)
    let textLimit: Int = {
        if let s = args["text_limit"] as? String { return s.lowercased() == "max" ? Int.max : (Int(s).map { max(1, $0) } ?? 500) }
        if let i = args["text_limit"] as? Int { return max(1, i) }
        return 500
    }()

    elementRegistry.removeAll(); var counter = 0; var nodes: [Node] = []
    walk(win, depth: 0, counter: &counter, out: &nodes, maxNodes: maxNodes, maxDepth: maxDepth, textLimit: textLimit)

    let axTitle = axStr(win, "AXTitle")
    var content: [[String: Any]] = []
    var ctx: SnapshotContext?
    var note = ""

    if let cand = preferredWindow(forPid: app.processIdentifier, titleHint: axTitle),
       let img = captureWindow(cand.id, bounds: cand.bounds),
       let png = boundedPNG(img), cand.bounds.width > 0 {
        content.append(["type": "image", "data": png.data.base64EncodedString(), "mimeType": "image/png"])
        ctx = SnapshotContext(pid: app.processIdentifier,
                              appLabel: app.localizedName ?? appSpec,
                              windowId: cand.id,
                              windowBounds: cand.bounds,
                              pixelScale: CGFloat(png.width) / cand.bounds.width)
        note = "\nScreenshot: \(png.width)x\(png.height) px. Coordinates below and any x,y you pass back are in these screenshot pixels."
    } else if !screenRecordingGranted() {
        note = "\n(Screenshot unavailable: enable mac-computer-use in System Settings > Privacy & Security > Screen Recording. The accessibility tree below is fully usable meanwhile.)"
    } else {
        note = "\n(No capturable window; coordinates below are global screen points.)"
    }
    lastSnapshot = ctx

    let header = "App: \(app.localizedName ?? appSpec) (pid \(app.processIdentifier))\nWindow: \(axTitle ?? "")\(note)\nAccessibility tree (\(nodes.count) elements):"
    content.append(["type": "text", "text": header + "\n" + renderTree(nodes, ctx: ctx, maxLines: maxNodes)])
    return ["content": content, "isError": false]
}
func elementCenter(_ index: Int) -> CGPoint? { guard let el = elementRegistry[index], let f = axFrame(el) else { return nil }; return CGPoint(x: f.midX, y: f.midY) }
func elementFrame(_ index: Int) -> CGRect? { elementRegistry[index].flatMap(axFrame) }
func pidFor(_ args: [String: Any]) -> pid_t? {
    guard let spec = args["app"] as? String,
          !spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return resolveApp(spec)?.processIdentifier
}
func unresolvedAppError(_ args: [String: Any]) -> [String: Any] {
    guard let app = args["app"] as? String,
          !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return toolText("Input action needs 'app'.", isError: true)
    }
    return toolText("App not found: \(app). Try list_apps.", isError: true)
}
func num(_ args: [String: Any], _ k: String) -> Double? { (args[k] as? Double) ?? (args[k] as? Int).map(Double.init) }

// Element indices belong to the snapshot that produced them. The registry is global, so
// without this guard an index from get_app_state("Chrome") would silently address a
// Chrome element on a call that names a different app.
func registryElement(_ index: Int, forPid pid: pid_t?) -> AXUIElement? {
    if let pid = pid, let snap = lastSnapshot, snap.pid != pid { return nil }
    return elementRegistry[index]
}
func staleIndexError(_ index: Int) -> [String: Any] {
    toolText("element_index \(index) is not from this app's snapshot (last snapshot: \(lastSnapshot?.appLabel ?? "none")). Call get_app_state for this app first.", isError: true)
}

// x,y arrive in screenshot pixels relative to the last get_app_state for this app. With
// no snapshot for it, fall back to treating them as global screen points.
func inputPoint(x: Double, y: Double, pid: pid_t?) -> CGPoint {
    if let snap = lastSnapshot, pid == nil || snap.pid == pid { return pixelToScreen(CGPoint(x: x, y: y), snap) }
    return CGPoint(x: x, y: y)
}

// Report coordinates back in the same space the caller used.
func describePoint(_ p: CGPoint, pid: pid_t?) -> String {
    if let s = lastSnapshot, pid == nil || s.pid == pid {
        let px = screenToPixel(p, s)
        return "(\(Int(px.x)),\(Int(px.y))) px"
    }
    return "(\(Int(p.x)),\(Int(p.y)))"
}

func toolClick(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    let count = max(1, (args["click_count"] as? Int) ?? 1)
    let btnStr = (args["mouse_button"] as? String) ?? "left"
    let button: CGMouseButton = btnStr == "right" ? .right : (btnStr == "middle" ? .center : .left)
    let method = ((args["click_method"] as? String) ?? "auto").lowercased()
    guard ["auto", "accessibility", "app_post", "sky_click", "global"].contains(method) else {
        return toolText("click_method must be auto, accessibility, app_post, sky_click, or global.", isError: true)
    }
    let idx: Int? = { if let xs = args["element_index"], let i = Int("\(xs)") { return i }; return nil }()
    var pt: CGPoint?; var tgt: CGRect?
    if let i = idx {
        guard registryElement(i, forPid: pid) != nil else { return staleIndexError(i) }
        pt = elementCenter(i); tgt = elementFrame(i)
    }
    if pt == nil, let x = num(args, "x"), let y = num(args, "y") { pt = inputPoint(x: x, y: y, pid: pid) }

    // Accessibility press: fully in the background, no coordinates, no pointer movement.
    let el = idx.flatMap { elementRegistry[$0] }
    let axEligible = el.map { button == .left && count == 1 && axActions($0).contains("AXPress") } ?? false
    if method == "accessibility" || (method == "auto" && axEligible) {
        guard let i = idx, let el = el else {
            return toolText("click_method 'accessibility' requires element_index.", isError: true)
        }
        guard axEligible else {
            return toolText("Element [\(i)] has no AXPress action (or this is not a single left-click). Use click_method app_post or sky_click.", isError: true)
        }
        return controlled("Clicking", targetQuartz: tgt) {
            if let c = elementCenter(i) { OverlayController.shared.flashClickQuartz(c) }
            if AXUIElementPerformAction(el, "AXPress" as CFString) == .success { return toolText("Pressed [\(i)] (AX, background).") }
            if method == "accessibility" { return toolText("AXPress failed on [\(i)].", isError: true) }
            if let p = pt { mouseClick(p, button: .left, count: 1, pid: pid); return toolText("Clicked [\(i)] at \(describePoint(p, pid: pid)) (AXPress failed).") }
            return toolText("AXPress failed and no coordinates available.", isError: true)
        }
    }

    guard let p = pt else { return toolText("click needs element_index (from last get_app_state) or x,y.", isError: true) }

    // SkyLight: the only path that reaches background Chromium/Electron web content.
    // Deliberately never reached from `auto` and never fallen back from — if it fails,
    // the caller should know the click did not land rather than get a silent retry that
    // steals focus.
    if method == "sky_click" {
        guard let ctx = lastSnapshot, ctx.pid == pid else {
            return toolText("sky_click needs a get_app_state snapshot for this app first.", isError: true)
        }
        guard button == .left else { return toolText("sky_click supports the left button only.", isError: true) }
        return controlled("Clicking (SkyLight)", targetQuartz: tgt) {
            OverlayController.shared.flashClickQuartz(p)
            if let err = skyClick(screenPoint: p, ctx: ctx, clickCount: count) { return toolText(err, isError: true) }
            return toolText("Clicked x\(count) at \(describePoint(p, pid: pid)) via sky_click (background).")
        }
    }

    // app_post targets the app's process; global goes to the system HID tap and moves the
    // real pointer.
    let targetPid: pid_t? = method == "global" ? nil : pid
    return controlled("Clicking", targetQuartz: tgt) {
        mouseMoveTo(p, pid: targetPid); usleep(120_000)
        if cancelFlag.value { return toolText("Cancelled (Esc).") }
        mouseClick(p, button: button, count: count, pid: targetPid)
        return toolText("Clicked \(btnStr) x\(count) at \(describePoint(p, pid: pid))\(method == "global" ? " (global pointer)" : "").")
    }
}
func toolTypeText(_ args: [String: Any]) -> [String: Any] {
    guard let t = args["text"] as? String else { return toolText("type_text needs 'text'.", isError: true) }
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    // Optionally focus a target element first (e.g. a text field) via AX.
    if let xs = args["element_index"], let idx = Int("\(xs)"), let el = registryElement(idx, forPid: pid) {
        AXUIElementSetAttributeValue(el, "AXFocused" as CFString, kCFBooleanTrue); usleep(60_000)
    }
    return controlled("Typing") { typeText(t, pid: pid); return cancelFlag.value ? toolText("Cancelled (Esc).") : toolText("Typed \(t.count) chars.") }
}
func toolPressKey(_ args: [String: Any]) -> [String: Any] {
    guard let k = args["key"] as? String else { return toolText("press_key needs 'key'.", isError: true) }
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    return controlled("Pressing \(k)") { pressKeyCombo(k, pid: pid) ? toolText("Pressed \(k).") : toolText("Unknown key: \(k).", isError: true) }
}
func toolScroll(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    let dir = (args["direction"] as? String) ?? "down"
    let pages = (args["pages"] as? Double) ?? (args["pages"] as? Int).map(Double.init) ?? 1.0
    var tgt: CGRect?
    if let xs = args["element_index"], let idx = Int("\(xs)") {
        guard registryElement(idx, forPid: pid) != nil else { return staleIndexError(idx) }
        if let c = elementCenter(idx) { mouseMoveTo(c, pid: pid); usleep(30_000) }
        tgt = elementFrame(idx)
    }
    return controlled("Scrolling \(dir)", targetQuartz: tgt) {
        let amt = Int32(pages * 400)
        switch dir { case "up": scrollWheel(dx:0,dy:amt,pid:pid); case "down": scrollWheel(dx:0,dy:-amt,pid:pid)
        case "left": scrollWheel(dx:amt,dy:0,pid:pid); case "right": scrollWheel(dx:-amt,dy:0,pid:pid)
        default: return toolText("direction must be up/down/left/right.", isError: true) }
        return toolText("Scrolled \(dir) \(pages) page(s).")
    }
}
func toolSetValue(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    guard let xs = args["element_index"], let idx = Int("\(xs)"), let el = registryElement(idx, forPid: pid) else { return toolText("set_value needs a valid element_index from this app's last get_app_state.", isError: true) }
    guard let v = args["value"] as? String else { return toolText("set_value needs 'value'.", isError: true) }
    return controlled("Setting value", targetQuartz: elementFrame(idx)) {
        AXUIElementSetAttributeValue(el, "AXValue" as CFString, v as CFString) == .success ? toolText("Set value of [\(idx)].") : toolText("Element not settable.", isError: true)
    }
}
func toolDrag(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    guard let fx = num(args, "from_x"), let fy = num(args, "from_y"),
          let tx = num(args, "to_x"), let ty = num(args, "to_y") else { return toolText("drag needs from_x,from_y,to_x,to_y.", isError: true) }
    let from = inputPoint(x: fx, y: fy, pid: pid), to = inputPoint(x: tx, y: ty, pid: pid)
    return controlled("Dragging") { mouseDrag(from: from, to: to, pid: pid); return toolText("Dragged (\(Int(fx)),\(Int(fy))) -> (\(Int(tx)),\(Int(ty))).") }
}
func toolSecondaryAction(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    guard let xs = args["element_index"], let idx = Int("\(xs)"), let el = registryElement(idx, forPid: pid) else { return toolText("needs a valid element_index from this app's last get_app_state.", isError: true) }
    guard let action = args["action"] as? String else { return toolText("needs 'action'.", isError: true) }
    let a = action.hasPrefix("AX") ? action : "AX\(action)"
    return controlled("Action \(a)", targetQuartz: elementFrame(idx)) { AXUIElementPerformAction(el, a as CFString) == .success ? toolText("Performed \(a) on [\(idx)].") : toolText("Action failed.", isError: true) }
}
func toolSelectText(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    guard let xs = args["element_index"], let idx = Int("\(xs)"), let el = registryElement(idx, forPid: pid) else { return toolText("needs a valid element_index from this app's last get_app_state.", isError: true) }
    return controlled("Selecting", targetQuartz: elementFrame(idx)) { _ = AXUIElementPerformAction(el, "AXPress" as CFString); return toolText("Focused [\(idx)].") }
}

struct ToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: Any]
    let handler: ([String: Any]) -> [String: Any]

    var schema: [String: Any] {
        ["name": name, "description": description, "inputSchema": inputSchema]
    }
}

func toolDefinitions() -> [ToolDefinition] {
    func obj(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false,
        ]
    }
    let string: [String: Any] = ["type": "string"]
    let number: [String: Any] = ["type": "number"]
    let app: [String: Any] = [
        "type": "string",
        "description": "App name, bundle id, or path",
    ]

    return [
        ToolDefinition(
            name: "list_apps",
            description: "List running applications.",
            inputSchema: obj([:], []),
            handler: { _ in toolListApps() }
        ),
        ToolDefinition(
            name: "get_app_state",
            description: "Inspect an app without activating it: returns a screenshot of its key window plus an indexed accessibility tree. Call this once before interacting; element_index values and all coordinates come from here.",
            inputSchema: obj(
                [
                    "app": app,
                    "text_limit": [
                        "type": ["string", "integer"],
                        "description": "Max characters of text per element. Use \"max\" for full text. Default 500.",
                    ],
                    "max_tree_nodes": [
                        "type": "integer",
                        "description": "Max accessibility nodes to walk and render. Default 1200.",
                    ],
                    "max_tree_depth": [
                        "type": "integer",
                        "description": "Max tree depth to walk. Default 64.",
                    ],
                ],
                ["app"]
            ),
            handler: toolGetAppState
        ),
        ToolDefinition(
            name: "click",
            description: "Click by element_index (from get_app_state) or by x,y. Coordinates are in SCREENSHOT PIXELS — read them straight off the get_app_state image or its tree, not global screen points. Shows a live cursor + click flash.",
            inputSchema: obj(
                [
                    "app": app,
                    "element_index": string,
                    "x": number,
                    "y": number,
                    "click_count": ["type": "integer"],
                    "mouse_button": ["type": "string", "enum": ["left", "right", "middle"]],
                    "click_method": [
                        "type": "string",
                        "enum": ["auto", "accessibility", "app_post", "sky_click", "global"],
                        "description": "auto (default) presses via accessibility when possible, else posts to the app. accessibility forces AXPress. app_post posts a normal event to the app. sky_click uses the SkyLight background path — the one that works on background Chromium/Electron web content, left button only. global moves the real system pointer.",
                    ],
                ],
                ["app"]
            ),
            handler: toolClick
        ),
        ToolDefinition(
            name: "type_text",
            description: "Type literal unicode text.",
            inputSchema: obj(["app": app, "text": string], ["app", "text"]),
            handler: toolTypeText
        ),
        ToolDefinition(
            name: "press_key",
            description: "Press a key/combo (xdotool-style: Return, Tab, cmd+c, Up).",
            inputSchema: obj(["app": app, "key": string], ["app", "key"]),
            handler: toolPressKey
        ),
        ToolDefinition(
            name: "scroll",
            description: "Scroll up/down/left/right by pages, optionally over an element.",
            inputSchema: obj(
                [
                    "app": app,
                    "element_index": string,
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "pages": number,
                ],
                ["app", "direction"]
            ),
            handler: toolScroll
        ),
        ToolDefinition(
            name: "set_value",
            description: "Set the AXValue of a settable element.",
            inputSchema: obj(
                ["app": app, "element_index": string, "value": string],
                ["app", "element_index", "value"]
            ),
            handler: toolSetValue
        ),
        ToolDefinition(
            name: "drag",
            description: "Drag the mouse between two points, in screenshot pixel coordinates from the last get_app_state.",
            inputSchema: obj(
                [
                    "app": app,
                    "from_x": number,
                    "from_y": number,
                    "to_x": number,
                    "to_y": number,
                ],
                ["app", "from_x", "from_y", "to_x", "to_y"]
            ),
            handler: toolDrag
        ),
        ToolDefinition(
            name: "perform_secondary_action",
            description: "Invoke a named accessibility action on an element.",
            inputSchema: obj(
                ["app": app, "element_index": string, "action": string],
                ["app", "element_index", "action"]
            ),
            handler: toolSecondaryAction
        ),
        ToolDefinition(
            name: "select_text",
            description: "Focus a text element.",
            inputSchema: obj(
                ["app": app, "element_index": string, "text": string],
                ["app", "element_index", "text"]
            ),
            handler: toolSelectText
        ),
        ToolDefinition(
            name: "open_app",
            description: "Launch an app (or activate it if already running). Works for any macOS app — browsers, Music, Notes, etc. Use this to switch focus to an app before interacting, or to start one that isn't open.",
            inputSchema: obj(["app": app], ["app"]),
            handler: toolOpenApp
        ),
        ToolDefinition(
            name: "navigate",
            description: "Point a browser's active tab at a URL directly (reliable, background — no omnibox typing). Works for Safari and Chromium browsers (Chrome/Brave/Edge/Arc). Set new_tab=true to open in a new tab.",
            inputSchema: obj(
                ["app": app, "url": string, "new_tab": ["type": "boolean"]],
                ["url"]
            ),
            handler: toolNavigate
        ),
    ]
}

func toolSchemas() -> [[String: Any]] {
    toolDefinitions().map(\.schema)
}

// Background-first: input is delivered to the target app's pid (postToPid) and clicks
// prefer AXPress, so we do NOT force the app to the foreground. Use open_app to bring
// an app forward explicitly when you actually want it focused.
func dispatchTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
    guard let tool = toolDefinitions().first(where: { $0.name == name }) else {
        return toolText("Unknown tool: \(name)", isError: true)
    }
    return tool.handler(args)
}
