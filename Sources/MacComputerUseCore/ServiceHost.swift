// The Mac Computer Use service: the LaunchServices-launched app that owns the
// macOS permissions. Relays connect over a private Unix socket; each accepted
// connection runs in its own worker process (a child of this app, so macOS
// attributes its Accessibility and Screen Recording use to MacComputerUse.app).
// The service renders every session's overlay itself, so quitting the app
// removes every cursor at once.
import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import QuartzCore

// MARK: - Approved clients

public struct ApprovedServiceClient: Codable, Equatable {
    public let key: String
    public let displayName: String
    public let detail: String
    public let approvedAt: Date
}

/// Clients the user has allowed to drive the Mac through the service.
public final class ClientApprovalStore {
    private let defaults: UserDefaults
    private let defaultsKey = "approvedServiceClients"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var clients: [ApprovedServiceClient] {
        guard let data = defaults.data(forKey: defaultsKey),
              let clients = try? JSONDecoder().decode([ApprovedServiceClient].self, from: data) else {
            return []
        }
        return clients
    }

    public func isApproved(_ key: String) -> Bool {
        clients.contains { $0.key == key }
    }

    public func approve(_ identity: ServiceClientIdentity, at date: Date = Date()) {
        var current = clients.filter { $0.key != identity.key }
        current.append(ApprovedServiceClient(
            key: identity.key,
            displayName: identity.displayName,
            detail: identity.detail,
            approvedAt: date
        ))
        save(current)
    }

    public func revoke(_ key: String) {
        save(clients.filter { $0.key != key })
    }

