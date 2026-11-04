// Companion surfaces for teaching: watch what the person does during a
// "now you try" step, let them lasso a region back to the agent, magnify a
// small control live, and caption everything the agent says aloud.
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import QuartzCore
import ScreenCaptureKit

// MARK: - Shortcut names (pure)

private let watchSpecialKeys: [UInt16: String] = [
    36: "return", 76: "enter", 48: "tab", 49: "space", 51: "delete", 117: "forwarddelete", 53: "esc",
    123: "left", 124: "right", 125: "down", 126: "up", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
    122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
]

/// Canonical "cmd+shift+s" form, modifiers in a fixed order.
func canonicalShortcut(modifiers: Set<String>, key: String) -> String {
    let order = ["cmd", "ctrl", "opt", "shift", "fn"]
    return (order.filter(modifiers.contains) + [key.lowercased()]).joined(separator: "+")
}

/// Normalises an agent-written shortcut ("Command+Shift+S", "⌘⇧s") for matching.
func normalizedShortcutSpec(_ spec: String) -> String? {
    var text = spec.lowercased().replacingOccurrences(of: " ", with: "")
    for (symbol, name) in ["⌘": "cmd+", "⇧": "shift+", "⌥": "opt+", "⌃": "ctrl+"] {
        text = text.replacingOccurrences(of: symbol, with: name)
    }
    let parts = text.split(separator: "+").map(String.init).filter { !$0.isEmpty }
    guard let key = parts.last else { return nil }
    let synonyms = ["command": "cmd", "control": "ctrl", "option": "opt", "alt": "opt", "escape": "esc", "enter": "return"]
    let modifiers = Set(parts.dropLast().map { synonyms[$0] ?? $0 })
    return canonicalShortcut(modifiers: modifiers, key: synonyms[key] ?? key)
}

/// What a key press means without revealing what was typed: a shortcut, a
/// named key, or nil for plain typing (which is only ever counted).
func describeKeyPress(keyCode: UInt16, characters: String?, command: Bool, control: Bool, option: Bool, shift: Bool) -> String? {
    var modifiers: Set<String> = []
    if command { modifiers.insert("cmd") }
    if control { modifiers.insert("ctrl") }
    if option { modifiers.insert("opt") }
    if shift { modifiers.insert("shift") }
    if let special = watchSpecialKeys[keyCode] {
        if special == "space" && modifiers.subtracting(["shift"]).isEmpty { return nil }
        return canonicalShortcut(modifiers: modifiers, key: special)
    }
    // Option alone composes characters (é, ü): that is typing, not a shortcut.
    guard command || control, let key = characters?.lowercased(), !key.isEmpty else { return nil }
    return canonicalShortcut(modifiers: modifiers, key: key)
}

// MARK: - Watching the person

struct WatchStop {
    var anyClick = false
    var clickIn: CGRect?          // Quartz
    var app: String?              // localized name, case-insensitive
    var shortcut: String?         // canonical
    var idle: TimeInterval?       // after the first event
}

/// Records the person's own clicks, shortcuts and app switches. Plain typing
/// is counted, never recorded; agent-synthesised input is ignored.
@MainActor
final class UserWatch {
    private var monitors: [Any] = []
    private var observer: NSObjectProtocol?
    private var poll: Timer?
    private let started = CACurrentMediaTime()
    private var lastInput: CFTimeInterval?
    private var events: [[String: Any]] = []
    private let stop: WatchStop
    private let completion: ([String: Any]) -> Void
    private var finished = false

