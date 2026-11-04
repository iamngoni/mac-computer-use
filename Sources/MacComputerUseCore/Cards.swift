// Native cards an agent can put on screen: a suggestion the person accepts or
// dismisses (only a physical click counts), and job cards that show a
// long-running task's progress with Pause and Stop for that agent alone.
import AppKit
import QuartzCore

/// The shared card chrome: dark frosted glass with a hairline and shadow.
@MainActor
private func makeCardPanel(size: CGSize, interactive: Bool, captureVisible: Bool) -> (NSPanel, NSView) {
    let panel = InteractivePanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue)
    panel.ignoresMouseEvents = !interactive
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.sharingType = captureVisible ? .readOnly : .none
    let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
    effect.material = .hudWindow
    effect.appearance = NSAppearance(named: .darkAqua)
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 16
    effect.layer?.masksToBounds = true
    effect.layer?.borderWidth = 1
    effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    effect.layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.74).cgColor
    panel.contentView = effect
    return (panel, effect)
}

@MainActor
private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, lines: Int = 1) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.maximumNumberOfLines = lines
    if lines > 1 {
        field.lineBreakMode = .byWordWrapping
        field.cell?.truncatesLastVisibleLine = true
    } else {
        field.lineBreakMode = .byTruncatingTail
    }
    field.isSelectable = false
    return field
}

private func revealCard(_ panel: NSPanel) {
    panel.alphaValue = 0
    let target = panel.frame
    panel.setFrame(target.offsetBy(dx: 0, dy: 8), display: false)
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.28
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        panel.animator().alphaValue = 1
        panel.animator().setFrame(target, display: true)
    }
}

// MARK: - Suggestion card

/// A small card in the top-right corner: an idea from the agent with up to
/// three buttons. Agents cannot answer it themselves.
@MainActor
final class SuggestionCard: NSObject {
    private let panel: NSPanel
    private let actions: [String]
    private let completion: (Int?) -> Void
    private var finished = false

    init(agent: String, title: String, body: String?, symbol: String?, actions: [String], captureVisible: Bool, completion: @escaping (Int?) -> Void) {
        self.actions = actions
        self.completion = completion
        let width: CGFloat = 344
        let bodyHeight: CGFloat = body == nil ? 0 : min(CGFloat((body!.count / 46) + 1) * 17, 68)
        let height: CGFloat = 70 + bodyHeight + 44
        let made = makeCardPanel(size: CGSize(width: width, height: height), interactive: true, captureVisible: captureVisible)
        panel = made.0
        super.init()
        let root = made.1
        let icon = NSImageView(frame: CGRect(x: 16, y: height - 48, width: 30, height: 30))
        icon.image = NSImage(systemSymbolName: symbol ?? "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        icon.contentTintColor = .white
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 9
        icon.layer?.backgroundColor = accent.cgColor
        icon.imageScaling = .scaleNone
        root.addSubview(icon)
        let from = label("\(agent.isEmpty ? "Agent" : agent) suggests", size: 11, weight: .semibold, color: NSColor.white.withAlphaComponent(0.55))
        from.frame = CGRect(x: 56, y: height - 30, width: width - 72, height: 14)
        root.addSubview(from)
        let titleField = label(title, size: 14, weight: .semibold, color: .white, lines: 2)
        titleField.frame = CGRect(x: 56, y: height - 52 - 4, width: width - 72, height: 22)
        root.addSubview(titleField)
        if let body {
            let bodyField = label(body, size: 12.5, weight: .regular, color: NSColor.white.withAlphaComponent(0.72), lines: 4)
            bodyField.frame = CGRect(x: 56, y: 50, width: width - 72, height: bodyHeight)
            root.addSubview(bodyField)
        }
        var x = width - 16
        for (index, action) in actions.enumerated().reversed() {
            let button = NSButton(title: action, target: self, action: #selector(chose(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.keyEquivalent = ""
            if index == 0 { button.bezelColor = accent; button.keyEquivalent = "" }
            button.sizeToFit()
            let w = max(button.frame.width + 8, 72)
            x -= w
            button.frame = CGRect(x: x, y: 12, width: w, height: 28)
            x -= 8
            root.addSubview(button)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.maxX - width - 16, y: screen.visibleFrame.maxY - height - 16))
        }
        revealCard(panel)
    }

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    @objc private func chose(_ sender: NSButton) {
        // Only the person's own click answers; an agent's synthetic click is ignored.
        guard !eventIsAgentSynthesised(NSApp.currentEvent) else { return }
        finish(sender.tag)
    }

