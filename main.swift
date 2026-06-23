// mac-computer-use: native macOS Computer Use MCP server (bundled .app agent).
// Accessibility-tree driven control with a live "followable cursor" overlay.
//
// Architecture:
//   - main thread runs NSApplication + the overlay GUI (window server work must be on main).
//   - a background thread runs the MCP stdio JSON-RPC loop; tool calls synthesize input
//     (CGEvent) off-main and marshal overlay updates to main.
//   - stdout is the protocol channel; ALL logs go to stderr.

import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

// MARK: - Logging (stderr only)
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - Thread-safe cancel flag
final class Flag {
    private var v = false; private let l = NSLock()
    var value: Bool { l.lock(); defer { l.unlock() }; return v }
    func set(_ nv: Bool) { l.lock(); v = nv; l.unlock() }
}
let cancelFlag = Flag()

// MARK: - JSON / stdout
func toJSON(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8) }
let stdoutHandle = FileHandle.standardOutput
let stdoutLock = NSLock()
func writeMessage(_ obj: [String: Any]) {
    var data = toJSON(obj); data.append(0x0A)
    stdoutLock.lock(); stdoutHandle.write(data); stdoutLock.unlock()
}
func resultMsg(_ id: Any?, _ result: Any) {
    var m: [String: Any] = ["jsonrpc": "2.0", "result": result]; if let id = id { m["id"] = id }; writeMessage(m)
}
func errorMsg(_ id: Any?, _ code: Int, _ message: String) {
    var m: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]; if let id = id { m["id"] = id }; writeMessage(m)
}
func toolText(_ s: String, isError: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": s]], "isError": isError]
}

// MARK: - Coordinate conversion (Quartz top-left  <->  Cocoa bottom-left)
func primaryScreen() -> NSScreen { NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first ?? NSScreen.main! }
func quartzPointToCocoa(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryScreen().frame.height - p.y) }
func quartzRectToCocoa(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryScreen().frame.height - r.maxY, width: r.width, height: r.height) }

// MARK: - Overlay (followable cursor, banner, click flashes, target highlight)
let accent = NSColor(srgbRed: 0.42, green: 0.58, blue: 1.0, alpha: 1.0)

final class OverlayView: NSView {
    var cursor: CGPoint = .zero          // window-local
    var controlling = false
    var cancelling = false
    var status = ""
    var target: CGRect? = nil            // window-local
    var flashes: [(c: CGPoint, t: CFTimeInterval)] = []  // window-local + start time

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never intercept

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirty)
        let now = CACurrentMediaTime()

        // Target element highlight
        if let t = target {
            let path = NSBezierPath(roundedRect: t.insetBy(dx: -3, dy: -3), xRadius: 7, yRadius: 7)
            accent.withAlphaComponent(0.95).setStroke()
            path.lineWidth = 2.5
            ctx.setShadow(offset: .zero, blur: 10, color: accent.withAlphaComponent(0.8).cgColor)
            path.stroke()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            accent.withAlphaComponent(0.10).setFill(); path.fill()
        }

        // Click flashes (expanding fading rings)
        for f in flashes {
            let age = now - f.t; let dur = 0.45
            if age > dur { continue }
            let p = age / dur
            let r = 8 + 34 * p
            let ring = NSBezierPath(ovalIn: CGRect(x: f.c.x - r, y: f.c.y - r, width: r*2, height: r*2))
            accent.withAlphaComponent(CGFloat(1.0 - p)).setStroke(); ring.lineWidth = 3 * CGFloat(1.0 - p) + 0.5; ring.stroke()
        }

        // Followable cursor ring
        if controlling {
            let pulse = 0.5 + 0.5 * sin(now * 3.2)
            let outerR = 17.0 + 4.0 * pulse
            let outer = NSBezierPath(ovalIn: CGRect(x: cursor.x - outerR, y: cursor.y - outerR, width: outerR*2, height: outerR*2))
            let ringColor = cancelling ? NSColor.systemRed : accent
            ctx.setShadow(offset: .zero, blur: 14, color: ringColor.withAlphaComponent(0.9).cgColor)
            ringColor.withAlphaComponent(0.9).setStroke(); outer.lineWidth = 2.4; outer.stroke()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ringColor.withAlphaComponent(0.10 + 0.06*pulse).setFill(); outer.fill()
            let dotR = 3.0
            let dot = NSBezierPath(ovalIn: CGRect(x: cursor.x - dotR, y: cursor.y - dotR, width: dotR*2, height: dotR*2))
            ringColor.setFill(); dot.fill()
        }

        // Status banner (top-center of primary screen)
        if controlling {
            drawBanner(ctx: ctx)
        }
    }

    private func drawBanner(ctx: CGContext) {
        let label = cancelling ? "Cancelling…" : (status.isEmpty ? "mac-computer-use is controlling your Mac" : status)
        let hint = "Esc to cancel"
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let hintFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textColor = NSColor.white
        let aLabel = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: textColor])
        let aHint = NSAttributedString(string: hint, attributes: [.font: hintFont, .foregroundColor: NSColor(white: 1, alpha: 0.6)])
        let pad: CGFloat = 14, gap: CGFloat = 14, dot: CGFloat = 8
        let lw = aLabel.size().width, hw = aHint.size().width
        let sep: CGFloat = 1
        let w = pad + dot + 8 + lw + gap + sep + gap + hw + pad
        let h: CGFloat = 34
        // primary screen top-center, converted to window-local
        let ps = primaryScreen().frame
        let cocoaCenterX = ps.midX
        let cocoaTopY = ps.maxY - 24 - h
        guard let win = window else { return }
        let localX = cocoaCenterX - win.frame.minX - w/2
        let localY = cocoaTopY - win.frame.minY
        let rect = CGRect(x: localX, y: localY, width: w, height: h)
        let bg = NSBezierPath(roundedRect: rect, xRadius: h/2, yRadius: h/2)
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 16, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor(white: 0.08, alpha: 0.92).setFill(); bg.fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        // pulsing status dot
        let pulse = 0.5 + 0.5*sin(CACurrentMediaTime()*3.2)
        let dotColor = cancelling ? NSColor.systemRed : accent
        let dotRect = CGRect(x: rect.minX + pad, y: rect.midY - dot/2, width: dot, height: dot)
        dotColor.withAlphaComponent(0.6 + 0.4*pulse).setFill(); NSBezierPath(ovalIn: dotRect).fill()
        aLabel.draw(at: CGPoint(x: dotRect.maxX + 8, y: rect.midY - aLabel.size().height/2))
        let sepX = dotRect.maxX + 8 + lw + gap
        NSColor(white: 1, alpha: 0.18).setFill(); NSBezierPath(rect: CGRect(x: sepX, y: rect.minY+8, width: sep, height: h-16)).fill()
        aHint.draw(at: CGPoint(x: sepX + gap, y: rect.midY - aHint.size().height/2))
    }
}