    init(stop: WatchStop, completion: @escaping ([String: Any]) -> Void) {
        self.stop = stop
        self.completion = completion
        let mouse: (NSEvent) -> Void = { [weak self] event in
            guard !eventIsAgentSynthesised(event) else { return }
            let location = NSEvent.mouseLocation
            let quartz = CGPoint(x: location.x, y: primaryScreen().frame.height - location.y)
            let button = event.type == .rightMouseDown ? "right" : "left"
            let count = event.clickCount
            MainActor.assumeIsolated { self?.click(quartz, button: button, count: count) }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: mouse) {
            monitors.append(monitor)
        }
        let key: (NSEvent) -> Void = { [weak self] event in
            guard !eventIsAgentSynthesised(event), !event.isARepeat else { return }
            let flags = event.modifierFlags
            let name = describeKeyPress(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                command: flags.contains(.command), control: flags.contains(.control),
                option: flags.contains(.option), shift: flags.contains(.shift)
            )
            MainActor.assumeIsolated { self?.key(name) }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) {
            monitors.append(monitor)
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let name = app?.localizedName ?? "app"
            let pid = app?.processIdentifier ?? 0
            MainActor.assumeIsolated { self?.switched(to: name, pid: pid) }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
    }

    private var elapsed: Double { (CACurrentMediaTime() - started).rounded(toPlaces: 2) }

    private func record(_ event: [String: Any]) {
        lastInput = CACurrentMediaTime()
        guard events.count < 300 else { return }
        var entry = event
        entry["t"] = elapsed
        events.append(entry)
    }

    private func click(_ point: CGPoint, button: String, count: Int) {
        let owner = windowOwnerUnder(point).map { Int($0) } ?? 0
        record(["kind": "click", "point": [Double(point.x), Double(point.y)], "owner": owner, "button": button, "count": count])
        if stop.anyClick { finish("matched") }
        else if let rect = stop.clickIn, rect.insetBy(dx: -4, dy: -4).contains(point) { finish("matched") }
    }

    private func key(_ name: String?) {
        guard let name else {
            // Coalesce plain typing into one counted run.
            if var last = events.last, last["kind"] as? String == "typing" {
                last["count"] = (last["count"] as? Int ?? 0) + 1
                events[events.count - 1] = last
                lastInput = CACurrentMediaTime()
            } else {
                record(["kind": "typing", "count": 1])
            }
            return
        }
        record(["kind": "key", "shortcut": name])
        if let wanted = stop.shortcut, wanted == name { finish("matched") }
    }

    private func switched(to name: String, pid: pid_t) {
        guard pid != getpid() else { return }
        record(["kind": "app", "app": name])
        if let wanted = stop.app, name.caseInsensitiveCompare(wanted) == .orderedSame { finish("matched") }
    }

    private func checkIdle() {
        guard let idle = stop.idle, let lastInput, CACurrentMediaTime() - lastInput >= idle else { return }
        finish("idle")
    }

    func finish(_ outcome: String) {
        guard !finished else { return }
        finished = true
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        poll?.invalidate()
        completion(["outcome": outcome, "events": events, "elapsed": elapsed])
    }

    /// The events so far, for a timeout reply.
    var snapshot: [String: Any] { ["events": events, "elapsed": elapsed] }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}

// MARK: - Lasso

/// The person draws a loop (or a stroke) around something to show the agent.
@MainActor
final class LassoSession: NSObject {
    private final class CanvasView: NSView {
        weak var session: LassoSession?
        var points: [CGPoint] = [] // Cocoa, window-local
        var closing: CGFloat = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard !eventIsAgentSynthesised(event) else { return }
            points = [convert(event.locationInWindow, from: nil)]
            needsDisplay = true
        }
        override func mouseDragged(with event: NSEvent) {
            guard !eventIsAgentSynthesised(event), !points.isEmpty else { return }
            let point = convert(event.locationInWindow, from: nil)
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 2 { return }
            points.append(point)
            needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            guard !eventIsAgentSynthesised(event), let window else { return }
            let screenPoints = points.map { CGPoint(x: $0.x + window.frame.minX, y: $0.y + window.frame.minY) }
            MainActor.assumeIsolated { session?.drawn(screenPoints) }
        }
        override func draw(_ dirtyRect: NSRect) {
            NSGraphicsContext.current?.cgContext.clear(dirtyRect)
            NSColor.black.withAlphaComponent(0.18).setFill()
            bounds.fill()
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = 4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = accent
            glow.shadowBlurRadius = 10
            glow.set()
            accent.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    private var panels: [InteractivePanel] = []
    private let instruction: CursorBubblePanel
    private let completion: ([CGPoint]?) -> Void
    private var finished = false

    init(prompt: String, captureVisible: Bool, completion: @escaping ([CGPoint]?) -> Void) {
        self.completion = completion
        instruction = CursorBubblePanel(captureVisible: captureVisible)
        super.init()
        for screen in NSScreen.screens {
            let panel = InteractivePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.sharingType = captureVisible ? .readOnly : .none
            let view = CanvasView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.session = self
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        NSCursor.crosshair.push()
        instruction.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        instruction.show(text: "\(prompt)\nDraw around it · Esc to cancel", style: .handoff, now: CACurrentMediaTime(), holdSeconds: nil, typed: false)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            instruction.setFrameOrigin(CGPoint(
                x: screen.visibleFrame.midX - instruction.frame.width / 2,
                y: screen.visibleFrame.maxY - instruction.frame.height - 60
            ))
        }
        instruction.orderFrontRegardless()
    }

    var windowIDs: [CGWindowID] { (panels + [instruction]).map { CGWindowID($0.windowNumber) } }

    fileprivate func drawn(_ cocoaPoints: [CGPoint]) {
        // A tap or a tiny scribble is not a lasso; let the person try again.
        let bounds = cocoaPoints.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard cocoaPoints.count >= 3, bounds.width >= 8 || bounds.height >= 8 else { return }
        let height = primaryScreen().frame.height
        finish(cocoaPoints.map { CGPoint(x: $0.x, y: height - $0.y) })
    }

    func finish(_ result: [CGPoint]?) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        panels.forEach { $0.orderOut(nil) }
        instruction.orderOut(nil)
        completion(result)
    }
}

/// Reduces a freehand path to at most `limit` points, keeping its shape.
func simplifiedPath(_ points: [CGPoint], limit: Int = 120) -> [CGPoint] {
    guard points.count > limit, limit >= 2 else { return points }
    let stride = Double(points.count - 1) / Double(limit - 1)
    return (0..<limit).map { points[min(points.count - 1, Int((Double($0) * stride).rounded()))] }
}

// MARK: - Magnifier

/// A live circular zoom of a small region, drawn beside it.
@MainActor
final class MagnifierLens {
    private let panel: NSPanel
    private let video = CALayer()
    private let ring = CAShapeLayer()
    private let label = CATextLayer()
    private var stream: SCStream?
    private var output: AgentCamOutput?
    private var expiry: Timer?
    let owner: String
    var onClosed: (() -> Void)?
    private(set) var isClosed = false

