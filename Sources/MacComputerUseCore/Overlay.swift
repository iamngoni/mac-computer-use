import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - Overlay (followable cursor, banner, click feedback)
let accent = NSColor(srgbRed: 0.42, green: 0.58, blue: 1.0, alpha: 1.0)

struct OverlayPresentation {
    let showTransientOverlay: Bool
    let showCursor: Bool
}

func overlayPresentation(
    controlling: Bool,
    lingerUntil: Double,
    now: Double,
    captureHidden: Bool,
    hasCursor: Bool
) -> OverlayPresentation {
    let transientActive = controlling || now < lingerUntil
    return OverlayPresentation(
        showTransientOverlay: transientActive && !captureHidden,
        showCursor: hasCursor && !captureHidden
    )
}

struct MenuBarPresentation {
    let buttonTitle: String
    let accessibilityLabel: String
    let statusTitle: String
    let controlledAppTitles: [String]
}

func menuBarPresentation(
    currentApp: String?,
    controlledApps: [String],
    paused: Bool = false
) -> MenuBarPresentation {
    let current = currentApp?.trimmingCharacters(in: .whitespacesAndNewlines)
    let visibleCurrent = current.flatMap { $0.isEmpty ? nil : $0 }
    var normalizedApps = controlledApps.compactMap { app -> String? in
        let normalized = app.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
    if let visibleCurrent { normalizedApps.append(visibleCurrent) }
    let apps = Array(Set(normalizedApps)).sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    var accessibilityLabel: String
    var statusTitle: String
    switch apps.count {
    case 0:
        accessibilityLabel = "Mac Computer Use ready"
        statusTitle = "Ready"
    case 1:
        accessibilityLabel = "Mac Computer Use active: \(apps[0])"
        statusTitle = "Active · \(apps[0])"
    default:
        accessibilityLabel = "Mac Computer Use active: \(apps.count) apps"
        statusTitle = "Active · \(apps.count) apps"
    }
    if paused {
        accessibilityLabel = "Mac Computer Use paused"
        statusTitle = "Paused · agents stopped by Esc"
    }
    return MenuBarPresentation(
        buttonTitle: apps.isEmpty ? "" : "\(apps.count)",
        accessibilityLabel: accessibilityLabel,
        statusTitle: statusTitle,
        controlledAppTitles: apps
    )
}

public struct AutomationCursorAssets {
    public static let canvasSize = CGSize(width: 28, height: 28)
    public static let pointerHotspot = CGPoint(x: 6.75, y: 6.5)

    public let pointer: NSImage
    public let pulse: NSImage

    public static func load(resourceRoot: URL? = Bundle.main.resourceURL) -> AutomationCursorAssets? {
        guard let directory = resourceRoot?.appendingPathComponent(
            "VirtualCursor",
            isDirectory: true
        ),
        let pointer = loadScaleAwareImage(named: "cursor-pointer", from: directory),
        let pulse = loadScaleAwareImage(named: "cursor-pulse", from: directory) else {
            return nil
        }
        return AutomationCursorAssets(pointer: pointer, pulse: pulse)
    }

    static var emptyForTesting: AutomationCursorAssets {
        AutomationCursorAssets(
            pointer: NSImage(size: canvasSize),
            pulse: NSImage(size: canvasSize)
        )
    }

    private static func loadScaleAwareImage(named name: String, from directory: URL) -> NSImage? {
        let image = NSImage(size: canvasSize)
        for suffix in ["", "@2x", "@3x"] {
            let url = directory.appendingPathComponent(name + suffix + ".png")
            guard let data = try? Data(contentsOf: url),
                  let representation = NSBitmapImageRep(data: data) else {
                return nil
            }
            representation.size = canvasSize
            image.addRepresentation(representation)
        }
        image.isTemplate = false
        return image
    }
}

func cursorPointerDrawRect(in bounds: CGRect) -> CGRect {
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    return CGRect(
        x: center.x - AutomationCursorAssets.pointerHotspot.x,
        y: center.y - (
            AutomationCursorAssets.canvasSize.height
            - AutomationCursorAssets.pointerHotspot.y
        ),
        width: AutomationCursorAssets.canvasSize.width,
        height: AutomationCursorAssets.canvasSize.height
    )
}

func cursorPulseDrawRect(in bounds: CGRect, scale: CGFloat) -> CGRect {
    let size = CGSize(
        width: AutomationCursorAssets.canvasSize.width * scale,
        height: AutomationCursorAssets.canvasSize.height * scale
    )
    return CGRect(
        x: bounds.midX - size.width / 2,
        y: bounds.midY - size.height / 2,
        width: size.width,
        height: size.height
    )
}

func makeAutomationStatusImage(
    cursorImage: NSImage? = nil
) -> NSImage {
    let size = NSSize(width: 30, height: 18)
    let image = NSImage(size: size, flipped: false) { _ in
        let cursor = cursorImage ?? NSImage(
            systemSymbolName: "cursorarrow",
            accessibilityDescription: nil
        )
        cursor?.draw(
            in: NSRect(x: 0, y: 0, width: 18, height: 18),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        NSColor.systemBlue.setFill()
        NSBezierPath(
            ovalIn: NSRect(x: 22, y: 6, width: 6, height: 6)
        ).fill()
        return true
    }
    image.isTemplate = false
    return image
}

public struct AutomationStatusBarActions {
    public let version: String
    public let setup: () -> Void
    public let showPermissions: () -> Void
    public let checkForUpdates: () -> Void
    public let canCheckForUpdates: () -> Bool
    public let quit: () -> Void
    public let isPaused: () -> Bool
    public let setPaused: (Bool) -> Void
    public let sessions: () -> [ServiceSessionSummary]
    public let agentPreviewEnabled: () -> Bool
    public let setAgentPreviewEnabled: (Bool) -> Void
    public let tours: () -> [(name: String, title: String)]
    public let playTour: (String) -> Void
    public let openToursFolder: () -> Void

    public init(
        version: String,
        setup: @escaping () -> Void,
        showPermissions: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void,
        canCheckForUpdates: @escaping () -> Bool,
        quit: @escaping () -> Void,
        isPaused: @escaping () -> Bool = { false },
        setPaused: @escaping (Bool) -> Void = { _ in },
        sessions: @escaping () -> [ServiceSessionSummary] = { [] },
        agentPreviewEnabled: @escaping () -> Bool = { false },
        setAgentPreviewEnabled: @escaping (Bool) -> Void = { _ in },
        tours: @escaping () -> [(name: String, title: String)] = { [] },
        playTour: @escaping (String) -> Void = { _ in },
        openToursFolder: @escaping () -> Void = {}
    ) {
        self.version = version
        self.setup = setup
        self.showPermissions = showPermissions
        self.checkForUpdates = checkForUpdates
        self.canCheckForUpdates = canCheckForUpdates
        self.quit = quit
        self.isPaused = isPaused
        self.setPaused = setPaused
        self.sessions = sessions
        self.agentPreviewEnabled = agentPreviewEnabled
        self.setAgentPreviewEnabled = setAgentPreviewEnabled
        self.tours = tours
        self.playTour = playTour
        self.openToursFolder = openToursFolder
    }
}

/// Groups live sessions by client for the menu, e.g. "claude · 2 sessions".
func connectedClientTitles(_ sessions: [ServiceSessionSummary]) -> [String] {
    var counts: [String: Int] = [:]
    var pending = Set<String>()
    for session in sessions {
        counts[session.clientName, default: 0] += 1
        if session.approval == "pending" { pending.insert(session.clientName) }
        if session.approval == "denied" { pending.insert(session.clientName) }
    }
    return counts.keys.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }.map { name in
        let count = counts[name] ?? 0
        var title = count == 1 ? name : "\(name) · \(count) sessions"
        if pending.contains(name) { title += " (not allowed yet)" }
        return title
    }
}

@MainActor
final class AutomationStatusBarController {
    private let cursorImage: NSImage
    private let actions: AutomationStatusBarActions?
    private let statusItem: NSStatusItem
    private var lastSignature = ""

    init(cursorImage: NSImage, actions: AutomationStatusBarActions?) {
        self.cursorImage = cursorImage
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        update(currentApp: nil, controlledApps: [])
    }

    deinit { NSStatusBar.system.removeStatusItem(statusItem) }

    var isActive: Bool { statusItem.button != nil }

    /// Where the menu-bar item is on screen (Cocoa), for the cursor demo.
    var buttonFrame: CGRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func update(
        currentApp: String?,
        controlledApps: [String]
    ) {
        let paused = actions?.isPaused() == true
        let presentation = menuBarPresentation(
            currentApp: currentApp,
            controlledApps: controlledApps,
            paused: paused
        )
        let clients = connectedClientTitles(actions?.sessions() ?? [])
        let signature = ([
            presentation.accessibilityLabel,
            presentation.statusTitle,
            actions?.canCheckForUpdates() == true ? "updates-enabled" : "updates-disabled",
            paused ? "paused" : "running",
            actions?.agentPreviewEnabled() == true ? "preview" : "no-preview",
            (actions?.tours() ?? []).map(\.name).joined(separator: ","),
        ] + presentation.controlledAppTitles + ["|"] + clients).joined(separator: "\u{1f}")
        guard signature != lastSignature else { return }
        lastSignature = signature

        if let button = statusItem.button {
            button.title = presentation.buttonTitle
            button.image = makeAutomationStatusImage(cursorImage: cursorImage)
            button.imagePosition = presentation.buttonTitle.isEmpty ? .imageOnly : .imageLeading
            button.toolTip = presentation.accessibilityLabel
            button.setAccessibilityLabel(presentation.accessibilityLabel)
        }

        let menu = NSMenu(title: "Mac Computer Use")
        let status = NSMenuItem(
            title: presentation.controlledAppTitles.isEmpty && actions != nil
                ? "Ready"
                : presentation.statusTitle,
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let heading = NSMenuItem(
            title: "Controlled apps",
            action: nil,
            keyEquivalent: ""
        )
        heading.isEnabled = false
        menu.addItem(heading)
        if presentation.controlledAppTitles.isEmpty {
            let none = NSMenuItem(
                title: "No apps active",
                action: nil,
                keyEquivalent: ""
            )
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for appTitle in presentation.controlledAppTitles {
                let item = NSMenuItem(
                    title: "• " + appTitle,
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
        }
        if let actions {
            menu.addItem(.separator())
            let pause = NSMenuItem(
                title: paused ? "Resume Agents" : "Pause Agents",
                action: #selector(togglePause),
                keyEquivalent: ""
            )
            pause.target = self
            menu.addItem(pause)
            let preview = NSMenuItem(
                title: "Show Agent Preview",
                action: #selector(togglePreview),
                keyEquivalent: ""
            )
            preview.target = self
            preview.state = actions.agentPreviewEnabled() ? .on : .off
            menu.addItem(preview)

            menu.addItem(.separator())
            let clientsHeading = NSMenuItem(title: "Connected clients", action: nil, keyEquivalent: "")
            clientsHeading.isEnabled = false
            menu.addItem(clientsHeading)
            for title in clients.isEmpty ? ["None"] : clients {
                let item = NSMenuItem(title: clients.isEmpty ? title : "• " + title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }

            menu.addItem(.separator())
            let toursItem = NSMenuItem(title: "Guided Tours", action: nil, keyEquivalent: "")
            let toursMenu = NSMenu(title: "Guided Tours")
            let tours = actions.tours()
            if tours.isEmpty {
                let none = NSMenuItem(title: "No saved tours yet", action: nil, keyEquivalent: "")
                none.isEnabled = false
                toursMenu.addItem(none)
            }
            for tour in tours {
                let item = NSMenuItem(title: tour.title, action: #selector(playTour(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = tour.name
                toursMenu.addItem(item)
            }
            toursMenu.addItem(.separator())
            let folder = NSMenuItem(title: "Open Tours Folder…", action: #selector(openToursFolder), keyEquivalent: "")
            folder.target = self
            toursMenu.addItem(folder)
            toursItem.submenu = toursMenu
            menu.addItem(toursItem)

            let setup = NSMenuItem(
                title: "Setup Mac Computer Use…",
                action: #selector(openSetup),
                keyEquivalent: ""
            )
            setup.target = self
            menu.addItem(setup)

            let permissions = NSMenuItem(
                title: "Permissions…",
                action: #selector(openPermissions),
                keyEquivalent: ""
            )
            permissions.target = self
            menu.addItem(permissions)

            let updates = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
            updates.target = self
            updates.isEnabled = actions.canCheckForUpdates()
            menu.addItem(updates)

            menu.addItem(.separator())
            let version = NSMenuItem(
                title: "Version \(actions.version)",
                action: nil,
                keyEquivalent: ""
            )
            version.isEnabled = false
            menu.addItem(version)

            let quit = NSMenuItem(
                title: "Quit Mac Computer Use",
                action: #selector(quitManager),
                keyEquivalent: "q"
            )
            quit.target = self
            menu.addItem(quit)
        }
        statusItem.menu = menu
    }

    @objc private func openSetup() { actions?.setup() }
    @objc private func playTour(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        actions?.playTour(name)
    }
    @objc private func openToursFolder() { actions?.openToursFolder() }
    @objc private func togglePreview() {
        guard let actions else { return }
        actions.setAgentPreviewEnabled(!actions.agentPreviewEnabled())
    }
    @objc private func togglePause() {
        guard let actions else { return }
        actions.setPaused(!actions.isPaused())
    }
    @objc private func openPermissions() { actions?.showPermissions() }
    @objc private func checkForUpdates() { actions?.checkForUpdates() }
    @objc private func quitManager() { actions?.quit() }
}

final class ExclusiveFileLease {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL) -> ExclusiveFileLease? {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return ExclusiveFileLease(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

@MainActor
public final class AutomationStatusBarCoordinator {
    private let cursorImage: NSImage
    private let actions: AutomationStatusBarActions?
    private let lockURL: URL
    private let temporaryDirectory: URL
    private var lease: ExclusiveFileLease?
    private var statusBarController: AutomationStatusBarController?
    private var nextLeaseAttempt: CFTimeInterval = 0
    private var aggregatedApplications: [String] = []

    public init(
        cursorImage: NSImage,
        actions: AutomationStatusBarActions? = nil,
        temporaryDirectory: URL = macComputerUseCoordinationDirectory()
    ) {
        self.cursorImage = cursorImage
        self.actions = actions
        self.temporaryDirectory = temporaryDirectory
        lockURL = temporaryDirectory.appendingPathComponent("mac-computer-use-menubar.lock")
        acquireLeaseIfAvailable(now: CACurrentMediaTime())
    }

    deinit {
        statusBarController = nil
        lease = nil
    }

    public var isActive: Bool { statusBarController?.isActive == true }

    public var statusItemFrame: CGRect? { statusBarController?.buttonFrame }

    public func update(currentApp: String?, controlledApps: [String]) {
        let now = CACurrentMediaTime()
        acquireLeaseIfAvailable(now: now)
        guard let statusBarController else { return }

        // The service knows its sessions directly; no directory scanning.
        aggregatedApplications = Array(Set(controlledApps)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        statusBarController.update(
            currentApp: currentApp,
            controlledApps: aggregatedApplications
        )
    }

    private func acquireLeaseIfAvailable(now: CFTimeInterval) {
        guard statusBarController == nil, now >= nextLeaseAttempt else { return }
        nextLeaseAttempt = now + 0.5
        guard let lease = ExclusiveFileLease.acquire(at: lockURL) else { return }
        self.lease = lease
        statusBarController = AutomationStatusBarController(
            cursorImage: cursorImage,
            actions: actions
        )
    }
}

final class AutomationCursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct CursorPulsePresentation {
    let scale: CGFloat
    let opacity: CGFloat
}

private func smoothStep(_ progress: CGFloat) -> CGFloat {
    let t = min(max(progress, 0), 1)
    return t * t * (3 - 2 * t)
}

func cursorPulsePresentation(
    now: CFTimeInterval,
    clickStartedAt: CFTimeInterval?,
    cancelling: Bool
) -> CursorPulsePresentation {
    let breathingProgress = 0.5 + 0.5 * sin((now / 1.05) * .pi - (.pi / 2))
    let breathingScale = 0.82 + 0.30 * breathingProgress
    let breathingOpacity = 0.52 + 0.44 * breathingProgress
    let clickAge = clickStartedAt.map { now - $0 }
    let scale: CGFloat
    let opacity: CGFloat
    if let clickAge, clickAge >= 0, clickAge < 0.07 {
        let progress = smoothStep(CGFloat(clickAge / 0.07))
        scale = 1.0 - 0.24 * progress
        opacity = 1
    } else if let clickAge, clickAge < 0.23 {
        let progress = smoothStep(CGFloat((clickAge - 0.07) / 0.16))
        scale = 0.76 + 0.48 * progress
        opacity = 1
    } else if let clickAge, clickAge < 0.41 {
        let progress = smoothStep(CGFloat((clickAge - 0.23) / 0.18))
        scale = 1.24 + (breathingScale - 1.24) * progress
        opacity = 1 + (breathingOpacity - 1) * progress
    } else {
        scale = breathingScale
        opacity = breathingOpacity
    }
    return CursorPulsePresentation(
        scale: scale,
        opacity: cancelling ? 0.35 : opacity
    )
}

/// Reduce Motion: no breathing and no scale change. A click shows as a short,
/// steady brightening of the glow instead.
func reducedMotionCursorPulse(
    now: CFTimeInterval,
    clickStartedAt: CFTimeInterval?,
    cancelling: Bool
) -> CursorPulsePresentation {
    let clicked = clickStartedAt.map { now - $0 >= 0 && now - $0 < 0.3 } ?? false
    return CursorPulsePresentation(scale: 1, opacity: cancelling ? 0.35 : (clicked ? 1 : 0.8))
}

/// The cursor stays fully visible while its session acts, then fades out
/// after it has been idle for `fadeAfter` seconds, so a parked agent never
/// leaves a cursor on screen.
func cursorIdleOpacity(
    now: CFTimeInterval,
    lastActivity: CFTimeInterval,
    active: Bool,
    fadeAfter: TimeInterval = 8,
    fadeDuration: TimeInterval = 0.45
) -> CGFloat {
    if active { return 1 }
    let idle = now - lastActivity
    if idle <= fadeAfter { return 1 }
    let progress = min(max((idle - fadeAfter) / fadeDuration, 0), 1)
    return CGFloat(1 - progress * progress * (3 - 2 * progress))
}

struct CursorMotionState {
    private(set) var position: CGPoint?
    private(set) var velocity = CGVector.zero

    mutating func advance(
        toward target: CGPoint,
        deltaTime: CFTimeInterval,
        angularFrequency: CGFloat = 40
    ) -> CGPoint {
        guard target.x.isFinite, target.y.isFinite else {
            return position ?? .zero
        }
        guard let current = position else {
            position = target
            velocity = .zero
            return target
        }

        let dt = CGFloat(min(max(deltaTime, 0), 0.1))
        guard dt > 0, angularFrequency > 0 else { return current }
        let decay = exp(-angularFrequency * dt)

        func advanceAxis(position: CGFloat, velocity: CGFloat, target: CGFloat) -> (CGFloat, CGFloat) {
            let displacement = position - target
            let coefficient = velocity + angularFrequency * displacement
            let nextDisplacement = (displacement + coefficient * dt) * decay
            let nextVelocity = (velocity - angularFrequency * coefficient * dt) * decay
            return (target + nextDisplacement, nextVelocity)
        }

        let nextX = advanceAxis(position: current.x, velocity: velocity.dx, target: target.x)
        let nextY = advanceAxis(position: current.y, velocity: velocity.dy, target: target.y)
        let next = CGPoint(x: nextX.0, y: nextY.0)
        velocity = CGVector(dx: nextX.1, dy: nextY.1)

        let remaining = hypot(target.x - next.x, target.y - next.y)
        let speed = hypot(velocity.dx, velocity.dy)
        if remaining < 0.25, speed < 2 {
            position = target
            velocity = .zero
        } else {
            position = next
        }
        return position ?? target
    }

    mutating func reset() {
        position = nil
        velocity = .zero
    }
}

final class AutomationCursorView: NSView {
    var cancelling = false
    var reduceMotion = false
    var clickStartedAt: CFTimeInterval?
    /// Flight pose around the hotspot (radians, counterclockwise) and swell.
    var rotation: CGFloat = 0
    var flightScale: CGFloat = 1
    var glowColor: NSColor = .white
    var badgeSymbol: String?
    var shakeStartedAt: CFTimeInterval?
    var countdown: (start: CFTimeInterval, duration: TimeInterval)?
    private let assets: AutomationCursorAssets

    init(frame frameRect: NSRect, assets: AutomationCursorAssets) {
        self.assets = assets
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        let now = CACurrentMediaTime()
        let pulse = reduceMotion
            ? reducedMotionCursorPulse(now: now, clickStartedAt: clickStartedAt, cancelling: cancelling)
            : cursorPulsePresentation(
                now: now,
                clickStartedAt: clickStartedAt,
                cancelling: cancelling
            )
        let hotspot = CGPoint(
            x: bounds.midX + (reduceMotion ? 0 : cursorShakeOffset(now: now, startedAt: shakeStartedAt)),
            y: bounds.midY
        )
        // Follow the pointer silhouette with a breathing edge glow. Flight
        // rotation and swell pivot on the hotspot, so the tip stays exact.
        context.saveGState()
        context.translateBy(x: hotspot.x, y: hotspot.y)
        context.rotate(by: rotation)
        context.scaleBy(x: flightScale, y: flightScale)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        context.setShadow(
            offset: .zero,
            blur: 2 * pulse.scale,
            color: glowColor.withAlphaComponent(pulse.opacity).cgColor
        )
        assets.pointer.draw(
            in: cursorPointerDrawRect(in: bounds),
            from: .zero,
            operation: .sourceOver,
            fraction: cancelling ? 0.65 : 1
        )
        context.restoreGState()

        if let countdown {
            let remaining = cursorCountdownRemaining(now: now, start: countdown.start, duration: countdown.duration)
            if remaining > 0 { drawCountdown(context, around: hotspot, remaining: remaining) }
        }
        if let badgeSymbol { drawBadge(badgeSymbol, near: hotspot) }
    }

    private func drawCountdown(_ context: CGContext, around center: CGPoint, remaining: CGFloat) {
        let radius: CGFloat = 13
        context.saveGState()
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        context.strokePath()
        context.setStrokeColor(NSColor.systemOrange.cgColor)
        let start = CGFloat.pi / 2
        context.addArc(
            center: center,
            radius: radius,
            startAngle: start,
            endAngle: start - .pi * 2 * remaining,
            clockwise: true
        )
        context.strokePath()
        context.restoreGState()
    }

    private func drawBadge(_ symbol: String, near hotspot: CGPoint) {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        let diameter: CGFloat = 15
        let circle = CGRect(x: hotspot.x + 13, y: hotspot.y - 27, width: diameter, height: diameter)
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: circle).fill()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        NSBezierPath(ovalIn: circle.insetBy(dx: 0.25, dy: 0.25)).stroke()
        let configured = image.withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) ?? image
        let tinted = NSImage(size: configured.size, flipped: false) { rect in
            configured.draw(in: rect)
            accent.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        tinted.draw(in: CGRect(
            x: circle.midX - size.width / 2,
            y: circle.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }
}

func makeAutomationCursorPanel(
    size: CGFloat = 80,
    assets: AutomationCursorAssets = .emptyForTesting
) -> AutomationCursorPanel {
    let panel = AutomationCursorPanel(
        contentRect: CGRect(x: 0, y: 0, width: size, height: size),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .screenSaver
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.contentView = AutomationCursorView(
        frame: CGRect(x: 0, y: 0, width: size, height: size),
        assets: assets
    )
    return panel
}

final class OverlayView: NSView {
    var controlling = false
    var cancelling = false
    var paused = false
    var status = ""
    var hint = "Esc to cancel"


    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never intercept

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirty)

        // Status banner (top-center of primary screen)
        if controlling {
            drawBanner(ctx: ctx)
        }
    }

    private func drawBanner(ctx: CGContext) {
        let label = cancelling ? "Cancelling…" : (status.isEmpty ? "mac-computer-use is controlling your Mac" : status)
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
        let dotColor = cancelling ? NSColor.systemRed : (paused ? NSColor.systemOrange : accent)
        let dotRect = CGRect(x: rect.minX + pad, y: rect.midY - dot/2, width: dot, height: dot)
        dotColor.withAlphaComponent(0.6 + 0.4*pulse).setFill(); NSBezierPath(ovalIn: dotRect).fill()
        aLabel.draw(at: CGPoint(x: dotRect.maxX + 8, y: rect.midY - aLabel.size().height/2))
        let sepX = dotRect.maxX + 8 + lw + gap
        NSColor(white: 1, alpha: 0.18).setFill(); NSBezierPath(rect: CGRect(x: sepX, y: rect.minY+8, width: sep, height: h-16)).fill()
        aHint.draw(at: CGPoint(x: sepX + gap, y: rect.midY - aHint.size().height/2))
    }
}

// Each MCP process owns a private randomized IPC directory. A PID alone is not
// sufficient because it may be reused while a stale overlay child is still exiting.
struct OverlayIPCPaths {
    let channelID: String
    let directoryURL: URL
    let stateURL: URL
    let cancelURL: URL
    let readyURL: URL

    init(ownerPID: pid_t, nonce: UUID = UUID()) {
        channelID = nonce.uuidString.lowercased()
        let name = "mac-computer-use-overlay-\(ownerPID)-\(channelID)"
        directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        stateURL = directoryURL.appendingPathComponent("state.json")
        cancelURL = directoryURL.appendingPathComponent("cancel")
        readyURL = directoryURL.appendingPathComponent("ready.json")
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

// MCP-side bridge. A bare stdio subprocess cannot host AppKit, so the overlay
// runs in a separate LaunchServices-launched agent (same bundle, `overlay` arg).
// This bridge maintains overlay state, writes it to a file the agent renders,
// and polls a cancel file the agent writes on Esc.
final class OverlayController {
    static let shared = OverlayController()
    private let lock = NSLock()
    private let agentLaunchLock = NSLock()
    private let paths = OverlayIPCPaths(ownerPID: getpid())
    private var controlling = false, cancelling = false, status = ""
    private var currentApp: String?
    private var currentAppPID: pid_t?
    private var controlledApps = Set<String>()
    private var cursor: CGPoint? = nil                  // quartz point
    private var target: CGRect? = nil                 // quartz rect
    private var flashes: [(CGPoint, Double)] = []      // quartz points
    private var lingerUntil: Double = 0
    private var captureHide = false
    private var captureMode = false
    private var prepared = false
    private var pollerStarted = false
    private var agentLaunched = false
    private var launchStartedAt: Double?
    private var lastError: String?
    /// Set in worker mode: the service renders the overlay and owns Esc.
    private var serviceChannel: JSONLineChannel?
    private var cursorPace: CursorPace = .act
    private var lastCursorMoveAt: CFTimeInterval = 0
    private var currentWindowID: CGWindowID?

    private var usesService: Bool {
        lock.lock(); defer { lock.unlock() }
        return serviceChannel != nil
    }

    var isServiceAttached: Bool { usesService }

    /// Sends a presentation message (bubble, drawing, countdown) to the
    /// service. Returns false in-process, where there is no service overlay.
    @discardableResult
    func sendToService(_ message: [String: Any]) -> Bool {
        lock.lock(); let service = serviceChannel; lock.unlock()
        guard let service else { return false }
        return service.send(message)
    }

    func attachServiceChannel(_ channel: JSONLineChannel) {
        lock.lock(); serviceChannel = channel; lock.unlock()
    }

    func install() {
        captureMode = ProcessInfo.processInfo.environment["MACCU_CAPTURE_OVERLAY"] == "1"
    }

    func cleanup() {
        if usesService { return }
        lock.lock(); let shouldClean = prepared; lock.unlock()
        if shouldClean { paths.cleanup() }
    }
    func resetCancellation() {
        if usesService { return }
        lock.lock(); let isPrepared = prepared; lock.unlock()
        if isPrepared { try? FileManager.default.removeItem(at: paths.cancelURL) }
    }

    private func prepareIPC() -> Bool {
        lock.lock()
        if prepared { lock.unlock(); return true }
        lock.unlock()
        do {
            try paths.prepare()
        } catch {
            recordError("overlay IPC initialization failed: \(error.localizedDescription)")
            return false
        }
        lock.lock()
        prepared = true
        let shouldStartPoller = !pollerStarted
        pollerStarted = true
        lock.unlock()
        writeState()
        if shouldStartPoller {
            Thread.detachNewThread {
                while true {
                    if FileManager.default.fileExists(atPath: self.paths.cancelURL.path) {
                        cancelFlag.set(true)
                    }
                    self.lock.lock()
                    let shouldSupervise = self.agentLaunched
                    self.lock.unlock()
                    if shouldSupervise, self.readyAgentPID() == nil {
                        _ = self.ensureAgent()
                    }
                    Thread.sleep(forTimeInterval: 0.03)
                }
            }
        }
        return true
    }

    func healthSnapshot() -> [String: Any] {
        lock.lock()
        let service = serviceChannel
        lock.unlock()
        if let service {
            lock.lock()
            let snapshot: [String: Any] = [
                "transport": "service",
                "status": service.isOpen ? "running" : "error",
                "current_app": currentApp ?? NSNull(),
                "controlled_apps": controlledApps.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                },
                "cursor_initialized": cursor != nil,
                "last_error": lastError ?? NSNull(),
            ]
            lock.unlock()
            return snapshot
        }
        lock.lock()
        let launchRequested = agentLaunched
        let launchStartedAt = launchStartedAt
        let observedError = lastError
        lock.unlock()

        let stateFilePresent = FileManager.default.fileExists(atPath: paths.stateURL.path)
        let state: [String: Any]? = {
            guard let data = try? Data(contentsOf: paths.stateURL) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }()
        let stateOwnerIsCurrentProcess = state?["pid"] as? Int == Int(getpid())
        let ready: [String: Any]? = {
            guard let data = try? Data(contentsOf: paths.readyURL),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["owner_pid"] as? Int == Int(getpid()),
                  value["channel_id"] as? String == paths.channelID,
                  let agentPid = value["agent_pid"] as? Int,
                  agentPid > 0,
                  kill(pid_t(agentPid), 0) == 0 || errno == EPERM else {
                return nil
            }
            return value
        }()
        let agentPid = ready?["agent_pid"] as? Int
        let readinessError: String? = {
            guard observedError == nil,
                  launchRequested,
                  agentPid == nil,
                  let launchStartedAt,
                  ProcessInfo.processInfo.systemUptime - launchStartedAt > 2 else {
                return nil
            }
            return "overlay agent did not become ready within 2 seconds"
        }()
        let effectiveError = observedError ?? readinessError
        let status: String
        if effectiveError != nil {
            status = "error"
        } else if agentPid != nil {
            status = "running"
        } else if !launchRequested {
            status = "not_requested"
        } else {
            status = "launching"
        }

        return [
            "transport": "agent",
            "status": status,
            "launch_requested": launchRequested,
            "channel_id": paths.channelID,
            "state_file": paths.stateURL.path,
            "state_file_present": stateFilePresent,
            "state_owner_is_current_process": stateOwnerIsCurrentProcess,
            "ready_file": paths.readyURL.path,
            "ready_file_present": FileManager.default.fileExists(atPath: paths.readyURL.path),
            "agent_pid": agentPid ?? NSNull(),
            "menu_bar_item_active": managerProcessIsRunning(),
            "current_app": state?["current_app"] ?? NSNull(),
            "controlled_apps": state?["controlled_apps"] as? [String] ?? [],
            "cursor_initialized": ((state?["cursor"] as? [Double])?.count == 2),
            "last_error": effectiveError ?? NSNull(),
        ]
    }

    private func recordError(_ message: String) {
        lock.lock(); lastError = message; lock.unlock()
        log(message)
    }

    private func readyAgentPID() -> pid_t? {
        guard let data = try? Data(contentsOf: paths.readyURL),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["owner_pid"] as? Int == Int(getpid()),
              value["channel_id"] as? String == paths.channelID,
              let agentValue = value["agent_pid"] as? Int,
              agentValue > 0 else {
            return nil
        }
        let pid = pid_t(agentValue)
        guard kill(pid, 0) == 0 || errno == EPERM else { return nil }
        return pid
    }

    private func ensureAgent() -> pid_t? {
        lock.lock()
        let service = serviceChannel
        lock.unlock()
        if let service {
            guard service.isOpen else {
                recordError("the Mac Computer Use service is no longer connected")
                return nil
            }
            return getppid()
        }
        agentLaunchLock.lock()
        defer { agentLaunchLock.unlock() }
        guard prepareIPC() else { return nil }
        if let readyPID = readyAgentPID() {
            lock.lock()
            agentLaunched = true
            lastError = nil
            lock.unlock()
            return readyPID
        }

        try? FileManager.default.removeItem(at: paths.readyURL)
        lock.lock()
        agentLaunched = true
        launchStartedAt = ProcessInfo.processInfo.systemUptime
        lastError = nil
        lock.unlock()

        var launchFailure: String?
        for attempt in 1...3 {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [
                "-n", "-a", Bundle.main.bundlePath, "--args", "overlay",
                "--state-path", paths.stateURL.path,
                "--cancel-path", paths.cancelURL.path,
                "--ready-path", paths.readyURL.path,
                "--channel-id", paths.channelID,
                "--owner-pid", "\(getpid())",
            ] + (captureMode ? ["capture"] : [])
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
                let detail = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    launchFailure = nil
                    break
                }
                launchFailure = "status \(process.terminationStatus)"
                if let detail, !detail.isEmpty {
                    launchFailure? += ": \(detail)"
                }
            } catch {
                launchFailure = error.localizedDescription
            }
            if attempt < 3 { usleep(100_000) }
        }
        if let launchFailure {
            recordError("overlay launch failed after 3 attempts: \(launchFailure)")
            return nil
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 2
        repeat {
            if let readyPID = readyAgentPID() { return readyPID }
            usleep(20_000)
        } while ProcessInfo.processInfo.systemUptime < deadline
        recordError("overlay agent did not become ready within 2 seconds")
        return nil
    }

    /// The in-process overlay agent, whose windows desktop captures exclude.
    var legacyAgentProcessIdentifier: pid_t? {
        usesService ? nil : readyAgentPID()
    }

    func agentLeaseIsLive(_ pid: pid_t) -> Bool {
        lock.lock()
        let service = serviceChannel
        lock.unlock()
        if let service { return service.isOpen }
        return readyAgentPID() == pid
    }

    private func writeState() {
        lock.lock()
        let dict: [String: Any] = [
            "controlling": controlling, "cancelling": cancelling, "status": status,
            "current_app": currentApp ?? NSNull(),
            "current_app_pid": currentAppPID.map { Int($0) } ?? NSNull(),
            "controlled_apps": controlledApps.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            },
            "lingerUntil": lingerUntil, "captureHide": captureHide,
            "cursor": cursor.map { [$0.x, $0.y] } ?? [],
            "target": target.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
            "flashes": flashes.map { [$0.0.x, $0.0.y, $0.1] },
            "pid": Int(getpid()), "ts": CACurrentMediaTime(),
            "cursor_pace": cursorPace.rawValue,
            "window_id": currentWindowID.map { Int($0) } ?? NSNull(),
        ]
        let service = serviceChannel
        lock.unlock()
        if let service {
            var message = dict
            message["type"] = "state"
            service.send(message)
            return
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            try data.write(to: paths.stateURL, options: .atomic)
        } catch {
            recordError("overlay state write failed: \(error.localizedDescription)")
        }
    }

    func begin(
        status: String,
        appPID: pid_t?,
        appName: String?,
        targetQuartz: CGRect?
    ) -> pid_t? {
        if !usesService { ensureManagerIsRunning() }
        guard let agentPID = ensureAgent() else { return nil }
        let resolvedApp = appName ?? appPID.flatMap {
            NSRunningApplication(processIdentifier: $0)?.localizedName
        }
        lock.lock()
        controlling = true
        cancelling = false
        self.status = status
        if let resolvedApp,
           !resolvedApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentApp = resolvedApp
            currentAppPID = appPID
            controlledApps.insert(resolvedApp)
        }
        target = targetQuartz
        lingerUntil = 0
        if let snapshot = lastSnapshot, appPID == nil || snapshot.pid == appPID {
            currentWindowID = snapshot.windowId
        }
        lock.unlock()
        writeState()
        return agentPID
    }
    func updateControlledApplication(pid: pid_t, name: String) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        lock.lock()
        currentApp = normalized
        currentAppPID = pid
        controlledApps.insert(normalized)
        lock.unlock()
        writeState()
    }
    func end() { lock.lock(); controlling = false; lingerUntil = CACurrentMediaTime() + 0.9; lock.unlock(); writeState() }
    /// Moves the virtual cursor. With the service, waits until the cursor
    /// has landed, so the person sees where an action happens before it does.
    func moveCursorQuartz(_ p: CGPoint, pace: CursorPace = .act) {
        let wait = beginCursorMove(to: p, pace: pace)
        writeState()
        waitForCursorArrival(wait)
    }
    func flashClickQuartz(_ p: CGPoint) {
        let wait = beginCursorMove(to: p, pace: .act)
        if wait > 0 {
            writeState()
            waitForCursorArrival(wait)
        }
        lock.lock(); cursor = p; flashes.append((p, CACurrentMediaTime())); if flashes.count > 8 { flashes.removeFirst(flashes.count - 8) }; lock.unlock(); writeState()
    }

    /// Records the new target and returns how long the service's flight
    /// takes. A cursor that has faded out reappears at the target instantly.
    private func beginCursorMove(to p: CGPoint, pace: CursorPace) -> TimeInterval {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        let previous = cursor
        let recentlyVisible = now - lastCursorMoveAt < 8
        cursor = p
        cursorPace = pace
        lastCursorMoveAt = now
        guard serviceChannel != nil, recentlyVisible, let previous else { return 0 }
        return cursorFlightDuration(
            distance: hypot(p.x - previous.x, p.y - previous.y),
            pace: pace,
            multiplier: cursorPaceMultiplier()
        )
    }

    private func waitForCursorArrival(_ duration: TimeInterval) {
        guard duration > 0 else { return }
        let deadline = CACurrentMediaTime() + min(duration, 1.6)
        while CACurrentMediaTime() < deadline, !cancelFlag.value { usleep(10_000) }
    }

    /// Keeps the cursor awake while the person reads a bubble or answers.
    func touchCursor() {
        lock.lock(); lastCursorMoveAt = CACurrentMediaTime(); lock.unlock()
    }

    var cursorQuartz: CGPoint? {
        lock.lock(); defer { lock.unlock() }
        return cursor
    }
    func markCancelling() { lock.lock(); cancelling = true; lock.unlock(); writeState() }
    func hideForCapture() {
        // Service overlays are excluded from captures by window; nothing to hide.
        if captureMode || usesService { return }
        lock.lock(); captureHide = true; lock.unlock(); writeState(); usleep(120_000)
    }
    func showAfterCapture() {
        if usesService { return }
        lock.lock(); captureHide = false; lock.unlock(); writeState()
    }
}

// Run a controlling action with overlay + cancellation scaffolding.
func controlled(
    _ status: String,
    appPID: pid_t? = nil,
    appName: String? = nil,
    targetQuartz: CGRect? = nil,
    _ body: () -> [String: Any]
) -> [String: Any] {
    if let refusal = actionGate?() { return refusal }
    cancelFlag.set(false)
    OverlayController.shared.resetCancellation()
    if let pid = appPID, appName != "Desktop", let busy = yieldToUser(targetPID: pid, appName: appName) {
        return busy
    }
    guard let agentPID = OverlayController.shared.begin(
        status: status,
        appPID: appPID,
        appName: appName,
        targetQuartz: targetQuartz
    ) else {
        return toolText("Automation overlay agent is unavailable; action was not delivered.", isError: true)
    }

    let actionComplete = Flag()
    let leaseFailed = Flag()
    Thread.detachNewThread {
        while !actionComplete.value {
            if !OverlayController.shared.agentLeaseIsLive(agentPID) {
                leaseFailed.set(true)
                cancelFlag.set(true)
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    let result = body()
    actionComplete.set(true)
    let leaseStillLive = OverlayController.shared.agentLeaseIsLive(agentPID)
    OverlayController.shared.end()
    if leaseFailed.value || !leaseStillLive {
        return toolText(
            "Automation overlay agent exited during the action; input delivery was stopped.",
            isError: true
        )
    }
    if cancelFlag.value {
        // Esc is a human brake, not a soft result the agent can talk past.
        return userInterruptedResult(actionReport: toolResultText(result))
    }
    if result["isError"] as? Bool == true {
        OverlayController.shared.sendToService(["type": "cursor_feedback", "kind": "error"])
    }
    return result
}

func toolResultText(_ result: [String: Any]) -> String? {
    let parts = (result["content"] as? [[String: Any]] ?? []).compactMap { item -> String? in
        item["type"] as? String == "text" ? item["text"] as? String : nil
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
}

// MARK: - Overlay agent (separate LaunchServices-launched GUI process)
func runOverlayAgent(
    capture: Bool,
    statePath: String,
    cancelPath: String,
    readyPath: String,
    channelID: String,
    ownerPID: pid_t
) -> Never {
    let channelDirectory = URL(fileURLWithPath: statePath).deletingLastPathComponent()
    guard kill(ownerPID, 0) == 0 || errno == EPERM else {
        try? FileManager.default.removeItem(at: channelDirectory)
        exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard let cursorAssets = AutomationCursorAssets.load() else {
        log("virtual cursor runtime assets are missing or invalid")
        try? FileManager.default.removeItem(at: channelDirectory)
        exit(2)
    }
    let frame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false; window.backgroundColor = .clear; window.level = .screenSaver
    window.ignoresMouseEvents = true; window.hasShadow = false
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    window.sharingType = capture ? .readOnly : .none
    let view = OverlayView(frame: CGRect(origin: .zero, size: frame.size))
    window.contentView = view
    let cursorPanel = makeAutomationCursorPanel(assets: cursorAssets)
    cursorPanel.sharingType = capture ? .readOnly : .none
    guard let cursorView = cursorPanel.contentView as? AutomationCursorView else {
        log("automation cursor panel has an invalid content view")
        exit(2)
    }

    let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { ev in
        // A desktop_press_key Escape is an intentional global action. Only a
        // physical Escape should cancel the currently running automation.
        if ev.keyCode == 53,
           ev.cgEvent?.getIntegerValueField(.eventSourceUserData) != desktopSyntheticEventUserData {
            FileManager.default.createFile(atPath: cancelPath, contents: nil)
        }
    }

    let screenObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification,
        object: nil,
        queue: .main
    ) { _ in
        let updatedFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        window.setFrame(updatedFrame, display: window.isVisible)
        view.frame = CGRect(origin: .zero, size: updatedFrame.size)
    }

    func terminateOverlayAgent() {
        try? FileManager.default.removeItem(at: channelDirectory)
        NSApp.terminate(nil)
    }

    var missingReads = 0
    var cursorMotion = CursorMotionState()
    var lastCursorFrameTime = CACurrentMediaTime()
    var lastObservedFlashTimestamp: Double?
    var pendingClick: (point: CGPoint, observedAt: CFTimeInterval)?
    Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { _ in
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let st = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            missingReads += 1
            if missingReads > 60 { terminateOverlayAgent() }   // state file gone ~1s -> MCP exited
            return
        }
        missingReads = 0
        guard st["pid"] as? Int == Int(ownerPID), kill(ownerPID, 0) == 0 || errno == EPERM else {
            terminateOverlayAgent()
            return
        }
        let now = CACurrentMediaTime()
        let controlling = st["controlling"] as? Bool ?? false
        let linger = st["lingerUntil"] as? Double ?? 0
        let captureHide = st["captureHide"] as? Bool ?? false
        view.cancelling = st["cancelling"] as? Bool ?? false
        view.status = st["status"] as? String ?? ""
        var cursorPoint: CGPoint?
        if let c = st["cursor"] as? [Double], c.count == 2 {
            cursorPoint = quartzPointToCocoa(CGPoint(x: c[0], y: c[1]))
        }
        let frameDelta = now - lastCursorFrameTime
        lastCursorFrameTime = now
        let displayedCursorPoint: CGPoint?
        if let cursorPoint {
            displayedCursorPoint = cursorMotion.advance(
                toward: cursorPoint,
                deltaTime: frameDelta
            )
        } else {
            cursorMotion.reset()
            displayedCursorPoint = nil
        }
        let flashes = st["flashes"] as? [[Double]] ?? []
        if let latestFlash = flashes.last, latestFlash.count == 3 {
            let timestamp = latestFlash[2]
            if timestamp != lastObservedFlashTimestamp {
                lastObservedFlashTimestamp = timestamp
                if timestamp <= now, now - timestamp < 0.75 {
                    pendingClick = (
                        quartzPointToCocoa(CGPoint(x: latestFlash[0], y: latestFlash[1])),
                        now
                    )
                }
            }
        }
        if let click = pendingClick, let displayedCursorPoint {
            let distance = hypot(
                click.point.x - displayedCursorPoint.x,
                click.point.y - displayedCursorPoint.y
            )
            if distance < 12 || now - click.observedAt >= 0.2 {
                cursorView.clickStartedAt = now
                pendingClick = nil
            }
        }
        let presentation = overlayPresentation(
            controlling: controlling,
            lingerUntil: linger,
            now: now,
            captureHidden: captureHide,
            hasCursor: cursorPoint != nil
        )
        view.controlling = presentation.showTransientOverlay
        if presentation.showTransientOverlay {
            if !window.isVisible { window.orderFrontRegardless() }
            view.needsDisplay = true
        } else if window.isVisible {
            window.orderOut(nil)
        }
        if presentation.showCursor, let displayedCursorPoint {
            cursorView.cancelling = view.cancelling
            cursorPanel.setFrameOrigin(
                CGPoint(
                    x: displayedCursorPoint.x - cursorPanel.frame.width / 2,
                    y: displayedCursorPoint.y - cursorPanel.frame.height / 2
                )
            )
            if !cursorPanel.isVisible { cursorPanel.orderFrontRegardless() }
            cursorView.needsDisplay = true
        } else if cursorPanel.isVisible {
            cursorPanel.orderOut(nil)
        }
    }
    let ready: [String: Any] = [
        "owner_pid": Int(ownerPID),
        "agent_pid": Int(getpid()),
        "channel_id": channelID,
        "menu_bar_item": managerProcessIsRunning(),
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: ready)
        try data.write(to: URL(fileURLWithPath: readyPath), options: .atomic)
    } catch {
        log("overlay ready marker failed: \(error.localizedDescription)")
        try? FileManager.default.removeItem(at: channelDirectory)
        exit(2)
    }
    log("overlay agent running (capture=\(capture), channel=\(channelID))")
    app.run()
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    NotificationCenter.default.removeObserver(screenObserver)
    try? FileManager.default.removeItem(at: channelDirectory)
    exit(0)
}
