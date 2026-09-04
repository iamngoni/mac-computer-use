import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - JSON-RPC handler
func handle(_ msg: [String: Any]) {
    let id = msg["id"]
    guard let method = msg["method"] as? String else { return }
    switch method {
    case "initialize": resultMsg(id, ["protocolVersion":"2024-11-05","capabilities":["tools":["listChanged":false]],"serverInfo":["name":"mac-computer-use","version": macComputerUseVersion()]])
    case "notifications/initialized","initialized": break
    case "tools/list": resultMsg(id, ["tools": toolSchemas()])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        resultMsg(id, dispatchTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
    case "ping": resultMsg(id, [:])
    default: if id != nil { errorMsg(id, -32601, "Method not found: \(method)") }
    }
}

// MARK: - Entry: GUI on main, MCP loop on background
// MCP stdio loop (runs on the main thread; pure CLI, no AppKit).
func runStdinLoop() -> Never {
    while let line = readLine(strippingNewline: true) {
        if line.isEmpty { continue }
        guard let data = line.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { log("bad json"); continue }
        handle(obj)
    }
    OverlayController.shared.cleanup()
    exit(0) // stdin closed -> client gone
}

func macComputerUseVersion() -> String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.6.0"
}

public func runMacComputerUse() -> Never {
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
    log("mac-computer-use \(macComputerUseVersion()) (mcp) starting. AX trusted: \(AXIsProcessTrusted()), ScreenRecording: \(CGPreflightScreenCaptureAccess())")
    OverlayController.shared.install()
    runStdinLoop()
}
