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
import ImageIO
import ScreenCaptureKit

// MARK: - Logging (stderr only)
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - Thread-safe cancel flag
final class Flag {
    private var v = false; private let l = NSLock()
    var value: Bool { l.lock(); defer { l.unlock() }; return v }
    func set(_ nv: Bool) { l.lock(); v = nv; l.unlock() }
}
let cancelFlag = Flag()

// Thread-safe one-shot box, for handing a value back out of a detached Task.
final class Box<T>: @unchecked Sendable {
    private var v: T?; private let l = NSLock()
    func set(_ x: T?) { l.lock(); v = x; l.unlock() }
    func get() -> T? { l.lock(); defer { l.unlock() }; return v }
}

// Run an async operation from our synchronous tool path. Returns nil on throw or timeout.
func blockingRun<T>(timeout: TimeInterval, _ op: @escaping @Sendable () async throws -> T) -> T? {
    let sem = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task.detached { box.set(try? await op()); sem.signal() }
    if sem.wait(timeout: .now() + timeout) == .timedOut { return nil }
    return box.get()
}

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
// AX values routinely carry newlines and runs of whitespace (a whole note body arrives as
// one AXValue). Collapse them so one element stays one line and the text budget means
// what it says — otherwise 1200 elements render as thousands of lines.
func sanitizeText(_ s: String, limit: Int) -> String {
    let collapsed = s.split(whereSeparator: { $0.isNewline || $0 == "\t" })
        .joined(separator: " ")
        .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    guard limit != Int.max, collapsed.count > limit else { return collapsed }
    return String(collapsed.prefix(limit)) + "…"
}

func describe(_ el: AXUIElement, textLimit: Int) -> (String, String) {
    let role = axStr(el, "AXRole") ?? "AXUnknown"
    var label = axStr(el, "AXTitle") ?? ""
    if label.isEmpty { label = axStr(el, "AXValue") ?? "" }
    if label.isEmpty { label = axStr(el, "AXDescription") ?? "" }
    if label.isEmpty { label = axStr(el, "AXRoleDescription") ?? "" }
    return (role, sanitizeText(label, limit: textLimit))
}
func walk(_ el: AXUIElement, depth: Int, counter: inout Int, out: inout [Node], maxNodes: Int, maxDepth: Int, textLimit: Int) {
    if counter >= maxNodes || depth > maxDepth { return }
    let idx = counter; counter += 1; elementRegistry[idx] = el
    let d = describe(el, textLimit: textLimit)
    out.append(Node(index: idx, depth: depth, role: d.0, label: d.1, frame: axFrame(el), actions: axActions(el)))
    for child in axArr(el, "AXChildren") {
        if counter >= maxNodes { break }
        walk(child, depth: depth+1, counter: &counter, out: &out, maxNodes: maxNodes, maxDepth: maxDepth, textLimit: textLimit)
    }
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
// Coordinates are emitted in screenshot pixel space so they line up with the image the
// model is looking at — the same space `click(x, y)` expects. Elements that fall outside
// the captured window (menu bar extras, off-screen scrollers) get no coordinate at all
// rather than a misleading one.
func renderTree(_ nodes: [Node], ctx: SnapshotContext?, maxLines: Int) -> String {
    func interesting(_ n: Node) -> Bool {
        if n.role == "AXWindow" { return true }
        if interactiveRoles.contains(n.role) { return true }
        if !n.actions.filter({ !noiseActions.contains($0) }).isEmpty { return true }
        if (n.role == "AXStaticText" || n.role == "AXHeading"), !n.label.isEmpty { return true }
        return false
    }
    func coordinate(_ f: CGRect) -> String? {
        guard let ctx = ctx else { return "@(\(Int(f.midX)),\(Int(f.midY)))" }
        let p = screenToPixel(CGPoint(x: f.midX, y: f.midY), ctx)
        let w = CGFloat(ctx.windowBounds.width) * ctx.pixelScale
        let h = CGFloat(ctx.windowBounds.height) * ctx.pixelScale
        guard p.x >= 0, p.y >= 0, p.x <= w, p.y <= h else { return nil }
        return "@(\(Int(p.x)),\(Int(p.y)))"
    }
    var out: [String] = []
    var lastInteractiveLabel = ""
    for n in nodes {
        guard interesting(n) else { continue }
        // skip static text that just repeats the interactive element above it
        if n.role == "AXStaticText", n.label == lastInteractiveLabel { continue }
        let indent = String(repeating: " ", count: min(n.depth, 14))
        var line = "[\(n.index)]\(indent)\(n.role.replacingOccurrences(of: "AX", with: ""))"
        if !n.label.isEmpty { line += " \"\(n.label)\"" }
        if let f = n.frame, let c = coordinate(f) { line += " " + c }
        let acts = n.actions.filter { !noiseActions.contains($0) }
            .map { sanitizeText($0.replacingOccurrences(of: "AX", with: "").replacingOccurrences(of: "Action", with: ""), limit: 40) }
            .filter { !$0.isEmpty }
        if !acts.isEmpty { line += " {\(acts.joined(separator: ","))}" }
        // Belt and braces: some apps hand back multi-line action names or labels, and one
        // element must stay one line for the tree to be readable and for maxLines to hold.
        out.append(sanitizeText(line, limit: Int.max))
        if interactiveRoles.contains(n.role) { lastInteractiveLabel = n.label }
        if out.count >= maxLines { out.append("… (tree truncated at \(maxLines) elements; raise max_tree_nodes or scroll the view)"); break }
    }
    return out.joined(separator: "\n")
}

// MARK: - Screenshot
// Window captures go through ScreenCaptureKit on macOS 14+: it hands back an in-memory
// CGImage for one window, so there are no temp files, occluding windows are irrelevant,
// and a desktop-independent filter never sees our overlay — no hide/show dance needed.
// Older systems fall back to shelling out to `screencapture`, which does need it.

let screenshotMaxPNGBytes = 900_000
let screenshotMaxDimension: CGFloat = 1280
let screenshotMinScale: CGFloat = 0.25
let screenshotCaptureTimeout: TimeInterval = 8

func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }

