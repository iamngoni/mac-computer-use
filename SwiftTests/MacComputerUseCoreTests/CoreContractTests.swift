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
        let pressed = cursorPulsePresentation(
                now: 10,
                clickStartedAt: 10,
                cancelling: false
            )
        XCTAssertEqual(pressed.scale, 1, accuracy: 0.001)
        XCTAssertEqual(pressed.opacity, 1, accuracy: 0.001)
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

    func testCursorMotionSmoothlyConvergesWithoutChangingTheTarget() {
        var motion = CursorMotionState()
        XCTAssertEqual(
            motion.advance(toward: CGPoint(x: 10, y: 20), deltaTime: 1.0 / 60.0),
            CGPoint(x: 10, y: 20)
        )

        let firstFrame = motion.advance(
            toward: CGPoint(x: 210, y: 120),
            deltaTime: 1.0 / 60.0
        )
        XCTAssertGreaterThan(firstFrame.x, 10)
        XCTAssertLessThan(firstFrame.x, 210)
        XCTAssertGreaterThan(firstFrame.y, 20)
        XCTAssertLessThan(firstFrame.y, 120)

        var finalFrame = firstFrame
        for _ in 0..<30 {
            finalFrame = motion.advance(
                toward: CGPoint(x: 210, y: 120),
                deltaTime: 1.0 / 60.0
            )
        }
        XCTAssertEqual(finalFrame.x, 210, accuracy: 0.25)
        XCTAssertEqual(finalFrame.y, 120, accuracy: 0.25)
    }

    func testCursorMotionIsStableAcrossRefreshRates() {
        var sixtyHertz = CursorMotionState()
        var oneTwentyHertz = CursorMotionState()
        _ = sixtyHertz.advance(toward: .zero, deltaTime: 1.0 / 60.0)
        _ = oneTwentyHertz.advance(toward: .zero, deltaTime: 1.0 / 120.0)

        var sixtyPosition = CGPoint.zero
        var oneTwentyPosition = CGPoint.zero
        for _ in 0..<6 {
            sixtyPosition = sixtyHertz.advance(
                toward: CGPoint(x: 500, y: 250),
                deltaTime: 1.0 / 60.0
            )
        }
        for _ in 0..<12 {
            oneTwentyPosition = oneTwentyHertz.advance(
                toward: CGPoint(x: 500, y: 250),
                deltaTime: 1.0 / 120.0
            )
        }
        XCTAssertEqual(sixtyPosition.x, oneTwentyPosition.x, accuracy: 0.001)
        XCTAssertEqual(sixtyPosition.y, oneTwentyPosition.y, accuracy: 0.001)
    }

    func testMenuBarPresentationCountsAndNamesControlledApps() {
        let presentation = menuBarPresentation(
            currentApp: "Google Chrome",
            controlledApps: ["Finder", "Google Chrome"]
        )

        XCTAssertEqual(presentation.buttonTitle, "2")
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Mac Computer Use active: 2 apps"
        )
        XCTAssertEqual(presentation.statusTitle, "Active · 2 apps")
        XCTAssertEqual(
            presentation.controlledAppTitles,
            ["Finder", "Google Chrome"]
        )

        let statusImage = makeAutomationStatusImage()
        XCTAssertEqual(statusImage.size, NSSize(width: 30, height: 18))
    }

    func testMenuBarPresentationUsesTheSingleAppName() {
        let presentation = menuBarPresentation(
            currentApp: "Safari",
            controlledApps: []
        )

        XCTAssertEqual(presentation.buttonTitle, "1")
        XCTAssertEqual(presentation.accessibilityLabel, "Mac Computer Use active: Safari")
        XCTAssertEqual(presentation.statusTitle, "Active · Safari")
        XCTAssertEqual(presentation.controlledAppTitles, ["Safari"])
    }

    func testActiveOverlayAppsAggregateOnlyLiveValidatedSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "maccu-menu-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        func writeSession(
            ownerPID: Int,
            agentPID: Int,
            channelID: String,
            apps: [String]
        ) throws {
            let directory = root.appendingPathComponent(
                "mac-computer-use-overlay-\(ownerPID)-\(channelID)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let ready: [String: Any] = [
                "owner_pid": ownerPID,
                "agent_pid": agentPID,
                "channel_id": channelID,
            ]
            let state: [String: Any] = [
                "pid": ownerPID,
                "controlled_apps": apps,
            ]
            try JSONSerialization.data(withJSONObject: ready).write(
                to: directory.appendingPathComponent("ready.json")
            )
            try JSONSerialization.data(withJSONObject: state).write(
                to: directory.appendingPathComponent("state.json")
            )
        }

        try writeSession(ownerPID: 101, agentPID: 201, channelID: "live-a", apps: ["Safari"])
        try writeSession(ownerPID: 102, agentPID: 202, channelID: "live-b", apps: ["Finder", "Safari"])
        try writeSession(ownerPID: 103, agentPID: 203, channelID: "stale", apps: ["Ghost"])

        let apps = activeOverlayControlledApps(in: root) { pid in
            [101, 102, 201, 202].contains(Int(pid))
        }
        XCTAssertEqual(apps, ["Finder", "Safari"])
    }

    func testMenuBarLeaseAllowsOneOwnerAndCleanTakeover() throws {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "maccu-menu-lock-test-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: lockURL) }

        var firstLease: ExclusiveFileLease? = ExclusiveFileLease.acquire(at: lockURL)
        XCTAssertNotNil(firstLease)
        XCTAssertNil(ExclusiveFileLease.acquire(at: lockURL))

        firstLease = nil
        XCTAssertNotNil(ExclusiveFileLease.acquire(at: lockURL))
    }

    func testExactWindowAuthorizationRequiresIdentityResolver() {
        XCTAssertTrue(canAuthorizeExactWindow(identityResolverAvailable: true))
        XCTAssertFalse(canAuthorizeExactWindow(identityResolverAvailable: false))
    }

    func testOpenAppSuccessRequiresResolvedApplicationIdentity() {
        let completion = completeOpenAppLaunch(
            spec: "Ghost App",
            launchResult: (ok: true, msg: "Launched Ghost App."),
            timeout: 0,
            resolver: { nil }
        )

        XCTAssertNil(completion.app)
        XCTAssertEqual(completion.result["isError"] as? Bool, true)
    }

    func testBoundedStateSearchDoesNotConfuseTruncationWithAbsence() {
        let result = boundedDepthFirstSearch(
            roots: [0],
            maxNodes: 5_000,
            children: { node in node < 5_999 ? [node + 1] : [] },
            matches: { $0 == 5_500 }
        )

        XCTAssertEqual(result, .truncated)
    }

    func testUnavailableScreenshotDoesNotClaimInputAuthority() {
        let note = unavailableSnapshotNote(screenRecordingGranted: false)

        XCTAssertTrue(note.contains("read-only"))
        XCTAssertTrue(note.contains("not authorized for input"))
        XCTAssertFalse(note.contains("fully usable"))
        XCTAssertFalse(note.contains("global screen points"))
    }

    func testJSONWireTypesDoNotCrossCastBooleansAndNumbers() throws {
        let data = Data(#"{"boolean":true,"integer":1,"fraction":1.5}"#.utf8)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(strictJSONInteger(object["boolean"]))
        XCTAssertNil(strictJSONDouble(object["boolean"]))
        XCTAssertNil(strictJSONBoolean(object["integer"]))
        XCTAssertEqual(strictJSONInteger(object["integer"]), 1)
        XCTAssertEqual(strictJSONDouble(object["fraction"]), 1.5)
        XCTAssertEqual(strictJSONBoolean(object["boolean"]), true)
    }
}
