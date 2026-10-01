// Everything the service draws for agents: cursors (with arc flights, action
// badges and per-agent colours), speech bubbles, hand-drawn annotations, and
// the few interactive surfaces where the person answers an agent (choice
// chips, pick mode, hand-offs). None of it is visible to agent screenshots.
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

// MARK: - Speech bubbles

enum BubbleStyle: String {
    case teach, handoff, nudge, tag, done
}

final class CursorBubbleView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    var visibleCharacters = 0 { didSet { needsDisplay = true } }
    var style: BubbleStyle = .teach { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func font(for style: BubbleStyle) -> NSFont {
        style == .tag
            ? .systemFont(ofSize: 10.5, weight: .semibold)
            : .systemFont(ofSize: 13, weight: .medium)
    }

    static func size(for text: String, style: BubbleStyle) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font(for: style)]
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: style == .tag ? 160 : 280, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let horizontal: CGFloat = style == .tag ? 7 : 11
        let vertical: CGFloat = style == .tag ? 3 : 7
        return NSSize(
            width: ceil(bounds.width) + horizontal * 2,
            height: ceil(bounds.height) + vertical * 2
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.clear(dirtyRect)
        let fill: NSColor
        let ink: NSColor
        switch style {
        case .teach: fill = NSColor(white: 0.98, alpha: 0.97); ink = NSColor(white: 0.1, alpha: 1)
        case .handoff: fill = accent; ink = .white
        case .nudge: fill = .systemOrange; ink = .white
        case .tag: fill = NSColor(white: 0.08, alpha: 0.82); ink = .white
        case .done: fill = .systemGreen; ink = .white
        }
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: style == .tag ? 7 : 10,
            yRadius: style == .tag ? 7 : 10
        )
        fill.setFill()
        shape.fill()
        NSColor.black.withAlphaComponent(style == .teach ? 0.14 : 0.08).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let shown = String(text.prefix(visibleCharacters))
        let horizontal: CGFloat = style == .tag ? 7 : 11
        let vertical: CGFloat = style == .tag ? 3 : 7
        (shown as NSString).draw(
            with: bounds.insetBy(dx: horizontal, dy: vertical),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.font(for: style), .foregroundColor: ink]
        )
    }
}

final class CursorBubblePanel: NSPanel {
    let bubbleView = CursorBubbleView()
    private(set) var shownAt: CFTimeInterval = 0
    var hideAt: CFTimeInterval?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(captureVisible: Bool) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        sharingType = captureVisible ? .readOnly : .none
        contentView = bubbleView
    }

    func show(text: String, style: BubbleStyle, now: CFTimeInterval, holdSeconds: Double?, typed: Bool) {
        bubbleView.text = text
        bubbleView.style = style
        bubbleView.visibleCharacters = typed ? 0 : text.count
        let size = CursorBubbleView.size(for: text, style: style)
        setContentSize(size)
        bubbleView.frame = NSRect(origin: .zero, size: size)
        shownAt = now
        hideAt = holdSeconds.map { now + typingDuration + $0 }
        alphaValue = 1
    }

    var typingDuration: Double {
        let count = Double(bubbleView.text.count)
        return min(count / 34, 1.2)
    }

    /// Advances the typing animation. Returns true while it still animates.
    func advance(now: CFTimeInterval, reduceMotion: Bool) -> Bool {
        let total = bubbleView.text.count
        guard bubbleView.visibleCharacters < total else { return false }
        if reduceMotion || typingDuration <= 0 {
            bubbleView.visibleCharacters = total
            return false
        }
        let progress = (now - shownAt) / typingDuration
        bubbleView.visibleCharacters = min(total, Int(Double(total) * progress) + 1)
        return bubbleView.visibleCharacters < total
    }

    /// Places the bubble below and right of a Cocoa point, kept on screen.
    func place(near point: CGPoint, offset: CGPoint = CGPoint(x: 20, y: -16)) {
        var origin = CGPoint(x: point.x + offset.x, y: point.y + offset.y - frame.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - frame.height - 4)
        }
        setFrameOrigin(origin)
    }
}

// MARK: - Annotations

enum AnnotationShape: String {
    case rect, ellipse, arrow, line, path, label
}

func annotationColor(_ name: String?) -> NSColor {
    switch name?.lowercased() {
    case "orange": return .systemOrange
    case "yellow": return .systemYellow
    case "green": return .systemGreen
    case "blue": return .systemBlue
    case "purple": return .systemPurple
    case "pink": return .systemPink
    case "white": return .white
    case "black": return .black
    default: return .systemRed
    }
}