    func finish(_ index: Int?) {
        guard !finished else { return }
        finished = true
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
        completion(index)
    }
}

// MARK: - Job cards

/// A slim progress bar that reads well on dark glass: determinate fill, or a
/// sliding shimmer while the agent cannot say how far along it is.
@MainActor
final class GlowBar: NSView {
    private let fill = CAGradientLayer()
    var progress: Double? { didSet { layoutFill() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.masksToBounds = true
        fill.colors = [accent.cgColor, NSColor.systemTeal.cgColor]
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.cornerRadius = frame.height / 2
        layer?.addSublayer(fill)
        layoutFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func layoutFill() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        fill.removeAnimation(forKey: "shimmer")
        if let progress {
            fill.frame = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(min(max(progress, 0), 1)), height: bounds.height)
        } else {
            fill.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.3, height: bounds.height)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let slide = CABasicAnimation(keyPath: "position.x")
                slide.fromValue = -bounds.width * 0.15
                slide.toValue = bounds.width * 1.15
                slide.duration = 1.3
                slide.repeatCount = .infinity
                slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                fill.add(slide, forKey: "shimmer")
            }
        }
        CATransaction.commit()
    }
}

/// What an agent reports about one long-running task.
struct JobState: Equatable {
    var title: String
    var step: String?
    var progress: Double?     // 0...1, nil = indeterminate
    var state: String         // running, done, failed
}

/// Stacks each agent's job cards in the bottom-left corner.
@MainActor
final class JobBoard {
    private final class Card {
        let panel: NSPanel
        let title: NSTextField
        let step: NSTextField
        let bar: GlowBar
        let status: NSImageView
        let pause: NSButton
        let stop: NSButton
        var removal: DispatchWorkItem?
        init(panel: NSPanel, title: NSTextField, step: NSTextField, bar: GlowBar, status: NSImageView, pause: NSButton, stop: NSButton) {
            self.panel = panel; self.title = title; self.step = step; self.bar = bar; self.status = status; self.pause = pause; self.stop = stop
        }
    }

    @MainActor
    private final class Target: NSObject {
        var action: () -> Void = {}
        @objc func fire() {
            guard !eventIsAgentSynthesised(NSApp.currentEvent) else { return }
            action()
        }
    }

    private let captureVisible: Bool
    private var cards: [String: Card] = [:]
    private var order: [String] = []
    private var targets: [String: [Target]] = [:]
    private var pausedSessions: Set<String> = []
    var onPause: ((String, Bool) -> Void)?
    var onStop: ((String) -> Void)?
    var onWindowsChanged: (() -> Void)?

    init(captureVisible: Bool) { self.captureVisible = captureVisible }

    var windowIDs: [CGWindowID] { cards.values.map { CGWindowID($0.panel.windowNumber) } }

