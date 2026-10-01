import AppKit
import XCTest
@testable import MacComputerUseCore

final class CoreContractTests: XCTestCase {
    func testLaunchModePreservesLegacyStdioAndSupportsExplicitModes() {
        XCTAssertEqual(
            macComputerUseLaunchMode(arguments: ["mac-computer-use"], standardInputIsPipe: true),
            .mcp
        )
        XCTAssertEqual(
            macComputerUseLaunchMode(arguments: ["mac-computer-use"], standardInputIsPipe: false),
            .manager
        )
        XCTAssertEqual(
            macComputerUseLaunchMode(arguments: ["mac-computer-use", "mcp"], standardInputIsPipe: false),
            .mcp
        )
        XCTAssertEqual(
            macComputerUseLaunchMode(arguments: ["mac-computer-use", "overlay"], standardInputIsPipe: false),
            .overlay
        )
        XCTAssertEqual(
            macComputerUseLaunchMode(arguments: ["mac-computer-use", "worker", "--session", "x"], standardInputIsPipe: true),
            .worker
        )
        XCTAssertEqual(
            macComputerUseLaunchMode(arguments: ["mac-computer-use", "manager", "--background"], standardInputIsPipe: true),
            .manager
        )
    }

    func testMCPRunsInProcessOnlyOutsideTheAppOrWhenAskedTo() {
        let app = URL(fileURLWithPath: "/Applications/MacComputerUse.app")
        let loose = URL(fileURLWithPath: "/tmp/build/debug")
        XCTAssertFalse(mcpShouldRunInProcess(arguments: ["x", "mcp"], environment: [:], bundleURL: app))
        XCTAssertTrue(mcpShouldRunInProcess(arguments: ["x", "mcp", "--in-process"], environment: [:], bundleURL: app))
        XCTAssertTrue(mcpShouldRunInProcess(arguments: ["x"], environment: ["MACCU_IN_PROCESS": "1"], bundleURL: app))
        XCTAssertTrue(mcpShouldRunInProcess(arguments: ["x"], environment: ["MACCU_DISABLE_MANAGER": "1"], bundleURL: app))
        XCTAssertTrue(mcpShouldRunInProcess(arguments: ["x"], environment: [:], bundleURL: loose))
    }

