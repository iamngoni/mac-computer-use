// Live visuals: an agent renders anything a browser engine can draw (HTML,
// CSS, SVG, canvas, WebGL, 3D) straight onto the screen, pinned to real UI.
// Each visual is a transparent web panel owned by one agent session. It
// follows its window, never takes clicks unless made interactive, is hidden
// from agents' screenshots, and talks back through `window.maccu`.
import AppKit
import CoreGraphics
import Foundation
import WebKit

// MARK: - Placement (pure, testable)

enum VisualPlacement: String {
    case beside, over, center, window, screen, at
}

/// Where a visual lands, in Quartz screen points. `side` tells the page
/// where its anchor sits relative to the panel, for drawing pointers.
struct VisualLayout: Equatable {
    var frame: CGRect
    var side: String
}

/// Places a visual of `size` against `anchor` inside `screen` (all Quartz,
/// y down). `beside` tries right, left, below, then above, and always clamps
/// the result onto the screen.
func visualLayout(
    placement: VisualPlacement,
    anchor: CGRect?,
    window: CGRect?,
    screen: CGRect,
    size: CGSize,
    gap: CGFloat = 14
) -> VisualLayout {
    func clamp(_ rect: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, screen.width)
        r.size.height = min(r.height, screen.height)
        r.origin.x = min(max(r.minX, screen.minX), screen.maxX - r.width)
        r.origin.y = min(max(r.minY, screen.minY), screen.maxY - r.height)
        return r.integral
    }
    switch placement {
    case .screen:
        return VisualLayout(frame: screen, side: "none")
    case .window:
        return VisualLayout(frame: clamp(window ?? screen), side: "none")
    case .over:
        let target = anchor ?? window ?? screen
        return VisualLayout(frame: clamp(target), side: "none")
    case .center:
        let host = anchor ?? window ?? screen
        return VisualLayout(
            frame: clamp(CGRect(x: host.midX - size.width / 2, y: host.midY - size.height / 2, width: size.width, height: size.height)),
            side: "none"
        )
    case .at:
        let origin = anchor?.origin ?? CGPoint(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2)
        return VisualLayout(frame: clamp(CGRect(origin: origin, size: size)), side: "none")
    case .beside:
        guard let a = anchor else {
            return visualLayout(placement: .center, anchor: nil, window: window, screen: screen, size: size, gap: gap)
        }
        let midY = a.midY - size.height / 2
        let midX = a.midX - size.width / 2
        let candidates: [(CGRect, String)] = [
            (CGRect(x: a.maxX + gap, y: midY, width: size.width, height: size.height), "left"),
            (CGRect(x: a.minX - gap - size.width, y: midY, width: size.width, height: size.height), "right"),
            (CGRect(x: midX, y: a.maxY + gap, width: size.width, height: size.height), "top"),
            (CGRect(x: midX, y: a.minY - gap - size.height, width: size.width, height: size.height), "bottom"),
        ]
        for (rect, side) in candidates {
            let fitsX = rect.minX >= screen.minX && rect.maxX <= screen.maxX
            let fitsY = rect.minY >= screen.minY && rect.maxY <= screen.maxY
            // Side placements may slide vertically, stacked ones horizontally.
            if side == "left" || side == "right" ? fitsX : fitsY {
                return VisualLayout(frame: clamp(rect), side: side)
            }
        }
        return VisualLayout(frame: clamp(candidates[0].0), side: "left")
    }
}

/// Converts Quartz target rects to the panel's CSS pixel space.
func visualLocalTargets(_ targets: [String: CGRect], panel: CGRect) -> [String: [String: Double]] {
    targets.mapValues { rect in
        [
            "x": Double(rect.minX - panel.minX), "y": Double(rect.minY - panel.minY),
            "width": Double(rect.width), "height": Double(rect.height),
            "cx": Double(rect.midX - panel.minX), "cy": Double(rect.midY - panel.minY),
        ]
    }
}