    init(owner: String, region: CGRect, zoom: CGFloat, label text: String?, captureVisible: Bool, duration: TimeInterval) {
        self.owner = owner
        let side = min(max(max(region.width, region.height) * zoom, 160), 420)
        let labelHeight: CGFloat = text == nil ? 0 : 30
        let screen = cocoaRectToQuartzRect(
            (NSScreen.screens.first { quartzRectToCocoa(region).intersects($0.frame) } ?? NSScreen.main)?.visibleFrame ?? .zero
        )
        let layout = visualLayout(placement: .beside, anchor: region, window: nil, screen: screen, size: CGSize(width: side + 16, height: side + 16 + labelHeight), gap: 18)
        panel = NSPanel(contentRect: quartzRectToCocoa(layout.frame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = captureVisible ? .readOnly : .none
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: layout.frame.size)
        let lensFrame = CGRect(x: 8, y: 8, width: side, height: side)
        let shadow = CALayer()
        shadow.frame = lensFrame
        shadow.cornerRadius = side / 2
        shadow.backgroundColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.45
        shadow.shadowRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: -3)
        root.addSublayer(shadow)
        video.frame = lensFrame
        video.cornerRadius = side / 2
        video.masksToBounds = true
        video.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        video.contentsGravity = .resizeAspectFill
        video.magnificationFilter = .nearest
        root.addSublayer(video)
        ring.path = CGPath(ellipseIn: lensFrame.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = accent.cgColor
        ring.lineWidth = 3
        ring.shadowColor = accent.cgColor
        ring.shadowOpacity = 0.8
        ring.shadowRadius = 8
        ring.shadowOffset = .zero
        root.addSublayer(ring)
        if let text {
            label.string = text
            label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            label.fontSize = 13
            label.foregroundColor = NSColor.white.cgColor
            label.backgroundColor = NSColor(white: 0.08, alpha: 0.85).cgColor
            label.cornerRadius = 11
            label.alignmentMode = .center
            label.truncationMode = .end
            label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            let width = min((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width + 24, side + 16)
            label.frame = CGRect(x: (layout.frame.width - width) / 2, y: side + 16 + 4, width: width, height: 22)
            root.addSublayer(label)
        }
        let view = NSView(frame: root.frame)
        view.wantsLayer = true
        view.layer = root
        panel.contentView = view
        panel.alphaValue = 0
        startStream(region: region, pixelSize: side * (NSScreen.main?.backingScaleFactor ?? 2))
        if duration > 0 {
            expiry = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    private func startStream(region: CGRect, pixelSize: CGFloat) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let center = CGPoint(x: region.midX, y: region.midY)
                guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) }) ?? content.displays.first else { return }
                let bounds = CGDisplayBounds(display.displayID)
                // Square source around the region so the circle is not distorted.
                let side = max(region.width, region.height) + 8
                let source = CGRect(x: center.x - side / 2 - bounds.minX, y: center.y - side / 2 - bounds.minY, width: side, height: side)
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = source
                configuration.width = Int(pixelSize)
                configuration.height = Int(pixelSize)
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = true
                configuration.queueDepth = 3
                let own = content.applications.filter { $0.processID == getpid() }
                let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                let output = AgentCamOutput { [weak self] surface in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.video.contents = surface } }
                }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                try await stream.startCapture()
                guard !self.isClosed else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                self.output = output
                self.panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    self.panel.animator().alphaValue = 1
                }, completionHandler: nil)
                self.onClosed?() // window list changed
            } catch {
                log("magnifier unavailable: \(error.localizedDescription)")
                self.close()
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        expiry?.invalidate()
        expiry = nil
        if let stream { stream.stopCapture { _ in } }
        stream = nil
        panel.orderOut(nil)
        onClosed?()
        onClosed = nil
    }
}

