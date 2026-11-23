// Bring your own agent: Mac Computer Use acts as an Agent Client Protocol
// (ACP v1) client. It starts the person's own agent (Gemini CLI, Claude Code
// or Codex through their ACP adapters, ...), gives it Mac Computer Use as an
// MCP server, and sends it a review when the person asks. No model is bundled.
// Spec: https://agentclientprotocol.com/protocol/v1/overview
import AppKit
import Foundation

/// One agent the person can send reviews to. Stored in
/// ~/Library/Application Support/MacComputerUse/agents.json.
public struct ACPAgentConfig: Codable, Equatable, Sendable {
    public var name: String
    /// Run through the person's login shell, so PATH and npx work.
    public var command: String
    /// The folder the agent works in. Default: the home folder.
    public var cwd: String?

    public init(name: String, command: String, cwd: String? = nil) {
        self.name = name
        self.command = command
        self.cwd = cwd
    }
}

public enum ACPAgentConfigStore {
    public static func url() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacComputerUse/agents.json")
    }

    /// ACP commands that ship as their own executables. Only ones found on
    /// the person's PATH are offered.
    static let knownAgents: [(name: String, executable: String, command: String)] = [
        ("Gemini CLI", "gemini", "gemini --acp"),
        ("Claude Code", "claude-agent-acp", "claude-agent-acp"),
        ("Codex", "codex-acp", "codex-acp"),
    ]

    public static func load() -> [ACPAgentConfig] {
        if let data = try? Data(contentsOf: url()),
           let agents = try? JSONDecoder().decode([ACPAgentConfig].self, from: data) {
            return agents
        }
        let found = knownAgents.filter { loginShellHasExecutable($0.executable) }
            .map { ACPAgentConfig(name: $0.name, command: $0.command) }
        save(found)
        return found
    }

    public static func save(_ agents: [ACPAgentConfig]) {
        try? FileManager.default.createDirectory(at: url().deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(agents).write(to: url(), options: .atomic)
    }

    static func loginShellHasExecutable(_ name: String) -> Bool {
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// The text sent to the agent with a review.
func reviewPrompt(_ notes: [ReviewNote]) -> String {
    var lines = [
        "The user reviewed work on their Mac and left \(notes.count) review note\(notes.count == 1 ? "" : "s") by circling things on screen.",
        "Use the mac-computer-use tools: get_note shows a note in full with an image of what was circled.",
        "For each note that is about your work: claim_note, make the change, check it on screen, then resolve_note with a one-sentence reply.",
        "Leave notes that are not about your work for other agents.",
        "",
    ]
    for note in notes {
        var place = note.appName
        if let url = note.url { place += " \(url)" } else if let title = note.windowTitle { place += " “\(title)”" }
        lines.append("- \(note.id): \"\(note.text)\" · \(place)")
    }
    return lines.joined(separator: "\n")
}

/// One running agent over stdio, newline-delimited JSON-RPC 2.0.
@MainActor
final class ACPAgentConnection {
    let config: ACPAgentConfig
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: ([String: Any]?, [String: Any]?) -> Void] = [:]
    private var sessionID: String?
    private var messageText = ""
    private(set) var isRunning = false

    var onJob: ((JobState) -> Void)?
    var onPermission: ((String, [(id: String, name: String)], @escaping (String?) -> Void) -> Void)?
    var onExit: (() -> Void)?

    init(config: ACPAgentConfig) {
        self.config = config
    }

    func start(mcpCommand: String) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \(config.command)"]
        process.currentDirectoryURL = URL(fileURLWithPath: expandedCwd)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle(forWritingAtPath: MacComputerUseRuntime.workerLogURL().path) ?? FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.isRunning = false
                    self?.onExit?()
                }
            }
        }
        try process.run()
        isRunning = true
        request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "mac-computer-use", "version": macComputerUseVersion()],
        ]) { [weak self] _, error in
            guard let self else { return }
            if let error { return self.fail("initialize: \(error["message"] as? String ?? "failed")") }
            self.request("session/new", [
                "cwd": self.expandedCwd,
                "mcpServers": [["name": "mac-computer-use", "command": mcpCommand, "args": ["mcp"], "env": []]],
            ]) { [weak self] result, error in
                guard let self else { return }
                if let error { return self.fail("session/new: \(error["message"] as? String ?? "failed")") }
                self.sessionID = result?["sessionId"] as? String
                self.flushQueuedPrompt()
            }
        }
    }

    private var expandedCwd: String {
        (config.cwd.map { ($0 as NSString).expandingTildeInPath }) ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private var queuedPrompt: String?

    /// Sends a prompt now, or as soon as the session exists.
    func prompt(_ text: String) {
        queuedPrompt = text
        flushQueuedPrompt()
    }

    private func flushQueuedPrompt() {
        guard let sessionID, let text = queuedPrompt else { return }
        queuedPrompt = nil
        messageText = ""
        onJob?(JobState(title: "\(config.name): review", step: "Reading your notes", progress: nil, state: "running"))
        request("session/prompt", ["sessionId": sessionID, "prompt": [["type": "text", "text": text]]]) { [weak self] result, error in
            guard let self else { return }
            if let error { return self.fail(error["message"] as? String ?? "the prompt failed") }
            let reason = result?["stopReason"] as? String ?? "end_turn"
            let summary = self.messageText.trimmingCharacters(in: .whitespacesAndNewlines)
            self.onJob?(JobState(
                title: "\(self.config.name): review",
                step: summary.isEmpty ? reason.replacingOccurrences(of: "_", with: " ") : String(summary.suffix(120)),
                progress: 1,
                state: reason == "end_turn" ? "done" : "failed"
            ))
        }
    }

    func stop() {
        if let sessionID { notify("session/cancel", ["sessionId": sessionID]) }
        if process.isRunning { process.terminate() }
        isRunning = false
    }

    private func fail(_ message: String) {
        onJob?(JobState(title: "\(config.name): review", step: String(message.prefix(120)), progress: nil, state: "failed"))
    }

    // MARK: JSON-RPC

    private func send(_ message: [String: Any]) {
        var message = message
        message["jsonrpc"] = "2.0"
        guard isRunning, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        input.fileHandleForWriting.write(data + Data([0x0A]))
    }

    private func request(_ method: String, _ params: [String: Any], completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        let id = nextID
        nextID += 1
        pending[id] = completion
        send(["id": id, "method": method, "params": params])
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        send(["method": method, "params": params])
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if let id = message["id"] {
                handleRequest(id: id, method: method, params: params)
            } else if method == "session/update" {
                handleUpdate(params["update"] as? [String: Any] ?? [:])
            }
            return
        }
        guard let id = (message["id"] as? NSNumber)?.intValue, let completion = pending.removeValue(forKey: id) else { return }
        completion(message["result"] as? [String: Any], message["error"] as? [String: Any])
    }

    private func handleUpdate(_ update: [String: Any]) {
        let title = "\(config.name): review"
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            if let content = update["content"] as? [String: Any], let text = content["text"] as? String {
                messageText += text
                let line = messageText.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                if !line.isEmpty { onJob?(JobState(title: title, step: String(line.suffix(120)), progress: nil, state: "running")) }
            }
        case "tool_call":
            if let name = update["title"] as? String {
                onJob?(JobState(title: title, step: String(name.prefix(120)), progress: nil, state: "running"))
            }
        case "plan":
            let entries = update["entries"] as? [[String: Any]] ?? []
            let done = entries.filter { $0["status"] as? String == "completed" }.count
            let current = entries.first { $0["status"] as? String == "in_progress" }?["content"] as? String
            if !entries.isEmpty {
                onJob?(JobState(title: title, step: current.map { String($0.prefix(120)) }, progress: Double(done) / Double(entries.count), state: "running"))
            }
        default:
            break
        }
    }

    private func handleRequest(id: Any, method: String, params: [String: Any]) {
        switch method {
        case "session/request_permission":
            let options = (params["options"] as? [[String: Any]] ?? []).compactMap { option -> (id: String, name: String)? in
                guard let id = option["optionId"] as? String else { return nil }
                return (id, option["name"] as? String ?? id)
            }
            let call = params["toolCall"] as? [String: Any]
            let question = "\(config.name) wants to: \(call?["title"] as? String ?? "run a tool")"
            guard let onPermission, !options.isEmpty else {
                send(["id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                return
            }
            onPermission(question, Array(options.prefix(4))) { [weak self] chosen in
                let outcome: [String: Any] = chosen.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
                self?.send(["id": id, "result": ["outcome": outcome]])
            }
        default:
            // We offer no file system or terminal to the agent.
            send(["id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }
}

/// Keeps one connection per configured agent and sends reviews to it.
@MainActor
final class ACPAgentHost {
    private var connections: [String: ACPAgentConnection] = [:]
    private let mcpCommand: String
    var onJob: ((String, JobState) -> Void)?
    var onPermission: ((String, [(id: String, name: String)], @escaping (String?) -> Void) -> Void)?

    init(mcpCommand: String) {
        self.mcpCommand = mcpCommand
    }

    var agentNames: [String] { ACPAgentConfigStore.load().map(\.name) }

    func sendReview(_ notes: [ReviewNote], to name: String) {
        guard !notes.isEmpty, let config = ACPAgentConfigStore.load().first(where: { $0.name == name }) else { return }
        let jobID = "acp-" + name
        let connection: ACPAgentConnection
        if let existing = connections[name], existing.isRunning, existing.config == config {
            connection = existing
        } else {
            connections[name]?.stop()
            connection = ACPAgentConnection(config: config)
            connection.onJob = { [weak self] job in self?.onJob?(jobID, job) }
            connection.onPermission = { [weak self] question, options, reply in
                guard let onPermission = self?.onPermission else { return reply(nil) }
                onPermission(question, options, reply)
            }
            connection.onExit = { [weak self, weak connection] in
                guard let self, let connection, self.connections[name] === connection else { return }
                self.connections.removeValue(forKey: name)
            }
            do {
                try connection.start(mcpCommand: mcpCommand)
            } catch {
                onJob?(jobID, JobState(title: "\(name): review", step: "Could not start: \(error.localizedDescription)", progress: nil, state: "failed"))
                return
            }
            connections[name] = connection
        }
        connection.prompt(reviewPrompt(notes))
    }

    func stopAll() {
        connections.values.forEach { $0.stop() }
        connections.removeAll()
    }
}
