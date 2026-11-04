import AppKit
import XCTest
@testable import MacComputerUseCore

/// Renders a real visual on screen. Opt in with MACCU_LIVE_VISUAL_TESTS=1;
/// it needs a logged-in GUI session.
@MainActor
final class VisualStageLiveTests: XCTestCase {
    func testAVisualRendersRunsScriptsAndReportsEvents() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACCU_LIVE_VISUAL_TESTS"] == "1")
        NSApplication.shared.setActivationPolicy(.accessory); NSApplication.shared.finishLaunching()
        let stage = VisualStage(captureVisible: true)
        let html = try String(contentsOfFile: ProcessInfo.processInfo.environment["MACCU_VISUAL_HTML"] ?? "", encoding: .utf8)
        let screen = NSScreen.main!.frame
        let anchor = CGRect(x: screen.width / 2 - 260, y: 260, width: 120, height: 40)
        var shown: [String: Any]?
        stage.show(.init(
            owner: "test", agentName: "Claude", id: "demo", html: html,
            placement: .beside, anchor: anchor, window: nil, windowID: nil,
            size: CGSize(width: 520, height: 360), targets: ["anchor": anchor], data: ["value": 42],
            interactive: true, backdrop: "none", follow: false, duration: nil, reduceMotion: false
        )) { shown = $0 }
        let deadline = Date().addingTimeInterval(10)
        while shown == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(shown?["outcome"] as? String, "shown")
        XCTAssertNil(shown?["errors"], "\(shown?["errors"] ?? "")")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        var updated: [String: Any]?
        stage.update(.init(
            owner: "test", id: "demo",
            script: "maccu.send({clicked: 'yes'}); await new Promise(r => setTimeout(r, 50)); return document.title + ':' + maccu.data.value",
            html: nil, data: nil, hasData: false, targets: nil, snapshot: true, waitEvent: 1
        )) { updated = $0 }
        while updated == nil, Date() < deadline.addingTimeInterval(10) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let probe = ProcessInfo.processInfo.environment["MACCU_VISUAL_PROBE"] {
            var probed: [String: Any]?
            stage.update(.init(owner: "test", id: "demo", script: probe, html: nil, data: nil, hasData: false, targets: nil, snapshot: false, waitEvent: 0)) { probed = $0 }
            while probed == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            print("PROBE:", probed ?? [:])
        }
        XCTAssertNil(updated?["script_error"], "\(updated?["script_error"] ?? "")")
        XCTAssertEqual(updated?["result"] as? String, "demo:42")
        XCTAssertEqual((updated?["events"] as? [[String: Any]])?.first?["clicked"] as? String, "yes")
        if let png = updated?["png"] as? String, let out = ProcessInfo.processInfo.environment["MACCU_VISUAL_PNG"] {
            try Data(base64Encoded: png)?.write(to: URL(fileURLWithPath: out))
        }
        XCTAssertNotNil(updated?["png"])
        if let shot = ProcessInfo.processInfo.environment["MACCU_SCREEN_PNG"] {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", shot]
            try task.run(); task.waitUntilExit()
        }
        XCTAssertEqual(stage.clear(owner: "test"), 1)
    }
}