    private func save(_ clients: [ApprovedServiceClient]) {
        if let data = try? JSONEncoder().encode(clients) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

// MARK: - Sessions

public struct ServiceSessionSummary: Equatable {
    public let id: String
    public let clientName: String
    public let clientKey: String
    public let reportedClientName: String?
    public let approval: String
    public let busy: Bool
    public let currentApp: String?
    public let active: Bool
}

final class ServiceSession {
    let id: String
    let workerPID: pid_t
    let client: ServiceClientIdentity
    let reportedClientName: String?
    let control: JSONLineChannel
    var approval = "pending"
    var busy = false
    var currentApp: String?
    var controlling = false
    var lingerUntil: CFTimeInterval = 0

    init(
        id: String,
        workerPID: pid_t,
        client: ServiceClientIdentity,
        reportedClientName: String?,
        control: JSONLineChannel
    ) {
        self.id = id
        self.workerPID = workerPID
        self.client = client
        self.reportedClientName = reportedClientName
        self.control = control
    }

    func isActive(now: CFTimeInterval) -> Bool {
        controlling || now < lingerUntil
    }
}

// MARK: - Overlay presenter

/// Renders the cursor of every session and the shared action banner. Its
/// timer runs only while something is visible or moving.
@MainActor
final class ServiceOverlayPresenter {
    private struct SessionCursor {
        let panel: AutomationCursorPanel
        let view: AutomationCursorView
        var motion = CursorMotionState()
        var state: [String: Any] = [:]
        var target: CGPoint?
        var lastActivity: CFTimeInterval = 0
        var lastFlashTimestamp: Double?
        var pendingClick: (point: CGPoint, observedAt: CFTimeInterval)?
        var lastFrameTime = CACurrentMediaTime()
    }

    private let assets: AutomationCursorAssets
    private let captureVisible: Bool
    private let bannerWindow: NSWindow
    private let bannerView: OverlayView
    private var cursors: [String: SessionCursor] = [:]
    private var timer: Timer?
    private var pausedBannerUntil: CFTimeInterval = 0
    private var paused = false
    private var screenObserver: NSObjectProtocol?
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
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    var hasVisibleCursor: Bool {
        cursors.values.contains { $0.panel.isVisible && $0.panel.alphaValue > 0.01 }
    }

    var windowIDs: [CGWindowID] {
        var identifiers = [CGWindowID(bannerWindow.windowNumber)]
        identifiers += cursors.values.map { CGWindowID($0.panel.windowNumber) }
        return identifiers.filter { $0 > 0 }
    }

    func update(sessionID: String, state: [String: Any]) {
        var cursor = cursors[sessionID] ?? makeCursor()
        let now = CACurrentMediaTime()
        let previous = cursor.state
        cursor.state = state
        if let point = state["cursor"] as? [Double], point.count == 2 {
            let target = quartzPointToCocoa(CGPoint(x: point[0], y: point[1]))
            if cursor.target != target { cursor.lastActivity = now }
            cursor.target = target
        }
        let controlling = state["controlling"] as? Bool ?? false
        if controlling || (previous["status"] as? String) != (state["status"] as? String) {
            cursor.lastActivity = now
        }
        if let flash = (state["flashes"] as? [[Double]])?.last, flash.count == 3,
           flash[2] != cursor.lastFlashTimestamp {
            cursor.lastFlashTimestamp = flash[2]
            if flash[2] <= now, now - flash[2] < 0.75 {
                cursor.pendingClick = (quartzPointToCocoa(CGPoint(x: flash[0], y: flash[1])), now)
                cursor.lastActivity = now
            }
        }
        let isNew = cursors[sessionID] == nil
        cursors[sessionID] = cursor
        if isNew { onWindowsChanged?(windowIDs) }
        ensureTimer()
    }

    func removeSession(_ sessionID: String) {
        guard let cursor = cursors.removeValue(forKey: sessionID) else { return }
        cursor.panel.orderOut(nil)
        cursor.panel.close()
        onWindowsChanged?(windowIDs)
        ensureTimer()
    }

    func removeAll() {
        for id in Array(cursors.keys) { removeSession(id) }
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
    }

    private func ensureTimer() {
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

        for (id, var cursor) in cursors {
            let controlling = cursor.state["controlling"] as? Bool ?? false
            let lingerUntil = cursor.state["lingerUntil"] as? Double ?? 0
            let active = controlling || now < lingerUntil
            if active {
                cursor.lastActivity = max(cursor.lastActivity, now)
                if bannerSession == nil || controlling { bannerSession = cursor }
            }
            let delta = now - cursor.lastFrameTime
            cursor.lastFrameTime = now
            var displayed: CGPoint?
            if let target = cursor.target {
                displayed = reduceMotion
                    ? target
                    : cursor.motion.advance(toward: target, deltaTime: delta)
                if reduceMotion { cursor.motion.reset() }
            }
            if let click = cursor.pendingClick, let displayed {
                let distance = hypot(click.point.x - displayed.x, click.point.y - displayed.y)
                if reduceMotion || distance < 12 || now - click.observedAt >= 0.2 {
                    cursor.view.clickStartedAt = now
                    cursor.pendingClick = nil
                }
            }
            let opacity = cursorIdleOpacity(
                now: now,
                lastActivity: cursor.lastActivity,
                active: active,
                fadeAfter: fadeAfter
            )
            if let displayed, opacity > 0.001 {
                cursor.view.reduceMotion = reduceMotion
                cursor.view.cancelling = cursor.state["cancelling"] as? Bool ?? false
                cursor.panel.setFrameOrigin(CGPoint(
                    x: displayed.x - cursor.panel.frame.width / 2,
                    y: displayed.y - cursor.panel.frame.height / 2
                ))
                cursor.panel.alphaValue = opacity
                if !cursor.panel.isVisible {
                    cursor.panel.orderFrontRegardless()
                    onWindowsChanged?(windowIDs)
                }
                cursor.view.needsDisplay = true
                needsFrames = true
            } else if cursor.panel.isVisible {
                cursor.panel.alphaValue = 0
                cursor.panel.orderOut(nil)
            }
            cursors[id] = cursor
        }

        let showPausedBanner = paused && now < pausedBannerUntil
        if let bannerSession, !showPausedBanner {
            bannerView.controlling = true
            bannerView.paused = false
            bannerView.cancelling = bannerSession.state["cancelling"] as? Bool ?? false
            bannerView.status = bannerSession.state["status"] as? String ?? ""
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
                onWindowsChanged?(windowIDs)
            }
            bannerView.needsDisplay = true
            needsFrames = true
        } else if bannerWindow.isVisible {
            bannerWindow.orderOut(nil)
        }

        if !needsFrames {
            timer?.invalidate()
            timer = nil
        }
    }
}

// MARK: - Service host

@MainActor
public final class ServiceHost {
    private let executablePath: String
    private let environment: [String: String]
    private let approvals: ClientApprovalStore
    private let presenter: ServiceOverlayPresenter?
    private var listenDescriptor: Int32 = -1
    private var sessions: [String: ServiceSession] = [:]
    private var acceptingConnections = false
    private var deniedThisRun = Set<String>()
    private var promptQueue: [ServiceClientIdentity] = []
    private var isPrompting = false
    private var keyMonitors: [Any] = []
    private var refreshScheduled = false
    public private(set) var isPaused = false
    public var onChange: (() -> Void)?
    public private(set) var lastError: String?

