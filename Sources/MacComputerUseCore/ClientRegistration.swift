import Foundation

public enum SupportedMCPClient: String, CaseIterable, Sendable {
    case codex = "Codex"
    case claude = "Claude Code"

    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }
}

public enum MCPClientRegistrationState: Equatable, Sendable {
    case unavailable
    case absent
    case installed
    case different(command: String, arguments: [String])
    case failed(String)
}

public struct ProcessResult: Sendable {
    public let status: Int32
    public let output: String
    public let errorOutput: String

    public init(status: Int32, output: String, errorOutput: String) {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
    }
}

public struct MCPClientRegistrationError: Error, Equatable, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct MCPClientRegistrationService: Sendable {
    public static let serverName = "mac-computer-use"

    public let serverExecutableURL: URL
    public let environment: [String: String]
    public let homeDirectory: URL
    public let runProcess: @Sendable (URL, [String]) -> ProcessResult

    public init(
        serverExecutableURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        runProcess: @escaping @Sendable (URL, [String]) -> ProcessResult = {
            MCPClientRegistrationService.run($0, $1)
        }
    ) {
        self.serverExecutableURL = serverExecutableURL.standardizedFileURL
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.runProcess = runProcess
    }

    public func clientExecutable(for client: SupportedMCPClient) -> URL? {
        var directories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        directories.append(homeDirectory.appendingPathComponent(".local/bin", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true))
        directories.append(URL(fileURLWithPath: "/usr/local/bin", isDirectory: true))

        var seen = Set<String>()
        for directory in directories {
            let candidate = directory.appendingPathComponent(client.executableName)
            guard seen.insert(candidate.path).inserted else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func inspectionArguments(for client: SupportedMCPClient) -> [String] {
        switch client {
        case .codex:
            return ["mcp", "get", Self.serverName, "--json"]
        case .claude:
            return ["mcp", "get", Self.serverName]
        }
    }

    public func removalArguments(for client: SupportedMCPClient) -> [String] {
        switch client {
        case .codex:
            return ["mcp", "remove", Self.serverName]
        case .claude:
            return ["mcp", "remove", Self.serverName, "--scope", "user"]
        }
    }

    public func installationArguments(for client: SupportedMCPClient) -> [String] {
        switch client {
        case .codex:
            return [
                "mcp", "add", Self.serverName, "--",
                serverExecutableURL.path, "mcp",
            ]
        case .claude:
            return [
                "mcp", "add", "--scope", "user", Self.serverName, "--",
                serverExecutableURL.path, "mcp",
            ]
        }
    }

    public func inspect(_ client: SupportedMCPClient) -> MCPClientRegistrationState {
        guard let executable = clientExecutable(for: client) else { return .unavailable }
        let result = runProcess(executable, inspectionArguments(for: client))
        guard result.status == 0 else {
            let combined = result.output + "\n" + result.errorOutput
            if combined.localizedCaseInsensitiveContains("not found") ||
                combined.localizedCaseInsensitiveContains("no server") ||
                combined.localizedCaseInsensitiveContains("no mcp server") ||
                combined.localizedCaseInsensitiveContains("does not exist") {
                return .absent
            }
            return .failed(cleanMessage(result))
        }
        guard let registration = parseRegistration(client: client, output: result.output) else {
            return .failed("Could not read the existing registration.")
        }
        if registration.command == serverExecutableURL.path,
           registration.arguments == ["mcp"] {
            return .installed
        }
        return .different(
            command: registration.command,
            arguments: registration.arguments
        )
    }

    public func install(
        _ client: SupportedMCPClient,
        replaceExisting: Bool
    ) -> Result<Void, MCPClientRegistrationError> {
        guard let executable = clientExecutable(for: client) else {
            return .failure(MCPClientRegistrationError(
                "\(client.rawValue) is not installed or is not on a standard PATH."
            ))
        }
        let current = inspect(client)
        if case .installed = current { return .success(()) }
        if case .different = current, !replaceExisting {
            return .failure(MCPClientRegistrationError(
                "A different mac-computer-use registration already exists."
            ))
        }
        if case .failed(let message) = current {
            return .failure(MCPClientRegistrationError(message))
        }
        if case .different = current {
            let removal = runProcess(executable, removalArguments(for: client))
            guard removal.status == 0 else {
                return .failure(MCPClientRegistrationError(cleanMessage(removal)))
            }
        }
        let installation = runProcess(executable, installationArguments(for: client))
        guard installation.status == 0 else {
            return .failure(MCPClientRegistrationError(cleanMessage(installation)))
        }
        return .success(())
    }

    public func copyableInstallationCommand(for client: SupportedMCPClient) -> String {
        ([client.executableName] + installationArguments(for: client))
            .map(Self.shellQuoted)
            .joined(separator: " ")
    }

    private func parseRegistration(
        client: SupportedMCPClient,
        output: String
    ) -> (command: String, arguments: [String])? {
        switch client {
        case .codex:
            guard let data = output.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let transport = object["transport"] as? [String: Any] ?? object
            guard let command = transport["command"] as? String else { return nil }
            return (command, transport["args"] as? [String] ?? [])
        case .claude:
            let lines = output.components(separatedBy: .newlines)
            guard let commandLine = lines.first(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("Command:")
            }) else { return nil }
            let command = commandLine
                .split(separator: ":", maxSplits: 1)
                .dropFirst()
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let argsLine = lines.first(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("Args:")
            })
            let args = argsLine?
                .split(separator: ":", maxSplits: 1)
                .dropFirst()
                .first
                .map(String.init)?
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init) ?? []
            return command.isEmpty ? nil : (command, args)
        }
    }

    private func cleanMessage(_ result: ProcessResult) -> String {
        let message = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return message }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "The client command failed with status \(result.status)." : output
    }

    private static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"
        )
        if !value.isEmpty && value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func run(_ executable: URL, _ arguments: [String]) -> ProcessResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(
                status: 127,
                output: "",
                errorOutput: error.localizedDescription
            )
        }
        return ProcessResult(
            status: process.terminationStatus,
            output: String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            errorOutput: String(
                data: error.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }
}
