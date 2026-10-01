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

// MARK: - Service host

/// A question, pick or hand-off waiting on the person.
@MainActor
final class ActiveInteraction {
    let sessionID: String
    let requestID: Int
    let windowIDs: () -> [CGWindowID]
    let dismiss: () -> Void
    var timer: Timer?

    init(sessionID: String, requestID: Int, windowIDs: @escaping () -> [CGWindowID], dismiss: @escaping () -> Void) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.windowIDs = windowIDs
        self.dismiss = dismiss
    }
}

func primaryScreenCenterQuartz() -> CGPoint {
    let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
    return CGPoint(x: frame.midX, y: primaryScreen().frame.height - frame.midY)
}

/// Plays a saved tour step by step with the service's own cursor.
@MainActor
final class TourPlayback {
    static let sessionID = "tour"
    private let tour: TourFile
    private let pid: pid_t
    private weak var presenter: ServiceOverlayPresenter?
    private let onFinish: () -> Void
    private var watch: HandoffWatch?
    private var index = 0
    private var finished = false

    init(tour: TourFile, pid: pid_t, presenter: ServiceOverlayPresenter, onFinish: @escaping () -> Void) {
        self.tour = tour
        self.pid = pid
        self.presenter = presenter
        self.onFinish = onFinish
    }

    func start() { runStep() }

    func cancel() {
        guard !finished else { return }
        watch?.stop()
        presenter?.showBubble(sessionID: Self.sessionID, text: "Tour stopped", style: .tag, holdSeconds: 1)
        finish()
    }

    private func finish() {
        finished = true
        watch = nil
        onFinish()
    }

    private func runStep() {
        guard !finished, let presenter else { return }
        guard index < tour.steps.count else {
            presenter.showBubble(sessionID: Self.sessionID, text: "All done!", style: .done, holdSeconds: 1.5)
            finish()
            return
        }
        let step = tour.steps[index]
        guard let element = findTourElement(step.locator, pid: pid), let frame = axFrame(element) else {
            let wanted = step.locator.title ?? step.locator.description ?? "the next item"
            presenter.moveLocalCursor(sessionID: Self.sessionID, name: tour.title, to: primaryScreenCenterQuartz(), pace: .teach, linger: 0.5)
            presenter.showBubble(
                sessionID: Self.sessionID,
                text: "Couldn’t find “\(wanted)” in \(step.locator.appName). It may look different now.",
                style: .nudge,
                holdSeconds: 4
            )
            finish()
            return
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        presenter.moveLocalCursor(sessionID: Self.sessionID, name: tour.title, to: point, pace: .teach, linger: 0.5)
        presenter.showBubble(
            sessionID: Self.sessionID,
            text: "Step \(index + 1) of \(tour.steps.count): \(step.instruction)",
            style: .handoff,
            holdSeconds: nil
        )
        watch = HandoffWatch(
            target: frame,
            onInside: { [weak self] in
                guard let self else { return }
                self.index += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated { self.runStep() }
                }
            },
            onOutside: { [weak presenter] in presenter?.shake(sessionID: Self.sessionID) }
        )
    }
}

/// Legacy overlay folders are named `mac-computer-use-overlay-<owner pid>-<uuid>`.
func staleLegacyOverlayChannelNames(_ names: [String], isAlive: (pid_t) -> Bool) -> [String] {
    let prefix = "mac-computer-use-overlay-"
    return names.filter { name in
        guard name.hasPrefix(prefix) else { return false }
        let remainder = name.dropFirst(prefix.count)
        guard let dash = remainder.firstIndex(of: "-"),
              let owner = pid_t(remainder[..<dash]), owner > 0 else { return false }
        return !isAlive(owner)
    }
}