func backingScale(forQuartzRect r: CGRect) -> CGFloat {
    let cocoa = quartzRectToCocoa(r)
    return NSScreen.screens.first(where: { $0.frame.intersects(cocoa) })?.backingScaleFactor
        ?? NSScreen.main?.backingScaleFactor ?? 1
}

@available(macOS 14.0, *)
func captureWindowSCK(_ windowId: CGWindowID, bounds: CGRect) -> CGImage? {
    let scale = backingScale(forQuartzRect: bounds)
    let w = max(1, Int((bounds.width * scale).rounded()))
    let h = max(1, Int((bounds.height * scale).rounded()))
    return blockingRun(timeout: screenshotCaptureTimeout) { () async throws -> CGImage in
        let content = try await SCShareableContent.current
        guard let win = content.windows.first(where: { $0.windowID == windowId }) else {
            throw NSError(domain: "maccu", code: 1, userInfo: [NSLocalizedDescriptionKey: "window \(windowId) not shareable"])
        }
        let cfg = SCStreamConfiguration()
        cfg.width = w; cfg.height = h
        cfg.showsCursor = false
        cfg.scalesToFit = false
        cfg.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: win)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

func captureWindowCLI(_ windowId: CGWindowID) -> CGImage? {
    OverlayController.shared.hideForCapture()
    defer { OverlayController.shared.showAfterCapture() }
    usleep(60_000)
    let tmp = NSTemporaryDirectory() + "maccu-w-\(UUID().uuidString).png"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l", "\(windowId)", tmp]
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: tmp) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// Capture a specific window by id — works even when the window is occluded or in the
// background, so we can inspect an app without bringing it to the front.
func captureWindow(_ windowId: CGWindowID, bounds: CGRect) -> CGImage? {
    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess(); return nil }
    if #available(macOS 14.0, *), let img = captureWindowSCK(windowId, bounds: bounds) { return img }
    return captureWindowCLI(windowId)
}

