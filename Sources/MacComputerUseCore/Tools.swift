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

func unavailableSnapshotNote(screenRecordingGranted: Bool) -> String {
    let reason = screenRecordingGranted
        ? "No capturable window is available."
        : "Screenshot unavailable: enable mac-computer-use in System Settings > Privacy & Security > Screen Recording."
    return "\n(\(reason) The accessibility tree below is read-only; its element indices and coordinates are not authorized for input.)"
}

func toolGetAppState(_ args: [String: Any]) -> [String: Any] {
    let appSpec = (args["app"] as? String) ?? ""
    guard let app = resolveApp(appSpec) else { return toolText(applicationTargetError(appSpec), isError: true) }
    // Do NOT activate — we inspect in the background. AX reads the tree regardless of
    // focus; the screenshot is captured by window id so it works even when occluded.
    if !AXIsProcessTrusted() { _ = ensureTrusted(); return toolText("Not Accessibility-trusted yet. Enable mac-computer-use in System Settings > Privacy & Security > Accessibility, then retry.", isError: true) }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)

    let requestedWindowId: CGWindowID? = {
        if let value = strictJSONInteger(args["window_id"]), value > 0 { return UInt32(exactly: value) }
        if let value = args["window_id"] as? String, let parsed = UInt32(value), parsed > 0 { return parsed }
        return nil
    }()
    if args["window_id"] != nil, requestedWindowId == nil {
        return toolText("window_id must be a positive integer.", isError: true)
    }
    let requestedCandidate: WindowCandidate?
    if let requestedWindowId {
        guard let candidate = windowCandidates(forPid: app.processIdentifier).first(where: { $0.id == requestedWindowId }) else {
            return toolText("Window not found for \(appSpec): window_id=\(requestedWindowId). Call list_windows again.", isError: true)
        }
        requestedCandidate = candidate
    } else {
        requestedCandidate = nil
    }

    let preferredAXWindow = axElement(axApp, "AXFocusedWindow")
        ?? axElement(axApp, "AXMainWindow")
        ?? axArr(axApp, "AXWindows").first
    let selectedCandidate = requestedCandidate ?? preferredWindow(
        forPid: app.processIdentifier,
        titleHint: preferredAXWindow.flatMap { axStr($0, "AXTitle") }
    )

    let win: AXUIElement
    if let selectedCandidate {
        guard let matched = accessibilityWindow(matching: selectedCandidate, in: axApp) else {
            return toolText(
                "Accessibility window identity could not be proven for window_id=\(selectedCandidate.id). Call list_windows again.",
                isError: true
            )
        }
        win = matched
    } else {
        guard let preferredAXWindow else {
            return toolText("No window found for \(appSpec). The app may have no open window.", isError: true)
        }
        win = preferredAXWindow
    }

    let maxNodes: Int
    if let supplied = args["max_tree_nodes"] {
        guard let value = strictJSONInteger(supplied), (1...10_000).contains(value) else {
            return toolText("max_tree_nodes must be an integer between 1 and 10000.", isError: true)
        }
        maxNodes = value
    } else {
        maxNodes = 1_200
    }
    let maxDepth: Int
    if let supplied = args["max_tree_depth"] {
        guard let value = strictJSONInteger(supplied), (1...256).contains(value) else {
            return toolText("max_tree_depth must be an integer between 1 and 256.", isError: true)
        }
        maxDepth = value
    } else {
        maxDepth = 64
    }
    let textLimit: Int
    if let supplied = args["text_limit"] {
        if let value = strictJSONInteger(supplied), (1...100_000).contains(value) {
            textLimit = value
        } else if let value = supplied as? String,
                  value.lowercased() == "max" {
            textLimit = Int.max
        } else {
            return toolText("text_limit must be an integer between 1 and 100000 or the string 'max'.", isError: true)
        }
    } else {
        textLimit = 500
    }

    elementRegistry.removeAll(); var counter = 0; var nodes: [Node] = []
    walk(win, depth: 0, counter: &counter, out: &nodes, maxNodes: maxNodes, maxDepth: maxDepth, textLimit: textLimit)

    let axTitle = axStr(win, "AXTitle")
    var content: [[String: Any]] = []
    var ctx: SnapshotContext?
    var note = ""

    if let cand = selectedCandidate,
       let img = captureWindow(cand.id, bounds: cand.bounds),
       let png = boundedPNG(img), cand.bounds.width > 0 {
        content.append(["type": "image", "data": png.data.base64EncodedString(), "mimeType": "image/png"])
        ctx = SnapshotContext(pid: app.processIdentifier,
                              appLabel: app.localizedName ?? appSpec,
                              windowId: cand.id,
                              windowBounds: cand.bounds,
                              pixelScale: CGFloat(png.width) / cand.bounds.width,
                              pixelWidth: CGFloat(png.width),
                              pixelHeight: CGFloat(png.height))
        note = "\nScreenshot: \(png.width)x\(png.height) px. Coordinates below and any x,y you pass back are in these screenshot pixels."
    } else {
        note = unavailableSnapshotNote(screenRecordingGranted: screenRecordingGranted())
    }
    lastSnapshot = ctx

    let windowLine = ctx.map { "\nWindow ID: \($0.windowId)" } ?? ""
    let header = "App: \(app.localizedName ?? appSpec) (pid \(app.processIdentifier))\nWindow: \(axTitle ?? "")\(windowLine)\(note)\nAccessibility tree (\(nodes.count) elements):"
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
    return toolText(applicationTargetError(app), isError: true)
}
func num(_ args: [String: Any], _ k: String) -> Double? { strictJSONDouble(args[k]) }