@MainActor
public final class ServiceHost {
    private let executablePath: String
    private let environment: [String: String]
    private let approvals: ClientApprovalStore
    private let presenter: ServiceOverlayPresenter?
    private let agentCam: AgentCam?
    private var listenDescriptor: Int32 = -1
    private var sessions: [String: ServiceSession] = [:]
    private var acceptingConnections = false
    private var deniedThisRun = Set<String>()
    private var promptQueue: [ServiceClientIdentity] = []
    private var isPrompting = false
    private var keyMonitors: [Any] = []
    private var refreshScheduled = false
    private var interactions: [ActiveInteraction] = []
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
        agentCam = presenter == nil ? nil : AgentCam(captureVisible: environment["MACCU_CAPTURE_OVERLAY"] == "1")
        presenter?.onWindowsChanged = { [weak self] identifiers in
            self?.broadcast(["type": "overlay_windows", "ids": identifiers.map { Int($0) }])
        }
        agentCam?.onWindowsChanged = { [weak self] in self?.refreshExtraWindows() }
    }

    // MARK: Lifecycle

    public func start() throws {
        sweepStaleLegacyOverlayChannels()
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
        agentCam?.hide()
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

    // MARK: Guided tours

    private var tourPlayback: TourPlayback?

    public var savedTours: [TourFile] { TourStore.all() }

    /// Replays a saved tour with the service's own cursor. The person asked
    /// for it from the menu, so the app is opened and brought forward.
    public func playTour(named name: String) {
        guard let presenter, tourPlayback == nil,
              let tour = TourStore.all().first(where: { $0.name == name }),
              let locator = tour.steps.first?.locator else { return }
        let bundleID = locator.bundleID
        func launchAndPlay(attempt: Int) {
            let running = bundleID.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
                ?? NSWorkspace.shared.runningApplications.first { $0.localizedName == locator.appName }
            if let running {
                running.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let playback = TourPlayback(tour: tour, pid: running.processIdentifier, presenter: presenter) { [weak self] in
                            self?.tourPlayback = nil
                        }
                        self.tourPlayback = playback
                        playback.start()
                    }
                }
                return
            }
            if attempt == 0, let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            guard attempt < 16 else {
                presenter.moveLocalCursor(sessionID: TourPlayback.sessionID, name: tour.title, to: primaryScreenCenterQuartz(), pace: .teach, linger: 0.5)
                presenter.showBubble(sessionID: TourPlayback.sessionID, text: "Couldn’t open \(locator.appName) for this tour.", style: .nudge, holdSeconds: 3)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { launchAndPlay(attempt: attempt + 1) }
            }
        }
        launchAndPlay(attempt: 0)
    }

    public func openToursFolder() {
        let directory = TourStore.directory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    // MARK: Cursor demo

    /// Setup's "Test cursor": the cursor appears mid-screen, flies to the menu
    /// bar item and explains itself, then fades like any idle agent cursor.
    public func runCursorDemo(statusItemFrame: CGRect?) {
        guard let presenter else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let primaryHeight = primaryScreen().frame.height
        func quartz(_ cocoa: CGPoint) -> CGPoint { CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y) }
        let center = screen.map { CGPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? .zero
        let target = statusItemFrame.map { CGPoint(x: $0.midX, y: $0.minY - 6) }
            ?? CGPoint(x: center.x + 240, y: center.y + 160)
        let id = "demo"
        presenter.removeSession(id)
        presenter.moveLocalCursor(sessionID: id, name: "Mac Computer Use", to: quartz(center), pace: .teach, linger: 6)
        let ready = AXIsProcessTrusted() && CGPreflightScreenCaptureAccess()
        presenter.showBubble(
            sessionID: id,
            text: ready
                ? "This is how an agent’s cursor looks. It never moves your pointer."
                : "Grant Accessibility and Screen Recording in Setup first.",
            style: ready ? .teach : .nudge,
            holdSeconds: 2.2
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let presenter = self?.presenter else { return }
                presenter.moveLocalCursor(sessionID: id, name: "Mac Computer Use", to: quartz(target), pace: .teach, linger: 5)
                let flight = presenter.flightDuration(sessionID: id, to: quartz(target), pace: .teach)
                DispatchQueue.main.asyncAfter(deadline: .now() + flight + 0.1) {
                    MainActor.assumeIsolated {
                        presenter.showBubble(
                            sessionID: id,
                            text: "Pause, resume or quit agents from here. Esc stops them.",
                            style: .teach,
                            holdSeconds: 3
                        )
                    }
                }
            }
        }
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
        presenter?.setIdentity(
            sessionID: sessionID,
            name: identity.displayName,
            colorIndex: cursorIdentityColorIndex(forClientKey: identity.key)
        )
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
        for interaction in interactions where interaction.sessionID == sessionID {
            finishInteraction(interaction, respond: nil)
        }
        presenter?.removeSession(sessionID)
        agentCam?.sessionEnded(sessionID)
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
            if let presenter, let agentCam {
                agentCam.observe(
                    sessionID: sessionID,
                    windowID: (message["window_id"] as? NSNumber).map { CGWindowID($0.uint32Value) },
                    title: [session.client.displayName, session.currentApp].compactMap { $0 }.joined(separator: " · "),
                    active: session.isActive(now: CACurrentMediaTime()) || presenter.cursorPoint(for: sessionID) != nil,
                    isVisible: { [weak presenter] id in presenter?.cursorPoint(for: id) != nil },
                    cursor: { [weak presenter] id in presenter?.cursorPoint(for: id) }
                )
            }
            notifyChange()
            scheduleRefresh(at: session.lingerUntil)
        case "busy":
            session.busy = message["busy"] as? Bool ?? false
            notifyChange()
        case "approval_request":
            requestApproval(for: session)
        case "bubble":
            let hold = (message["hold_ms"] as? NSNumber)?.doubleValue ?? 4000
            presenter?.showBubble(
                sessionID: sessionID,
                text: message["text"] as? String ?? "",
                style: BubbleStyle(rawValue: message["style"] as? String ?? "") ?? .teach,
                holdSeconds: hold > 0 ? hold / 1000 : nil
            )
        case "bubble_clear":
            presenter?.clearBubble(sessionID: sessionID)
        case "annotate":
            presenter?.annotations.show(
                items: message["items"] as? [[String: Any]] ?? [],
                caption: message["caption"] as? String,
                captionAnchor: quartzRect(message["window_bounds"]),
                duration: ((message["duration_ms"] as? NSNumber)?.doubleValue ?? 8000) / 1000,
                windowID: (message["window_id"] as? NSNumber).map { CGWindowID($0.uint32Value) },
                windowBounds: quartzRect(message["window_bounds"]),
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            )
        case "annotations_clear":
            presenter?.annotations.clear()
        case "countdown":
            presenter?.startCountdown(
                sessionID: sessionID,
                duration: ((message["duration_ms"] as? NSNumber)?.doubleValue ?? 2000) / 1000
            )
        case "cursor_feedback":
            if message["kind"] as? String == "error" { presenter?.shake(sessionID: sessionID) }
        case "request":
            startInteraction(message, for: session)
        case "request_cancel":
            if let id = message["id"] as? Int,
               let interaction = interactions.first(where: { $0.sessionID == sessionID && $0.requestID == id }) {
                finishInteraction(interaction, respond: nil)
            }
        default:
            break
        }
    }

    // MARK: Interactions

    private func startInteraction(_ message: [String: Any], for session: ServiceSession) {
        guard let requestID = message["id"] as? Int else { return }
        let sessionID = session.id
        let timeout = ((message["timeout_ms"] as? NSNumber)?.doubleValue ?? 120_000) / 1000
        let capture = environment["MACCU_CAPTURE_OVERLAY"] == "1"
        var interaction: ActiveInteraction?
        if message["kind"] as? String != "wait_click" { presenter?.clearBubble(sessionID: sessionID) }
        func respond(_ payload: [String: Any]) {
            guard let current = interaction else { return }
            finishInteraction(current, respond: payload)
        }
        switch message["kind"] as? String {
        case "ask":
            let options = (message["options"] as? [String] ?? []).prefix(4).map { String($0.prefix(40)) }
            guard options.count >= 2 else {
                session.control.send(["type": "response", "id": requestID, "outcome": "invalid"])
                return
            }
            let prompt = ChoicePrompt(
                question: String((message["question"] as? String ?? "").prefix(200)),
                options: Array(options),
                near: presenter?.cursorPoint(for: sessionID),
                captureVisible: capture
            ) { index in
                if let index {
                    respond(["outcome": "chosen", "index": index, "choice": options[index]])
                } else {
                    respond(["outcome": "cancelled"])
                }
            }
            interaction = ActiveInteraction(
                sessionID: sessionID,
                requestID: requestID,
                windowIDs: { [CGWindowID(prompt.panel.windowNumber)] },
                dismiss: { prompt.finish(nil) }
            )
        case "pick":
            let pick = PickSession(
                prompt: String((message["prompt"] as? String ?? "Click the item you mean").prefix(160)),
                multiple: message["multiple"] as? Bool ?? false,
                captureVisible: capture
            ) { points in
                guard let points else {
                    respond(["outcome": "cancelled"])
                    return
                }
                respond([
                    "outcome": "picked",
                    "points": points.map { [Double($0.x), Double($0.y)] },
                    "owners": points.map { windowOwnerUnder($0).map { Int($0) } ?? 0 },
                ])
            }
            interaction = ActiveInteraction(
                sessionID: sessionID,
                requestID: requestID,
                windowIDs: { pick.windowIDs },
                dismiss: { pick.finish(nil) }
            )
        case "wait_click":
            guard let rect = quartzRect(message["rect"]) else {
                session.control.send(["type": "response", "id": requestID, "outcome": "invalid"])
                return
            }
            var lastNudge: CFTimeInterval = 0
            let watch = HandoffWatch(
                target: rect,
                onInside: { respond(["outcome": "clicked"]) },
                onOutside: { [weak self] in
                    let now = CACurrentMediaTime()
                    guard now - lastNudge > 1 else { return }
                    lastNudge = now
                    self?.presenter?.shake(sessionID: sessionID)
                }
            )
            interaction = ActiveInteraction(
                sessionID: sessionID,
                requestID: requestID,
                windowIDs: { [] },
                dismiss: { watch.stop() }
            )
        default:
            session.control.send(["type": "response", "id": requestID, "outcome": "invalid"])
            return
        }
        guard let interaction else { return }
        interaction.timer = Timer.scheduledTimer(withTimeInterval: max(timeout, 1), repeats: false) { [weak self, weak interaction] _ in
            MainActor.assumeIsolated {
                guard let self, let interaction else { return }
                self.finishInteraction(interaction, respond: ["outcome": "timeout"])
            }
        }
        interactions.append(interaction)
        refreshExtraWindows()
    }

    private func refreshExtraWindows() {
        presenter?.setExtraWindows(interactions.flatMap { $0.windowIDs() } + (agentCam?.panelWindowID.map { [$0] } ?? []))
    }

    public var agentPreviewEnabled: Bool {
        get { AgentCamPreference.isEnabled }
        set {
            AgentCamPreference.isEnabled = newValue
            if !newValue { agentCam?.hide() }
            notifyChange()
        }
    }

    /// Ends an interaction once: dismisses its surface, and replies to the
    /// worker unless the worker itself withdrew the request.
    private func finishInteraction(_ interaction: ActiveInteraction, respond payload: [String: Any]?) {
        guard let index = interactions.firstIndex(where: { $0 === interaction }) else { return }
        interactions.remove(at: index)
        interaction.timer?.invalidate()
        interaction.dismiss()
        if let payload, let session = sessions[interaction.sessionID] {
            var message = payload
            message["type"] = "response"
            message["id"] = interaction.requestID
            session.control.send(message)
        }
        refreshExtraWindows()
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
        if let tourPlayback {
            tourPlayback.cancel()
            return
        }
        // Esc first dismisses whatever the agent asked the person.
        if let latest = interactions.last {
            finishInteraction(latest, respond: ["outcome": "cancelled"])
            return
        }
        let now = CACurrentMediaTime()
        let agentVisible = presenter?.hasVisibleCursor == true
            || sessions.values.contains { $0.isActive(now: now) }
        guard agentVisible else {
            presenter?.annotations.clear()
            return
        }
        broadcast(["type": "cancel"])
        setPaused(true)
    }

    // MARK: Helpers

    /// Removes overlay channel folders left in $TMPDIR by earlier in-process
    /// sessions whose owner has exited.
    private func sweepStaleLegacyOverlayChannels() {
        let directory = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in staleLegacyOverlayChannelNames(names, isAlive: processIsAlive) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

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
