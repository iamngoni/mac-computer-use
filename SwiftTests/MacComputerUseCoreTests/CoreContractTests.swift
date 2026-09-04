import AppKit
import XCTest
@testable import MacComputerUseCore

final class CoreContractTests: XCTestCase {
    func testToolSchemasPreserveExistingContract() {
        let names = toolSchemas().compactMap { $0["name"] as? String }

        XCTAssertEqual(
            names,
            [
                "list_apps",
                "get_app_state",
                "click",
                "type_text",
                "press_key",
                "scroll",
                "set_value",
                "drag",
                "perform_secondary_action",
                "select_text",
                "open_app",
                "navigate",
                "list_windows",
                "verify_state",
                "set_window_frame",
                "invoke_menu",
                "health_report",
            ]
        )
    }

    func testAutomationCursorPanelIsSmallNonActivatingAndInputTransparent() {
        let panel = makeAutomationCursorPanel()
        defer { panel.close() }

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertLessThanOrEqual(panel.frame.width, 96)
        XCTAssertLessThanOrEqual(panel.frame.height, 96)
        XCTAssertEqual(panel.level, .screenSaver)
    }

    func testClickSchemaDoesNotExposeGlobalHardwarePointerMode() throws {
        let click = try XCTUnwrap(toolSchemas().first { $0["name"] as? String == "click" })
        let input = try XCTUnwrap(click["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let method = try XCTUnwrap(properties["click_method"] as? [String: Any])
        let methods = try XCTUnwrap(method["enum"] as? [String])

        XCTAssertFalse(methods.contains("global"))
    }

    func testQuartzToCocoaConversionSupportsDisplaysAroundPrimary() {
        XCTAssertEqual(
            quartzPointToCocoa(CGPoint(x: -320, y: -120), primaryDisplayHeight: 900),
            CGPoint(x: -320, y: 1020)
        )
        XCTAssertEqual(
            quartzPointToCocoa(CGPoint(x: 1400, y: 1200), primaryDisplayHeight: 900),
            CGPoint(x: 1400, y: -300)
        )
    }

    func testAutomationCursorRemainsVisibleAfterActionLingerEnds() {
        let presentation = overlayPresentation(
            controlling: false,
            lingerUntil: 10,
            now: 20,
            captureHidden: false,
            hasCursor: true
        )

        XCTAssertFalse(presentation.showTransientOverlay)
        XCTAssertTrue(presentation.showCursor)
    }

    func testCursorAssetGeometryAlignsPointerHotspotToAutomationCoordinate() {
        let bounds = CGRect(x: 0, y: 0, width: 72, height: 72)
        XCTAssertEqual(
            cursorPointerDrawRect(in: bounds),
            CGRect(x: 24, y: 7, width: 36, height: 36)
        )
        XCTAssertEqual(
            cursorPulseDrawRect(in: bounds, scale: 1),
            CGRect(x: 18, y: 18, width: 36, height: 36)
        )
    }

    func testCursorAssetClickMotionUsesAuthoredCompressionAndReboundTiming() {
        XCTAssertEqual(
            cursorPulsePresentation(
                now: 10,
                clickStartedAt: 10,
                cancelling: false
            ).scale,
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            cursorPulsePresentation(
                now: 10.07,
                clickStartedAt: 10,
                cancelling: false
            ).scale,
            0.76,
            accuracy: 0.001
        )
        XCTAssertEqual(
            cursorPulsePresentation(
                now: 10.23,
                clickStartedAt: 10,
                cancelling: false
            ).scale,
            1.24,
            accuracy: 0.001
        )
    }

    func testMenuBarPresentationNamesCurrentAndSessionApps() {
        let presentation = menuBarPresentation(
            currentApp: "Google Chrome",
            controlledApps: ["Finder", "Google Chrome"]
        )

        XCTAssertEqual(presentation.buttonTitle, "")
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Mac Computer Use active: Google Chrome"
        )
        XCTAssertEqual(presentation.statusTitle, "Active · Google Chrome")
        XCTAssertEqual(
            presentation.controlledAppTitles,
            ["Finder", "Google Chrome"]
        )

        let appIcon = NSImage(size: NSSize(width: 32, height: 32))
        let statusImage = makeAutomationStatusImage(appIcon: appIcon)
        XCTAssertEqual(statusImage.size, NSSize(width: 52, height: 18))
    }
}