    public init(
        executableURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        approvals: ClientApprovalStore = ClientApprovalStore()
    ) {
        executablePath = executableURL.path
        self.environment = environment
        self.approvals = approvals
        if let assets = AutomationCursorAssets.load() {
            presenter = ServiceOverlayPresenter(
                assets: assets,
                captureVisible: environment["MACCU_CAPTURE_OVERLAY"] == "1"
            )
        } else {
            presenter = nil
            log("virtual cursor runtime assets are missing; the service will run without an overlay")
        }
        presenter?.onWindowsChanged = { [weak self] identifiers in
            self?.broadcast(["type": "overlay_windows", "ids": identifiers.map { Int($0) }])
        }
    }

    // MARK: Lifecycle

    public func start() throws {
        try MacComputerUseRuntime.prepareDirectory(environment: environment)
        let socketPath = MacComputerUseRuntime.socketURL(environment: environment).path
        listenDescriptor = try listenUnixSocket(path: socketPath)
        acceptingConnections = true
        let descriptor = listenDescriptor
        let thread = Thread { [weak self] in
            while true {
                let connection = accept(descriptor, nil, nil)
                if connection < 0 {
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    return // the listener was closed
                }
                _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.handshake(connection)
                }
            }
        }
        thread.name = "mac-computer-use.service.accept"
        thread.start()
        installEscapeMonitor()
        log("mac-computer-use \(macComputerUseVersion()) service listening at \(socketPath)")
    }

    /// Stops every session and removes every overlay. `userInitiated` records
    /// that the user quit, so relays do not relaunch the service on their own.
    public func shutdown(userInitiated: Bool) {
        if userInitiated { MacComputerUseRuntime.markStoppedByUser(environment: environment) }
        acceptingConnections = false
        if listenDescriptor >= 0 {
            shutdownSocket(listenDescriptor)
            close(listenDescriptor)
            listenDescriptor = -1
            unlink(MacComputerUseRuntime.socketURL(environment: environment).path)
        }
        for session in sessions.values {
            session.control.close()
            kill(session.workerPID, SIGTERM)
        }
        sessions.removeAll()
        presenter?.removeAll()
        for monitor in keyMonitors { NSEvent.removeMonitor(monitor) }
        keyMonitors.removeAll()
        notifyChange()
    }

