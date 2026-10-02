// The stdio process an MCP client launches. It forwards JSON-RPC lines to the
// Mac Computer Use service, which runs every tool inside a worker that macOS
// attributes to MacComputerUse.app. The client app therefore needs no
// Accessibility or Screen Recording permission of its own.
import Foundation
import Darwin

enum RelayUnavailableReason: Equatable {
    case stoppedByUser
    case updating
    case launchFailed(String)
    case serviceMismatch
    case rejected(String)

    var toolMessage: String {
        switch self {
        case .stoppedByUser:
            return "[stopped_by_user] Mac Computer Use was quit from its menu bar, so automation is off. Ask the user to open Mac Computer Use, then retry."
        case .updating:
            return "[updating] Mac Computer Use is installing an update. Retry in a few seconds."
        case .launchFailed(let detail):
            return "[service_unavailable] Mac Computer Use could not be started (\(detail)). Ask the user to open it from Applications, then retry."
        case .serviceMismatch:
            return "[service_mismatch] A different build of Mac Computer Use is running. Ask the user to quit it from its menu bar, then retry."
        case .rejected(let detail):
            return "[service_rejected] \(detail)"
        }
    }
}

let relayDisconnectedToolMessage = "[service_disconnected] Mac Computer Use stopped or restarted while this call was running, so it may or may not have completed. Call get_app_state before retrying."

/// The reply a relay sends while the service is unavailable. Exposed for tests.
func relayLocalReply(to message: [String: Any], reason: RelayUnavailableReason) -> [String: Any]? {
    guard let id = message["id"], let method = message["method"] as? String else { return nil }
    switch method {
    case "initialize":
        return ["jsonrpc": "2.0", "id": id, "result": mcpInitializeResult()]
    case "tools/list":
        return ["jsonrpc": "2.0", "id": id, "result": ["tools": toolSchemas()]]
    case "ping":
        return ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
    case "tools/call":
        return ["jsonrpc": "2.0", "id": id, "result": toolText(reason.toolMessage, isError: true)]
    default:
        return [
            "jsonrpc": "2.0", "id": id,
            "error": ["code": -32601, "message": "Method not found: \(method)"],
        ]
    }
}

/// The reply for a request that was in flight when the service went away.
/// When the user quit the app, that is the reason the agent needs to hear.
func relayDisconnectedReply(id: Any, method: String, stoppedByUser: Bool = false) -> [String: Any] {
    if method == "tools/call" {
        let message = stoppedByUser ? RelayUnavailableReason.stoppedByUser.toolMessage : relayDisconnectedToolMessage
        return ["jsonrpc": "2.0", "id": id, "result": toolText(message, isError: true)]
    }
    return [
        "jsonrpc": "2.0", "id": id,
        "error": ["code": -32000, "message": "Mac Computer Use disconnected before replying."],
    ]
}

func jsonRPCIdentifierKey(_ id: Any) -> String {
    if let string = id as? String { return "s:\(string)" }
    if let number = id as? NSNumber { return "n:\(number.stringValue)" }
    return "x:\(id)"
}

final class MCPRelay: @unchecked Sendable {
    private let environment: [String: String]
    private let bundleURL: URL?
    private let lock = NSLock()
    private let stdoutLock = NSLock()
    private var descriptor: Int32?
    private var generation = 0
    private var initializeMessage: [String: Any]?
    private var inFlight: [String: (id: Any, method: String)] = [:]
    private var lastReason: RelayUnavailableReason = .launchFailed("not started")

    init(environment: [String: String], bundleURL: URL?) {
        self.environment = environment
        self.bundleURL = bundleURL
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        while let line = Swift.readLine(strippingNewline: true) {
            autoreleasepool { handleClientLine(line) }
        }
        lock.lock()
        let current = descriptor
        descriptor = nil
        lock.unlock()
        if let current { close(current) }
        exit(0)
    }

    // MARK: Client -> service