func quartzPoint(_ value: Any?) -> CGPoint? {
    guard let array = value as? [NSNumber], array.count == 2 else { return nil }
    let point = CGPoint(x: array[0].doubleValue, y: array[1].doubleValue)
    return point.x.isFinite && point.y.isFinite ? point : nil
}

func quartzRect(_ value: Any?) -> CGRect? {
    guard let array = value as? [NSNumber], array.count == 4 else { return nil }
    let rect = CGRect(
        x: array[0].doubleValue, y: array[1].doubleValue,
        width: array[2].doubleValue, height: array[3].doubleValue
    )
    return rect.isNull || rect.isInfinite ? nil : rect
}

/// A transparent, click-through window spanning every display that draws
/// agent annotations with a hand-drawn reveal.
@MainActor
final class AnnotationOverlay {
    private let window: NSWindow
    private let rootLayer = CALayer()
    private var groups: [(id: Int, layer: CALayer, windowID: CGWindowID?, bounds: CGRect?, timer: Timer?)] = []
    private var nextGroupID = 1
    private var watchTimer: Timer?
    var onVisibilityChanged: (() -> Void)?

    init(captureVisible: Bool) {
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.sharingType = captureVisible ? .readOnly : .none
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer = rootLayer
        rootLayer.frame = view.bounds
        window.contentView = view
    }

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }
    var isVisible: Bool { !groups.isEmpty }

    func screensChanged() {
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        window.setFrame(frame, display: false)
        rootLayer.frame = CGRect(origin: .zero, size: frame.size)
    }

    private func local(_ quartz: CGPoint) -> CGPoint {
        let cocoa = quartzPointToCocoa(quartz)
        return CGPoint(x: cocoa.x - window.frame.minX, y: cocoa.y - window.frame.minY)
    }

    private func local(_ quartz: CGRect) -> CGRect {
        let cocoa = quartzRectToCocoa(quartz)
        return cocoa.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
    }

    /// Draws one annotation set. Items carry Quartz screen geometry.
    func show(
        items: [[String: Any]],
        caption: String?,
        captionAnchor: CGRect?,
        duration: TimeInterval,
        windowID: CGWindowID?,
        windowBounds: CGRect?,
        reduceMotion: Bool
    ) {
        let group = CALayer()
        group.frame = rootLayer.bounds
        var delay: CFTimeInterval = 0
        let base = CACurrentMediaTime()
        for item in items {
            guard let shape = AnnotationShape(rawValue: item["shape"] as? String ?? "") else { continue }
            let color = annotationColor(item["color"] as? String)
            if shape == .label {
                guard let at = quartzPoint(item["at"]), let text = item["text"] as? String else { continue }
                group.addSublayer(pill(text: text, color: color, at: local(at), appearAt: base + delay, reduceMotion: reduceMotion))
            } else if let path = strokePath(shape, item) {
                let layer = CAShapeLayer()
                layer.path = path
                layer.fillColor = nil
                layer.strokeColor = color.cgColor
                layer.lineWidth = 3
                layer.lineCap = .round
                layer.lineJoin = .round
                layer.shadowColor = NSColor.black.cgColor
                layer.shadowOpacity = 0.25
                layer.shadowRadius = 2
                layer.shadowOffset = CGSize(width: 0, height: -1)
                if !reduceMotion {
                    layer.strokeEnd = 1
                    let reveal = CABasicAnimation(keyPath: "strokeEnd")
                    reveal.fromValue = 0
                    reveal.toValue = 1
                    reveal.beginTime = base + delay
                    reveal.duration = 0.45
                    reveal.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    reveal.fillMode = .backwards
                    layer.add(reveal, forKey: "reveal")
                }
                group.addSublayer(layer)
            }
            delay += 0.18
        }
        if let caption, !caption.isEmpty {
            let anchor = captionAnchor.map(local) ?? rootLayer.bounds
            let at = CGPoint(x: anchor.midX, y: anchor.minY + 34)
            group.addSublayer(pill(
                text: caption,
                color: NSColor(white: 0.08, alpha: 0.85),
                at: at,
                appearAt: base + delay,
                reduceMotion: reduceMotion,
                centered: true,
                fontSize: 15
            ))
        }
        rootLayer.addSublayer(group)
        if !window.isVisible {
            window.orderFrontRegardless()
            onVisibilityChanged?()
        }
        let groupID = nextGroupID
        nextGroupID += 1
        let timer = Timer.scheduledTimer(withTimeInterval: max(duration, 0.5), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let entry = self.groups.first(where: { $0.id == groupID }) else { return }
                self.remove(entry.layer)
            }
        }
        groups.append((groupID, group, windowID, windowBounds, timer))
        startWatching()
    }

    func clear() {
        for entry in groups { remove(entry.layer) }
    }

    private func remove(_ layer: CALayer) {
        guard let index = groups.firstIndex(where: { $0.layer === layer }) else { return }
        groups[index].timer?.invalidate()
        groups.remove(at: index)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                layer.removeFromSuperlayer()
                if self?.groups.isEmpty == true {
                    self?.window.orderOut(nil)
                    self?.watchTimer?.invalidate()
                    self?.watchTimer = nil
                    self?.onVisibilityChanged?()
                }
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.3
        layer.opacity = 0
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// Annotations belong to a window; if it moves, resizes or closes they
    /// clear rather than drift onto the wrong content.
    private func startWatching() {
        guard watchTimer == nil else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for entry in self.groups {
                    guard let id = entry.windowID, let expected = entry.bounds else { continue }
                    let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]]
                    let bounds = (info?.first?[kCGWindowBounds as String] as? NSDictionary)
                        .flatMap { CGRect(dictionaryRepresentation: $0) }
                    guard let bounds,
                          abs(bounds.minX - expected.minX) < 3, abs(bounds.minY - expected.minY) < 3,
                          abs(bounds.width - expected.width) < 3, abs(bounds.height - expected.height) < 3 else {
                        self.remove(entry.layer)
                        continue
                    }
                }
            }
        }
    }

    private func strokePath(_ shape: AnnotationShape, _ item: [String: Any]) -> CGPath? {
        switch shape {
        case .rect:
            guard let rect = quartzRect(item["rect"]) else { return nil }
            return CGPath(roundedRect: local(rect).insetBy(dx: -4, dy: -4), cornerWidth: 6, cornerHeight: 6, transform: nil)
        case .ellipse:
            guard let rect = quartzRect(item["rect"]) else { return nil }
            return CGPath(ellipseIn: local(rect).insetBy(dx: -8, dy: -6), transform: nil)
        case .line, .arrow:
            guard let from = quartzPoint(item["from"]), let to = quartzPoint(item["to"]) else { return nil }
            let a = local(from), b = local(to)
            let path = CGMutablePath()
            path.move(to: a)
            path.addLine(to: b)
            if shape == .arrow {
                let angle = atan2(b.y - a.y, b.x - a.x)
                for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                    path.move(to: b)
                    path.addLine(to: CGPoint(x: b.x + 14 * cos(angle + side), y: b.y + 14 * sin(angle + side)))
                }
            }
            return path
        case .path:
            let points = (item["points"] as? [Any] ?? []).compactMap(quartzPoint).map(local)
            guard points.count >= 2 else { return nil }
            let path = CGMutablePath()
            path.addLines(between: points)
            return path
        case .label:
            return nil
        }
    }

    private func pill(
        text: String,
        color: NSColor,
        at point: CGPoint,
        appearAt: CFTimeInterval,
        reduceMotion: Bool,
        centered: Bool = false,
        fontSize: CGFloat = 12
    ) -> CALayer {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let width = min(ceil(size.width) + 16, 520)
        let height = ceil(size.height) + 8
        let container = CALayer()
        container.frame = CGRect(
            x: centered ? point.x - width / 2 : point.x,
            y: point.y - height / 2,
            width: width,
            height: height
        )
        container.backgroundColor = color.cgColor
        container.cornerRadius = height / 2
        container.shadowOpacity = 0.25
        container.shadowRadius = 3
        container.shadowOffset = CGSize(width: 0, height: -1)
        let label = CATextLayer()
        label.string = text
        label.font = font
        label.fontSize = fontSize
        label.foregroundColor = NSColor.white.cgColor
        label.alignmentMode = .center
        label.truncationMode = .end
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        label.frame = CGRect(x: 8, y: 4, width: width - 16, height: ceil(size.height))
        container.addSublayer(label)
        if !reduceMotion {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.beginTime = appearAt
            appear.duration = 0.25
            appear.fillMode = .backwards
            container.add(appear, forKey: "appear")
        }
        return container
    }
}