    func update(sessionID: String, agent: String, color: NSColor, id: String, job: JobState) {
        let key = "\(sessionID)#\(id)"
        let card = cards[key] ?? makeCard(key: key, sessionID: sessionID, agent: agent, color: color)
        card.title.stringValue = job.title
        card.step.stringValue = job.step ?? (job.state == "done" ? "Done" : job.state == "failed" ? "Failed" : "Working…")
        if let progress = job.progress {
            card.bar.progress = progress
        } else if job.state == "running" {
            card.bar.progress = nil
        }
        let symbol: String
        let tint: NSColor
        switch job.state {
        case "done": symbol = "checkmark.circle.fill"; tint = .systemGreen
        case "failed": symbol = "exclamationmark.triangle.fill"; tint = .systemOrange
        default: symbol = pausedSessions.contains(sessionID) ? "pause.circle.fill" : "circle.dotted"; tint = color
        }
        card.status.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        card.status.contentTintColor = tint
        let finished = job.state != "running"
        card.pause.isHidden = finished
        card.stop.isHidden = finished
        if finished {
            card.bar.progress = job.state == "done" ? 1 : (job.progress ?? 0)
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.remove(key) } }
            card.removal?.cancel()
            card.removal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        } else {
            card.removal?.cancel()
            card.removal = nil
        }
        layout()
    }

    func remove(sessionID: String?, id: String? = nil) {
        for key in Array(cards.keys) where sessionID == nil || key.hasPrefix("\(sessionID!)#") && (id == nil || key == "\(sessionID!)#\(id!)") {
            remove(key)
        }
    }

    func setPaused(_ sessionID: String, _ paused: Bool) {
        if paused { pausedSessions.insert(sessionID) } else { pausedSessions.remove(sessionID) }
        for (key, card) in cards where key.hasPrefix("\(sessionID)#") {
            card.pause.title = paused ? "Resume" : "Pause"
            if card.stop.isHidden == false {
                card.status.image = NSImage(systemSymbolName: paused ? "pause.circle.fill" : "circle.dotted", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            }
        }
    }

    private func remove(_ key: String) {
        guard let card = cards.removeValue(forKey: key) else { return }
        order.removeAll { $0 == key }
        targets.removeValue(forKey: key)
        card.removal?.cancel()
        let panel = card.panel
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
        layout()
        onWindowsChanged?()
    }

    private func makeCard(key: String, sessionID: String, agent: String, color: NSColor) -> Card {
        let size = CGSize(width: 300, height: 96)
        let (panel, root) = makeCardPanel(size: size, interactive: true, captureVisible: captureVisible)
        let dot = NSView(frame: CGRect(x: 14, y: size.height - 24, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = color.cgColor
        root.addSubview(dot)
        let who = label(agent.isEmpty ? "Agent" : agent, size: 11, weight: .semibold, color: NSColor.white.withAlphaComponent(0.55))
        who.frame = CGRect(x: 28, y: size.height - 28, width: 200, height: 14)
        root.addSubview(who)
        let status = NSImageView(frame: CGRect(x: size.width - 32, y: size.height - 32, width: 18, height: 18))
        root.addSubview(status)
        let title = label("", size: 13.5, weight: .semibold, color: .white)
        title.frame = CGRect(x: 14, y: size.height - 50, width: size.width - 28, height: 18)
        root.addSubview(title)
        let step = label("", size: 12, weight: .regular, color: NSColor.white.withAlphaComponent(0.7))
        step.frame = CGRect(x: 14, y: size.height - 68, width: size.width - 150, height: 16)
        root.addSubview(step)
        let bar = GlowBar(frame: CGRect(x: 14, y: 16, width: size.width - 150, height: 5))
        root.addSubview(bar)
        let pauseTarget = Target()
        pauseTarget.action = { [weak self] in
            guard let self else { return }
            let paused = !self.pausedSessions.contains(sessionID)
            self.setPaused(sessionID, paused)
            self.onPause?(sessionID, paused)
        }
        let stopTarget = Target()
        stopTarget.action = { [weak self] in self?.onStop?(sessionID) }
        targets[key] = [pauseTarget, stopTarget]
        let pause = NSButton(title: pausedSessions.contains(sessionID) ? "Resume" : "Pause", target: pauseTarget, action: #selector(Target.fire))
        pause.bezelStyle = .rounded
        pause.controlSize = .small
        pause.frame = CGRect(x: size.width - 132, y: 8, width: 64, height: 24)
        root.addSubview(pause)
        let stop = NSButton(title: "Stop", target: stopTarget, action: #selector(Target.fire))
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.frame = CGRect(x: size.width - 64, y: 8, width: 52, height: 24)
        root.addSubview(stop)
        let card = Card(panel: panel, title: title, step: step, bar: bar, status: status, pause: pause, stop: stop)
        cards[key] = card
        order.append(key)
        layout(animatedFor: key)
        onWindowsChanged?()
        return card
    }

    private func layout(animatedFor newKey: String? = nil) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var y = screen.minY + 16
        for key in order {
            guard let card = cards[key] else { continue }
            let origin = CGPoint(x: screen.minX + 16, y: y)
            if key == newKey {
                card.panel.setFrameOrigin(origin)
                revealCard(card.panel)
            } else if card.panel.frame.origin != origin {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.2; card.panel.animator().setFrameOrigin(origin) }
            }
            y += card.panel.frame.height + 10
        }
    }
}

// MARK: - Walkthrough timeline

/// A step bar along the top of the screen during a walkthrough: which step
/// the person is on, every step's progress, and Back, Replay, Skip (or Next)
/// and Stop. Only physical clicks count.
@MainActor
final class StepTimeline: NSObject {
    private let panel: NSPanel
    private let root: NSView
    private let counter = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private var segments: [CALayer] = []
    private var buttons: [NSButton] = []
    private let onAction: (String) -> Void
    private(set) var sessionID: String
    private let width: CGFloat = 460

    init(sessionID: String, captureVisible: Bool, onAction: @escaping (String) -> Void) {
        self.sessionID = sessionID
        self.onAction = onAction
        let made = makeCardPanel(size: CGSize(width: 460, height: 66), interactive: true, captureVisible: captureVisible)
        panel = made.0
        root = made.1
        super.init()
        counter.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        counter.textColor = accent.blended(withFraction: 0.35, of: .white)
        counter.frame = CGRect(x: 16, y: 38, width: 90, height: 16)
        root.addSubview(counter)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        title.frame = CGRect(x: 16, y: 18, width: width - 180, height: 18)
        root.addSubview(title)
        let specs: [(String, String, String)] = [
            ("back", "chevron.left", "Back"), ("replay", "arrow.counterclockwise", "Show again"),
            ("skip", "chevron.right", "Skip this step"), ("stop", "xmark", "Stop the walkthrough"),
        ]
        for (index, spec) in specs.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: spec.1, accessibilityDescription: spec.2)!, target: self, action: #selector(pressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(spec.0)
            button.bezelStyle = .circular
            button.isBordered = false
            button.contentTintColor = .white
            button.toolTip = spec.2
            button.wantsLayer = true
            button.layer?.cornerRadius = 14
            button.layer?.backgroundColor = NSColor.white.withAlphaComponent(spec.0 == "skip" ? 0.18 : 0.08).cgColor
            button.frame = CGRect(x: width - 16 - CGFloat(specs.count - index) * 34 + 4, y: 19, width: 28, height: 28)
            root.addSubview(button)
            buttons.append(button)
        }
    }

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    func show(steps: [String], current: Int, manual: Bool) {
        counter.stringValue = "STEP \(current + 1) OF \(steps.count)"
        title.stringValue = current < steps.count ? steps[current] : ""
        buttons.first { $0.identifier?.rawValue == "back" }?.isEnabled = current > 0
        if let skip = buttons.first(where: { $0.identifier?.rawValue == "skip" }) {
            skip.toolTip = manual ? "Next" : "Skip this step"
            skip.layer?.backgroundColor = (manual ? accent : NSColor.white.withAlphaComponent(0.18)).cgColor
        }
        segments.forEach { $0.removeFromSuperlayer() }
        segments = []
        let gap: CGFloat = 4, total = CGFloat(max(steps.count, 1))
        let barWidth = width - 32
        let segmentWidth = (barWidth - gap * (total - 1)) / total
        for index in 0..<steps.count {
            let segment = CALayer()
            segment.frame = CGRect(x: 16 + CGFloat(index) * (segmentWidth + gap), y: 8, width: segmentWidth, height: 4)
            segment.cornerRadius = 2
            segment.backgroundColor = (index < current ? accent : index == current ? accent.blended(withFraction: 0.4, of: .white)! : NSColor.white.withAlphaComponent(0.16)).cgColor
            if index == current, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1
                pulse.toValue = 0.45
                pulse.duration = 0.8
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                segment.add(pulse, forKey: "pulse")
            }
            root.layer?.addSublayer(segment)
            segments.append(segment)
        }
        if !panel.isVisible {
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
                // Below the agent banner, which sits at the top centre.
                panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.maxY - 66 - 58))
            }
            revealCard(panel)
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        guard !eventIsAgentSynthesised(NSApp.currentEvent), let action = sender.identifier?.rawValue else { return }
        onAction(action)
    }

    func hide() {
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
    }
}