// IPC paths shared between the MCP process and the overlay agent.
let kOverlayStatePath = "/tmp/maccu-overlay-state.json"
let kOverlayCancelPath = "/tmp/maccu-overlay-cancel"

// MCP-side bridge. A bare stdio subprocess cannot host AppKit, so the overlay
// runs in a separate LaunchServices-launched agent (same bundle, `overlay` arg).
// This bridge maintains overlay state, writes it to a file the agent renders,
// and polls a cancel file the agent writes on Esc.
final class OverlayController {
    static let shared = OverlayController()
    private let lock = NSLock()
    private var controlling = false, cancelling = false, status = ""
    private var target: CGRect? = nil                 // quartz rect
    private var flashes: [(CGPoint, Double)] = []      // quartz points
    private var lingerUntil: Double = 0
    private var captureHide = false
    private var captureMode = false
    private var agentLaunched = false

    func install() {
        captureMode = ProcessInfo.processInfo.environment["MACCU_CAPTURE_OVERLAY"] == "1"
        try? FileManager.default.removeItem(atPath: kOverlayCancelPath)
        writeState()
        // Poll the cancel file (written by the agent on Esc) -> trip cancelFlag.
        Thread.detachNewThread {
            while true {
                if FileManager.default.fileExists(atPath: kOverlayCancelPath) { cancelFlag.set(true) }
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: kOverlayStatePath) }

    private func ensureAgent() {
        lock.lock(); let already = agentLaunched; agentLaunched = true; lock.unlock()
        if already { return }
        let bundle = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "-a", bundle, "--args", "overlay"] + (captureMode ? ["capture"] : [])
        try? p.run()
    }

    private func writeState() {
        lock.lock()
        let dict: [String: Any] = [
            "controlling": controlling, "cancelling": cancelling, "status": status,
            "lingerUntil": lingerUntil, "captureHide": captureHide,
            "target": target.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
            "flashes": flashes.map { [$0.0.x, $0.0.y, $0.1] },
            "pid": Int(getpid()), "ts": CACurrentMediaTime(),
        ]
        lock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: URL(fileURLWithPath: kOverlayStatePath), options: .atomic)
        }
    }

    func begin(status: String, targetQuartz: CGRect?) {
        ensureAgent()
        lock.lock(); controlling = true; cancelling = false; self.status = status; target = targetQuartz; lingerUntil = 0; lock.unlock()
        writeState()
    }
    func end() { lock.lock(); controlling = false; lingerUntil = CACurrentMediaTime() + 0.9; lock.unlock(); writeState() }
    func flashClickQuartz(_ p: CGPoint) {
        lock.lock(); flashes.append((p, CACurrentMediaTime())); if flashes.count > 8 { flashes.removeFirst(flashes.count - 8) }; lock.unlock(); writeState()
    }
    func markCancelling() { lock.lock(); cancelling = true; lock.unlock(); writeState() }
    func hideForCapture() {
        if captureMode { return }
        lock.lock(); captureHide = true; lock.unlock(); writeState(); usleep(120_000)
    }
    func showAfterCapture() { lock.lock(); captureHide = false; lock.unlock(); writeState() }
}

