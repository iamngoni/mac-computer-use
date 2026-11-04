import AppKit
import XCTest
@testable import MacComputerUseCore

/// Renders every template and saves a PNG per template. Opt in with
/// MACCU_LIVE_VISUAL_TESTS=1 and MACCU_TEMPLATE_PNG_DIR.
@MainActor
final class VisualTemplateLiveTests: XCTestCase {
    func testEveryTemplateRendersWithoutPageErrors() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACCU_LIVE_VISUAL_TESTS"] == "1")
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let out = ProcessInfo.processInfo.environment["MACCU_TEMPLATE_PNG_DIR"]
        let stage = VisualStage(captureVisible: true)
        let screen = cocoaRectToQuartzRect(NSScreen.main!.visibleFrame)
        let anchor = CGRect(x: screen.minX + 420, y: screen.minY + 300, width: 140, height: 36)
        let samples: [String: Any] = [
            "spotlight": ["title": "Export lives here", "text": "Click Export to save a copy as PDF."],
            "coach": ["step": 2, "total": 4, "title": "Open the Export menu", "body": "Everything you can save as lives in here.", "hint": "Click Export"],
            "checklist": ["title": "Set up your project", "current": 2, "items": [["text": "Create a workspace", "done": true], ["text": "Invite your team", "done": true], "Connect GitHub", "Ship the first build"]],
            "keycaps": ["keys": "cmd+shift+4", "caption": "Screenshot a region"],
            "confetti": ["message": "Shipped!"],
            "chart": ["type": "bar", "title": "Weekly signups", "labels": ["Mon", "Tue", "Wed", "Thu", "Fri"], "values": [120, 180, 150, 260, 310], "highlight": 4],
            "model3d": ["title": "Inside a capacitor", "caption": "Drag to look around.", "highlight": "Dielectric", "parts": [["shape": "cylinder", "size": [1.2, 0.2], "position": [0, 0.7, 0], "color": "#c0c6d6", "metalness": 0.9, "roughness": 0.25, "label": "Plate"], ["shape": "cylinder", "size": [1.15, 0.5], "position": [0, 0.35, 0], "color": "#7c5cff", "opacity": 0.8, "label": "Dielectric"], ["shape": "cylinder", "size": [1.2, 0.2], "position": [0, 0, 0], "color": "#c0c6d6", "metalness": 0.9, "roughness": 0.25], ["shape": "cylinder", "size": [0.06, 1.2], "position": [0.3, -0.6, 0], "color": "#fbbf24", "metalness": 1, "label": "Lead"]]],
            "compare": ["title": "Your config", "before": ["title": "Polling", "items": ["Checks every 5 s", "Wastes battery"]], "after": ["title": "Webhooks", "items": ["Instant updates", "No idle work"]]],
        ]
        for (name, template) in visualTemplates.sorted(by: { $0.key < $1.key }) {
            var shown: [String: Any]?
            stage.show(.init(
                owner: "test", agentName: "Claude", id: name, html: visualTemplatePage(template, extra: nil),
                placement: template.placement, anchor: anchor, window: nil, windowID: nil,
                size: template.size == .zero ? CGSize(width: 380, height: 240) : template.size,
                targets: ["anchor": anchor], data: samples[name], interactive: false, backdrop: "none",
                follow: false, duration: nil, reduceMotion: false
            )) { shown = $0 }
            let deadline = Date().addingTimeInterval(10)
            while shown == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            RunLoop.main.run(until: Date().addingTimeInterval(name == "confetti" ? 0.5 : (name == "model3d" ? 4 : 1.4)))
            var snap: [String: Any]?
            stage.update(.init(owner: "test", id: name, script: ProcessInfo.processInfo.environment["MACCU_PROBE_\(name)"], html: nil, data: nil, hasData: false, targets: nil, snapshot: true, waitEvent: 0)) { snap = $0 }
            while snap == nil, Date() < deadline.addingTimeInterval(5) { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if let r = snap?["result"] ?? snap?["script_error"] { print("PROBE \(name):", r) }
            let errors = ((shown?["errors"] as? [String]) ?? []) + ((snap?["errors"] as? [String]) ?? [])
            XCTAssertTrue(errors.isEmpty, "\(name): \(errors)")
            if let out, let png = snap?["png"] as? String {
                try Data(base64Encoded: png)?.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
            }
            _ = stage.clear(owner: "test", id: name)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
    }
}