    private func handleClientLine(_ line: String) {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        let method = message["method"] as? String
        let id = message["id"]

        if method == "initialize", let id {
            initializeMessage = message
            if !isConnected {
                // One attempt only, so clients with short startup timeouts
                // get a clear local answer instead of timing out.
                if let result = connect() {
                    writeToClient(["jsonrpc": "2.0", "id": id, "result": result])
                } else {
                    lock.lock(); let reason = lastReason; lock.unlock()
                    if let reply = relayLocalReply(to: message, reason: reason) { writeToClient(reply) }
                }
                return
            }
        }
        if method == "notifications/initialized" || method == "initialized" {
            if isConnected { forward(line, id: nil, method: nil) }
            return
        }
        if let id, let method {
            if !isConnected, initializeMessage != nil { _ = connect() }
            if isConnected, forward(line, id: id, method: method) { return }
            lock.lock(); let reason = lastReason; lock.unlock()
            if let reply = relayLocalReply(to: message, reason: reason) { writeToClient(reply) }
            return
        }
        if isConnected { forward(line, id: nil, method: nil) }
    }

    private var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return descriptor != nil
    }

    @discardableResult
    private func forward(_ line: String, id: Any?, method: String?) -> Bool {
        lock.lock()
        guard let current = descriptor else { lock.unlock(); return false }
        if let id, let method { inFlight[jsonRPCIdentifierKey(id)] = (id, method) }
        lock.unlock()
        var data = Data(line.utf8)
        data.append(0x0A)
        if writeAll(current, data) { return true }
        if let id { lock.lock(); inFlight.removeValue(forKey: jsonRPCIdentifierKey(id)); lock.unlock() }
        // Only the reader thread closes the socket: it drains what is left,
        // answers the remaining requests once, and then closes.
        shutdown(current, SHUT_RDWR)
        return false
    }

    // MARK: Connection

    /// Connects, launching the service when needed, and replays the client's
    /// initialize handshake. Returns the service's initialize result.
    private func connect() -> [String: Any]? {
        guard let initializeMessage else { return nil }
        if MacComputerUseRuntime.userStoppedService(environment: environment) {
            setReason(.stoppedByUser)
            return nil
        }
        if !waitForUpdateToFinish() {
            setReason(.updating)
            return nil
        }
        let socketPath = MacComputerUseRuntime.socketURL(environment: environment).path
        var candidate = connectUnixSocket(path: socketPath)
        if candidate == nil {
            if let failure = launchService() {
                setReason(.launchFailed(failure))
                return nil
            }
            // An isolated runtime's service is started by its owner, never by us.
            let deadline = Date().addingTimeInterval(MacComputerUseRuntime.isOverridden(environment: environment) ? 3 : 15)
            while candidate == nil, Date() < deadline {
                if MacComputerUseRuntime.userStoppedService(environment: environment) {
                    setReason(.stoppedByUser)
                    return nil
                }
                usleep(100_000)
                candidate = connectUnixSocket(path: socketPath)
            }
        }
        guard let connection = candidate else {
            setReason(.launchFailed("the service did not start listening in time"))
            return nil
        }
        guard socketPeerIsCurrentUser(connection), socketPeerSharesCurrentCodeIdentity(connection) else {
            close(connection)
            setReason(.serviceMismatch)
            return nil
        }

        let reader = LineReader(descriptor: connection)
        let params = initializeMessage["params"] as? [String: Any] ?? [:]
        let hello: [String: Any] = [
            "maccu_relay": 1,
            "version": macComputerUseVersion(),
            "pid": Int(getpid()),
            "client_info": params["clientInfo"] ?? NSNull(),
        ]
        guard writeAll(connection, encodeJSONLine(hello)),
              let ackLine = reader.readLine(timeout: 10),
              let ack = decodeJSONLine(ackLine) else {
            close(connection)
            setReason(.launchFailed("the service did not acknowledge the connection"))
            return nil
        }
        guard ack["accepted"] as? Bool == true else {
            close(connection)
            setReason(.rejected(ack["error"] as? String ?? "The service refused the connection."))
            return nil
        }

        lock.lock()
        generation += 1
        let currentGeneration = generation
        lock.unlock()
        let handshakeID = "maccu-relay-initialize-\(currentGeneration)"
        var replay = initializeMessage
        replay["id"] = handshakeID
        guard writeAll(connection, encodeJSONLine(replay)) else {
            close(connection)
            setReason(.launchFailed("the session closed during initialization"))
            return nil
        }
        var initializeResult: [String: Any]?
        while initializeResult == nil {
            guard let line = reader.readLine(timeout: 30), let message = decodeJSONLine(line) else {
                close(connection)
                setReason(.launchFailed("the session did not finish initializing"))
                return nil
            }
            if message["id"] as? String == handshakeID {
                initializeResult = message["result"] as? [String: Any] ?? [:]
            }
        }
        guard writeAll(connection, encodeJSONLine([
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ])) else {
            close(connection)
            setReason(.launchFailed("the session closed during initialization"))
            return nil
        }

        lock.lock()
        descriptor = connection
        lock.unlock()
        startReading(connection, reader: reader, generation: currentGeneration)
        return initializeResult
    }

    private func setReason(_ reason: RelayUnavailableReason) {
        lock.lock(); lastReason = reason; lock.unlock()
    }

    private func waitForUpdateToFinish() -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while macComputerUseUpdateInProgress(environment: environment) {
            guard Date() < deadline else { return false }
            usleep(250_000)
        }
        return true
    }

    /// Launches MacComputerUse.app through LaunchServices so macOS treats the
    /// service, and every worker it spawns, as the app itself.
    private func launchService() -> String? {
        guard !MacComputerUseRuntime.isOverridden(environment: environment) else {
            return nil // isolated runtimes are started explicitly by their owner
        }
        guard let bundleURL else { return "the relay is not inside MacComputerUse.app" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", bundleURL.path, "--args", "manager", "--background"]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return error.localizedDescription
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return detail.isEmpty ? "open exited with status \(process.terminationStatus)" : detail
        }
        return nil
    }

    // MARK: Service -> client

    private func startReading(_ connection: Int32, reader: LineReader, generation currentGeneration: Int) {
        let thread = Thread { [self] in
            while let line = reader.readLine() {
                autoreleasepool {
                    if let message = decodeJSONLine(line),
                       let id = message["id"],
                       message["result"] != nil || message["error"] != nil {
                        lock.lock()
                        inFlight.removeValue(forKey: jsonRPCIdentifierKey(id))
                        lock.unlock()
                    }
                    var data = line
                    data.append(0x0A)
                    writeRawToClient(data)
                }
            }
            lock.lock()
            let isCurrent = generation == currentGeneration
            lock.unlock()
            if isCurrent { dropConnection(connection) } else { close(connection) }
        }
        thread.name = "mac-computer-use.relay"
        thread.start()
    }

    private func dropConnection(_ connection: Int32) {
        lock.lock()
        guard descriptor == connection else { lock.unlock(); return }
        descriptor = nil
        let pending = inFlight
        inFlight.removeAll()
        let stoppedByUser = MacComputerUseRuntime.userStoppedService(environment: environment)
        lastReason = stoppedByUser ? .stoppedByUser : .launchFailed("the service stopped")
        lock.unlock()
        close(connection)
        for (_, request) in pending {
            writeToClient(relayDisconnectedReply(id: request.id, method: request.method, stoppedByUser: stoppedByUser))
        }
    }

    private func writeToClient(_ message: [String: Any]) {
        writeRawToClient(encodeJSONLine(message))
    }

    private func writeRawToClient(_ data: Data) {
        stdoutLock.lock()
        let delivered = writeAll(STDOUT_FILENO, data)
        stdoutLock.unlock()
        if !delivered { exit(0) } // the client is gone
    }
}

public func runMacComputerUseRelay(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main
) -> Never {
    let bundleURL = bundle.bundleURL.pathExtension == "app" ? bundle.bundleURL : nil
    MCPRelay(environment: environment, bundleURL: bundleURL).run()
}