// Run a controlling action with overlay + cancellation scaffolding.
func controlled<T>(_ status: String, targetQuartz: CGRect? = nil, _ body: () -> T) -> T {
    cancelFlag.set(false)
    try? FileManager.default.removeItem(atPath: kOverlayCancelPath)
    OverlayController.shared.begin(status: status, targetQuartz: targetQuartz)
    let r = body()
    OverlayController.shared.end()
    return r
}

// MARK: - Overlay agent (separate LaunchServices-launched GUI process)
func runOverlayAgent(capture: Bool) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false; window.backgroundColor = .clear; window.level = .screenSaver
    window.ignoresMouseEvents = true; window.hasShadow = false
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    window.sharingType = capture ? .readOnly : .none
    let view = OverlayView(frame: CGRect(origin: .zero, size: frame.size))
    window.contentView = view
    func toLocalP(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - window.frame.minX, y: p.y - window.frame.minY) }
    func toLocalR(_ r: CGRect) -> CGRect { CGRect(x: r.minX - window.frame.minX, y: r.minY - window.frame.minY, width: r.width, height: r.height) }

    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { ev in
        if ev.keyCode == 53 { FileManager.default.createFile(atPath: kOverlayCancelPath, contents: nil) }
    }

    var missingReads = 0
    Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: kOverlayStatePath)),
              let st = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            missingReads += 1
            if missingReads > 60 { NSApp.terminate(nil) }   // state file gone ~1s -> MCP exited
            return
        }
        missingReads = 0
        if let pid = st["pid"] as? Int, pid > 0, kill(pid_t(pid), 0) != 0 { NSApp.terminate(nil) }
        let now = CACurrentMediaTime()
        let controlling = st["controlling"] as? Bool ?? false
        let linger = st["lingerUntil"] as? Double ?? 0
        let captureHide = st["captureHide"] as? Bool ?? false
        let active = controlling || now < linger
        let showing = active && !captureHide
        view.controlling = active
        view.cancelling = st["cancelling"] as? Bool ?? false
        view.status = st["status"] as? String ?? ""
        view.cursor = toLocalP(NSEvent.mouseLocation)
        if let t = st["target"] as? [Double], t.count == 4 {
            view.target = toLocalR(quartzRectToCocoa(CGRect(x: t[0], y: t[1], width: t[2], height: t[3])))
        } else { view.target = nil }
        let fl = (st["flashes"] as? [[Double]]) ?? []
        view.flashes = fl.filter { now - $0[2] < 0.5 }.map { (toLocalP(quartzPointToCocoa(CGPoint(x: $0[0], y: $0[1]))), $0[2]) }
        if showing { if !window.isVisible { window.orderFrontRegardless() }; view.needsDisplay = true }
        else if window.isVisible { window.orderOut(nil) }
    }
    log("overlay agent running (capture=\(capture))")
    app.run()
    exit(0)
}

// MARK: - Accessibility helpers
func axCopy(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var v: AnyObject?; return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
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

// MARK: - App resolution
func runningApps() -> [NSRunningApplication] { NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular } }
func resolveApp(_ spec: String) -> NSRunningApplication? {
    let apps = runningApps()
    if let a = apps.first(where: { $0.bundleIdentifier?.caseInsensitiveCompare(spec) == .orderedSame }) { return a }
    if let a = apps.first(where: { $0.localizedName?.caseInsensitiveCompare(spec) == .orderedSame }) { return a }
    if let a = apps.first(where: { ($0.localizedName ?? "").lowercased().contains(spec.lowercased()) }) { return a }
    if let a = apps.first(where: { $0.bundleURL?.path.caseInsensitiveCompare(spec) == .orderedSame }) { return a }
    return nil
}

// Bring an app to the front before synthesizing input, so keystrokes/clicks land in
// the right place. Without this, input goes to whatever app is currently frontmost.
func activateApp(_ spec: String) {
    guard let app = resolveApp(spec) else { return }
    if !app.isActive {
        app.activate(options: [.activateAllWindows])
        usleep(220_000) // let the window server bring it forward
    }
}

// Launch an app if not running, otherwise just activate it. Returns a status string.
func launchOrActivate(_ spec: String) -> (ok: Bool, msg: String) {
    if let app = resolveApp(spec) {
        app.activate(options: [.activateAllWindows]); usleep(150_000)
        return (true, "Activated \(app.localizedName ?? spec).")
    }
    let ws = NSWorkspace.shared
    // by bundle id
    if let url = ws.urlForApplication(withBundleIdentifier: spec) {
        ws.open(url); usleep(600_000); return (true, "Launched \(spec).")
    }
    // by app name / path via `open -a`
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", spec]
    do { try p.run(); p.waitUntilExit() } catch { return (false, "Could not launch \(spec).") }
    usleep(700_000)
    return (p.terminationStatus == 0, p.terminationStatus == 0 ? "Launched \(spec)." : "App not found: \(spec).")
}

