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
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.5.0"
}

public func runMacComputerUse() -> Never {
    if CommandLine.arguments.contains("overlay") {
        runOverlayAgent(capture: CommandLine.arguments.contains("capture"))
    }
    _ = CGRequestScreenCaptureAccess()
    log("mac-computer-use \(macComputerUseVersion()) (mcp) starting. AX trusted: \(AXIsProcessTrusted()), ScreenRecording: \(CGPreflightScreenCaptureAccess())")
    OverlayController.shared.install()
    runStdinLoop()
}
