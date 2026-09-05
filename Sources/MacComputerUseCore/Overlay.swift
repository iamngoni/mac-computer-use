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
    controlledApps: [String]
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
    let accessibilityLabel: String
    let statusTitle: String
    switch apps.count {
    case 0:
        accessibilityLabel = "Mac Computer Use active"
        statusTitle = "Active"
    case 1:
        accessibilityLabel = "Mac Computer Use active: \(apps[0])"
        statusTitle = "Active · \(apps[0])"
    default:
        accessibilityLabel = "Mac Computer Use active: \(apps.count) apps"
        statusTitle = "Active · \(apps.count) apps"
    }
    return MenuBarPresentation(
        buttonTitle: apps.isEmpty ? "" : "\(apps.count)",
        accessibilityLabel: accessibilityLabel,
        statusTitle: statusTitle,
        controlledAppTitles: apps
    )
}

public struct AutomationCursorAssets {
    public static let canvasSize = CGSize(width: 36, height: 36)
    public static let pointerHotspot = CGPoint(x: 12, y: 7)

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

    public init(
        version: String,
        setup: @escaping () -> Void,
        showPermissions: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void,
        canCheckForUpdates: @escaping () -> Bool,
        quit: @escaping () -> Void
    ) {
        self.version = version
        self.setup = setup
        self.showPermissions = showPermissions
        self.checkForUpdates = checkForUpdates
        self.canCheckForUpdates = canCheckForUpdates
        self.quit = quit
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

    func update(
        currentApp: String?,
        controlledApps: [String]
    ) {
        let presentation = menuBarPresentation(
            currentApp: currentApp,
            controlledApps: controlledApps
        )
        let signature = ([
            presentation.accessibilityLabel,
            presentation.statusTitle,
            actions?.canCheckForUpdates() == true ? "updates-enabled" : "updates-disabled",
        ] + presentation.controlledAppTitles).joined(separator: "\u{1f}")
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
                title: "No app controlled yet",
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
    @objc private func openPermissions() { actions?.showPermissions() }
    @objc private func checkForUpdates() { actions?.checkForUpdates() }
    @objc private func quitManager() { actions?.quit() }
}

private let overlayIPCDirectoryPrefix = "mac-computer-use-overlay-"

public func overlayProcessIsAlive(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    errno = 0
    return kill(pid, 0) == 0 || errno == EPERM
}

public func activeOverlayControlledApps(
    in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    processIsAlive: (pid_t) -> Bool = overlayProcessIsAlive
) -> [String] {
    guard let directories = try? FileManager.default.contentsOfDirectory(
        at: temporaryDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var applications = Set<String>()
    for directory in directories where directory.lastPathComponent.hasPrefix(overlayIPCDirectoryPrefix) {
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let readyData = try? Data(contentsOf: directory.appendingPathComponent("ready.json")),
              let stateData = try? Data(contentsOf: directory.appendingPathComponent("state.json")),
              let ready = try? JSONSerialization.jsonObject(with: readyData) as? [String: Any],
              let state = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any],
              let ownerPID = ready["owner_pid"] as? Int,
              let agentPID = ready["agent_pid"] as? Int,
              let channelID = ready["channel_id"] as? String,
              state["pid"] as? Int == ownerPID,
              directory.lastPathComponent == "\(overlayIPCDirectoryPrefix)\(ownerPID)-\(channelID)",
              processIsAlive(pid_t(ownerPID)),
              processIsAlive(pid_t(agentPID)) else {
            continue
        }
        for app in state["controlled_apps"] as? [String] ?? [] {
            let normalized = app.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { applications.insert(normalized) }
        }
        if let current = state["current_app"] as? String {
            let normalized = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty { applications.insert(normalized) }
        }
    }
    return applications.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
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
    private var nextApplicationRefresh: CFTimeInterval = 0
    private var aggregatedApplications: [String] = []

    public init(
        cursorImage: NSImage,
        actions: AutomationStatusBarActions? = nil,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
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

    public func update(currentApp: String?, controlledApps: [String]) {
        let now = CACurrentMediaTime()
        acquireLeaseIfAvailable(now: now)
        guard let statusBarController else { return }

        if now >= nextApplicationRefresh {
            aggregatedApplications = Array(Set(
                activeOverlayControlledApps(in: temporaryDirectory) + controlledApps
            )).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            nextApplicationRefresh = now + 0.25
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
        nextApplicationRefresh = 0
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
    var clickStartedAt: CFTimeInterval?
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
        let pulse = cursorPulsePresentation(
            now: now,
            clickStartedAt: clickStartedAt,
            cancelling: cancelling
        )
        assets.pulse.draw(
            in: cursorPulseDrawRect(in: bounds, scale: pulse.scale),
            from: .zero,
            operation: .sourceOver,
            fraction: pulse.opacity
        )
        assets.pointer.draw(
            in: cursorPointerDrawRect(in: bounds),
            from: .zero,
            operation: .sourceOver,
            fraction: cancelling ? 0.65 : 1
        )
    }
}

func makeAutomationCursorPanel(
    size: CGFloat = 72,
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
    var status = ""
    var target: CGRect? = nil            // window-local


    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never intercept

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirty)

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

    func install() {
        captureMode = ProcessInfo.processInfo.environment["MACCU_CAPTURE_OVERLAY"] == "1"
    }

    func cleanup() {
        lock.lock(); let shouldClean = prepared; lock.unlock()
        if shouldClean { paths.cleanup() }
    }
    func resetCancellation() {
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

    func agentLeaseIsLive(_ pid: pid_t) -> Bool {
        readyAgentPID() == pid
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
        ]
        lock.unlock()
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
        ensureManagerIsRunning()
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
    func moveCursorQuartz(_ p: CGPoint) {
        lock.lock(); cursor = p; lock.unlock(); writeState()
    }
    func flashClickQuartz(_ p: CGPoint) {
        lock.lock(); cursor = p; flashes.append((p, CACurrentMediaTime())); if flashes.count > 8 { flashes.removeFirst(flashes.count - 8) }; lock.unlock(); writeState()
    }
    func markCancelling() { lock.lock(); cancelling = true; lock.unlock(); writeState() }
    func hideForCapture() {
        if captureMode { return }
        lock.lock(); captureHide = true; lock.unlock(); writeState(); usleep(120_000)
    }
    func showAfterCapture() { lock.lock(); captureHide = false; lock.unlock(); writeState() }
}

// Run a controlling action with overlay + cancellation scaffolding.
func controlled(
    _ status: String,
    appPID: pid_t? = nil,
    appName: String? = nil,
    targetQuartz: CGRect? = nil,
    _ body: () -> [String: Any]
) -> [String: Any] {
    cancelFlag.set(false)
    OverlayController.shared.resetCancellation()
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
    return result
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
    func toLocalR(_ r: CGRect) -> CGRect { CGRect(x: r.minX - window.frame.minX, y: r.minY - window.frame.minY, width: r.width, height: r.height) }

    let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { ev in
        if ev.keyCode == 53 { FileManager.default.createFile(atPath: cancelPath, contents: nil) }
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
        if let t = st["target"] as? [Double], t.count == 4 {
            view.target = toLocalR(
                quartzRectToCocoa(
                    CGRect(x: t[0], y: t[1], width: t[2], height: t[3])
                )
            )
        } else {
            view.target = nil
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