    private nonisolated func shutdownSocket(_ descriptor: Int32) {
        Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    // MARK: Status

    public var hasBusySession: Bool { sessions.values.contains { $0.busy } }

    public var sessionSummaries: [ServiceSessionSummary] {
        let now = CACurrentMediaTime()
        return sessions.values.map {
            ServiceSessionSummary(
                id: $0.id,
                clientName: $0.client.displayName,
                clientKey: $0.client.key,
                reportedClientName: $0.reportedClientName,
                approval: $0.approval,
                busy: $0.busy,
                currentApp: $0.currentApp,
                active: $0.isActive(now: now)
            )
        }.sorted { $0.id < $1.id }
    }

    /// Apps that a session is acting on right now (or lingered on moments ago).
    public var activeControlledApps: [String] {
        let now = CACurrentMediaTime()
        let names = sessions.values.filter { $0.isActive(now: now) }.compactMap(\.currentApp)
        return Array(Set(names)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    public var approvedClients: [ApprovedServiceClient] { approvals.clients }

    public func revokeClient(_ key: String) {
        approvals.revoke(key)
        for session in sessions.values where session.client.key == key {
            session.approval = "pending"
            session.control.send(["type": "approval", "state": "pending"])
        }
        notifyChange()
    }

    public func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        broadcast(["type": "pause", "paused": paused])
        presenter?.setPaused(paused)
        notifyChange()
    }

    // MARK: Connections

    private nonisolated func handshake(_ connection: Int32) {
        guard socketPeerIsCurrentUser(connection),
              let peer = socketPeerProcessIdentifier(connection) else {
            close(connection)
            return
        }
        let reader = LineReader(descriptor: connection)
        guard let line = reader.readLine(timeout: 10),
              let hello = decodeJSONLine(line),
              hello["maccu_relay"] as? Int == 1 else {
            close(connection)
            return
        }
        let identity = identifyServiceClient(peerProcess: peer)
        let reportedName = (hello["client_info"] as? [String: Any])?["name"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.admit(connection, identity: identity, reportedClientName: reportedName)
            }
        }
    }

    private func admit(_ connection: Int32, identity: ServiceClientIdentity, reportedClientName: String?) {
        func refuse(_ message: String) {
            writeAll(connection, encodeJSONLine(["maccu_service": 1, "accepted": false, "error": message]))
            close(connection)
        }
        guard acceptingConnections else {
            refuse("Mac Computer Use is shutting down. Retry in a few seconds.")
            return
        }
        guard !macComputerUseUpdateInProgress(environment: environment) else {
            refuse("Mac Computer Use is installing an update. Retry in a few seconds.")
            return
        }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            refuse("Mac Computer Use could not create a session channel.")
            return
        }
        _ = fcntl(pair[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(pair[1], F_SETFD, FD_CLOEXEC)
        let sessionID = UUID().uuidString.lowercased()
        guard let workerPID = spawnWorker(connection: connection, control: pair[1], sessionID: sessionID) else {
            close(pair[0]); close(pair[1])
            refuse("Mac Computer Use could not start a session worker.")
            return
        }
        close(pair[1])
        writeAll(connection, encodeJSONLine(["maccu_service": 1, "accepted": true, "session": sessionID]))
        close(connection)

        let control = JSONLineChannel(descriptor: pair[0])
        let session = ServiceSession(
            id: sessionID,
            workerPID: workerPID,
            client: identity,
            reportedClientName: reportedClientName,
            control: control
        )
        session.approval = approvalState(for: identity)
        sessions[sessionID] = session
        control.startReading(
            onMessage: { [weak self] message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(message, from: sessionID) }
                }
            },
            onClose: { [weak self] in
                var status: Int32 = 0
                waitpid(workerPID, &status, 0)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.end(sessionID) }
                }
            }
        )
        control.send([
            "type": "session",
            "session_id": sessionID,
            "approval": session.approval,
            "client": [
                "name": identity.displayName,
                "key": identity.key,
                "detail": identity.detail,
                "path": identity.path,
                "reported_name": (reportedClientName as Any?) ?? NSNull(),
            ] as [String: Any],
        ])
        if let presenter {
            control.send(["type": "overlay_windows", "ids": presenter.windowIDs.map { Int($0) }])
        }
        if isPaused { control.send(["type": "pause", "paused": true]) }
        log("session \(sessionID) started for \(identity.displayName) [\(identity.key)] worker \(workerPID)")
        notifyChange()
    }

    private func approvalState(for identity: ServiceClientIdentity) -> String {
        if MacComputerUseRuntime.isOverridden(environment: environment),
           environment["MACCU_TEST_AUTO_APPROVE"] == "1" {
            return "approved"
        }
        if approvals.isApproved(identity.key) { return "approved" }
        if deniedThisRun.contains(identity.key) { return "denied" }
        return "pending"
    }

    private func spawnWorker(connection: Int32, control: Int32, sessionID: String) -> pid_t? {
        let logURL = MacComputerUseRuntime.workerLogURL()
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, connection, 0)
        posix_spawn_file_actions_adddup2(&actions, connection, 1)
        posix_spawn_file_actions_adddup2(&actions, control, workerControlDescriptor)
        posix_spawn_file_actions_addopen(&actions, 2, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        )
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGPIPE)
        sigaddset(&defaults, SIGTERM)
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        var workerEnvironment = environment
        workerEnvironment["MACCU_SESSION_ID"] = sessionID
        let arguments = [executablePath, "worker", "--session", sessionID]
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = workerEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executablePath, &actions, &attributes, argv, envp)
        guard result == 0 else {
            lastError = "worker spawn failed: \(String(cString: strerror(result)))"
            log(lastError ?? "")
            return nil
        }
        return pid
    }

    private func end(_ sessionID: String) {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        presenter?.removeSession(sessionID)
        log("session \(sessionID) ended for \(session.client.displayName)")
        notifyChange()
    }

    private func handle(_ message: [String: Any], from sessionID: String) {
        guard let session = sessions[sessionID] else { return }
        switch message["type"] as? String {
        case "state":
            session.controlling = message["controlling"] as? Bool ?? false
            session.lingerUntil = message["lingerUntil"] as? Double ?? 0
            if let app = message["current_app"] as? String, !app.isEmpty { session.currentApp = app }
            presenter?.update(sessionID: sessionID, state: message)
            notifyChange()
            scheduleRefresh(at: session.lingerUntil)
        case "busy":
            session.busy = message["busy"] as? Bool ?? false
            notifyChange()
        case "approval_request":
            requestApproval(for: session)
        default:
            break
        }
    }

    // MARK: Approval

    private func requestApproval(for session: ServiceSession) {
        let state = approvalState(for: session.client)
        guard state == "pending" else {
            session.approval = state
            session.control.send(["type": "approval", "state": state])
            return
        }
        if !promptQueue.contains(where: { $0.key == session.client.key }) {
            promptQueue.append(session.client)
        }
        presentNextPrompt()
    }

    private func presentNextPrompt() {
        guard !isPrompting, !promptQueue.isEmpty else { return }
        isPrompting = true
        let identity = promptQueue.removeFirst()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let allowed = self.askUserToApprove(identity)
                self.decide(identity, allowed: allowed)
                self.isPrompting = false
                self.presentNextPrompt()
            }
        }
    }

    private func askUserToApprove(_ identity: ServiceClientIdentity) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow “\(identity.displayName)” to control your Mac?"
        alert.informativeText = """
        \(identity.displayName) wants to use Mac Computer Use to see and operate apps on this Mac, using the Accessibility and Screen Recording access you gave Mac Computer Use.

        Identified as: \(identity.detail)

        You can remove this later in Mac Computer Use Setup.
        """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func decide(_ identity: ServiceClientIdentity, allowed: Bool) {
        if allowed {
            approvals.approve(identity)
            deniedThisRun.remove(identity.key)
        } else {
            deniedThisRun.insert(identity.key)
        }
        let state = allowed ? "approved" : "denied"
        for session in sessions.values where session.client.key == identity.key {
            session.approval = state
            session.control.send(["type": "approval", "state": state])
        }
        notifyChange()
    }

    // MARK: Esc

    /// A physical Esc while any agent cursor is on screen pauses every
    /// session. Synthetic desktop Escape events are ignored.
    private func installEscapeMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == 53,
                  event.cgEvent?.getIntegerValueField(.eventSourceUserData) != desktopSyntheticEventUserData else {
                return
            }
            MainActor.assumeIsolated { self?.escapePressed() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) {
            keyMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            handler(event)
            return event
        }) {
            keyMonitors.append(local)
        }
    }

    private func escapePressed() {
        let now = CACurrentMediaTime()
        let agentVisible = presenter?.hasVisibleCursor == true
            || sessions.values.contains { $0.isActive(now: now) }
        guard agentVisible else { return }
        broadcast(["type": "cancel"])
        setPaused(true)
    }

    // MARK: Helpers

    private func broadcast(_ message: [String: Any]) {
        for session in sessions.values { session.control.send(message) }
    }

    private func notifyChange() {
        onChange?()
    }

    /// Refreshes status once a session's linger period has ended.
    private func scheduleRefresh(at time: CFTimeInterval) {
        let delay = time - CACurrentMediaTime()
        guard delay > 0, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.notifyChange()
            }
        }
    }
}
