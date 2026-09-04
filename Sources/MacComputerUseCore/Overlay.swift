import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

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
