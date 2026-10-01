// A worker runs one client's MCP session inside the service. The service
// spawns it with the client connection on stdin/stdout and a control channel
// on descriptor 3. Because the service is a LaunchServices-launched app and
// the worker is its child, macOS attributes the worker's Accessibility and
// Screen Recording use to MacComputerUse.app.
import Foundation
import ApplicationServices
import CoreGraphics
import Darwin

let workerControlDescriptor: Int32 = 3

let userInterruptedPrefix = "[user_interrupted]"

func userInterruptedResult(actionReport: String? = nil) -> [String: Any] {
    var message = "\(userInterruptedPrefix) The user pressed Esc and stopped this action. Stop and ask the user before continuing."
    if let actionReport, !actionReport.isEmpty {
        message += " The action reported: \(actionReport)"
    }
    return toolText(message, isError: true)
}

let userPausedMessage = "\(userInterruptedPrefix) The user paused automation with Esc. Do not retry; ask the user what to do. They can resume from the Mac Computer Use menu bar."

/// Optional check run before any tool. Returns a result to refuse the call.
var toolCallGate: ((String) -> [String: Any]?)?

/// Optional check run before any action that drives an app. Returns a result
/// to refuse the action.
var actionGate: (() -> [String: Any]?)?

/// Tools that never change anything and stay available while paused or before
/// the user has approved the client.
let diagnosticToolNames: Set<String> = ["health_report"]

final class WorkerSession: @unchecked Sendable {
    static let shared = WorkerSession()

    private let condition = NSCondition()
    private var channel: JSONLineChannel?
    private var approval = "pending"
    private var approvalRequested = false
    private var paused = false
    private var overlayWindows: [CGWindowID] = []
    private var sessionInfo: [String: Any] = [:]
    private var nextRequestID = 1
    private var responses: [Int: [String: Any]] = [:]

    var isAttached: Bool {
        condition.lock(); defer { condition.unlock() }
        return channel != nil
    }

    var isPaused: Bool {
        condition.lock(); defer { condition.unlock() }
        return paused
    }

    var overlayWindowIDs: [CGWindowID] {
        condition.lock(); defer { condition.unlock() }
        return overlayWindows
    }

    func attach(descriptor: Int32) -> JSONLineChannel {
        let channel = JSONLineChannel(descriptor: descriptor)
        condition.lock(); self.channel = channel; condition.unlock()
        channel.startReading(
            onMessage: { [weak self] message in self?.handle(message) },
            onClose: {
                // The service quit or stopped this session. Stop driving apps now.
                cancelFlag.set(true)
                exit(0)
            }
        )
        return channel
    }

    func send(_ message: [String: Any]) {
        condition.lock(); let channel = channel; condition.unlock()
        channel?.send(message)
    }

    func reportBusy(_ busy: Bool, tool: String) {
        send(["type": "busy", "busy": busy, "tool": tool])
    }