// MARK: - Interactive surfaces

/// True for an event an agent synthesised through the desktop tools. Answers
/// to an agent's question must come from the person, never the agent.
func eventIsAgentSynthesised(_ event: NSEvent?) -> Bool {
    event?.cgEvent?.getIntegerValueField(.eventSourceUserData) == desktopSyntheticEventUserData
}

final class InteractivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Up to four answer chips beside the agent's cursor.
@MainActor
final class ChoicePrompt: NSObject {
    let panel: InteractivePanel
    private let options: [String]
    private let completion: (Int?) -> Void
    private var finished = false

    init(question: String, options: [String], near point: CGPoint?, captureVisible: Bool, completion: @escaping (Int?) -> Void) {
        self.options = options
        self.completion = completion
        panel = InteractivePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = captureVisible ? .readOnly : .none

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(wrappingLabelWithString: question)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.preferredMaxLayoutWidth = 300
        stack.addArrangedSubview(title)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        for (index, option) in options.enumerated() {
            let button = NSButton(title: option, target: self, action: #selector(choose(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            if index == 0 { button.keyEquivalent = "" }
            row.addArrangedSubview(button)
        }
        stack.addArrangedSubview(row)
        let hint = NSTextField(labelWithString: "Only your click counts · Esc to dismiss")
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])
        panel.contentView = background
        let fitting = background.fittingSize
        panel.setContentSize(NSSize(width: max(fitting.width, 220), height: fitting.height))

