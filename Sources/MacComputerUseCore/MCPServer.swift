import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - JSON-RPC handler
func mcpInitializeResult() -> [String: Any] {
    [
        "protocolVersion": "2024-11-05",
        "capabilities": ["tools": ["listChanged": false]],
        "serverInfo": ["name": "mac-computer-use", "version": macComputerUseVersion()],
    ]
}

func handle(_ msg: [String: Any]) {
    let id = msg["id"]
    guard let method = msg["method"] as? String else { return }
    switch method {
    case "initialize": resultMsg(id, mcpInitializeResult())
    case "notifications/initialized","initialized": break
    case "tools/list": resultMsg(id, ["tools": toolSchemas()])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let reportsBusy = WorkerSession.shared.isAttached
        // A brake from an earlier Esc must not cancel this new call.
        if reportsBusy, !WorkerSession.shared.isPaused { cancelFlag.set(false) }
        if reportsBusy { WorkerSession.shared.reportBusy(true, tool: name) }
        let result = dispatchTool(name, params["arguments"] as? [String: Any] ?? [:])
        if reportsBusy { WorkerSession.shared.reportBusy(false, tool: name) }
        resultMsg(id, result)
    case "ping": resultMsg(id, [:])
    default: if id != nil { errorMsg(id, -32601, "Method not found: \(method)") }
    }
}

// MARK: - Entry: GUI on main, MCP loop on background
// MCP stdio loop (runs on the main thread; pure CLI, no AppKit).
func runStdinLoop() -> Never {
    while let line = readLine(strippingNewline: true) {
        // Nothing drains the implicit top-level pool on this thread — there is no run
        // loop here, only readLine. Without a pool per message every autoreleased AX
        // object and image buffer lives until the client disconnects, which on a
        // long-lived session is gigabytes. Drain on each request instead.
        autoreleasepool {
            if line.isEmpty { return }
            guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { log("bad json"); return }
            handle(obj)
        }
    }
    OverlayController.shared.cleanup()
    exit(0) // stdin closed -> client gone
}

public func macComputerUseVersion(bundle: Bundle = .main) -> String {
    (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "development"
}

private var activeMCPSessionLease: MCPProcessSessionLease?

func ensureManagerIsRunning(bundle: Bundle = .main) {
    guard ProcessInfo.processInfo.environment["MACCU_DISABLE_MANAGER"] != "1",
          bundle.bundleURL.pathExtension == "app",
          !managerProcessIsRunning() else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [
        "-g", "-a", bundle.bundleURL.path,
        "--args", "manager", "--background",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

/// `mcp` mode. Inside MacComputerUse.app it relays to the service so the
/// client app needs no permissions; unbundled development binaries, tests and
/// an explicit `--in-process` run the tools in this process instead.
public func runMacComputerUseMCP(
    arguments: [String] = CommandLine.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundle: Bundle = .main
) -> Never {
    if mcpShouldRunInProcess(arguments: arguments, environment: environment, bundleURL: bundle.bundleURL) {
        runMacComputerUseService()
    }
    runMacComputerUseRelay(environment: environment, bundle: bundle)
}

public func mcpShouldRunInProcess(
    arguments: [String],
    environment: [String: String],
    bundleURL: URL
) -> Bool {
    arguments.contains("--in-process")
        || environment["MACCU_IN_PROCESS"] == "1"
        || environment["MACCU_DISABLE_MANAGER"] == "1"
        || bundleURL.pathExtension != "app"
}

public func runMacComputerUseService() -> Never {
    if CommandLine.arguments.contains("overlay") {
        func argumentValue(after flag: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: flag),
                  CommandLine.arguments.indices.contains(index + 1) else { return nil }
            return CommandLine.arguments[index + 1]
        }
        guard let statePath = argumentValue(after: "--state-path"),
              let cancelPath = argumentValue(after: "--cancel-path"),
              let readyPath = argumentValue(after: "--ready-path"),
              let channelID = argumentValue(after: "--channel-id"),
              let ownerValue = argumentValue(after: "--owner-pid"),
              let ownerPID = Int32(ownerValue), ownerPID > 0,
              let channelUUID = UUID(uuidString: channelID) else {
            log("overlay agent requires valid channel paths, channel id, and owner pid")
            exit(2)
        }
        let expected = OverlayIPCPaths(ownerPID: ownerPID, nonce: channelUUID)
        guard expected.stateURL.standardizedFileURL.path == URL(fileURLWithPath: statePath).standardizedFileURL.path,
              expected.cancelURL.standardizedFileURL.path == URL(fileURLWithPath: cancelPath).standardizedFileURL.path,
              expected.readyURL.standardizedFileURL.path == URL(fileURLWithPath: readyPath).standardizedFileURL.path else {
            log("overlay agent rejected mismatched channel paths")
            exit(2)
        }
        runOverlayAgent(
            capture: CommandLine.arguments.contains("capture"),
            statePath: statePath,
            cancelPath: cancelPath,
            readyPath: readyPath,
            channelID: expected.channelID,
            ownerPID: ownerPID
        )
    }
    guard let sessionLease = MCPProcessSessionLease.acquire() else {
        log("mac-computer-use update is installing; retry when the manager finishes")
        exit(EX_TEMPFAIL)
    }
    activeMCPSessionLease = sessionLease
    ensureManagerIsRunning()
    log("mac-computer-use \(macComputerUseVersion()) (mcp) starting. AX trusted: \(AXIsProcessTrusted()), ScreenRecording: \(CGPreflightScreenCaptureAccess())")
    OverlayController.shared.install()
    runStdinLoop()
}