// Element indices belong to the snapshot that produced them. The registry is global, so
// without this guard an index from get_app_state("Chrome") would silently address a
// Chrome element on a call that names a different app.
func registryElement(_ index: Int, forPid pid: pid_t?) -> AXUIElement? {
    guard let pid, authorizedSnapshot(forPid: pid) != nil else { return nil }
    return elementRegistry[index]
}
func staleIndexError(_ index: Int) -> [String: Any] {
    toolText("element_index \(index) is not from this app's snapshot (last snapshot: \(lastSnapshot?.appLabel ?? "none")). Call get_app_state for this app first.", isError: true)
}

func accessibilityElement(atScreenPoint point: CGPoint, pid: pid_t) -> AXUIElement? {
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(
        AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &element
    ) == .success else { return nil }
    return element
}

func describePoint(_ p: CGPoint, context: SnapshotContext) -> String {
    let px = screenToPixel(p, context)
    return "(\(Int(px.x)),\(Int(px.y))) px"
}

func toolClick(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    let count: Int
    if let suppliedCount = args["click_count"] {
        guard let parsedCount = strictJSONInteger(suppliedCount), (1...3).contains(parsedCount) else {
            return toolText("click_count must be an integer between 1 and 3.", isError: true)
        }
        count = parsedCount
    } else {
        count = 1
    }
    let btnStr: String
    if let suppliedButton = args["mouse_button"] {
        guard let parsedButton = suppliedButton as? String else {
            return toolText("mouse_button must be a string.", isError: true)
        }
        btnStr = parsedButton
    } else {
        btnStr = "left"
    }
    guard ["left", "right", "middle"].contains(btnStr) else {
        return toolText("mouse_button must be left, right, or middle.", isError: true)
    }
    let button: CGMouseButton = btnStr == "right" ? .right : (btnStr == "middle" ? .center : .left)
    let method: String
    if let suppliedMethod = args["click_method"] {
        guard let parsedMethod = suppliedMethod as? String else {
            return toolText("click_method must be a string.", isError: true)
        }
        method = parsedMethod.lowercased()
    } else {
        method = "auto"
    }
    guard ["auto", "accessibility", "app_post", "sky_click"].contains(method) else {
        return toolText("click_method must be auto, accessibility, app_post, or sky_click.", isError: true)
    }
    guard let ctx = authorizedSnapshot(forPid: pid) else {
        return toolText("click needs a fresh get_app_state snapshot for this app first.", isError: true)
    }
    let idx: Int?
    if let suppliedIndex = args["element_index"] {
        guard let indexString = suppliedIndex as? String,
              let parsedIndex = Int(indexString), parsedIndex >= 0 else {
            return toolText("element_index must be a non-negative integer string.", isError: true)
        }
        idx = parsedIndex
    } else {
        idx = nil
    }
    var pt: CGPoint?; var tgt: CGRect?
    if let i = idx {
        guard registryElement(i, forPid: pid) != nil else { return staleIndexError(i) }
        pt = elementCenter(i); tgt = elementFrame(i)
    }
    if pt == nil, let x = num(args, "x"), let y = num(args, "y") {
        guard let input = inputPoint(x: x, y: y, context: ctx) else {
            return toolText("click x,y must be finite and inside the screenshot bounds.", isError: true)
        }
        pt = input
    }

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
        return controlled("Clicking", appPID: pid, targetQuartz: tgt) {
            if let veto = confirmRiskyAction(element: el, point: elementCenter(i)) { return veto }
            if let c = elementCenter(i) { OverlayController.shared.flashClickQuartz(c) }
            if AXUIElementPerformAction(el, "AXPress" as CFString) == .success { return toolText("Pressed [\(i)] (AX, background).") }
            if method == "accessibility" { return toolText("AXPress failed on [\(i)].", isError: true) }
            if let p = pt {
                guard mouseClick(
                    p,
                    button: .left,
                    count: 1,
                    pid: pid,
                    authorize: { inputScreenPointIsCurrentlyAuthorized(p, context: ctx) }
                ) else {
                    return toolText("Click snapshot became stale before delivery. Run get_app_state again.", isError: true)
                }
                return toolText("Clicked [\(i)] at \(describePoint(p, context: ctx)) (AXPress failed).")
            }
            return toolText("AXPress failed and no coordinates available.", isError: true)
        }
    }

    guard let p = pt else { return toolText("click needs element_index (from last get_app_state) or x,y.", isError: true) }
    guard inputScreenPointIsAuthorized(p, context: ctx) else {
        return toolText("click target must be inside the screenshot bounds.", isError: true)
    }

    // SkyLight: the only path that reaches background Chromium/Electron web content.
    // Deliberately never reached from `auto` and never fallen back from — if it fails,
    // the caller should know the click did not land rather than get a silent retry that
    // steals focus.
    if method == "sky_click" {
        guard button == .left else { return toolText("sky_click supports the left button only.", isError: true) }
        return controlled("Clicking (SkyLight)", appPID: pid, targetQuartz: tgt) {
            if let veto = confirmRiskyAction(element: el ?? accessibilityElement(atScreenPoint: p, pid: pid), point: p) { return veto }
            OverlayController.shared.moveCursorQuartz(p)
            if let err = skyClick(
                screenPoint: p,
                ctx: ctx,
                clickCount: count,
                onClick: { OverlayController.shared.flashClickQuartz(p) }
            ) { return toolText(err, isError: true) }
            return toolText("Clicked x\(count) at \(describePoint(p, context: ctx)) via sky_click (background).")
        }
    }

    return controlled("Clicking", appPID: pid, targetQuartz: tgt) {
        if button == .left, let veto = confirmRiskyAction(element: el ?? accessibilityElement(atScreenPoint: p, pid: pid), point: p) {
            return veto
        }
        OverlayController.shared.moveCursorQuartz(p)
        mouseMoveTo(p, pid: pid); usleep(120_000)
        if cancelFlag.value { return toolText("Cancelled (Esc).") }
        guard mouseClick(
            p,
            button: button,
            count: count,
            pid: pid,
            authorize: { inputScreenPointIsCurrentlyAuthorized(p, context: ctx) }
        ) else {
            if cancelFlag.value { return toolText("Cancelled (Esc).") }
            return toolText("Click snapshot became stale before delivery. Run get_app_state again.", isError: true)
        }
        return toolText("Clicked \(btnStr) x\(count) at \(describePoint(p, context: ctx)) (application-scoped).")
    }
}
func toolTypeText(_ args: [String: Any]) -> [String: Any] {
    guard let t = args["text"] as? String else { return toolText("type_text needs 'text'.", isError: true) }
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    // Optionally focus a target element first (e.g. a text field) via AX.
    if let rawIndex = args["element_index"] {
        guard let idx = Int("\(rawIndex)"), let el = registryElement(idx, forPid: pid) else {
            return toolText(
                "type_text needs a valid element_index from this app's current get_app_state snapshot.",
                isError: true
            )
        }
        AXUIElementSetAttributeValue(el, "AXFocused" as CFString, kCFBooleanTrue)
        usleep(60_000)
    }
    return controlled("Typing", appPID: pid) { typeText(t, pid: pid); return cancelFlag.value ? toolText("Cancelled (Esc).") : toolText("Typed \(t.count) chars.") }
}
func toolPressKey(_ args: [String: Any]) -> [String: Any] {
    guard let k = args["key"] as? String else { return toolText("press_key needs 'key'.", isError: true) }
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    return controlled("Pressing \(k)", appPID: pid) {
        switch sendKeyCombo(k, pid: pid) {
        case .success: return toolText("Pressed \(k).")
        case .failure(let error): return toolText(error.description, isError: true)
        }
    }
}
func toolScroll(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    guard let dir = args["direction"] as? String else {
        return toolText("scroll needs string 'direction'.", isError: true)
    }
    let pages: Double
    if args["pages"] != nil {
        guard let suppliedPages = num(args, "pages") else {
            return toolText("scroll pages must be numeric.", isError: true)
        }
        pages = suppliedPages
    } else {
        pages = 1.0
    }
    guard ["up", "down", "left", "right"].contains(dir) else {
        return toolText("direction must be up/down/left/right.", isError: true)
    }
    guard pages.isFinite, pages >= 0, pages <= 100 else {
        return toolText("scroll pages must be finite and between 0 and 100.", isError: true)
    }
    guard let ctx = authorizedSnapshot(forPid: pid) else {
        return toolText("scroll needs a fresh get_app_state snapshot for this app first.", isError: true)
    }
    var tgt: CGRect?
    var point = CGPoint(x: ctx.windowBounds.midX, y: ctx.windowBounds.midY)
    if let suppliedIndex = args["element_index"] {
        guard let indexString = suppliedIndex as? String,
              let idx = Int(indexString), idx >= 0 else {
            return toolText("element_index must be a non-negative integer string.", isError: true)
        }
        guard registryElement(idx, forPid: pid) != nil else { return staleIndexError(idx) }
        if let center = elementCenter(idx) { point = center }
        tgt = elementFrame(idx)
    }
    return controlled("Scrolling \(dir)", appPID: pid, targetQuartz: tgt) {
        OverlayController.shared.moveCursorQuartz(point)
        let amt = Int32(pages * 400)
        let delta: (Int32, Int32)
        switch dir {
        case "up": delta = (0, amt)
        case "down": delta = (0, -amt)
        case "left": delta = (amt, 0)
        default: delta = (-amt, 0)
        }
        if let error = skyScroll(screenPoint: point, ctx: ctx, dx: delta.0, dy: delta.1) {
            return toolText(error, isError: true)
        }
        return toolText("Scrolled \(dir) \(pages) page(s).")
    }
}
func toolSetValue(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    guard let xs = args["element_index"], let idx = Int("\(xs)"), let el = registryElement(idx, forPid: pid) else { return toolText("set_value needs a valid element_index from this app's last get_app_state.", isError: true) }
    guard let v = args["value"] as? String else { return toolText("set_value needs 'value'.", isError: true) }
    return controlled("Setting value", appPID: pid, targetQuartz: elementFrame(idx)) {
        AXUIElementSetAttributeValue(el, "AXValue" as CFString, v as CFString) == .success ? toolText("Set value of [\(idx)].") : toolText("Element not settable.", isError: true)
    }
}
func toolDrag(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    guard let fx = num(args, "from_x"), let fy = num(args, "from_y"),
          let tx = num(args, "to_x"), let ty = num(args, "to_y") else { return toolText("drag needs from_x,from_y,to_x,to_y.", isError: true) }
    guard let ctx = authorizedSnapshot(forPid: pid) else {
        return toolText("drag needs a fresh get_app_state snapshot for this app first.", isError: true)
    }
    guard let from = inputPoint(x: fx, y: fy, context: ctx),
          let to = inputPoint(x: tx, y: ty, context: ctx) else {
        return toolText("drag coordinates must be finite and inside the screenshot bounds.", isError: true)
    }
    return controlled("Dragging", appPID: pid) {
        if let error = skyDrag(
            from: from,
            to: to,
            ctx: ctx,
            onMove: { OverlayController.shared.moveCursorQuartz($0) }
        ) {
            return toolText(error, isError: error != "Drag cancelled.")
        }
        return toolText("Dragged (\(Int(fx)),\(Int(fy))) -> (\(Int(tx)),\(Int(ty))) in the target window.")
    }
}
func toolSecondaryAction(_ args: [String: Any]) -> [String: Any] {
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    guard let xs = args["element_index"], let idx = Int("\(xs)"), let el = registryElement(idx, forPid: pid) else { return toolText("needs a valid element_index from this app's last get_app_state.", isError: true) }
    guard let action = args["action"] as? String else { return toolText("needs 'action'.", isError: true) }
    let a = action.hasPrefix("AX") ? action : "AX\(action)"
    return controlled("Action \(a)", appPID: pid, targetQuartz: elementFrame(idx)) {
        if ["AXPress", "AXConfirm", "AXPick"].contains(a), let veto = confirmRiskyAction(element: el, point: elementCenter(idx)) {
            return veto
        }
        return AXUIElementPerformAction(el, a as CFString) == .success ? toolText("Performed \(a) on [\(idx)].") : toolText("Action failed.", isError: true)
    }
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
    let speakOption: [String: Any] = [
        "type": ["boolean", "string"],
        "description": "Also say it aloud: true reads this tool's text, a string says that instead. Skipped when the user has turned Speak Aloud off.",
    ]
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
    let screenshotCoordinate: [String: Any] = [
        "type": "number",
        "minimum": 0,
        "description": "Finite screenshot pixel coordinate inside the last matching get_app_state image.",
    ]
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
                    "window_id": [
                        "type": "integer",
                        "minimum": 1,
                        "description": "Exact WindowServer ID from list_windows. Omit to inspect the preferred window.",
                    ],
                    "text_limit": [
                        "type": ["string", "integer"],
                        "description": "Max characters of text per element. Use \"max\" for full text. Default 500.",
                    ],
                    "max_tree_nodes": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 10_000,
                        "description": "Max accessibility nodes to walk and render. Default 1200.",
                    ],
                    "max_tree_depth": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 256,
                        "description": "Max tree depth to walk. Default 64.",
                    ],
                ],
                ["app"]
            ),
            handler: toolGetAppState
        ),
        ToolDefinition(
            name: "get_desktop_state",
            description: "Capture one display and return a fresh snapshot token plus indexed visible menu/status accessibility elements. Desktop coordinates are screenshot pixels relative to the selected display.",
            inputSchema: obj(
                [
                    "display_id": [
                        "type": "integer",
                        "minimum": 1,
                        "description": "Optional active CGDirectDisplayID. Omit to use the main display.",
                    ],
                ],
                []
            ),
            handler: toolGetDesktopState
        ),
        ToolDefinition(
            name: "desktop_click",
            description: "Explicitly click the desktop or a visible indexed menu/status element. This is the only global HID input path and requires allow_global_input: true. Use either element_index or screenshot-pixel x,y, never both.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "snapshot_id": ["type": "string", "minLength": 1],
                    "element_index": ["type": "integer", "minimum": 0],
                    "x": screenshotCoordinate,
                    "y": screenshotCoordinate,
                    "mouse_button": ["type": "string", "enum": ["left", "right", "middle"]],
                    "click_count": ["type": "integer", "minimum": 1, "maximum": 3],
                    "allow_global_input": ["type": "boolean", "const": true],
                ],
                "required": ["snapshot_id", "allow_global_input"],
                "oneOf": [
                    ["required": ["element_index"]],
                    ["required": ["x", "y"]],
                ],
                "additionalProperties": false,
            ],
            handler: toolDesktopClick
        ),
        ToolDefinition(
            name: "desktop_press_key",
            description: "Explicitly press a key or combo through global HID input. Requires a fresh get_desktop_state snapshot and allow_global_input: true.",
            inputSchema: obj(
                [
                    "snapshot_id": ["type": "string", "minLength": 1],
                    "key": string,
                    "allow_global_input": ["type": "boolean", "const": true],
                ],
                ["snapshot_id", "key", "allow_global_input"]
            ),
            handler: toolDesktopPressKey
        ),
        ToolDefinition(
            name: "click",
            description: "Click by element_index (from get_app_state) or by x,y. Coordinates are in SCREENSHOT PIXELS — read them straight off the get_app_state image or its tree, not global screen points. Shows a live cursor + click flash.",
            inputSchema: obj(
                [
                    "app": app,
                    "element_index": string,
                    "x": screenshotCoordinate,
                    "y": screenshotCoordinate,
                    "click_count": ["type": "integer", "minimum": 1, "maximum": 3],
                    "mouse_button": ["type": "string", "enum": ["left", "right", "middle"]],
                    "click_method": [
                        "type": "string",
                        "enum": ["auto", "accessibility", "app_post", "sky_click"],
                        "description": "auto (default) presses via accessibility when possible, else posts to the app. accessibility forces AXPress. app_post posts a normal event to the app. sky_click uses the SkyLight background path — the one that works on background Chromium/Electron web content, left button only. All methods are application-scoped and leave the hardware pointer untouched.",
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
                    "pages": ["type": "number", "minimum": 0, "maximum": 100],
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
                    "from_x": screenshotCoordinate,
                    "from_y": screenshotCoordinate,
                    "to_x": screenshotCoordinate,
                    "to_y": screenshotCoordinate,
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
            description: "Select text inside a text element via accessibility (background, never clicks or presses). 'text' must occur exactly (case-sensitive) in the element's full value; if it occurs more than once the call fails unless prefix/suffix/occurrence pick one. selection cursor_before/cursor_after places the caret instead. The result is read back and verified. Secure (password) fields are refused.",
            inputSchema: obj(
                [
                    "app": app,
                    "element_index": string,
                    "text": ["type": "string", "minLength": 1, "description": "Exact text to select."],
                    "prefix": ["type": "string", "description": "Only match where this text immediately precedes it."],
                    "suffix": ["type": "string", "description": "Only match where this text immediately follows it."],
                    "occurrence": ["type": "integer", "minimum": 1, "description": "1-based pick among the remaining matches. Required when more than one remains."],
                    "selection": [
                        "type": "string",
                        "enum": TextSelectionMode.allCases.map(\.rawValue),
                        "description": "text (default) selects the match; cursor_before/cursor_after place a zero-length caret at its start/end.",
                    ],
                ],
                ["app", "element_index", "text"]
            ),
            handler: toolSelectText
        ),
        ToolDefinition(
            name: "open_app",
            description: "Launch an app that isn't running, or bring a running one to the front. You do not need this to interact with a running app: every other tool works on background apps without taking focus. Set background=true to launch without bringing the app forward (and to leave an already running app where it is).",
            inputSchema: obj([
                "app": app,
                "background": [
                    "type": "boolean",
                    "description": "Launch or keep the app in the background instead of activating it. Default false.",
                ],
            ], ["app"]),
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
        ToolDefinition(
            name: "list_windows",
            description: "List on-screen app windows with stable WindowServer IDs, process IDs, titles, bounds, and front-to-back order. Optionally filter by app.",
            inputSchema: obj(["app": app], []),
            handler: toolListWindows
        ),
        ToolDefinition(
            name: "verify_state",
            description: "Wait up to a bounded timeout for accessibility text to exist or not exist in an app. Optionally restrict the match to an AX role.",
            inputSchema: obj(
                [
                    "app": app,
                    "text": string,
                    "condition": ["type": "string", "enum": ["exists", "not_exists"]],
                    "role": string,
                    "timeout_ms": ["type": "integer", "minimum": 0, "maximum": 15_000],
                    "poll_interval_ms": ["type": "integer", "minimum": 20, "maximum": 1_000],
                ],
                ["app", "text"]
            ),
            handler: toolVerifyState
        ),
        ToolDefinition(
            name: "set_window_frame",
            description: "Move and resize a specific app window by stable window_id from list_windows. Coordinates are global screen points.",
            inputSchema: obj(
                [
                    "app": app,
                    "window_id": ["type": "integer", "minimum": 1],
                    "x": number,
                    "y": number,
                    "width": ["type": "number", "minimum": 64, "maximum": 20_000],
                    "height": ["type": "number", "minimum": 64, "maximum": 20_000],
                ],
                ["app", "window_id", "x", "y", "width", "height"]
            ),
            handler: toolSetWindowFrame
        ),
        ToolDefinition(
            name: "invoke_menu",
            description: "Invoke an app menu item by title path, for example [\"File\", \"New Window\"]. Intermediate menus are opened with AXPress and the final item is invoked.",
            inputSchema: obj(
                [
                    "app": app,
                    "path": [
                        "type": "array",
                        "items": ["type": "string", "minLength": 1],
                        "minItems": 1,
                        "maxItems": 8,
                    ],
                ],
                ["app", "path"]
            ),
            handler: toolInvokeMenu
        ),
        ToolDefinition(
            name: "point_at",
            description: "Show the user something without touching it: the cursor flies to an element (or x,y) from the last get_app_state and shows an optional label bubble. Nothing is clicked or focused. Use it to teach, or to show what you are about to act on.",
            inputSchema: obj(
                [
                    "app": app,
                    "element_index": ["type": ["string", "integer"], "description": "Element from the last get_app_state of this app."],
                    "x": screenshotCoordinate,
                    "y": screenshotCoordinate,
                    "label": ["type": "string", "maxLength": 160, "description": "Short text shown beside the cursor."],
                    "hold_ms": ["type": "integer", "minimum": 500, "maximum": 15000, "description": "How long the label stays. Default 4000."],
                    "speak": speakOption,
                ],
                ["app"]
            ),
            handler: toolPointAt
        ),
        ToolDefinition(
            name: "annotate",
            description: "Draw on screen over an app to explain something: rectangles, ellipses, arrows, lines, freehand paths and pill labels, plus an optional caption, in screenshot pixels or pinned to element_index. Strokes draw themselves in, never receive clicks, are hidden from your screenshots, and clear after duration_ms or if the window moves.",
            inputSchema: obj(
                [
                    "app": app,
                    "items": [
                        "type": "array",
                        "maxItems": 24,
                        "items": [
                            "type": "object",
                            "properties": [
                                "shape": ["type": "string", "enum": ["rect", "ellipse", "arrow", "line", "path", "label"]],
                                "element_index": ["type": ["string", "integer"]],
                                "x": number, "y": number, "width": number, "height": number,
                                "from": ["type": "array", "items": number, "minItems": 2, "maxItems": 2],
                                "to": ["type": "array", "items": number, "minItems": 2, "maxItems": 2],
                                "at": ["type": "array", "items": number, "minItems": 2, "maxItems": 2],
                                "points": ["type": "array", "items": ["type": "array", "items": number]],
                                "text": ["type": "string", "maxLength": 60],
                                "color": ["type": "string", "enum": ["red", "orange", "yellow", "green", "blue", "purple", "pink", "white", "black"]],
                            ],
                            "required": ["shape"],
                        ],
                    ],
                    "caption": ["type": "string", "maxLength": 200, "description": "Subtitle shown along the bottom of the window."],
                    "duration_ms": ["type": "integer", "minimum": 1000, "maximum": 60000, "description": "Default 8000."],
                    "speak": speakOption,
                ],
                ["app"]
            ),
            handler: toolAnnotate
        ),
        ToolDefinition(
            name: "buddy",
            description: "Give your cursor presence. follow: true makes it ride beside the user's own pointer while you talk them through something (your actions still fly it to their targets). thinking: true shows animated dots while you work something out. emote reacts once: nod (yes / got it), shake (no / not quite), sparkle (look here / nice), celebrate (done!). Flights leave a soft trail automatically.",
            inputSchema: obj(
                [
                    "follow": ["type": "boolean"],
                    "follow_ms": ["type": "integer", "minimum": 1000, "maximum": 1800000, "description": "Default 120000."],
                    "thinking": ["type": "boolean"],
                    "thinking_ms": ["type": "integer", "minimum": 500, "maximum": 600000, "description": "Auto-clear after this long. Default 30000."],
                    "emote": ["type": "string", "enum": ["nod", "shake", "sparkle", "celebrate"]],
                    "speak": speakOption,
                ],
                []
            ),
            handler: toolBuddy
        ),
        ToolDefinition(
            name: "watch_user",
            description: "Watch what the user does during a \"now you try\" step, then coach them: returns a timeline of their own clicks (with the element and app under each), keyboard shortcuts, app switches and how many characters they typed (never what). Your own input is ignored. Stops when the user clicks anything (until: click), clicks a given element (click_element), switches to target_app (app), presses a shortcut (shortcut), pauses for idle_ms (idle, default), or when duration_ms runs out (duration). Optional prompt shows as a bubble.",
            inputSchema: obj(
                [
                    "until": ["type": "string", "enum": ["click", "click_element", "app", "shortcut", "idle", "duration"]],
                    "app": app,
                    "element_index": ["type": ["string", "integer"], "description": "For click_element."],
                    "x": number, "y": number, "width": number, "height": number,
                    "target_app": ["type": "string", "description": "For until: app."],
                    "shortcut": ["type": "string", "description": "For until: shortcut, like cmd+shift+s."],
                    "idle_ms": ["type": "integer", "minimum": 500, "maximum": 120000, "description": "Default 4000."],
                    "duration_ms": ["type": "integer", "minimum": 2000, "maximum": 600000, "description": "Longest to watch. Default 60000."],
                    "prompt": ["type": "string", "maxLength": 160, "description": "What you asked them to try, shown as a bubble."],
                    "speak": speakOption,
                ],
                []
            ),
            handler: toolWatchUser
        ),
        ToolDefinition(
            name: "lasso_region",
            description: "Ask the user to draw around something on screen with their mouse (a circle, loop or stroke) to show you what they mean, for example \"what's this?\" Returns the region in screen points, the element at its centre, and an image of what is inside it. Only the user's physical drawing counts. Esc cancels.",
            inputSchema: obj(
                [
                    "prompt": ["type": "string", "maxLength": 160],
                    "timeout_s": ["type": "integer", "minimum": 5, "maximum": 600, "description": "Default 120."],
                    "speak": speakOption,
                ],
                []
            ),
            handler: toolLassoRegion
        ),
        ToolDefinition(
            name: "magnify",
            description: "Show a live, circular zoom lens of a small region beside it, so a tiny control or dense text is readable while you explain it. Pin it to element_index (or x, y, width, height in screenshot pixels with app; screen points without). It updates in real time, never takes clicks, and closes after duration_ms or with clear: true.",
            inputSchema: obj(
                [
                    "app": app,
                    "element_index": ["type": ["string", "integer"]],
                    "x": number, "y": number, "width": number, "height": number,
                    "zoom": ["type": "number", "minimum": 1.5, "maximum": 8, "description": "Default 3."],
                    "label": ["type": "string", "maxLength": 80],
                    "duration_ms": ["type": "integer", "minimum": 1000, "maximum": 120000, "description": "Default 8000."],
                    "clear": ["type": "boolean", "description": "Close your magnifier."],
                    "speak": speakOption,
                ],
                []
            ),
            handler: toolMagnify
        ),
        ToolDefinition(
            name: "suggest",
            description: "Offer the user an idea on a small card in the top-right corner (\"Want me to rename these 40 files?\") with 1 to 3 buttons, the first being your primary action, and wait for their answer. Only a physical click by the user counts. Use it instead of acting on a guess.",
            inputSchema: obj(
                [
                    "title": ["type": "string", "maxLength": 90],
                    "body": ["type": "string", "maxLength": 240],
                    "actions": ["type": "array", "items": ["type": "string", "maxLength": 24], "minItems": 1, "maxItems": 3, "description": "Default [\"Do it\", \"Not now\"]."],
                    "symbol": ["type": "string", "description": "An SF Symbol name for the icon, like wand.and.stars. Default sparkles."],
                    "timeout_s": ["type": "integer", "minimum": 5, "maximum": 900, "description": "Default 120."],
                    "speak": speakOption,
                ],
                ["title"]
            ),
            handler: toolSuggest
        ),
        ToolDefinition(
            name: "job",
            description: "Show a job card for a long-running task in the bottom-left corner: title, current step, and progress (0 to 1, or omit for a busy bar). Call it again with the same id to update it, and finish with state done or failed. The card gives the user Pause and Stop buttons that act on you alone, so keep it updated while you work.",
            inputSchema: obj(
                [
                    "id": ["type": "string", "maxLength": 64, "description": "Default main."],
                    "title": ["type": "string", "maxLength": 80],
                    "step": ["type": "string", "maxLength": 120],
                    "progress": ["type": "number", "minimum": 0, "maximum": 1],
                    "state": ["type": "string", "enum": ["running", "done", "failed"]],
                    "clear": ["type": "boolean"],
                ],
                []
            ),
            handler: toolJob
        ),
        ToolDefinition(
            name: "clear_annotations",
            description: "Remove everything annotate drew.",
            inputSchema: obj([:], []),
            handler: toolClearAnnotations
        ),
        ToolDefinition(
            name: "show_visual",
            description: """
            Render anything on the user's screen, live: write HTML with CSS, SVG, canvas, WebGL, scripts or CDN libraries \
            (three.js, d3, Chart.js, GSAP...) and it appears in a transparent panel pinned beside or over an element, over a \
            window, or across the screen. Use it to explain, teach, visualise data, diagram how something works, celebrate, \
            or build a small interactive widget. The page gets window.maccu: data (your JSON), targets (named rects in the \
            panel's CSS pixels, including anchor and window, each with x, y, width, height, cx, cy), side (where the anchor \
            is: left/right/top/bottom/none), frame, reduceMotion, send(value) to report events to you, close(), \
            on('update', fn), resize(w, h) to fit content, and curve(x1,y1,x2,y2) for arrow paths. Or pick a template \
            (spotlight, coach, checklist, keycaps, confetti, chart, compare) and pass data. A design kit is preloaded: mc-card, mc-title, mc-sub, \
            mc-pill, mc-gradient-text, mc-glow, mc-ring, mc-in, mc-stagger, mc-draw, CSS variables --mc-accent, --mc-accent-2, \
            --mc-hot, --mc-ok, --mc-warn, --mc-ink, --mc-dim, --mc-glass. The background is transparent, so draw only what \
            should show. Panels are click-through unless interactive, follow their window, are hidden from your screenshots, \
            and showing the same id again replaces it. Esc or Pause clears every visual.
            """,
            inputSchema: obj(
                [
                    "id": ["type": "string", "maxLength": 64, "description": "Name for this visual, to update or clear it. Default main."],
                    "html": ["type": "string", "description": "The page or fragment to render. With a template, extra HTML (styles, scripts) appended to it."],
                    "template": [
                        "type": "string",
                        "enum": visualTemplates.keys.sorted(),
                        "description": "A ready-made visual driven by data: " + visualTemplates.values.sorted { $0.name < $1.name }.map { "\($0.name): \($0.summary)" }.joined(separator: " "),
                    ],
                    "app": ["type": "string", "description": "Pin to this app's window (needs a fresh get_app_state). Omit for screen-level visuals."],
                    "element_index": ["type": ["string", "integer"], "description": "Anchor element from the last get_app_state."],
                    "x": number, "y": number, "width": number, "height": number,
                    "placement": [
                        "type": "string",
                        "enum": ["beside", "over", "center", "window", "screen", "at"],
                        "description": "beside the anchor (default with an anchor), over it exactly, centred on it or the window/screen (default otherwise), covering the window, covering the screen, or at the anchor's top-left. x, y, width, height are screenshot pixels with app, screen points without.",
                    ],
                    "panel_width": ["type": "number", "description": "Panel width in points for beside/center/at. Default 380."],
                    "panel_height": ["type": "number", "description": "Panel height in points. Default 240."],
                    "targets": [
                        "type": "object",
                        "description": "Named elements the page can draw to: {\"save\": 12, \"chart\": [x, y, w, h]}. Delivered as maccu.targets in panel coordinates.",
                    ],
                    "data": ["description": "Any JSON, delivered as maccu.data."],
                    "interactive": ["type": "boolean", "description": "Let the user click and type in it (it is labelled as yours). Default false: clicks pass through."],
                    "backdrop": ["type": "string", "enum": ["none", "glass", "dark"], "description": "A native frosted backdrop behind the page. Default none."],
                    "follow_window": ["type": "boolean", "description": "Move with the app window. Default true."],
                    "duration_ms": ["type": "integer", "minimum": 0, "maximum": 1800000, "description": "Lifetime; 0 keeps it until cleared. Default 30000."],
                    "speak": speakOption,
                ],
                []
            ),
            handler: toolShowVisual
        ),
        ToolDefinition(
            name: "update_visual",
            description: "Change a live visual without redrawing it: run JavaScript in it (top-level await and return work; the returned value comes back to you), push new data (fires maccu.on('update')), move targets, or replace its html. Also collects what the user did in it (events from maccu.send), waits for the next event with wait_event_ms, reports page errors, and with snapshot: true returns a PNG of the visual so you can check how it looks.",
            inputSchema: obj(
                [
                    "id": ["type": "string", "maxLength": 64, "description": "Default main."],
                    "app": ["type": "string", "description": "Needed only to resolve element-index targets."],
                    "script": ["type": "string", "description": "JavaScript function body run in the page, for example: document.querySelector('#n').textContent = 42; return 'ok'."],
                    "html": ["type": "string", "description": "Replace the whole page."],
                    "data": ["description": "New maccu.data."],
                    "targets": ["type": "object", "description": "Replace maccu.targets, like show_visual."],
                    "snapshot": ["type": "boolean", "description": "Return a PNG of the visual."],
                    "wait_event_ms": ["type": "integer", "minimum": 0, "maximum": 600000, "description": "Wait up to this long for the user to trigger maccu.send."],
                ],
                []
            ),
            handler: toolUpdateVisual
        ),
        ToolDefinition(
            name: "clear_visuals",
            description: "Remove one live visual by id, or all of yours.",
            inputSchema: obj(["id": ["type": "string", "maxLength": 64]], []),
            handler: toolClearVisuals
        ),
        ToolDefinition(
            name: "ask_user",
            description: "Ask the user a short question with 2 to 4 answer chips beside your cursor and wait for their click. Only a physical click by the user counts; your own input tools cannot answer it.",
            inputSchema: obj(
                [
                    "question": ["type": "string", "maxLength": 200],
                    "options": ["type": "array", "items": ["type": "string", "maxLength": 40], "minItems": 2, "maxItems": 4],
                    "timeout_s": ["type": "integer", "minimum": 5, "maximum": 600, "description": "Default 120."],
                    "speak": speakOption,
                ],
                ["question", "options"]
            ),
            handler: toolAskUser
        ),
        ToolDefinition(
            name: "pick_element",
            description: "Let the user point back: their next click (or several clicks, then Done) is captured instead of reaching the app, and you get the app, element and, when it is in your last snapshot, its element_index and coordinates.",
            inputSchema: obj(
                [
                    "prompt": ["type": "string", "maxLength": 160, "description": "e.g. Click the email you mean"],
                    "multiple": ["type": "boolean", "description": "Collect several clicks until the user presses Done."],
                    "timeout_s": ["type": "integer", "minimum": 5, "maximum": 600, "description": "Default 120."],
                ],
                []
            ),
            handler: toolPickElement
        ),
        ToolDefinition(
            name: "wait_for_user",
            description: "Hand a step to the user (passwords, 2FA codes, permission dialogs, anything you should not do yourself): point at the element with an instruction and wait until they click it or change its value. Secure fields are only watched by length; their contents are never read.",
            inputSchema: obj(
                [
                    "app": app,
                    "element_index": ["type": ["string", "integer"]],
                    "x": screenshotCoordinate,
                    "y": screenshotCoordinate,
                    "instruction": ["type": "string", "maxLength": 160, "description": "e.g. Enter your password, then click Sign In"],
                    "until": ["type": "string", "enum": ["click", "value_change", "either"], "description": "Default either."],
                    "timeout_s": ["type": "integer", "minimum": 5, "maximum": 600, "description": "Default 120."],
                    "speak": speakOption,
                ],
                ["app", "instruction"]
            ),
            handler: toolWaitForUser
        ),
        ToolDefinition(
            name: "guide",
            description: "Walk the user through a task step by step (up to 20 steps). A timeline bar across the top shows every step with Back, Show again, Skip/Next and Stop. Each step points at an element with an instruction and, by default, advances when the user clicks it; advance_on can instead wait for a shortcut, a switch to another app, or the user pressing Next. wait_for holds a step until an app (and optionally a window) is open, for steps that span apps. Steps may carry annotate items. Reports which steps the user skipped. Set save_as to keep the tour (element-based, not pixels) so the user can replay it later from the Mac Computer Use menu without you.",
            inputSchema: obj(
                [
                    "app": app,
                    "steps": [
                        "type": "array",
                        "minItems": 1,
                        "maxItems": 20,
                        "items": [
                            "type": "object",
                            "properties": [
                                "element_index": ["type": ["string", "integer"]],
                                "x": number,
                                "y": number,
                                "instruction": ["type": "string", "maxLength": 140],
                                "annotate": ["type": "array", "items": ["type": "object"]],
                                "speak": speakOption,
                                "advance_on": ["type": "string", "enum": ["click", "shortcut", "app", "next"], "description": "Default click with a target, next without."],
                                "shortcut": ["type": "string", "description": "For advance_on shortcut, like cmd+s."],
                                "target_app": ["type": "string", "description": "For advance_on app."],
                                "wait_for": [
                                    "type": "object",
                                    "properties": ["app": ["type": "string"], "window": ["type": "string", "description": "Text the window title must contain."]],
                                    "required": ["app"],
                                ],
                            ],
                            "required": ["instruction"],
                        ],
                    ],
                    "title": ["type": "string", "maxLength": 80],
                    "save_as": ["type": "string", "maxLength": 60, "description": "Name to save the tour under. Every step must use element_index."],
                    "timeout_s": ["type": "integer", "minimum": 5, "maximum": 600, "description": "Per step. Default 120."],
                    "speak": ["type": "boolean", "description": "Read every step's instruction aloud. A step's own speak overrides it."],
                ],
                ["app", "steps"]
            ),
            handler: toolGuide
        ),
        ToolDefinition(
            name: "say",
            description: "Say something aloud to the user in the Mac's own voice (on-device, no cloud). Use it to narrate what you are doing or to get their attention; keep it to a sentence or two. Speech queues behind other agents', Esc stops it, and when the user has turned Speak Aloud off the result says they did not hear it.",
            inputSchema: obj(
                [
                    "text": ["type": "string", "maxLength": 400],
                    "wait": ["type": "boolean", "description": "Wait until the speech finishes. Default true."],
                    "rate": ["type": "number", "minimum": 0.5, "maximum": 1.5, "description": "Speaking speed, 1 = normal. Default: the user's setting."],
                    "voice": ["type": "string", "description": "A voice name (Samantha), language (en-GB) or identifier; \"list\" returns the installed voices. Default: the user's setting."],
                ],
                []
            ),
            handler: toolSay
        ),
        ToolDefinition(
            name: "health_report",
            description: "Report permission, process, bundle, overlay, app/window-resolution, and input-safety health as machine-readable JSON without prompting for permissions.",
            inputSchema: obj([:], []),
            handler: { _ in toolHealthReport() }
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
    if let refusal = toolCallGate?(name) { return refusal }
    return tool.handler(args)
}