func toolOpenApp(_ args: [String: Any]) -> [String: Any] {
    guard let spec = args["app"] as? String, !spec.isEmpty else { return toolText("open_app needs 'app'.", isError: true) }
    let r = launchOrActivate(spec)
    return toolText(r.msg, isError: !r.ok)
}

// Run AppleScript and return (output, error). Used for reliable browser navigation and
// other scriptable-app control. First use prompts for Automation permission.
func runAppleScript(_ script: String, timeout: TimeInterval = 30) -> (out: String, err: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let outPipe = Pipe(); let errPipe = Pipe()
    p.standardOutput = outPipe; p.standardError = errPipe
    do { try p.run() } catch { return ("", "Failed to run osascript: \(error)") }
    let watchdog = Thread { Thread.sleep(forTimeInterval: timeout); if p.isRunning { p.terminate() } }
    watchdog.start()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: outData, encoding: .utf8) ?? ""
    let err = String(data: errData, encoding: .utf8) ?? ""
    return (out.trimmingCharacters(in: .whitespacesAndNewlines), err.trimmingCharacters(in: .whitespacesAndNewlines))
}

// Set a browser's active-tab URL directly (background-safe, no keystroke/omnibox dance).
// Works for Safari and any Chromium browser (Chrome, Brave, Edge, Arc, …).
func toolNavigate(_ args: [String: Any]) -> [String: Any] {
    let appSpec = (args["app"] as? String) ?? "Google Chrome"
    guard var url = args["url"] as? String, !url.isEmpty else { return toolText("navigate needs 'url'.", isError: true) }
    if !url.contains("://") { url = "https://" + url }
    let appName = resolveApp(appSpec)?.localizedName ?? appSpec
    let esc = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let isSafari = appName.lowercased().contains("safari")
    let tabExpr = isSafari ? "URL of current tab of front window" : "URL of active tab of front window"
    let newTab = isSafari
        ? "tell application \"\(appName)\" to tell front window to set current tab to (make new tab with properties {URL:\"\(esc)\"})"
        : "tell application \"\(appName)\" to tell front window to make new tab with properties {URL:\"\(esc)\"}"
    let openWin = "tell application \"\(appName)\" to make new window"
    let wantNewTab = (args["new_tab"] as? Bool) ?? false
    // Ensure the app is running first (launch if needed, no foregrounding required for scripting).
    if resolveApp(appSpec) == nil { _ = launchOrActivate(appSpec); usleep(700_000) }
    return controlled("Navigating \(appName)") {
        let script = wantNewTab
            ? "try\n\(newTab)\non error\n\(openWin)\nend try"
            : "try\ntell application \"\(appName)\" to set \(tabExpr) to \"\(esc)\"\non error\n\(openWin)\ntell application \"\(appName)\" to set \(tabExpr) to \"\(esc)\"\nend try"
        let r = runAppleScript(script)
        if r.err.isEmpty { return toolText("Navigated \(appName) to \(url).") }
        return toolText("Navigate failed: \(r.err). (If this is an Automation-permission prompt, approve it and retry.)", isError: true)
    }
}

// MARK: - AX tree
var elementRegistry: [Int: AXUIElement] = [:]
struct Node { let index: Int; let depth: Int; let role: String; let label: String; let frame: CGRect?; let actions: [String] }
func describe(_ el: AXUIElement) -> (String, String) {
    let role = axStr(el, "AXRole") ?? "AXUnknown"
    var label = axStr(el, "AXTitle") ?? ""
    if label.isEmpty { label = axStr(el, "AXValue").map { String($0.prefix(120)) } ?? "" }
    if label.isEmpty { label = axStr(el, "AXDescription") ?? "" }
    if label.isEmpty { label = axStr(el, "AXRoleDescription") ?? "" }
    return (role, label.trimmingCharacters(in: .whitespacesAndNewlines))
}
func walk(_ el: AXUIElement, depth: Int, counter: inout Int, out: inout [Node], maxNodes: Int) {
    if counter >= maxNodes { return }
    let idx = counter; counter += 1; elementRegistry[idx] = el
    let d = describe(el)
    out.append(Node(index: idx, depth: depth, role: d.0, label: d.1, frame: axFrame(el), actions: axActions(el)))
    for child in axArr(el, "AXChildren") { if counter >= maxNodes { break }; walk(child, depth: depth+1, counter: &counter, out: &out, maxNodes: maxNodes) }
}
let interactiveRoles: Set<String> = [
    "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton",
    "AXPopUpButton", "AXComboBox", "AXMenuButton", "AXMenuItem", "AXTabButton", "AXTab",
    "AXSlider", "AXDisclosureTriangle", "AXSearchField", "AXIncrementor", "AXSegment",
]
let noiseActions: Set<String> = ["AXScrollToVisible", "AXShowMenu", "AXRaise"]

