import AppKit
import XCTest
@testable import MacComputerUseCore

/// Drives buddy mode, a flight trail, the magnifier and captions on the real
/// screen and saves screenshots. Opt in with MACCU_LIVE_VISUAL_TESTS=1.
@MainActor
final class CompanionLiveTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func shoot(_ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["MACCU_TEMPLATE_PNG_DIR"] else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "\(dir)/\(name).png"]
        try task.run()
        task.waitUntilExit()
    }

    func testCompanionSurfacesAppearOnScreen() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACCU_LIVE_VISUAL_TESTS"] == "1")
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets")
        let assets = try XCTUnwrap(AutomationCursorAssets.load(resourceRoot: root))
        let presenter = ServiceOverlayPresenter(assets: assets, captureVisible: true)
        let screen = cocoaRectToQuartzRect(NSScreen.main!.visibleFrame)
        let now = CACurrentMediaTime()

        // A flight across the screen leaves a trail.
        presenter.update(sessionID: "s", state: ["controlling": false, "lingerUntil": now + 6, "status": "",
                                                 "cursor": [Double(screen.minX + 300), Double(screen.minY + 300)], "cursor_pace": "act"])
        spin(0.4)
        presenter.update(sessionID: "s", state: ["controlling": false, "lingerUntil": now + 6, "status": "",
                                                 "cursor": [Double(screen.minX + 900), Double(screen.minY + 420)], "cursor_pace": "teach"])
        spin(0.45)
        try shoot("trail")
        spin(1.2)
        presenter.buddy(sessionID: "s", follow: nil, thinking: 5, emote: .celebrate)
        spin(0.3)
        try shoot("celebrate")
        spin(1.0)
        try shoot("thinking")

        // Magnify the clock area of the menu bar and caption a sentence.
        let primary = primaryScreen().frame
        presenter.magnify(sessionID: "s", region: CGRect(x: primary.width - 220, y: 4, width: 90, height: 20), zoom: 3, label: "The clock", duration: 6)
        presenter.captions.start("Here is the clock, right in the menu bar, where it always lives.")
        presenter.captions.word(NSRange(location: 12, length: 5))
        spin(1.5)
        try shoot("magnify")
        presenter.captions.end()
        presenter.removeAll()
        spin(0.5)
    }

    func testCardsAndTimelineAppearOnScreen() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MACCU_LIVE_VISUAL_TESTS"] == "1")
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Assets")
        let presenter = ServiceOverlayPresenter(assets: try XCTUnwrap(AutomationCursorAssets.load(resourceRoot: root)), captureVisible: true)
        let previousTint = CompanionPreferences.cursorTint, previousScale = CompanionPreferences.cursorScale
        CompanionPreferences.cursorTint = "pink"
        CompanionPreferences.cursorScale = 1.5
        defer { CompanionPreferences.cursorTint = previousTint; CompanionPreferences.cursorScale = previousScale }
        let screen = cocoaRectToQuartzRect(NSScreen.main!.visibleFrame)
        presenter.setIdentity(sessionID: "s", name: "Claude", colorIndex: 1)
        presenter.update(sessionID: "s", state: ["controlling": false, "lingerUntil": CACurrentMediaTime() + 8, "status": "",
                                                 "cursor": [Double(screen.midX), Double(screen.midY)], "cursor_pace": "act"])
        presenter.showTimeline(sessionID: "s", steps: ["Open Settings", "Choose Privacy", "Turn on Location", "Close the window"], current: 1, manual: false) { _ in }
        presenter.job(sessionID: "s", id: "a", job: JobState(title: "Renaming 40 photos", step: "IMG_0123 → Beach-01.jpg", progress: 0.62, state: "running"))
        presenter.job(sessionID: "s", id: "b", job: JobState(title: "Research: best standing desks", step: "Reading 6 reviews", progress: nil, state: "running"))
        let card = SuggestionCard(agent: "Claude", title: "Want me to tidy your Downloads?", body: "There are 212 files older than 30 days. I can sort them into folders by type.",
                                  symbol: "wand.and.stars", actions: ["Tidy up", "Not now"], captureVisible: true) { _ in }
        spin(1.2)
        try shoot("cards")
        card.finish(nil)
        presenter.removeAll()
        spin(0.4)
    }
}