/// Serialises a value for embedding in JavaScript source.
func visualJSONLiteral(_ value: Any?) -> String {
    guard let value, !(value is NSNull), JSONSerialization.isValidJSONObject([value]),
          let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
          var text = String(data: data, encoding: .utf8) else { return "null" }
    text.removeFirst()
    text.removeLast()
    return text
        .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        .replacingOccurrences(of: "</", with: "<\\/")
}

// MARK: - Page runtime

/// Injected before the agent's page loads: the `maccu` bridge plus a small
/// design kit (`mc-*` classes, CSS variables, keyframes) so a few lines of
/// HTML already look finished.
let visualRuntimeScript = #"""
(function () {
  const init = window.__maccuInit || {};
  const listeners = {};
  const post = (m) => { try { window.webkit.messageHandlers.maccu.postMessage(m); } catch (_) {} };
  const maccu = {
    id: init.id, data: init.data ?? null, targets: init.targets || {}, side: init.side || "none",
    frame: init.frame || { width: innerWidth, height: innerHeight },
    reduceMotion: !!init.reduceMotion, interactive: !!init.interactive, agent: init.agent || "",
    send(payload) { post({ kind: "event", payload: payload === undefined ? null : payload }); },
    close() { post({ kind: "close" }); },
    // Ask for a new panel size in points; the panel re-places itself
    // against its anchor and fires "update" with the new frame and targets.
    resize(width, height) { post({ kind: "resize", width: +width, height: +height }); },
    on(name, fn) { (listeners[name] = listeners[name] || []).push(fn); return () => { listeners[name] = listeners[name].filter(f => f !== fn); }; },
    _emit(name, value) { for (const fn of listeners[name] || []) { try { fn(value); } catch (e) { maccu._error(e); } } },
    _update(patch) {
      if (patch.targets) maccu.targets = patch.targets;
      if (patch.frame) maccu.frame = patch.frame;
      if (patch.side) maccu.side = patch.side;
      if ("data" in patch) maccu.data = patch.data;
      maccu._emit("update", maccu);
    },
    _error(e) { post({ kind: "error", payload: String((e && (e.stack || e.message)) || e) }); },
    // Arrow helper: an SVG path from (x1,y1) to (x2,y2) with a gentle curve.
    curve(x1, y1, x2, y2, bend = 0.25) {
      const mx = (x1 + x2) / 2, my = (y1 + y2) / 2, dx = x2 - x1, dy = y2 - y1;
      return `M${x1},${y1} Q${mx - dy * bend},${my + dx * bend} ${x2},${y2}`;
    },
  };
  window.maccu = maccu;
  addEventListener("error", (e) => maccu._error(e.error || e.message));
  addEventListener("unhandledrejection", (e) => maccu._error(e.reason));
  const kit = `
:root{--mc-accent:#7c5cff;--mc-accent-2:#22d3ee;--mc-hot:#ff4d8d;--mc-ok:#34d399;--mc-warn:#fbbf24;
--mc-ink:#f8fafc;--mc-dim:rgba(248,250,252,.68);--mc-glass:rgba(17,20,32,.72);--mc-line:rgba(255,255,255,.14);
--mc-radius:18px;--mc-font:-apple-system,BlinkMacSystemFont,"SF Pro Display",system-ui,sans-serif;
--mc-mono:ui-monospace,"SF Mono",Menlo,monospace;color-scheme:dark}
html,body{margin:0;padding:0;background:transparent!important;width:100%;height:100%;overflow:hidden;
font-family:var(--mc-font);color:var(--mc-ink);-webkit-font-smoothing:antialiased;user-select:none;-webkit-user-select:none}
.mc-card{background:var(--mc-glass);border:1px solid var(--mc-line);border-radius:var(--mc-radius);padding:18px 20px;
box-shadow:0 24px 60px rgba(0,0,0,.45),inset 0 1px 0 rgba(255,255,255,.08);animation:mc-pop .5s cubic-bezier(.2,.9,.25,1.2) both}
.mc-title{font-size:19px;font-weight:700;letter-spacing:-.01em;margin:0 0 6px}
.mc-sub{font-size:13px;color:var(--mc-dim);line-height:1.45}
.mc-mono{font-family:var(--mc-mono)}
.mc-pill{display:inline-flex;align-items:center;gap:6px;padding:4px 10px;border-radius:999px;font-size:12px;font-weight:600;
background:rgba(124,92,255,.22);border:1px solid rgba(124,92,255,.45)}
.mc-gradient-text{background:linear-gradient(90deg,var(--mc-accent),var(--mc-accent-2),var(--mc-hot));-webkit-background-clip:text;color:transparent}
.mc-glow{box-shadow:0 0 0 2px var(--mc-accent),0 0 28px 6px rgba(124,92,255,.55)}
.mc-ring{position:absolute;border-radius:14px;border:2.5px solid var(--mc-accent);box-shadow:0 0 24px rgba(124,92,255,.7);animation:mc-pulse 1.6s ease-in-out infinite}
.mc-spotlight{position:fixed;inset:0;pointer-events:none}
.mc-in{animation:mc-pop .5s cubic-bezier(.2,.9,.25,1.2) both}
.mc-fade{animation:mc-fade .6s ease both}
.mc-stagger>*{animation:mc-rise .55s cubic-bezier(.2,.9,.25,1) both}
.mc-stagger>*:nth-child(2){animation-delay:.08s}.mc-stagger>*:nth-child(3){animation-delay:.16s}
.mc-stagger>*:nth-child(4){animation-delay:.24s}.mc-stagger>*:nth-child(5){animation-delay:.32s}
.mc-stagger>*:nth-child(n+6){animation-delay:.4s}
.mc-draw{stroke-dasharray:var(--mc-len,1000);stroke-dashoffset:var(--mc-len,1000);animation:mc-draw 1s ease forwards}
button,.mc-button{font:inherit;font-weight:600;font-size:13px;color:#fff;border:0;border-radius:10px;padding:8px 14px;cursor:pointer;
background:linear-gradient(180deg,#8b6dff,#6a46ff);box-shadow:0 6px 18px rgba(106,70,255,.45)}
@keyframes mc-pop{from{opacity:0;transform:translateY(8px) scale(.96)}to{opacity:1;transform:none}}
@keyframes mc-rise{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
@keyframes mc-fade{from{opacity:0}to{opacity:1}}
@keyframes mc-pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.55;transform:scale(1.03)}}
@keyframes mc-draw{to{stroke-dashoffset:0}}
@media (prefers-reduced-motion:reduce){*{animation-duration:.01ms!important;animation-iteration-count:1!important;transition:none!important}}`;
  const style = document.createElement("style");
  style.id = "maccu-kit";
  style.textContent = kit;
  const attach = () => { (document.head || document.documentElement).prepend(style); };
  if (document.documentElement) attach(); else addEventListener("DOMContentLoaded", attach);
})();
"""#

// MARK: - Service-side stage

private final class VisualMessageProxy: NSObject, WKScriptMessageHandler {
    weak var stage: VisualStage?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { stage?.received(message) }
    }
}

final class VisualPanel: NSPanel {
    var interactive = false
    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { false }
}

/// Owns every live visual across sessions.
@MainActor
final class VisualStage: NSObject, WKNavigationDelegate {
    final class Entry {
        let key: String
        let owner: String
        let id: String
        let panel: VisualPanel
        let web: WKWebView
        let container: NSView
        var windowID: CGWindowID?
        var windowBounds: CGRect?
        var fillsWindow = false
        var quartzFrame: CGRect
        var targets: [String: CGRect]
        var events: [Any] = []
        var errors: [String] = []
        var expiry: Timer?
        var loaded: ((Bool, String?) -> Void)?
        var hiddenForWindow = false
        var placement: VisualPlacement = .center
        var anchor: CGRect?
        var side = "none"
        init(key: String, owner: String, id: String, panel: VisualPanel, web: WKWebView, container: NSView, frame: CGRect, targets: [String: CGRect]) {
            self.key = key; self.owner = owner; self.id = id; self.panel = panel; self.web = web
            self.container = container; self.quartzFrame = frame; self.targets = targets
        }
    }

    nonisolated static let maxPerOwner = 12
    nonisolated static let maxHTMLBytes = 2_000_000

    private let captureVisible: Bool
    private var entries: [String: Entry] = [:]
    private var followTimer: Timer?
    private let proxy = VisualMessageProxy()
    var onWindowsChanged: (() -> Void)?

    init(captureVisible: Bool) {
        self.captureVisible = captureVisible
        super.init()
        proxy.stage = self
    }

    var windowIDs: [CGWindowID] { entries.values.map { CGWindowID($0.panel.windowNumber) }.filter { $0 > 0 } }

    func count(owner: String) -> Int { entries.values.filter { $0.owner == owner }.count }

    // MARK: Show

    struct ShowRequest {
        var owner: String
        var agentName: String
        var id: String
        var html: String
        var placement: VisualPlacement
        var anchor: CGRect?
        var window: CGRect?
        var windowID: CGWindowID?
        var size: CGSize
        var targets: [String: CGRect]
        var data: Any?
        var interactive: Bool
        var backdrop: String
        var follow: Bool
        var duration: TimeInterval?
        var reduceMotion: Bool
    }

    func show(_ request: ShowRequest, completion: @escaping ([String: Any]) -> Void) {
        let key = "\(request.owner)#\(request.id)"
        if let existing = entries[key] { dismiss(existing, animated: false) }
        guard count(owner: request.owner) < Self.maxPerOwner else {
            completion(["outcome": "invalid", "message": "at most \(Self.maxPerOwner) visuals per agent; clear some first"])
            return
        }
        let screen = screenFrame(containing: request.anchor ?? request.window)
        let layout = visualLayout(
            placement: request.placement, anchor: request.anchor, window: request.window,
            screen: screen, size: request.size
        )
        let panel = VisualPanel(
            contentRect: quartzRectToCocoa(layout.frame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.interactive = request.interactive
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        panel.ignoresMouseEvents = !request.interactive
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = captureVisible ? .readOnly : .none
        panel.alphaValue = 0

        let bounds = CGRect(origin: .zero, size: layout.frame.size)
        let container: NSView
        switch request.backdrop {
        case "glass", "dark":
            let effect = NSVisualEffectView(frame: bounds)
            effect.material = request.backdrop == "dark" ? .hudWindow : .popover
            effect.appearance = NSAppearance(named: .darkAqua)
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 18
            effect.layer?.masksToBounds = true
            container = effect
        default:
            container = NSView(frame: bounds)
            container.wantsLayer = true
        }
        container.autoresizingMask = [.width, .height]

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let controller = WKUserContentController()
        controller.add(proxy, name: "maccu")
        let initPayload: [String: Any] = [
            "id": request.id,
            "data": request.data ?? NSNull(),
            "targets": visualLocalTargets(request.targets, panel: layout.frame),
            "side": layout.side,
            "frame": ["width": Double(layout.frame.width), "height": Double(layout.frame.height)],
            "reduceMotion": request.reduceMotion,
            "interactive": request.interactive,
            "agent": request.agentName,
        ]
        controller.addUserScript(WKUserScript(
            source: "window.__maccuInit = \(visualJSONLiteral(initPayload));\n" + visualRuntimeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        configuration.userContentController = controller
        let web = WKWebView(frame: bounds, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        disableOcclusionThrottling(web)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        container.addSubview(web)
        if request.interactive {
            // A visual that takes input always says who drew it, so it cannot
            // pass for a system or app dialog.
            container.addSubview(makeProvenanceTag(agent: request.agentName, in: bounds))
        }
        panel.contentView = container

        let entry = Entry(
            key: key, owner: request.owner, id: request.id, panel: panel, web: web,
            container: container, frame: layout.frame, targets: request.targets
        )
        entry.windowID = request.follow ? request.windowID : nil
        entry.windowBounds = request.window
        entry.fillsWindow = request.placement == .window
        entry.placement = request.placement
        entry.anchor = request.anchor
        entry.side = layout.side
        entries[key] = entry

        var answered = false
        let answer: (Bool, String?) -> Void = { [weak self, weak entry] ok, failure in
            guard !answered else { return }
            answered = true
            guard let self, let entry else { return }
            entry.loaded = nil
            if !ok, let failure { entry.errors.append(failure) }
            self.reveal(entry, reduceMotion: request.reduceMotion)
            // Give scripts a beat to run so early errors come back with the result.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak entry] in
                guard let self, let entry else { return }
                var result = self.drain(entry)
                result["outcome"] = "shown"
                result["frame"] = [Double(entry.quartzFrame.minX), Double(entry.quartzFrame.minY),
                                   Double(entry.quartzFrame.width), Double(entry.quartzFrame.height)]
                result["side"] = layout.side
                completion(result)
            }
        }
        entry.loaded = answer
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { answer(true, nil) }
        web.loadHTMLString(request.html, baseURL: URL(string: "https://maccu.visual/"))

        if let duration = request.duration {
            entry.expiry = Timer.scheduledTimer(withTimeInterval: max(duration, 0.5), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let entry = self.entries[key] else { return }
                    self.dismiss(entry, animated: true)
                }
            }
        }
        startFollowing()
        onWindowsChanged?()
    }

    private func makeProvenanceTag(agent: String, in bounds: CGRect) -> NSView {
        let text = "\(agent.isEmpty ? "Agent" : agent) · visual"
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()
        let width = label.frame.width + 14
        let tag = NSView(frame: CGRect(x: bounds.width - width - 8, y: bounds.height - 22, width: width, height: 16))
        tag.wantsLayer = true
        tag.layer?.backgroundColor = NSColor(calibratedRed: 0.35, green: 0.25, blue: 0.95, alpha: 0.9).cgColor
        tag.layer?.cornerRadius = 8
        tag.autoresizingMask = [.minXMargin, .minYMargin]
        label.frame.origin = CGPoint(x: 7, y: 1)
        tag.addSubview(label)
        return tag
    }

    private func reveal(_ entry: Entry, reduceMotion: Bool) {
        entry.panel.orderFrontRegardless()
        if reduceMotion {
            entry.panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            entry.panel.animator().alphaValue = 1
        }
    }

    // MARK: Update

    struct UpdateRequest {
        var owner: String
        var id: String
        var script: String?
        var html: String?
        var data: Any?
        var hasData: Bool
        var targets: [String: CGRect]?
        var snapshot: Bool
        var waitEvent: TimeInterval
    }

    func update(_ request: UpdateRequest, completion: @escaping ([String: Any]) -> Void) {
        guard let entry = entries["\(request.owner)#\(request.id)"] else {
            completion(["outcome": "missing"])
            return
        }
        var result: [String: Any] = ["outcome": "updated"]
        let finish: () -> Void = { [weak self, weak entry] in
            guard let self, let entry else { completion(["outcome": "missing"]); return }
            self.waitForEvents(entry, until: CACurrentMediaTime() + request.waitEvent) { [weak self, weak entry] in
                guard let self, let entry else { completion(["outcome": "missing"]); return }
                result.merge(self.drain(entry)) { _, new in new }
                guard request.snapshot else { completion(result); return }
                entry.web.takeSnapshot(with: nil) { image, _ in
                    MainActor.assumeIsolated {
                        if let image, let tiff = image.tiffRepresentation,
                           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                            result["png"] = png.base64EncodedString()
                        }
                        completion(result)
                    }
                }
            }
        }
        if let targets = request.targets { entry.targets = targets }
        var patch: [String: Any] = [:]
        if request.targets != nil { patch["targets"] = visualLocalTargets(entry.targets, panel: entry.quartzFrame) }
        if request.hasData { patch["data"] = request.data ?? NSNull() }

        let runScript: () -> Void = {
            let push: () -> Void = {
                guard let script = request.script else { finish(); return }
                entry.web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { outcome in
                    MainActor.assumeIsolated {
                        switch outcome {
                        case .success(let value):
                            if let text = visualResultText(value) { result["result"] = text }
                        case .failure(let error):
                            result["script_error"] = visualScriptError(error)
                        }
                        finish()
                    }
                }
            }
            guard !patch.isEmpty else { push(); return }
            entry.web.evaluateJavaScript("window.maccu && window.maccu._update(\(visualJSONLiteral(patch)));") { _, _ in
                MainActor.assumeIsolated { push() }
            }
        }
        if let html = request.html {
            entry.loaded = { _, failure in
                if let failure { entry.errors.append(failure) }
                entry.loaded = nil
                runScript()
            }
            entry.web.loadHTMLString(html, baseURL: URL(string: "https://maccu.visual/"))
        } else {
            runScript()
        }
    }

    private func waitForEvents(_ entry: Entry, until deadline: CFTimeInterval, then done: @escaping () -> Void) {
        if !entry.events.isEmpty || CACurrentMediaTime() >= deadline || entries[entry.key] == nil {
            done()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak entry] in
            guard let self, let entry else { done(); return }
            self.waitForEvents(entry, until: deadline, then: done)
        }
    }

    private func drain(_ entry: Entry) -> [String: Any] {
        var result: [String: Any] = [:]
        if !entry.events.isEmpty { result["events"] = entry.events }
        if !entry.errors.isEmpty { result["errors"] = Array(entry.errors.suffix(8)) }
        entry.events.removeAll()
        entry.errors.removeAll()
        return result
    }

    // MARK: Clear

    func clear(owner: String?, id: String? = nil) -> Int {
        let doomed = entries.values.filter { (owner == nil || $0.owner == owner) && (id == nil || $0.id == id) }
        for entry in doomed { dismiss(entry, animated: true) }
        return doomed.count
    }

    private func dismiss(_ entry: Entry, animated: Bool) {
        guard entries[entry.key] === entry else { return }
        entries.removeValue(forKey: entry.key)
        entry.expiry?.invalidate()
        entry.web.configuration.userContentController.removeScriptMessageHandler(forName: "maccu")
        let close = { [weak self] in
            entry.web.stopLoading()
            entry.web.navigationDelegate = nil
            entry.panel.orderOut(nil)
            entry.panel.close()
            self?.onWindowsChanged?()
        }
        if animated, entry.panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                entry.panel.animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { close() } })
        } else {
            close()
        }
        if entries.isEmpty {
            followTimer?.invalidate()
            followTimer = nil
        }
    }

    // MARK: Following windows

    private func startFollowing() {
        guard followTimer == nil, entries.values.contains(where: { $0.windowID != nil }) else { return }
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
    }

    private func follow() {
        let tracked = entries.values.filter { $0.windowID != nil }
        guard !tracked.isEmpty else {
            followTimer?.invalidate()
            followTimer = nil
            return
        }
        for entry in tracked {
            guard let id = entry.windowID, let previous = entry.windowBounds else { continue }
            let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first
            guard let info else {
                dismiss(entry, animated: true) // window closed
                continue
            }
            let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            if !onScreen != entry.hiddenForWindow {
                entry.hiddenForWindow = !onScreen
                if onScreen { entry.panel.orderFrontRegardless() } else { entry.panel.orderOut(nil) }
            }
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds != previous else { continue }
            let dx = bounds.minX - previous.minX, dy = bounds.minY - previous.minY
            var frame = entry.quartzFrame.offsetBy(dx: dx, dy: dy)
            if entry.fillsWindow { frame = bounds }
            let delta = CGPoint(x: dx, y: dy)
            entry.windowBounds = bounds
            entry.quartzFrame = frame
            entry.targets = entry.targets.mapValues { $0.offsetBy(dx: delta.x, dy: delta.y) }
            entry.anchor = entry.anchor?.offsetBy(dx: delta.x, dy: delta.y)
            entry.panel.setFrame(quartzRectToCocoa(frame), display: true)
            if entry.fillsWindow, bounds.size != previous.size {
                let patch: [String: Any] = [
                    "frame": ["width": Double(frame.width), "height": Double(frame.height)],
                    "targets": visualLocalTargets(entry.targets, panel: frame),
                ]
                entry.web.evaluateJavaScript("window.maccu && window.maccu._update(\(visualJSONLiteral(patch)));")
            }
        }
    }

    private func screenFrame(containing rect: CGRect?) -> CGRect {
        let screens = NSScreen.screens
        let cocoa = rect.map(quartzRectToCocoa)
        let screen = cocoa.flatMap { r in screens.max { $0.frame.intersection(r).area < $1.frame.intersection(r).area } }
            ?? NSScreen.main ?? screens.first
        guard let screen else { return CGRect(x: 0, y: 0, width: 1440, height: 900) }
        // visibleFrame keeps visuals clear of the menu bar and Dock.
        return cocoaRectToQuartzRect(screen.visibleFrame)
    }

    // MARK: Bridge

    fileprivate func received(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let entry = entries.values.first(where: { $0.web === message.webView }) else { return }
        switch body["kind"] as? String {
        case "event":
            if entry.events.count < 200 { entry.events.append(body["payload"] ?? NSNull()) }
        case "error":
            if entry.errors.count < 50 { entry.errors.append(String((body["payload"] as? String ?? "error").prefix(600))) }
        case "close":
            dismiss(entry, animated: true)
        case "resize":
            let width = (body["width"] as? NSNumber)?.doubleValue ?? 0
            let height = (body["height"] as? NSNumber)?.doubleValue ?? 0
            guard width.isFinite, height.isFinite, width >= 20, height >= 20 else { return }
            resize(entry, to: CGSize(width: min(width, 4000), height: min(height, 3000)))
        default:
            break
        }
    }

    private func resize(_ entry: Entry, to size: CGSize) {
        guard [.beside, .center, .at].contains(entry.placement),
              abs(size.width - entry.quartzFrame.width) > 0.5 || abs(size.height - entry.quartzFrame.height) > 0.5 else { return }
        let layout = visualLayout(
            placement: entry.placement, anchor: entry.anchor, window: entry.windowBounds,
            screen: screenFrame(containing: entry.anchor ?? entry.windowBounds), size: size
        )
        entry.quartzFrame = layout.frame
        entry.side = layout.side
        entry.panel.setFrame(quartzRectToCocoa(layout.frame), display: true)
        let patch: [String: Any] = [
            "frame": ["width": Double(layout.frame.width), "height": Double(layout.frame.height)],
            "targets": visualLocalTargets(entry.targets, panel: layout.frame),
            "side": layout.side,
        ]
        entry.web.evaluateJavaScript("window.maccu && window.maccu._update(\(visualJSONLiteral(patch)));")
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // The page may load subresources and iframes, but the visual itself
        // never navigates away from what the agent drew.
        if action.targetFrame?.isMainFrame ?? true, action.navigationType != .other {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        entries.values.first { $0.web === webView }?.loaded?(true, nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        entries.values.first { $0.web === webView }?.loaded?(false, error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        entries.values.first { $0.web === webView }?.loaded?(false, error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let entry = entries.values.first(where: { $0.web === webView }) else { return }
        entry.errors.append("web content process ended; the visual was cleared")
        dismiss(entry, animated: false)
    }
}

/// Overlay panels are transparent and never key, so AppKit reports them as
/// occluded and WebKit would freeze their animations at frame zero. Visuals
/// are meant to move, so they opt out of occlusion throttling.
@MainActor
private func disableOcclusionThrottling(_ web: WKWebView) {
    let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
    guard web.responds(to: selector), let method = class_getInstanceMethod(type(of: web), selector) else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(method_getImplementation(method), to: Setter.self)(web, selector, false)
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

func cocoaRectToQuartzRect(_ rect: CGRect) -> CGRect {
    let height = primaryScreen().frame.height
    return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
}

func visualResultText(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    let text: String
    if let string = value as? String {
        text = string
    } else if JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) {
        text = json
    } else {
        text = String(describing: value)
    }
    return text.count > 20_000 ? String(text.prefix(20_000)) + "…" : text
}

func visualScriptError(_ error: Error) -> String {
    let info = (error as NSError).userInfo
    let message = info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    if let line = info["WKJavaScriptExceptionLineNumber"] as? NSNumber {
        return "\(message) (line \(line))"
    }
    return message
}