// Only emit interactive elements and text content. Structural AXGroup/AXList nodes
// with no label and no real action are dropped. All indices stay valid (the registry
// holds every walked element); we just don't print the noise.
func renderTree(_ nodes: [Node]) -> String {
    func interesting(_ n: Node) -> Bool {
        if n.role == "AXWindow" { return true }
        if interactiveRoles.contains(n.role) { return true }
        if !n.actions.filter({ !noiseActions.contains($0) }).isEmpty { return true }
        if (n.role == "AXStaticText" || n.role == "AXHeading"), !n.label.isEmpty { return true }
        return false
    }
    var out: [String] = []
    var lastInteractiveLabel = ""
    for n in nodes {
        guard interesting(n) else { continue }
        // skip static text that just repeats the interactive element above it
        if n.role == "AXStaticText", n.label == lastInteractiveLabel { continue }
        let indent = String(repeating: " ", count: min(n.depth, 14))
        var line = "[\(n.index)]\(indent)\(n.role.replacingOccurrences(of: "AX", with: ""))"
        if !n.label.isEmpty { line += " \"\(n.label.prefix(90))\"" }
        if let f = n.frame { line += " @(\(Int(f.midX)),\(Int(f.midY)))" }
        let acts = n.actions.filter { !noiseActions.contains($0) }
        if !acts.isEmpty { line += " {\(acts.map { $0.replacingOccurrences(of: "AX", with: "").replacingOccurrences(of: "Action", with: "") }.joined(separator: ","))}" }
        out.append(line)
        if interactiveRoles.contains(n.role) { lastInteractiveLabel = n.label }
        if out.count >= 320 { out.append("… (tree truncated at 320 elements; scroll or narrow the view)"); break }
    }
    return out.joined(separator: "\n")
}

// MARK: - Screenshot
func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }
func screenshotBase64(rect: CGRect?) -> String? {
    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess(); return nil }
    OverlayController.shared.hideForCapture()
    usleep(60_000)
    let tmp = NSTemporaryDirectory() + "maccu-\(Int(Date().timeIntervalSince1970*1000)).png"
    var args = ["-x", "-o"]
    if let r = rect, r.width > 1, r.height > 1 { args += ["-R", "\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))"] }
    args.append(tmp)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); p.arguments = args
    do { try p.run(); p.waitUntilExit() } catch { OverlayController.shared.showAfterCapture(); return nil }
    OverlayController.shared.showAfterCapture()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: tmp)) else { return nil }
    try? FileManager.default.removeItem(atPath: tmp)
    return data.base64EncodedString()
}

// The frontmost on-screen window id owned by a pid (layer 0 = normal windows).
func frontWindowId(forPid pid: pid_t) -> CGWindowID? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in list {
        if let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
           let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
           let num = info[kCGWindowNumber as String] as? CGWindowID { return num }
    }
    return nil
}

// Capture a specific window by id — works even when the window is occluded or in the
// background, so we can inspect an app without bringing it to the front.
func screenshotWindowBase64(_ windowId: CGWindowID) -> String? {
    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess(); return nil }
    OverlayController.shared.hideForCapture()
    let tmp = NSTemporaryDirectory() + "maccu-w-\(Int(Date().timeIntervalSince1970*1000)).png"
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", "\(windowId)", tmp]
    do { try p.run(); p.waitUntilExit() } catch { OverlayController.shared.showAfterCapture(); return nil }
    OverlayController.shared.showAfterCapture()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: tmp)) else { return nil }
    try? FileManager.default.removeItem(atPath: tmp)
    return data.base64EncodedString()
}

// MARK: - Input synthesis (background-capable)
// When a pid is supplied, events are delivered to that process via postToPid — so we
// can drive an app WITHOUT bringing it to the foreground (like Codex). When pid is nil,
// events go to the global HID tap (whatever is frontmost).
func postEvent(_ e: CGEvent, pid: pid_t?) {
    if let pid = pid { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
}

func mouseClick(_ pt: CGPoint, button: CGMouseButton, count: Int, pid: pid_t?) {
    let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp)
        : (button == .center ? (.otherMouseDown, .otherMouseUp) : (.leftMouseDown, .leftMouseUp))
    for i in 1...max(1, count) {
        if cancelFlag.value { return }
        OverlayController.shared.flashClickQuartz(pt)
        if let e = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: pt, mouseButton: button) { e.setIntegerValueField(.mouseEventClickState, value: Int64(i)); postEvent(e, pid: pid) }
        if let e = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: pt, mouseButton: button) { e.setIntegerValueField(.mouseEventClickState, value: Int64(i)); postEvent(e, pid: pid) }
        usleep(40_000)
    }
}
func mouseMoveTo(_ pt: CGPoint, pid: pid_t?) { if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) { postEvent(e, pid: pid) } }
func mouseDrag(from: CGPoint, to: CGPoint, pid: pid_t?) {
    if let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left) { postEvent(e, pid: pid) }; usleep(60_000)
    let steps = 22
    for i in 1...steps {
        if cancelFlag.value { if let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: from, mouseButton: .left) { postEvent(e, pid: pid) }; return }
        let t = Double(i)/Double(steps)
        let p = CGPoint(x: from.x + (to.x-from.x)*t, y: from.y + (to.y-from.y)*t)
        if let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left) { postEvent(e, pid: pid) }; usleep(9_000)
    }
    if let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left) { postEvent(e, pid: pid) }
}
func scrollWheel(dx: Int32, dy: Int32, pid: pid_t?) { if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) { postEvent(e, pid: pid) } }

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