    func healthSnapshot() -> [String: Any] {
        condition.lock(); defer { condition.unlock() }
        var snapshot = sessionInfo
        snapshot["approval"] = approval
        snapshot["paused"] = paused
        snapshot["service_pid"] = Int(getppid())
        snapshot["connected"] = channel?.isOpen == true
        return snapshot
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "session":
            condition.lock()
            sessionInfo = message.filter { $0.key != "type" }
            if let state = message["approval"] as? String { approval = state }
            condition.broadcast()
            condition.unlock()
        case "approval":
            condition.lock()
            approval = message["state"] as? String ?? "pending"
            if approval == "pending" { approvalRequested = false }
            condition.broadcast()
            condition.unlock()
        case "cancel":
            cancelFlag.set(true)
            OverlayController.shared.markCancelling()
        case "pause":
            let isPaused = message["paused"] as? Bool ?? false
            condition.lock(); paused = isPaused; condition.unlock()
            if isPaused { cancelFlag.set(true) }
        case "overlay_windows":
            let identifiers = (message["ids"] as? [NSNumber] ?? []).map { CGWindowID($0.uint32Value) }
            condition.lock(); overlayWindows = identifiers; condition.unlock()
        case "response":
            guard let id = message["id"] as? Int else { return }
            condition.lock()
            responses[id] = message
            condition.broadcast()
            condition.unlock()
        default:
            break
        }
    }

    enum InteractionOutcome {
        case response([String: Any])
        case cancelled
        case timedOut
        case unavailable
        case polled([String: Any])
    }

    /// Asks the service to run an interaction with the person (a question,
    /// pick mode, a hand-off) and waits for it. Esc (`cancelFlag`) or the
    /// timeout ends the wait and dismisses the interaction. `poll` runs every
    /// 100 ms; a non-nil result ends the interaction early.
    func interact(
        _ kind: String,
        _ parameters: [String: Any],
        timeout: TimeInterval,
        poll: (() -> [String: Any]?)? = nil
    ) -> InteractionOutcome {
        condition.lock()
        guard let channel, channel.isOpen else {
            condition.unlock()
            return .unavailable
        }
        let id = nextRequestID
        nextRequestID += 1
        condition.unlock()
        var message = parameters
        message["type"] = "request"
        message["kind"] = kind
        message["id"] = id
        message["timeout_ms"] = Int(timeout * 1000)
        guard channel.send(message) else { return .unavailable }

        let deadline = Date().addingTimeInterval(timeout + 1)
        while true {
            condition.lock()
            if let response = responses.removeValue(forKey: id) {
                condition.unlock()
                switch response["outcome"] as? String {
                case "cancelled": return .cancelled
                case "timeout": return .timedOut
                default: return .response(response)
                }
            }
            _ = condition.wait(until: Date().addingTimeInterval(0.1))
            condition.unlock()
            if cancelFlag.value {
                channel.send(["type": "request_cancel", "id": id])
                return .cancelled
            }
            if let poll, let early = poll() {
                channel.send(["type": "request_cancel", "id": id])
                return .polled(early)
            }
            if Date() > deadline {
                channel.send(["type": "request_cancel", "id": id])
                return .timedOut
            }
            if !channel.isOpen { return .unavailable }
        }
    }

    /// Waits for the user's decision about this client. Returns nil once the
    /// client is approved, or a result that refuses the call.
    func requireApproval(timeout: TimeInterval = 120) -> [String: Any]? {
        condition.lock()
        defer { condition.unlock() }
        if approval == "approved" { return nil }
        if approval == "denied" {
            return toolText(
                "[client_not_allowed] The user did not allow this app to control the Mac through Mac Computer Use. Ask the user to allow it in Mac Computer Use Setup, then retry.",
                isError: true
            )
        }
        if !approvalRequested {
            approvalRequested = true
            channel?.send(["type": "approval_request"])
        }
        let deadline = Date().addingTimeInterval(timeout)
        while approval == "pending" {
            guard condition.wait(until: deadline) else { break }
        }
        switch approval {
        case "approved":
            return nil
        case "denied":
            return toolText(
                "[client_not_allowed] The user did not allow this app to control the Mac through Mac Computer Use. Ask the user to allow it in Mac Computer Use Setup, then retry.",
                isError: true
            )
        default:
            return toolText(
                "[approval_pending] Mac Computer Use is asking the user to allow this app. Ask the user to respond to the prompt, then retry.",
                isError: true
            )
        }
    }
}

public func runMacComputerUseWorker() -> Never {
    signal(SIGPIPE, SIG_IGN)
    var status = stat()
    guard fstat(workerControlDescriptor, &status) == 0 else {
        log("worker started without a control channel")
        exit(EX_USAGE)
    }
    let channel = WorkerSession.shared.attach(descriptor: workerControlDescriptor)
    OverlayController.shared.attachServiceChannel(channel)
    toolCallGate = { name in
        guard !diagnosticToolNames.contains(name) else { return nil }
        return WorkerSession.shared.requireApproval()
    }
    actionGate = {
        WorkerSession.shared.isPaused ? toolText(userPausedMessage, isError: true) : nil
    }
    log("mac-computer-use \(macComputerUseVersion()) (worker) starting. AX trusted: \(AXIsProcessTrusted()), ScreenRecording: \(CGPreflightScreenCaptureAccess())")
    runStdinLoop()
}