        let screen = point.flatMap { p in NSScreen.screens.first { $0.frame.contains(p) } } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        var origin = point.map { CGPoint(x: $0.x + 24, y: $0.y - 24 - panel.frame.height) }
            ?? CGPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    @objc private func choose(_ sender: NSButton) {
        guard !eventIsAgentSynthesised(NSApp.currentEvent) else { return }
        finish(sender.tag)
    }

    func finish(_ index: Int?) {
        guard !finished else { return }
        finished = true
        panel.orderOut(nil)
        completion(index)
    }
}

/// Pick mode: the person's next click (or several, then Done) is captured
/// and returned to the agent instead of reaching the app underneath.
@MainActor
final class PickSession: NSObject {
    private final class CatchView: NSView {
        weak var session: PickSession?
        var highlight: CGRect?
        var marks: [CGPoint] = []
        override var isFlipped: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }
        override func mouseMoved(with event: NSEvent) {
            MainActor.assumeIsolated { session?.hover(NSEvent.mouseLocation) }
        }
        override func mouseDown(with event: NSEvent) {
            guard !eventIsAgentSynthesised(event) else { return }
            MainActor.assumeIsolated { session?.pick(NSEvent.mouseLocation) }
        }
        override func rightMouseDown(with event: NSEvent) {}
        override func draw(_ dirtyRect: NSRect) {
            NSGraphicsContext.current?.cgContext.clear(dirtyRect)
            NSColor.black.withAlphaComponent(0.012).setFill()
            bounds.fill()
            if let highlight {
                let local = highlight.offsetBy(dx: -(window?.frame.minX ?? 0), dy: -(window?.frame.minY ?? 0))
                let path = NSBezierPath(roundedRect: local.insetBy(dx: -3, dy: -3), xRadius: 5, yRadius: 5)
                path.lineWidth = 2
                accent.setStroke()
                path.stroke()
            }
            for (index, mark) in marks.enumerated() {
                let local = CGPoint(x: mark.x - (window?.frame.minX ?? 0), y: mark.y - (window?.frame.minY ?? 0))
                let circle = CGRect(x: local.x - 10, y: local.y - 10, width: 20, height: 20)
                accent.setFill()
                NSBezierPath(ovalIn: circle).fill()
                let label = "\(index + 1)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white,
                ]
                let size = label.size(withAttributes: attributes)
                label.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attributes)
            }
        }
    }

    private var panels: [InteractivePanel] = []
    private var views: [CatchView] = []
    private let instruction: CursorBubblePanel
    private var doneButtonPanel: InteractivePanel?
    private let multiple: Bool
    private var picks: [CGPoint] = [] // Quartz
    private let completion: ([CGPoint]?) -> Void
    private var finished = false
    private var lastHover: CFTimeInterval = 0

    init(prompt: String, multiple: Bool, captureVisible: Bool, completion: @escaping ([CGPoint]?) -> Void) {
        self.multiple = multiple
        self.completion = completion
        instruction = CursorBubblePanel(captureVisible: captureVisible)
        super.init()
        for screen in NSScreen.screens {
            let panel = InteractivePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.sharingType = captureVisible ? .readOnly : .none
            let view = CatchView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.session = self
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
        let text = multiple
            ? "\(prompt)\nClick each one, then Done · Esc to cancel"
            : "\(prompt)\nClick it · Esc to cancel"
        instruction.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        instruction.show(text: text, style: .handoff, now: CACurrentMediaTime(), holdSeconds: nil, typed: false)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            instruction.setFrameOrigin(CGPoint(
                x: screen.visibleFrame.midX - instruction.frame.width / 2,
                y: screen.visibleFrame.maxY - instruction.frame.height - 60
            ))
            if multiple {
                let done = InteractivePanel(contentRect: NSRect(x: 0, y: 0, width: 90, height: 34), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                done.isOpaque = false
                done.backgroundColor = .clear
                done.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
                done.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
                done.sharingType = captureVisible ? .readOnly : .none
                let button = NSButton(title: "Done", target: self, action: #selector(doneClicked))
                button.bezelStyle = .rounded
                button.frame = NSRect(x: 5, y: 2, width: 80, height: 30)
                let container = NSView(frame: NSRect(x: 0, y: 0, width: 90, height: 34))
                container.addSubview(button)
                done.contentView = container
                done.setFrameOrigin(CGPoint(x: instruction.frame.maxX + 8, y: instruction.frame.midY - 17))
                done.orderFrontRegardless()
                doneButtonPanel = done
            }
        }
        instruction.orderFrontRegardless()
    }

    var windowIDs: [CGWindowID] {
        (panels + [instruction] + (doneButtonPanel.map { [$0] } ?? [])).map { CGWindowID($0.windowNumber) }
    }

    fileprivate func hover(_ cocoaPoint: CGPoint) {
        let now = CACurrentMediaTime()
        guard now - lastHover > 0.06 else { return }
        lastHover = now
        let quartz = CGPoint(x: cocoaPoint.x, y: primaryScreen().frame.height - cocoaPoint.y)
        let frame = elementFrameUnder(quartz).map(quartzRectToCocoa)
        for view in views where view.highlight != frame {
            view.highlight = frame
            view.needsDisplay = true
        }
    }

    fileprivate func pick(_ cocoaPoint: CGPoint) {
        let quartz = CGPoint(x: cocoaPoint.x, y: primaryScreen().frame.height - cocoaPoint.y)
        picks.append(quartz)
        guard multiple else {
            finish(picks)
            return
        }
        for view in views {
            view.marks.append(cocoaPoint)
            view.needsDisplay = true
        }
    }

    @objc private func doneClicked() {
        guard !eventIsAgentSynthesised(NSApp.currentEvent) else { return }
        finish(picks)
    }

    func finish(_ result: [CGPoint]?) {
        guard !finished else { return }
        finished = true
        panels.forEach { $0.orderOut(nil) }
        instruction.orderOut(nil)
        doneButtonPanel?.orderOut(nil)
        completion(result)
    }
}

/// The accessibility frame (Quartz) of the element in another app at a
/// point, skipping Mac Computer Use's own windows.
func elementFrameUnder(_ quartz: CGPoint) -> CGRect? {
    guard let pid = windowOwnerUnder(quartz) else { return nil }
    var element: AXUIElement?
    let app = AXUIElementCreateApplication(pid)
    guard AXUIElementCopyElementAtPosition(app, Float(quartz.x), Float(quartz.y), &element) == .success,
          let element else { return nil }
    return axFrame(element)
}

/// The frontmost layer-0 window owner at a Quartz point, excluding this process.
func windowOwnerUnder(_ quartz: CGPoint) -> pid_t? {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in info {
        guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              owner != getpid(),
              let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
              bounds.contains(quartz) else { continue }
        return owner
    }
    return nil
}

/// Hand-off: watches for the person's own click inside a target while the
/// cursor points at it. Clicks still reach the app; nothing is intercepted.
@MainActor
final class HandoffWatch {
    private var monitors: [Any] = []
    private let target: CGRect // Quartz
    private let onInside: () -> Void
    private let onOutside: () -> Void
    private var finished = false

    init(target: CGRect, onInside: @escaping () -> Void, onOutside: @escaping () -> Void) {
        self.target = target
        self.onInside = onInside
        self.onOutside = onOutside
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard !eventIsAgentSynthesised(event) else { return }
            let location = NSEvent.mouseLocation
            let quartz = CGPoint(x: location.x, y: primaryScreen().frame.height - location.y)
            MainActor.assumeIsolated { self?.observe(quartz) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            monitors.append(global)
        }
    }

    private func observe(_ quartz: CGPoint) {
        guard !finished else { return }
        if target.insetBy(dx: -4, dy: -4).contains(quartz) {
            stop()
            onInside()
        } else {
            onOutside()
        }
    }

    func stop() {
        guard !finished else { return }
        finished = true
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }
}

// MARK: - Overlay presenter

/// Renders every session's cursor, the shared action banner and agent
/// bubbles. Its timer runs only while something is visible or moving.
@MainActor
final class ServiceOverlayPresenter {
    private struct SessionCursor {
        let panel: AutomationCursorPanel
        let view: AutomationCursorView
        var state: [String: Any] = [:]
        var target: CGPoint?
        var displayed: CGPoint?
        var flight: CursorFlight?
        var lastActivity: CFTimeInterval = 0
        var lastFlashTimestamp: Double?
        var pendingClickAt: CFTimeInterval?
        var name = ""
        var colorIndex = 0
        var bubble: CursorBubblePanel?
        var tag: CursorBubblePanel?
        var countdownEnds: CFTimeInterval = 0
        var visible = false
    }

    private let assets: AutomationCursorAssets
    let captureVisible: Bool
    private let bannerWindow: NSWindow
    private let bannerView: OverlayView
    let annotations: AnnotationOverlay
    private var cursors: [String: SessionCursor] = [:]
    private var timer: Timer?
    private var pausedBannerUntil: CFTimeInterval = 0
    private var paused = false
    private var screenObserver: NSObjectProtocol?
    private var extraWindowIDs: [CGWindowID] = []
    var fadeAfter: TimeInterval = 8
    var onWindowsChanged: (([CGWindowID]) -> Void)?

    init(assets: AutomationCursorAssets, captureVisible: Bool) {
        self.assets = assets
        self.captureVisible = captureVisible
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        bannerWindow = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        bannerWindow.isOpaque = false
        bannerWindow.backgroundColor = .clear
        bannerWindow.level = .screenSaver
        bannerWindow.ignoresMouseEvents = true
        bannerWindow.hasShadow = false
        bannerWindow.isReleasedWhenClosed = false
        bannerWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        bannerWindow.sharingType = captureVisible ? .readOnly : .none
        bannerView = OverlayView(frame: CGRect(origin: .zero, size: frame.size))
        bannerWindow.contentView = bannerView
        annotations = AnnotationOverlay(captureVisible: captureVisible)
        annotations.onVisibilityChanged = { [weak self] in
            guard let self else { return }
            self.onWindowsChanged?(self.windowIDs)
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    var hasVisibleCursor: Bool { cursors.values.contains { $0.visible } }

    var windowIDs: [CGWindowID] {
        var identifiers = [CGWindowID(bannerWindow.windowNumber), annotations.windowID]
        for cursor in cursors.values {
            identifiers.append(CGWindowID(cursor.panel.windowNumber))
            if let bubble = cursor.bubble { identifiers.append(CGWindowID(bubble.windowNumber)) }
            if let tag = cursor.tag { identifiers.append(CGWindowID(tag.windowNumber)) }
        }
        identifiers += extraWindowIDs
        return identifiers.filter { $0 > 0 }
    }

    /// Windows of interactive surfaces (pick mode, chips) to hide from captures.
    func setExtraWindows(_ identifiers: [CGWindowID]) {
        extraWindowIDs = identifiers
        onWindowsChanged?(windowIDs)
    }

    func cursorPoint(for sessionID: String) -> CGPoint? {
        guard let cursor = cursors[sessionID], cursor.visible else { return nil }
        return cursor.displayed
    }

    func setIdentity(sessionID: String, name: String, colorIndex: Int) {
        var cursor = cursors[sessionID] ?? makeCursor()
        cursor.name = name
        cursor.colorIndex = colorIndex
        cursors[sessionID] = cursor
    }

    func update(sessionID: String, state: [String: Any]) {
        var cursor = cursors[sessionID] ?? makeCursor()
        let now = CACurrentMediaTime()
        let previous = cursor.state
        cursor.state = state
        if let point = state["cursor"] as? [Double], point.count == 2 {
            let target = quartzPointToCocoa(CGPoint(x: point[0], y: point[1]))
            if cursor.target != target {
                let pace = CursorPace(rawValue: state["cursor_pace"] as? String ?? "") ?? .act
                if let from = cursor.displayed, cursor.visible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    cursor.flight = CursorFlight(from: from, to: target, start: now, pace: pace, multiplier: cursorPaceMultiplier())
                } else {
                    cursor.flight = nil
                    cursor.displayed = target
                }
                cursor.target = target
                cursor.lastActivity = now
            }
        }
        let controlling = state["controlling"] as? Bool ?? false
        if controlling || (previous["status"] as? String) != (state["status"] as? String) {
            cursor.lastActivity = now
        }
        if let flash = (state["flashes"] as? [[Double]])?.last, flash.count == 3,
           flash[2] != cursor.lastFlashTimestamp {
            cursor.lastFlashTimestamp = flash[2]
            if flash[2] <= now, now - flash[2] < 0.75 {
                cursor.pendingClickAt = now
                cursor.lastActivity = now
            }
        }
        let isNew = cursors[sessionID] == nil
        cursors[sessionID] = cursor
        if isNew { onWindowsChanged?(windowIDs) }
        ensureTimer()
    }

    func showBubble(sessionID: String, text: String, style: BubbleStyle, holdSeconds: Double?) {
        guard var cursor = cursors[sessionID] else { return }
        let bubble = cursor.bubble ?? CursorBubblePanel(captureVisible: captureVisible)
        let isNew = cursor.bubble == nil
        cursor.bubble = bubble
        cursor.lastActivity = CACurrentMediaTime()
        bubble.show(
            text: String(text.prefix(220)),
            style: style,
            now: CACurrentMediaTime(),
            holdSeconds: holdSeconds,
            // Only explanations type themselves out; warnings and requests
            // must be readable at once.
            typed: style == .teach && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        cursors[sessionID] = cursor
        if isNew { onWindowsChanged?(windowIDs) }
        ensureTimer()
    }

    func clearBubble(sessionID: String) {
        cursors[sessionID]?.bubble?.hideAt = CACurrentMediaTime()
        ensureTimer()
    }

    func startCountdown(sessionID: String, duration: TimeInterval) {
        guard var cursor = cursors[sessionID] else { return }
        let now = CACurrentMediaTime()
        cursor.view.countdown = (now, duration)
        cursor.countdownEnds = now + duration
        cursor.lastActivity = now
        cursors[sessionID] = cursor
        ensureTimer()
    }

    func shake(sessionID: String) {
        guard let cursor = cursors[sessionID] else { return }
        cursor.view.shakeStartedAt = CACurrentMediaTime()
        ensureTimer()
    }

    func removeSession(_ sessionID: String) {
        guard let cursor = cursors.removeValue(forKey: sessionID) else { return }
        cursor.panel.orderOut(nil)
        cursor.panel.close()
        cursor.bubble?.orderOut(nil)
        cursor.tag?.orderOut(nil)
        onWindowsChanged?(windowIDs)
        ensureTimer()
    }

    func removeAll() {
        for id in Array(cursors.keys) { removeSession(id) }
        annotations.clear()
        bannerWindow.orderOut(nil)
        timer?.invalidate()
        timer = nil
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        pausedBannerUntil = paused ? CACurrentMediaTime() + 4 : 0
        ensureTimer()
    }

    private func makeCursor() -> SessionCursor {
        let panel = makeAutomationCursorPanel(assets: assets)
        panel.sharingType = captureVisible ? .readOnly : .none
        panel.alphaValue = 0
        let view = panel.contentView as! AutomationCursorView
        return SessionCursor(panel: panel, view: view)
    }

    private func screensChanged() {
        let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        bannerWindow.setFrame(frame, display: bannerWindow.isVisible)
        bannerView.frame = CGRect(origin: .zero, size: frame.size)
        annotations.screensChanged()
    }

    func ensureTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var needsFrames = false
        var bannerSession: SessionCursor?
        var windowsChanged = false

        for (id, var cursor) in cursors {
            let controlling = cursor.state["controlling"] as? Bool ?? false
            let lingerUntil = cursor.state["lingerUntil"] as? Double ?? 0
            let bubbleShowing = cursor.bubble.map { $0.isVisible && ($0.hideAt.map { now < $0 } ?? true) } ?? false
            let active = controlling || now < lingerUntil || bubbleShowing || now < cursor.countdownEnds
            if active {
                cursor.lastActivity = max(cursor.lastActivity, now)
                if controlling && (bannerSession == nil || controlling) { bannerSession = cursor }
                else if bannerSession == nil && now < lingerUntil { bannerSession = cursor }
            }

            if let flight = cursor.flight {
                let sample = flight.sample(at: now)
                cursor.displayed = sample.point
                cursor.view.rotation = reduceMotion ? 0 : sample.rotation
                cursor.view.flightScale = reduceMotion ? 1 : sample.scale
                if sample.finished { cursor.flight = nil }
                needsFrames = true
            } else if cursor.displayed == nil {
                cursor.displayed = cursor.target
            }
            if cursor.pendingClickAt != nil, cursor.flight == nil {
                cursor.view.clickStartedAt = now
                cursor.pendingClickAt = nil
            }
            if now >= cursor.countdownEnds { cursor.view.countdown = nil }
            cursor.view.badgeSymbol = controlling ? cursorBadgeSymbol(forStatus: cursor.state["status"] as? String ?? "") : nil

            let opacity = cursorIdleOpacity(now: now, lastActivity: cursor.lastActivity, active: active, fadeAfter: fadeAfter)
            if let displayed = cursor.displayed, opacity > 0.001 {
                cursor.view.reduceMotion = reduceMotion
                cursor.view.cancelling = cursor.state["cancelling"] as? Bool ?? false
                cursor.panel.setFrameOrigin(CGPoint(
                    x: displayed.x - cursor.panel.frame.width / 2,
                    y: displayed.y - cursor.panel.frame.height / 2
                ))
                cursor.panel.alphaValue = opacity
                if !cursor.panel.isVisible {
                    cursor.panel.orderFrontRegardless()
                    windowsChanged = true
                }
                cursor.visible = true
                cursor.view.needsDisplay = true
                needsFrames = true
                if let bubble = cursor.bubble {
                    if let hideAt = bubble.hideAt, now >= hideAt {
                        let fade = max(0, 1 - (now - hideAt) / 0.3)
                        bubble.alphaValue = fade
                        if fade <= 0 { bubble.orderOut(nil) }
                    } else {
                        if !bubble.isVisible { bubble.orderFrontRegardless() }
                        bubble.alphaValue = opacity
                        _ = bubble.advance(now: now, reduceMotion: reduceMotion)
                        bubble.bubbleView.needsDisplay = true
                    }
                    bubble.place(near: displayed)
                }
            } else {
                if cursor.panel.isVisible {
                    cursor.panel.alphaValue = 0
                    cursor.panel.orderOut(nil)
                }
                cursor.bubble?.orderOut(nil)
                cursor.tag?.orderOut(nil)
                cursor.visible = false
            }
            cursors[id] = cursor
        }

        // Several agents at once: colour each cursor and show who it is.
        let visibleIDs = cursors.filter { $0.value.visible }.map(\.key)
        for (id, var cursor) in cursors {
            let showIdentity = visibleIDs.count > 1 && cursor.visible
            cursor.view.glowColor = showIdentity ? cursorIdentityPalette[cursor.colorIndex] : .white
            if showIdentity, let displayed = cursor.displayed, !cursor.name.isEmpty {
                let tag = cursor.tag ?? CursorBubblePanel(captureVisible: captureVisible)
                if cursor.tag == nil {
                    tag.show(text: cursor.name, style: .tag, now: now, holdSeconds: nil, typed: false)
                    cursor.tag = tag
                    windowsChanged = true
                }
                tag.place(near: displayed, offset: CGPoint(x: -10, y: -26))
                tag.alphaValue = cursor.panel.alphaValue
                if !tag.isVisible { tag.orderFrontRegardless() }
            } else {
                cursor.tag?.orderOut(nil)
            }
            cursors[id] = cursor
        }

        let showPausedBanner = paused && now < pausedBannerUntil
        if let bannerSession, !showPausedBanner {
            bannerView.controlling = true
            bannerView.paused = false
            bannerView.cancelling = bannerSession.state["cancelling"] as? Bool ?? false
            let status = bannerSession.state["status"] as? String ?? ""
            bannerView.status = visibleIDs.count > 1 && !bannerSession.name.isEmpty ? "\(bannerSession.name): \(status)" : status
            bannerView.hint = "Esc to stop"
        } else if showPausedBanner {
            bannerView.controlling = true
            bannerView.paused = true
            bannerView.cancelling = false
            bannerView.status = "Agents paused"
            bannerView.hint = "Resume from the menu bar"
        } else {
            bannerView.controlling = false
        }
        if bannerView.controlling {
            if !bannerWindow.isVisible {
                bannerWindow.orderFrontRegardless()
                windowsChanged = true
            }
            bannerView.needsDisplay = true
            needsFrames = true
        } else if bannerWindow.isVisible {
            bannerWindow.orderOut(nil)
        }

        if windowsChanged { onWindowsChanged?(windowIDs) }
        if !needsFrames {
            timer?.invalidate()
            timer = nil
        }
    }
}