func typeText(_ s: String, pid: pid_t?) {
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
func pressKeyCombo(_ spec: String, pid: pid_t?) -> Bool {
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

// MARK: - Tools
func ensureTrusted() -> Bool { AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }

func toolListApps() -> [String: Any] {
    let apps = runningApps().map { "- \($0.localizedName ?? "?")  [\($0.bundleIdentifier ?? "")] pid=\($0.processIdentifier)\($0.isActive ? " (active)" : "")" }
    return toolText("Running apps:\n" + apps.joined(separator: "\n"))
}
func toolGetAppState(_ appSpec: String) -> [String: Any] {
    guard let app = resolveApp(appSpec) else { return toolText("App not found: \(appSpec). Try list_apps.", isError: true) }
    // Do NOT activate — we inspect in the background. AX reads the tree regardless of
    // focus; the screenshot is captured by window id so it works even when occluded.
    if !AXIsProcessTrusted() { _ = ensureTrusted(); return toolText("Not Accessibility-trusted yet. Enable mac-computer-use in System Settings > Privacy & Security > Accessibility, then retry.", isError: true) }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    let window: AXUIElement? = (axCopy(axApp, "AXFocusedWindow") as! AXUIElement?) ?? (axCopy(axApp, "AXMainWindow") as! AXUIElement?) ?? axArr(axApp, "AXWindows").first
    guard let win = window else { return toolText("No window found for \(appSpec). The app may have no open window.", isError: true) }
    elementRegistry.removeAll(); var counter = 0; var nodes: [Node] = []
    walk(win, depth: 0, counter: &counter, out: &nodes, maxNodes: 600)
    let frame = axFrame(win)
    var content: [[String: Any]] = []
    let shot = frontWindowId(forPid: app.processIdentifier).flatMap(screenshotWindowBase64) ?? screenshotBase64(rect: frame)
    if let b64 = shot { content.append(["type": "image", "data": b64, "mimeType": "image/png"]) }
    var note = ""
    if !screenRecordingGranted() { note = "\n(Screenshot unavailable: enable mac-computer-use in System Settings > Privacy & Security > Screen Recording. The accessibility tree below is fully usable meanwhile.)" }
    let header = "App: \(app.localizedName ?? appSpec) (pid \(app.processIdentifier))\nWindow: \(axStr(win, "AXTitle") ?? "")\(note)\nAccessibility tree (\(nodes.count) elements):"
    content.append(["type": "text", "text": header + "\n" + renderTree(nodes)])
    return ["content": content, "isError": false]
}
func elementCenter(_ index: Int) -> CGPoint? { guard let el = elementRegistry[index], let f = axFrame(el) else { return nil }; return CGPoint(x: f.midX, y: f.midY) }
func elementFrame(_ index: Int) -> CGRect? { elementRegistry[index].flatMap(axFrame) }
func pidFor(_ args: [String: Any]) -> pid_t? { (args["app"] as? String).flatMap(resolveApp)?.processIdentifier }

func toolClick(_ args: [String: Any]) -> [String: Any] {
    let pid = pidFor(args)
    let count = (args["click_count"] as? Int) ?? 1
    let btnStr = (args["mouse_button"] as? String) ?? "left"
    let button: CGMouseButton = btnStr == "right" ? .right : (btnStr == "middle" ? .center : .left)
    let idx: Int? = { if let xs = args["element_index"], let i = Int("\(xs)") { return i }; return nil }()
    var pt: CGPoint?; var tgt: CGRect?
    if let i = idx { pt = elementCenter(i); tgt = elementFrame(i) }
    if pt == nil, let x = args["x"] as? Double, let y = args["y"] as? Double { pt = CGPoint(x: x, y: y) }
    if pt == nil, let x = args["x"] as? Int, let y = args["y"] as? Int { pt = CGPoint(x: Double(x), y: Double(y)) }

    // Prefer a background AXPress for single left-clicks on elements that support it.
    if let i = idx, let el = elementRegistry[i], button == .left, count == 1, axActions(el).contains("AXPress") {
        return controlled("Clicking", targetQuartz: tgt) {
            if let c = elementCenter(i) { OverlayController.shared.flashClickQuartz(c) }
            if AXUIElementPerformAction(el, "AXPress" as CFString) == .success { return toolText("Pressed [\(i)] (AX, background).") }
            if let p = pt { mouseClick(p, button: .left, count: 1, pid: pid); return toolText("Clicked [\(i)] at (\(Int(p.x)),\(Int(p.y))) (AXPress failed).") }
            return toolText("AXPress failed and no coordinates available.", isError: true)
        }
    }
    guard let p = pt else { return toolText("click needs element_index (from last get_app_state) or x,y.", isError: true) }
    return controlled("Clicking", targetQuartz: tgt) {
        mouseMoveTo(p, pid: pid); usleep(120_000)
        if cancelFlag.value { return toolText("Cancelled (Esc).") }
        mouseClick(p, button: button, count: count, pid: pid)
        return toolText("Clicked \(btnStr) x\(count) at (\(Int(p.x)),\(Int(p.y))).")
    }
}
func toolTypeText(_ args: [String: Any]) -> [String: Any] {
    guard let t = args["text"] as? String else { return toolText("type_text needs 'text'.", isError: true) }
    let pid = pidFor(args)
    // Optionally focus a target element first (e.g. a text field) via AX.
    if let xs = args["element_index"], let idx = Int("\(xs)"), let el = elementRegistry[idx] {
        AXUIElementSetAttributeValue(el, "AXFocused" as CFString, kCFBooleanTrue); usleep(60_000)
    }
    return controlled("Typing") { typeText(t, pid: pid); return cancelFlag.value ? toolText("Cancelled (Esc).") : toolText("Typed \(t.count) chars.") }
}
func toolPressKey(_ args: [String: Any]) -> [String: Any] {
    guard let k = args["key"] as? String else { return toolText("press_key needs 'key'.", isError: true) }
    let pid = pidFor(args)
    return controlled("Pressing \(k)") { pressKeyCombo(k, pid: pid) ? toolText("Pressed \(k).") : toolText("Unknown key: \(k).", isError: true) }
}
func toolScroll(_ args: [String: Any]) -> [String: Any] {
    let pid = pidFor(args)
    let dir = (args["direction"] as? String) ?? "down"
    let pages = (args["pages"] as? Double) ?? (args["pages"] as? Int).map(Double.init) ?? 1.0
    var tgt: CGRect?
    if let xs = args["element_index"], let idx = Int("\(xs)") { if let c = elementCenter(idx) { mouseMoveTo(c, pid: pid); usleep(30_000) }; tgt = elementFrame(idx) }
    return controlled("Scrolling \(dir)", targetQuartz: tgt) {
        let amt = Int32(pages * 400)
        switch dir { case "up": scrollWheel(dx:0,dy:amt,pid:pid); case "down": scrollWheel(dx:0,dy:-amt,pid:pid)
        case "left": scrollWheel(dx:amt,dy:0,pid:pid); case "right": scrollWheel(dx:-amt,dy:0,pid:pid)
        default: return toolText("direction must be up/down/left/right.", isError: true) }
        return toolText("Scrolled \(dir) \(pages) page(s).")
    }
}
func toolSetValue(_ args: [String: Any]) -> [String: Any] {
    guard let xs = args["element_index"], let idx = Int("\(xs)"), let el = elementRegistry[idx] else { return toolText("set_value needs element_index from last get_app_state.", isError: true) }
    guard let v = args["value"] as? String else { return toolText("set_value needs 'value'.", isError: true) }
    return controlled("Setting value", targetQuartz: elementFrame(idx)) {
        AXUIElementSetAttributeValue(el, "AXValue" as CFString, v as CFString) == .success ? toolText("Set value of [\(idx)].") : toolText("Element not settable.", isError: true)
    }
}
func toolDrag(_ args: [String: Any]) -> [String: Any] {
    let pid = pidFor(args)
    func d(_ k: String) -> Double? { (args[k] as? Double) ?? (args[k] as? Int).map(Double.init) }
    guard let fx = d("from_x"), let fy = d("from_y"), let tx = d("to_x"), let ty = d("to_y") else { return toolText("drag needs from_x,from_y,to_x,to_y.", isError: true) }
    return controlled("Dragging") { mouseDrag(from: CGPoint(x:fx,y:fy), to: CGPoint(x:tx,y:ty), pid: pid); return toolText("Dragged (\(Int(fx)),\(Int(fy))) -> (\(Int(tx)),\(Int(ty))).") }
}
func toolSecondaryAction(_ args: [String: Any]) -> [String: Any] {
    guard let xs = args["element_index"], let idx = Int("\(xs)"), let el = elementRegistry[idx] else { return toolText("needs element_index.", isError: true) }
    guard let action = args["action"] as? String else { return toolText("needs 'action'.", isError: true) }
    let a = action.hasPrefix("AX") ? action : "AX\(action)"
    return controlled("Action \(a)", targetQuartz: elementFrame(idx)) { AXUIElementPerformAction(el, a as CFString) == .success ? toolText("Performed \(a) on [\(idx)].") : toolText("Action failed.", isError: true) }
}
func toolSelectText(_ args: [String: Any]) -> [String: Any] {
    guard let xs = args["element_index"], let idx = Int("\(xs)"), let el = elementRegistry[idx] else { return toolText("needs element_index.", isError: true) }
    return controlled("Selecting", targetQuartz: elementFrame(idx)) { _ = AXUIElementPerformAction(el, "AXPress" as CFString); return toolText("Focused [\(idx)].") }
}

func toolSchemas() -> [[String: Any]] {
    func obj(_ p: [String: Any], _ req: [String]) -> [String: Any] { ["type":"object","properties":p,"required":req,"additionalProperties":false] }
    let s: [String: Any] = ["type":"string"]; let n: [String: Any] = ["type":"number"]
    let app: [String: Any] = ["type":"string","description":"App name, bundle id, or path"]
    return [
        ["name":"list_apps","description":"List running applications.","inputSchema":obj([:],[])],
        ["name":"get_app_state","description":"Activate an app and return a screenshot of its key window plus an indexed accessibility tree. Call once before interacting; element_index values come from here.","inputSchema":obj(["app":app],["app"])],
        ["name":"click","description":"Click by element_index (from get_app_state) or x,y pixels. Shows a live cursor + click flash.","inputSchema":obj(["app":app,"element_index":s,"x":n,"y":n,"click_count":["type":"integer"],"mouse_button":["type":"string","enum":["left","right","middle"]]],["app"])],
        ["name":"type_text","description":"Type literal unicode text.","inputSchema":obj(["app":app,"text":s],["app","text"])],
        ["name":"press_key","description":"Press a key/combo (xdotool-style: Return, Tab, cmd+c, Up).","inputSchema":obj(["app":app,"key":s],["app","key"])],
        ["name":"scroll","description":"Scroll up/down/left/right by pages, optionally over an element.","inputSchema":obj(["app":app,"element_index":s,"direction":["type":"string","enum":["up","down","left","right"]],"pages":n],["app","direction"])],
        ["name":"set_value","description":"Set the AXValue of a settable element.","inputSchema":obj(["app":app,"element_index":s,"value":s],["app","element_index","value"])],
        ["name":"drag","description":"Drag the mouse between two screen points.","inputSchema":obj(["app":app,"from_x":n,"from_y":n,"to_x":n,"to_y":n],["app","from_x","from_y","to_x","to_y"])],
        ["name":"perform_secondary_action","description":"Invoke a named accessibility action on an element.","inputSchema":obj(["app":app,"element_index":s,"action":s],["app","element_index","action"])],
        ["name":"select_text","description":"Focus a text element.","inputSchema":obj(["app":app,"element_index":s,"text":s],["app","element_index","text"])],
        ["name":"open_app","description":"Launch an app (or activate it if already running). Works for any macOS app — browsers, Music, Notes, etc. Use this to switch focus to an app before interacting, or to start one that isn't open.","inputSchema":obj(["app":app],["app"])],
        ["name":"navigate","description":"Point a browser's active tab at a URL directly (reliable, background — no omnibox typing). Works for Safari and Chromium browsers (Chrome/Brave/Edge/Arc). Set new_tab=true to open in a new tab.","inputSchema":obj(["app":app,"url":s,"new_tab":["type":"boolean"]],["url"])],
    ]
}
// Background-first: input is delivered to the target app's pid (postToPid) and clicks
// prefer AXPress, so we do NOT force the app to the foreground. Use open_app to bring
// an app forward explicitly when you actually want it focused.
func dispatchTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
    switch name {
    case "list_apps": return toolListApps()
    case "open_app": return toolOpenApp(args)
    case "navigate": return toolNavigate(args)
    case "get_app_state": return toolGetAppState((args["app"] as? String) ?? "")
    case "click": return toolClick(args)
    case "type_text": return toolTypeText(args)
    case "press_key": return toolPressKey(args)
    case "scroll": return toolScroll(args)
    case "set_value": return toolSetValue(args)
    case "drag": return toolDrag(args)
    case "perform_secondary_action": return toolSecondaryAction(args)
    case "select_text": return toolSelectText(args)
    default: return toolText("Unknown tool: \(name)", isError: true)
    }
}

// MARK: - JSON-RPC handler
func handle(_ msg: [String: Any]) {
    let id = msg["id"]
    guard let method = msg["method"] as? String else { return }
    switch method {
    case "initialize": resultMsg(id, ["protocolVersion":"2024-11-05","capabilities":["tools":["listChanged":false]],"serverInfo":["name":"mac-computer-use","version":"0.4.0"]])
    case "notifications/initialized","initialized": break
    case "tools/list": resultMsg(id, ["tools": toolSchemas()])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        resultMsg(id, dispatchTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
    case "ping": resultMsg(id, [:])
    default: if id != nil { errorMsg(id, -32601, "Method not found: \(method)") }
    }
}

// MARK: - Entry: GUI on main, MCP loop on background
// MCP stdio loop (runs on the main thread; pure CLI, no AppKit).
func runStdinLoop() -> Never {
    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { log("bad json"); continue }
        handle(obj)
    }
    OverlayController.shared.cleanup()
    exit(0) // stdin closed -> client gone
}

// MARK: - Entry: `overlay` arg => GUI agent; otherwise => MCP stdio server.
if CommandLine.arguments.contains("overlay") {
    runOverlayAgent(capture: CommandLine.arguments.contains("capture"))
}
_ = CGRequestScreenCaptureAccess()   // MCP process needs Screen Recording for screenshots
log("mac-computer-use 0.2.0 (mcp) starting. AX trusted: \(AXIsProcessTrusted()), ScreenRecording: \(CGPreflightScreenCaptureAccess())")
OverlayController.shared.install()
runStdinLoop()