func pngData(_ image: CGImage) -> Data? {
    NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

func resizedImage(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let w = max(1, Int((CGFloat(image.width) * scale).rounded()))
    let h = max(1, Int((CGFloat(image.height) * scale).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

// Shrink until the PNG fits the byte budget. A full-res Retina window capture is several
// MB of base64 straight into the model's context; this keeps it bounded. Returns the
// final pixel size too, so the caller can derive the true pixel<->point scale.
func boundedPNG(_ image: CGImage) -> (data: Data, width: Int, height: Int)? {
    guard image.width > 0, image.height > 0 else { return nil }
    var scale = min(1, screenshotMaxDimension / CGFloat(max(image.width, image.height)))
    if scale >= 1, let d = pngData(image), d.count <= screenshotMaxPNGBytes {
        return (d, image.width, image.height)
    }
    var best: (data: Data, width: Int, height: Int)?
    while scale >= screenshotMinScale {
        guard let r = resizedImage(image, scale: scale), let d = pngData(r) else { break }
        best = (d, r.width, r.height)
        if d.count <= screenshotMaxPNGBytes { return best }
        scale *= 0.85
    }
    if best == nil, let d = pngData(image) { best = (d, image.width, image.height) }
    return best
}

// MARK: - Window selection
struct WindowCandidate { let id: CGWindowID; let bounds: CGRect; let title: String?; let order: Int }

func windowCandidates(forPid pid: pid_t) -> [WindowCandidate] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [WindowCandidate] = []
    for (i, info) in list.enumerated() {
        guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let num = info[kCGWindowNumber as String] as? CGWindowID,
              let b = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
        out.append(WindowCandidate(id: num, bounds: rect, title: info[kCGWindowName as String] as? String, order: i))
    }
    return out
}

// Front-to-back order, skipping palettes and toolbars too small to be the real window.
// A title hint (from the AX focused window) wins unless the frontmost window overlaps it —
// that's a sheet or dialog sitting on its parent, and the sheet is what we want to see.
func preferredWindow(forPid pid: pid_t, titleHint: String?) -> WindowCandidate? {
    let all = windowCandidates(forPid: pid)
    let usable = all.filter { $0.bounds.width * $0.bounds.height >= 20_000 }.sorted { $0.order < $1.order }
    guard let frontmost = usable.first else {
        return all.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }.first
    }
    guard let hint = titleHint, !hint.isEmpty, let hinted = usable.first(where: { $0.title == hint }) else {
        return frontmost
    }
    if frontmost.id != hinted.id, frontmost.bounds.intersects(hinted.bounds) { return frontmost }
    return hinted
}

// MARK: - Snapshot context (screenshot pixel space <-> screen points)
// The screenshot handed to the model is a *window crop*, possibly downscaled, while AX
// frames are global screen points. Every coordinate we print or accept is in screenshot
// pixels; this is the only place that translation lives.
struct SnapshotContext {
    let pid: pid_t
    let appLabel: String
    let windowId: CGWindowID
    let windowBounds: CGRect   // Quartz screen points
    let pixelScale: CGFloat    // screenshot pixels per screen point
}
var lastSnapshot: SnapshotContext?

func pixelToScreen(_ p: CGPoint, _ ctx: SnapshotContext) -> CGPoint {
    CGPoint(x: ctx.windowBounds.minX + p.x / ctx.pixelScale,
            y: ctx.windowBounds.minY + p.y / ctx.pixelScale)
}
func screenToPixel(_ p: CGPoint, _ ctx: SnapshotContext) -> CGPoint {
    CGPoint(x: (p.x - ctx.windowBounds.minX) * ctx.pixelScale,
            y: (p.y - ctx.windowBounds.minY) * ctx.pixelScale)
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

// The snapshot's window must still exist, still belong to the app, and still be on screen.
func skyWindowIsCurrent(windowId: CGWindowID, pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowId) as? [[String: Any]] else { return false }
    return list.contains { info in
        (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowId
            && (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            && ((info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
    }
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
    guard skyWindowIsCurrent(windowId: ctx.windowId, pid: ctx.pid) else {
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

    for step in skyClickRecipe(clickCount: clickCount) {
        let pt = step.onTarget ? screenPoint : primer
        let local = step.onTarget ? windowPoint : primer
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
    return nil
}

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
func pidFor(_ args: [String: Any]) -> pid_t? { (args["app"] as? String).flatMap(resolveApp)?.processIdentifier }
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
    let pid = pidFor(args)
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
        guard let ctx = lastSnapshot, pid == nil || ctx.pid == pid else {
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
    let pid = pidFor(args)
    // Optionally focus a target element first (e.g. a text field) via AX.
    if let xs = args["element_index"], let idx = Int("\(xs)"), let el = registryElement(idx, forPid: pid) {
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
    guard let xs = args["element_index"], let idx = Int("\(xs)"), let el = registryElement(idx, forPid: pidFor(args)) else { return toolText("set_value needs a valid element_index from this app's last get_app_state.", isError: true) }
    guard let v = args["value"] as? String else { return toolText("set_value needs 'value'.", isError: true) }
    return controlled("Setting value", targetQuartz: elementFrame(idx)) {
        AXUIElementSetAttributeValue(el, "AXValue" as CFString, v as CFString) == .success ? toolText("Set value of [\(idx)].") : toolText("Element not settable.", isError: true)
    }
}
func toolDrag(_ args: [String: Any]) -> [String: Any] {
    let pid = pidFor(args)
    guard let fx = num(args, "from_x"), let fy = num(args, "from_y"),
          let tx = num(args, "to_x"), let ty = num(args, "to_y") else { return toolText("drag needs from_x,from_y,to_x,to_y.", isError: true) }
    let from = inputPoint(x: fx, y: fy, pid: pid), to = inputPoint(x: tx, y: ty, pid: pid)
    return controlled("Dragging") { mouseDrag(from: from, to: to, pid: pid); return toolText("Dragged (\(Int(fx)),\(Int(fy))) -> (\(Int(tx)),\(Int(ty))).") }
}
func toolSecondaryAction(_ args: [String: Any]) -> [String: Any] {
    guard let xs = args["element_index"], let idx = Int("\(xs)"), let el = registryElement(idx, forPid: pidFor(args)) else { return toolText("needs a valid element_index from this app's last get_app_state.", isError: true) }
    guard let action = args["action"] as? String else { return toolText("needs 'action'.", isError: true) }
    let a = action.hasPrefix("AX") ? action : "AX\(action)"
    return controlled("Action \(a)", targetQuartz: elementFrame(idx)) { AXUIElementPerformAction(el, a as CFString) == .success ? toolText("Performed \(a) on [\(idx)].") : toolText("Action failed.", isError: true) }
}
func toolSelectText(_ args: [String: Any]) -> [String: Any] {
    guard let xs = args["element_index"], let idx = Int("\(xs)"), let el = registryElement(idx, forPid: pidFor(args)) else { return toolText("needs a valid element_index from this app's last get_app_state.", isError: true) }
    return controlled("Selecting", targetQuartz: elementFrame(idx)) { _ = AXUIElementPerformAction(el, "AXPress" as CFString); return toolText("Focused [\(idx)].") }
}

func toolSchemas() -> [[String: Any]] {
    func obj(_ p: [String: Any], _ req: [String]) -> [String: Any] { ["type":"object","properties":p,"required":req,"additionalProperties":false] }
    let s: [String: Any] = ["type":"string"]; let n: [String: Any] = ["type":"number"]
    let app: [String: Any] = ["type":"string","description":"App name, bundle id, or path"]
    return [
        ["name":"list_apps","description":"List running applications.","inputSchema":obj([:],[])],
        ["name":"get_app_state","description":"Inspect an app without activating it: returns a screenshot of its key window plus an indexed accessibility tree. Call this once before interacting; element_index values and all coordinates come from here.","inputSchema":obj(["app":app,"text_limit":["type":["string","integer"],"description":"Max characters of text per element. Use \"max\" for full text. Default 500."],"max_tree_nodes":["type":"integer","description":"Max accessibility nodes to walk and render. Default 1200."],"max_tree_depth":["type":"integer","description":"Max tree depth to walk. Default 64."]],["app"])],
        ["name":"click","description":"Click by element_index (from get_app_state) or by x,y. Coordinates are in SCREENSHOT PIXELS — read them straight off the get_app_state image or its tree, not global screen points. Shows a live cursor + click flash.","inputSchema":obj(["app":app,"element_index":s,"x":n,"y":n,"click_count":["type":"integer"],"mouse_button":["type":"string","enum":["left","right","middle"]],"click_method":["type":"string","enum":["auto","accessibility","app_post","sky_click","global"],"description":"auto (default) presses via accessibility when possible, else posts to the app. accessibility forces AXPress. app_post posts a normal event to the app. sky_click uses the SkyLight background path — the one that works on background Chromium/Electron web content, left button only. global moves the real system pointer."]],["app"])],
        ["name":"type_text","description":"Type literal unicode text.","inputSchema":obj(["app":app,"text":s],["app","text"])],
        ["name":"press_key","description":"Press a key/combo (xdotool-style: Return, Tab, cmd+c, Up).","inputSchema":obj(["app":app,"key":s],["app","key"])],
        ["name":"scroll","description":"Scroll up/down/left/right by pages, optionally over an element.","inputSchema":obj(["app":app,"element_index":s,"direction":["type":"string","enum":["up","down","left","right"]],"pages":n],["app","direction"])],
        ["name":"set_value","description":"Set the AXValue of a settable element.","inputSchema":obj(["app":app,"element_index":s,"value":s],["app","element_index","value"])],
        ["name":"drag","description":"Drag the mouse between two points, in screenshot pixel coordinates from the last get_app_state.","inputSchema":obj(["app":app,"from_x":n,"from_y":n,"to_x":n,"to_y":n],["app","from_x","from_y","to_x","to_y"])],
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
    case "get_app_state": return toolGetAppState(args)
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
    case "initialize": resultMsg(id, ["protocolVersion":"2024-11-05","capabilities":["tools":["listChanged":false]],"serverInfo":["name":"mac-computer-use","version":"0.5.0"]])
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
log("mac-computer-use 0.5.0 (mcp) starting. AX trusted: \(AXIsProcessTrusted()), ScreenRecording: \(CGPreflightScreenCaptureAccess())")
OverlayController.shared.install()
runStdinLoop()