// MARK: - Captions

public enum CaptionsPreference {
    static let defaultsKey = "showCaptions"
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

/// Splits caption text into display lines and returns the line holding `range`,
/// so long utterances scroll a line at a time instead of shrinking.
func captionWindow(_ text: String, highlighting range: NSRange, maxCharacters: Int = 90) -> (text: String, range: NSRange) {
    let ns = text as NSString
    guard ns.length > maxCharacters else { return (text, range) }
    var lines: [NSRange] = []
    var start = 0
    while start < ns.length {
        var end = min(start + maxCharacters, ns.length)
        if end < ns.length {
            let space = ns.rangeOfCharacter(from: .whitespaces, options: .backwards, range: NSRange(location: start, length: end - start))
            if space.location != NSNotFound, space.location > start { end = space.location }
        }
        lines.append(NSRange(location: start, length: end - start))
        start = end
        while start < ns.length, ns.character(at: start) == 32 { start += 1 }
    }
    let line = lines.first { NSLocationInRange(range.location, $0) } ?? lines.last!
    let local = NSRange(location: max(0, range.location - line.location), length: min(range.length, line.length))
    return (ns.substring(with: line), local)
}

/// A subtitle strip along the bottom of the screen with the spoken word lit.
@MainActor
final class CaptionStrip {
    private let panel: NSPanel
    private let field = NSTextField(labelWithString: "")
    private var text = ""
    private var hideWork: DispatchWorkItem?

    init(captureVisible: Bool) {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 600, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue)
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = captureVisible ? .readOnly : .none
        let background = NSVisualEffectView(frame: panel.contentLayoutRect)
        background.material = .hudWindow
        background.appearance = NSAppearance(named: .darkAqua)
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.04, alpha: 0.55).cgColor
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        field.alignment = .center
        field.lineBreakMode = .byTruncatingTail
        field.frame = background.bounds.insetBy(dx: 18, dy: 10)
        field.autoresizingMask = [.width, .height]
        background.addSubview(field)
        panel.contentView = background
    }

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    func start(_ text: String) {
        self.text = text
        hideWork?.cancel()
        show(range: NSRange(location: 0, length: 0))
    }

    func word(_ range: NSRange) {
        guard !text.isEmpty else { return }
        show(range: range)
    }

    func end() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.panel.animator().alphaValue = 0 },
                                                     completionHandler: { MainActor.assumeIsolated { self.panel.orderOut(nil) } })
                self.text = ""
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func show(range: NSRange) {
        let window = captionWindow(text, highlighting: range)
        let font = NSFont.systemFont(ofSize: 18, weight: .medium)
        let attributed = NSMutableAttributedString(string: window.text, attributes: [
            .font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.72),
        ])
        if window.range.length > 0, NSMaxRange(window.range) <= attributed.length {
            attributed.addAttributes([
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 18, weight: .bold),
            ], range: window.range)
        }
        field.attributedStringValue = attributed
        let width = min(max(attributed.size().width + 48, 200), 980)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(CGRect(x: visible.midX - width / 2, y: visible.minY + 36, width: width, height: 46), display: true)
        }
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }
}