    func testRelayAnswersLocallyWhileTheServiceIsOff() throws {
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "list_apps"]]
        let stopped = try XCTUnwrap(relayLocalReply(to: call, reason: .stoppedByUser))
        let result = try XCTUnwrap(stopped["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue((toolResultText(result) ?? "").hasPrefix("[stopped_by_user]"))

        let list = try XCTUnwrap(relayLocalReply(to: ["id": 8, "method": "tools/list"], reason: .updating))
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, toolSchemas().count)

        XCTAssertNil(relayLocalReply(to: ["method": "notifications/initialized"], reason: .updating))

        let disconnected = relayDisconnectedReply(id: "a", method: "tools/call")
        let disconnectedResult = try XCTUnwrap(disconnected["result"] as? [String: Any])
        XCTAssertTrue((toolResultText(disconnectedResult) ?? "").hasPrefix("[service_disconnected]"))
        XCTAssertNotNil(relayDisconnectedReply(id: 3, method: "ping")["error"])
    }

    func testClientIdentityKeysSurviveUpdatesButPinUnsignedClients() {
        XCTAssertEqual(
            serviceClientApprovalKey(teamIdentifier: "TEAM123", signingIdentifier: "com.example.app", path: "/A/App.app"),
            "team:TEAM123:com.example.app"
        )
        XCTAssertEqual(
            serviceClientApprovalKey(teamIdentifier: nil, signingIdentifier: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app"),
            "apple:com.apple.Terminal"
        )
        XCTAssertEqual(
            serviceClientApprovalKey(teamIdentifier: nil, signingIdentifier: "a.out-1234", path: "/Users/me/tool"),
            "path:/Users/me/tool"
        )
        XCTAssertEqual(
            outermostApplicationBundle(containingExecutable: "/Applications/Host.app/Contents/Frameworks/Host Helper.app/Contents/MacOS/Host Helper"),
            "/Applications/Host.app"
        )
        XCTAssertNil(outermostApplicationBundle(containingExecutable: "/usr/local/bin/node"))
    }

    func testClientApprovalsPersistAndCanBeRevoked() throws {
        let suite = "mac-computer-use-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClientApprovalStore(defaults: defaults)
        let identity = ServiceClientIdentity(
            key: "team:T:com.example", displayName: "Example", bundleIdentifier: "com.example",
            teamIdentifier: "T", signer: "Developer ID Application: Example (T)", path: "/Applications/Example.app"
        )
        XCTAssertFalse(store.isApproved(identity.key))
        store.approve(identity)
        store.approve(identity)
        XCTAssertTrue(ClientApprovalStore(defaults: defaults).isApproved(identity.key))
        XCTAssertEqual(store.clients.count, 1)
        XCTAssertEqual(store.clients.first?.detail, "Developer ID Application: Example (T)")
        store.revoke(identity.key)
        XCTAssertFalse(store.isApproved(identity.key))
    }

    func testRuntimeDirectoryHonoursOverrideAndKeepsSocketPathShort() {
        let overridden = MacComputerUseRuntime.directory(environment: ["MACCU_RUNTIME_DIR": "/tmp/x"])
        XCTAssertEqual(overridden.path, "/tmp/x")
        XCTAssertEqual(
            MacComputerUseRuntime.stoppedMarkerURL(environment: ["MACCU_RUNTIME_DIR": "/tmp/x"]).path,
            "/tmp/x/stopped-by-user"
        )
        let socket = MacComputerUseRuntime.socketURL(environment: [:]).path
        XCTAssertLessThan(socket.utf8.count, 104, socket)
        XCTAssertTrue(socket.hasSuffix("com.modestnerd.mac-computer-use/service.sock"))
    }

    func testLineReaderSplitsLinesAcrossReads() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        let big = String(repeating: "x", count: 200_000)
        let writer = pair[1]
        let written = expectation(description: "written")
        // The payload exceeds the socket buffer, so write while the reader drains.
        DispatchQueue.global().async {
            _ = writeAll(writer, Data("{\"a\":1}\n{\"b\":\"".utf8))
            _ = writeAll(writer, Data((big + "\"}\n").utf8))
            written.fulfill()
        }
        let reader = LineReader(descriptor: pair[0])
        XCTAssertEqual(decodeJSONLine(try XCTUnwrap(reader.readLine(timeout: 1)))?["a"] as? Int, 1)
        XCTAssertEqual((decodeJSONLine(try XCTUnwrap(reader.readLine(timeout: 1)))?["b"] as? String)?.count, big.count)
        XCTAssertNil(reader.readLine(timeout: 0.05))
        wait(for: [written], timeout: 5)
    }

    func testUpdateGateWaitsForSessionsAndBlocksNewOnesThroughInstallerHandoff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "maccu-update-gate-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        var session: MCPProcessSessionLease? = MCPProcessSessionLease.acquire(in: root)
        XCTAssertNotNil(session)
        XCTAssertNil(ExclusiveUpdateLease.acquire(version: "0.8.0", in: root))

        session = nil
        var update: ExclusiveUpdateLease? = ExclusiveUpdateLease.acquire(
            version: "0.8.0",
            keepsMarkerAfterRelease: true,
            in: root
        )
        XCTAssertNotNil(update)
        XCTAssertNil(MCPProcessSessionLease.acquire(in: root))

        update = nil
        XCTAssertNil(MCPProcessSessionLease.acquire(in: root))
        ExclusiveUpdateLease.recoverStaleMarker(in: root)
        XCTAssertNotNil(MCPProcessSessionLease.acquire(in: root))
    }

    func testClientRegistrationUsesExplicitMCPModeAndNeverOverwritesSilently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "maccu-registration-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: codex.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        let server = URL(fileURLWithPath: "/Applications/MacComputerUse.app/Contents/MacOS/mac-computer-use")

        let service = MCPClientRegistrationService(
            serverExecutableURL: server,
            environment: ["PATH": root.path],
            homeDirectory: root,
            runProcess: { _, _ in
                ProcessResult(
                    status: 0,
                    output: #"{"transport":{"command":"/tmp/old/mac-computer-use","args":[]}}"#,
                    errorOutput: ""
                )
            }
        )

        XCTAssertEqual(
            service.installationArguments(for: .codex),
            ["mcp", "add", "mac-computer-use", "--", server.path, "mcp"]
        )
        XCTAssertEqual(
            service.installationArguments(for: .claude),
            ["mcp", "add", "--scope", "user", "mac-computer-use", "--", server.path, "mcp"]
        )
        guard case .failure(let error) = service.install(.codex, replaceExisting: false) else {
            return XCTFail("A different registration must require an explicit replace action.")
        }
        XCTAssertTrue(error.message.contains("different"))

        let absentService = MCPClientRegistrationService(
            serverExecutableURL: server,
            environment: ["PATH": root.path],
            homeDirectory: root,
            runProcess: { _, _ in
                ProcessResult(
                    status: 1,
                    output: "",
                    errorOutput: "Error: No MCP server named 'mac-computer-use' found."
                )
            }
        )
        XCTAssertEqual(absentService.inspect(.codex), .absent)

        let installableService = MCPClientRegistrationService(
            serverExecutableURL: server,
            environment: ["PATH": root.path],
            homeDirectory: root,
            runProcess: { _, arguments in
                if arguments.prefix(2) == ["mcp", "get"] {
                    return ProcessResult(
                        status: 1,
                        output: "",
                        errorOutput: "Error: No MCP server named 'mac-computer-use' found."
                    )
                }
                return ProcessResult(status: 0, output: "", errorOutput: "")
            }
        )
        guard case .success = installableService.install(.codex, replaceExisting: false) else {
            return XCTFail("An absent registration should install without replacement approval.")
        }
        XCTAssertEqual(
            installableService.copyableInstallationCommand(for: .codex),
            "codex mcp add mac-computer-use -- /Applications/MacComputerUse.app/Contents/MacOS/mac-computer-use mcp"
        )
    }

    func testToolSchemasPreserveExistingContract() {
        let names = toolSchemas().compactMap { $0["name"] as? String }

        XCTAssertEqual(
            names,
            [
                "list_apps",
                "get_app_state",
                "get_desktop_state",
                "desktop_click",
                "desktop_press_key",
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

    func testDesktopSchemasRequireExplicitGlobalInputAndUseAnExclusiveTargetShape() throws {
        let click = try XCTUnwrap(toolSchemas().first { $0["name"] as? String == "desktop_click" })
        let input = try XCTUnwrap(click["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        let permission = try XCTUnwrap(properties["allow_global_input"] as? [String: Any])
        XCTAssertEqual(permission["const"] as? Bool, true)
        XCTAssertEqual(
            desktopActionShapeIsValid(["element_index": 1]),
            true
        )
        XCTAssertEqual(
            desktopActionShapeIsValid(["x": 10.0, "y": 20.0]),
            true
        )
        XCTAssertFalse(
            desktopActionShapeIsValid(["element_index": 1, "x": 10.0, "y": 20.0])
        )
        XCTAssertFalse(desktopActionShapeIsValid(["x": 10.0]))
    }

    func testGlobalInputLeaseIsNonBlockingAndReleasesAfterFailurePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "maccu-global-input-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        var first: GlobalInputLease? = GlobalInputLease.acquire(in: root)
        XCTAssertNotNil(first)
        XCTAssertNil(GlobalInputLease.acquire(in: root))
        first?.release()
        first = nil
        XCTAssertNotNil(GlobalInputLease.acquire(in: root))
    }

    func testDesktopKeyValidationRejectsUnknownModifiersAndKeys() {
        XCTAssertTrue(desktopKeySpecIsKnown("cmd+shift+left"))
        XCTAssertTrue(desktopKeySpecIsKnown("Return"))
        XCTAssertFalse(desktopKeySpecIsKnown("fn+left"))
        XCTAssertFalse(desktopKeySpecIsKnown("not-a-key"))
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
        let bounds = CGRect(x: 0, y: 0, width: 48, height: 48)
        XCTAssertEqual(
            cursorPointerDrawRect(in: bounds),
            CGRect(x: 17.25, y: 2.5, width: 28, height: 28)
        )
        XCTAssertEqual(
            cursorPulseDrawRect(in: bounds, scale: 1),
            CGRect(x: 10, y: 10, width: 28, height: 28)
        )
    }

    func testShippedPointerArtMatchesTheDocumentedCanvasAndHotspot() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assets = try XCTUnwrap(
            AutomationCursorAssets.load(
                resourceRoot: repositoryRoot.appendingPathComponent("Assets", isDirectory: true)
            ),
            "The shipped VirtualCursor assets should load at every scale."
        )
        XCTAssertEqual(assets.pointer.size, AutomationCursorAssets.canvasSize)

        let scale = 4
        let width = Int(AutomationCursorAssets.canvasSize.width) * scale
        let height = Int(AutomationCursorAssets.canvasSize.height) * scale
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        bitmap.size = AutomationCursorAssets.canvasSize
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        assets.pointer.draw(
            in: CGRect(origin: .zero, size: AutomationCursorAssets.canvasSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        func alpha(atPointX x: CGFloat, y: CGFloat) throws -> CGFloat {
            try XCTUnwrap(bitmap.colorAt(x: Int(x * CGFloat(scale)), y: Int(y * CGFloat(scale)))).alphaComponent
        }
        let hotspot = AutomationCursorAssets.pointerHotspot
        // Just inside the apex is solid pointer; just outside it is clear, so the
        // automation coordinate sits on the visible tip rather than in padding.
        XCTAssertGreaterThan(try alpha(atPointX: hotspot.x + 1.25, y: hotspot.y + 1.0), 0.95)
        XCTAssertLessThan(try alpha(atPointX: hotspot.x - 2.5, y: hotspot.y - 2.5), 0.25)
    }

    func testAutomationCursorStaysCompactAndFitsItsPanelWithoutClippingTheGlow() {
        // The pointer should stay near system-cursor scale, not dominate the screen.
        XCTAssertLessThanOrEqual(AutomationCursorAssets.canvasSize.width, 32)
        XCTAssertLessThanOrEqual(AutomationCursorAssets.canvasSize.height, 32)

        let panel = makeAutomationCursorPanel()
        defer { panel.close() }
        let bounds = CGRect(origin: .zero, size: panel.frame.size)
        XCTAssertTrue(bounds.contains(cursorPointerDrawRect(in: bounds)))
        XCTAssertTrue(bounds.contains(cursorPulseDrawRect(in: bounds, scale: 1)))
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

    func testIdleSessionsNeverLookActiveAndClientsGroupHonestly() {
        let summary = { (id: String, name: String, approval: String) in
            ServiceSessionSummary(
                id: id, clientName: name, clientKey: "k-" + name, reportedClientName: nil,
                approval: approval, busy: false, currentApp: nil, active: false
            )
        }
        XCTAssertEqual(
            connectedClientTitles([
                summary("1", "claude", "approved"),
                summary("2", "claude", "approved"),
                summary("3", "ChatGPT", "pending"),
            ]),
            ["ChatGPT (not allowed yet)", "claude · 2 sessions"]
        )
        XCTAssertEqual(connectedClientTitles([]), [])
    }

    func testServiceSweepsOnlyLegacyOverlayFoldersWhoseOwnerExited() {
        let names = [
            "mac-computer-use-overlay-100-aaaa-bbbb",
            "mac-computer-use-overlay-200-cccc-dddd",
            "mac-computer-use-overlay-notapid-eeee",
            "mac-computer-use-update-gate.lock",
            "unrelated",
        ]
        XCTAssertEqual(
            staleLegacyOverlayChannelNames(names, isAlive: { $0 == 200 }),
            ["mac-computer-use-overlay-100-aaaa-bbbb"]
        )
    }

    func testCursorFadesOutOnlyAfterTheIdleDelay() {
        XCTAssertEqual(cursorIdleOpacity(now: 100, lastActivity: 0, active: true), 1)
        XCTAssertEqual(cursorIdleOpacity(now: 7.9, lastActivity: 0, active: false), 1)
        XCTAssertEqual(cursorIdleOpacity(now: 8.0 + 0.45, lastActivity: 0, active: false), 0, accuracy: 0.0001)
        let midway = cursorIdleOpacity(now: 8.0 + 0.225, lastActivity: 0, active: false)
        XCTAssertGreaterThan(midway, 0.2)
        XCTAssertLessThan(midway, 0.8)
        XCTAssertEqual(cursorIdleOpacity(now: 9, lastActivity: 0, active: false, fadeAfter: 30), 1)
    }

    func testReducedMotionPulseNeverScales() {
        XCTAssertEqual(reducedMotionCursorPulse(now: 10, clickStartedAt: 10, cancelling: false).scale, 1)
        XCTAssertEqual(reducedMotionCursorPulse(now: 10.1, clickStartedAt: 10, cancelling: false).opacity, 1)
        XCTAssertEqual(reducedMotionCursorPulse(now: 11, clickStartedAt: 10, cancelling: false).opacity, 0.8)
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
