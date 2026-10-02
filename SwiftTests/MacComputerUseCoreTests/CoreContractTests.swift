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

    func testClientIdentityKeysSurviveUpdatesButPinUnverifiedClients() {
        XCTAssertEqual(
            serviceClientApprovalKey(teamIdentifier: "TEAM123", signingIdentifier: "com.example.app", path: "/A/App.app",
                                     teamVerified: true, appleVerified: false),
            "team:TEAM123:com.example.app"
        )
        XCTAssertEqual(
            serviceClientApprovalKey(teamIdentifier: nil, signingIdentifier: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app",
                                     teamVerified: false, appleVerified: true),
            "apple:com.apple.Terminal"
        )
        // A self-signed binary that merely claims Terminal's identifier must
        // not inherit Terminal's approval.
        XCTAssertEqual(
            serviceClientApprovalKey(teamIdentifier: nil, signingIdentifier: "com.apple.Terminal", path: "/tmp/Fake.app",
                                     teamVerified: false, appleVerified: false),
            "path:/tmp/Fake.app"
        )
        XCTAssertEqual(
            serviceClientApprovalKey(teamIdentifier: "TEAM123", signingIdentifier: "com.example.app", path: "/tmp/Fake.app",
                                     teamVerified: false, appleVerified: false),
            "path:/tmp/Fake.app"
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
        let store = ClientApprovalStore(defaults: defaults, anchor: nil)
        let identity = ServiceClientIdentity(
            key: "team:T:com.example", displayName: "Example", bundleIdentifier: "com.example",
            teamIdentifier: "T", signer: "Developer ID Application: Example (T)", path: "/Applications/Example.app",
            requirement: "identifier \"com.example\" and anchor apple generic"
        )
        XCTAssertFalse(store.isApproved(identity.key))
        store.approve(identity)
        store.approve(identity)
        XCTAssertTrue(ClientApprovalStore(defaults: defaults, anchor: nil).isApproved(identity.key))
        XCTAssertEqual(store.clients.count, 1)
        XCTAssertEqual(store.clients.first?.detail, "Developer ID Application: Example (T)")
        // Approval also requires the client's code to still satisfy the stored requirement.
        XCTAssertTrue(store.isApproved(identity, satisfies: { $0 == identity.requirement }))
        XCTAssertFalse(store.isApproved(identity, satisfies: { _ in false }))
        store.revoke(identity.key)
        XCTAssertFalse(store.isApproved(identity.key))
    }

    func testAnchoredApprovalsIgnoreForgedOrRolledBackPreferences() throws {
        final class MemoryAnchor: ApprovalAnchor {
            var digest: Data?
            func record(_ data: Data) { digest = sha256(data) }
            func matches(_ data: Data) -> Bool { digest == sha256(data) }
        }
        let suite = "mac-computer-use-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ClientApprovalStore(defaults: defaults, anchor: MemoryAnchor())
        func identity(_ path: String) -> ServiceClientIdentity {
            ServiceClientIdentity(key: "path:\(path)", displayName: path, bundleIdentifier: nil, teamIdentifier: nil,
                                  signer: nil, path: path, requirement: "cdhash H\"00\"")
        }
        store.approve(identity("/a"))
        store.approve(identity("/b"))
        let withB = try XCTUnwrap(defaults.data(forKey: "approvedServiceClients"))
        store.revoke("path:/b")
        XCTAssertFalse(store.isApproved("path:/b"))
        // Writing the older list back would restore the revoked client.
        defaults.set(withB, forKey: "approvedServiceClients")
        XCTAssertFalse(store.isApproved("path:/b"))
        XCTAssertEqual(store.clients, [])
        // A forged list is ignored the same way.
        defaults.set(try JSONEncoder().encode([ApprovedServiceClient(
            key: "path:/evil", displayName: "Evil", detail: "", approvedAt: Date(), requirement: nil
        )]), forKey: "approvedServiceClients")
        XCTAssertFalse(store.isApproved("path:/evil"))
    }

    func testTestAutoApprovalNeverAppliesToALaunchServicesService() {
        let env = ["MACCU_RUNTIME_DIR": "/tmp/x", "MACCU_TEST_AUTO_APPROVE": "1"]
        XCTAssertTrue(testAutoApprovalAllowed(environment: env, servicePID: 10, responsiblePID: { _ in 99 }))
        XCTAssertFalse(testAutoApprovalAllowed(environment: env, servicePID: 10, responsiblePID: { $0 }))
        XCTAssertFalse(testAutoApprovalAllowed(environment: ["MACCU_TEST_AUTO_APPROVE": "1"], servicePID: 10, responsiblePID: { _ in 99 }))
    }

    func testWorkersNeverInheritLoaderOverrides() {
        let environment = workerEnvironment(from: [
            "HOME": "/Users/me", "PATH": "/usr/bin", "LC_ALL": "en_US.UTF-8",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "MACCU_CURSOR_PACE": "off",
            "MACCU_TEST_AUTO_APPROVE": "1", "OPENAI_API_KEY": "secret",
        ])
        XCTAssertEqual(environment, [
            "HOME": "/Users/me", "PATH": "/usr/bin", "LC_ALL": "en_US.UTF-8", "MACCU_CURSOR_PACE": "off",
        ])
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
                "point_at",
                "annotate",
                "clear_annotations",
                "ask_user",
                "pick_element",
                "wait_for_user",
                "guide",
                "say",
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
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 80)
        XCTAssertEqual(
            cursorPointerDrawRect(in: bounds),
            CGRect(x: 33.25, y: 18.5, width: 28, height: 28)
        )
        XCTAssertEqual(
            cursorPulseDrawRect(in: bounds, scale: 1),
            CGRect(x: 26, y: 26, width: 28, height: 28)
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

        // Mid-flight the arrow can turn any way and swell 1.3x around its
        // hotspot; the farthest canvas corner must still fit in the panel.
        let canvas = AutomationCursorAssets.canvasSize
        let hotspot = AutomationCursorAssets.pointerHotspot
        let reach = [
            CGPoint(x: 0, y: 0), CGPoint(x: canvas.width, y: 0),
            CGPoint(x: 0, y: canvas.height), CGPoint(x: canvas.width, y: canvas.height),
        ].map { hypot($0.x - hotspot.x, $0.y - hotspot.y) }.max()! * 1.3
        XCTAssertLessThanOrEqual(reach, min(bounds.width, bounds.height) / 2)
    }

    func testArcFlightLandsExactlyAndFacesItsDirectionOfTravel() {
        let flight = CursorFlight(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 800, y: 0), start: 10, pace: .teach
        )
        XCTAssertEqual(flight.duration, 1.0, accuracy: 0.0001)
        let start = flight.sample(at: 10)
        XCTAssertEqual(start.point, CGPoint(x: 0, y: 0))
        XCTAssertEqual(start.rotation, 0, accuracy: 0.0001)
        let middle = flight.sample(at: 10.5)
        XCTAssertEqual(middle.point.x, 400, accuracy: 0.5)
        XCTAssertGreaterThan(middle.point.y, 0, "the path arcs upward")
        XCTAssertEqual(middle.scale, 1.3, accuracy: 0.0001)
        // Flying right, the up-left resting arrow turns clockwise to face +x.
        XCTAssertEqual(middle.rotation, -.pi * 3 / 4, accuracy: 0.01)
        let landed = flight.sample(at: 11.2)
        XCTAssertEqual(landed, CursorFlight.Sample(point: CGPoint(x: 800, y: 0), rotation: 0, scale: 1, finished: true))
    }

    func testFlightPaceKeepsActionsQuickAndSkipsTinyHops() {
        XCTAssertEqual(cursorFlightDuration(distance: 3, pace: .act), 0)
        XCTAssertEqual(cursorFlightDuration(distance: 100, pace: .act), 0.18, accuracy: 0.0001)
        XCTAssertEqual(cursorFlightDuration(distance: 5000, pace: .act), 0.5, accuracy: 0.0001)
        XCTAssertEqual(cursorFlightDuration(distance: 100, pace: .teach), 0.6, accuracy: 0.0001)
        XCTAssertEqual(cursorFlightDuration(distance: 5000, pace: .teach), 1.4, accuracy: 0.0001)
        XCTAssertEqual(cursorFlightDuration(distance: 400, pace: .act, multiplier: 0), 0)
        XCTAssertEqual(cursorPaceMultiplier(environment: ["MACCU_CURSOR_PACE": "showcase"]), 2)
        XCTAssertEqual(cursorPaceMultiplier(environment: ["MACCU_CURSOR_PACE": "off"]), 0)
        XCTAssertEqual(cursorPaceMultiplier(environment: [:]), 1)
    }

    func testCursorCuesDescribeTheActionAndStaySmall() {
        XCTAssertEqual(cursorBadgeSymbol(forStatus: "Typing"), "keyboard")
        XCTAssertEqual(cursorBadgeSymbol(forStatus: "Scrolling down"), "arrow.up.and.down")
        XCTAssertEqual(cursorBadgeSymbol(forStatus: "Pressing cmd+t"), "command")
        XCTAssertNil(cursorBadgeSymbol(forStatus: "Clicking"))
        XCTAssertEqual(cursorShakeOffset(now: 5, startedAt: nil), 0)
        XCTAssertEqual(cursorShakeOffset(now: 5.5, startedAt: 5), 0)
        XCTAssertLessThanOrEqual(abs(cursorShakeOffset(now: 5.03, startedAt: 5)), 4)
        XCTAssertEqual(cursorCountdownRemaining(now: 1, start: 0, duration: 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(cursorCountdownRemaining(now: 3, start: 0, duration: 2), 0)
        XCTAssertEqual(
            cursorIdentityColorIndex(forClientKey: "team:A:x"),
            cursorIdentityColorIndex(forClientKey: "team:A:x")
        )
        XCTAssertTrue((0..<cursorIdentityPalette.count).contains(cursorIdentityColorIndex(forClientKey: "k")))
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

    func testRiskyActionsAreRecognisedByWholeWords() {
        XCTAssertEqual(riskyActionPhrase(["Send"]), "send")
        XCTAssertEqual(riskyActionPhrase([nil, "Move to Trash"]), "move to trash")
        XCTAssertEqual(riskyActionPhrase(["Place Order"]), "place order")
        XCTAssertNil(riskyActionPhrase(["Sender details", "Postcode", "Reload"]))
        XCTAssertNil(riskyActionPhrase([nil, ""]))
        XCTAssertEqual(riskyConfirmationDelay(environment: [:]), 2)
        XCTAssertEqual(riskyConfirmationDelay(environment: ["MACCU_RISKY_CONFIRM_MS": "0"]), 0)
        XCTAssertEqual(riskyConfirmationDelay(environment: ["MACCU_RISKY_CONFIRM_MS": "50000"]), 10)
    }

    func testAgentsYieldOnlyWhenTheUserIsActiveInTheSameApp() {
        XCTAssertTrue(shouldYieldToUser(secondsSinceInput: 0.2, targetIsFrontmost: true))
        XCTAssertFalse(shouldYieldToUser(secondsSinceInput: 0.2, targetIsFrontmost: false))
        XCTAssertFalse(shouldYieldToUser(secondsSinceInput: 5, targetIsFrontmost: true))
    }

    func testInteractionToolsRefuseWithoutTheService() {
        for name in ["point_at", "annotate", "clear_annotations", "ask_user", "pick_element", "wait_for_user", "say"] {
            let result = dispatchTool(name, ["app": "Finder", "question": "q", "options": ["a", "b"], "instruction": "i", "text": "t"])
            XCTAssertEqual(result["isError"] as? Bool, true, name)
            XCTAssertTrue((toolResultText(result) ?? "").hasPrefix("[requires_service]"), name)
        }
    }

    func testElementIndexesAcceptIntegersOrIntegerStrings() {
        XCTAssertEqual(parseElementIndex("12") ?? nil, 12)
        XCTAssertEqual(parseElementIndex(NSNumber(value: 7)) ?? nil, 7)
        XCTAssertEqual(parseElementIndex(nil), .some(nil))
        XCTAssertEqual(parseElementIndex("-1"), .none)
        XCTAssertEqual(parseElementIndex(true), .none)
    }

    func testToursRoundTripAndMatchElementsBySemanticsNotPixels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maccu-tours-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let locator = TourLocator(
            bundleID: "com.example.mail", appName: "Mail", windowTitle: "Inbox",
            role: "AXButton", subrole: nil, title: "Archive", description: nil, identifier: nil
        )
        let tour = TourFile(name: "Archive mail", title: "Archive an email", createdAt: Date(timeIntervalSince1970: 0),
                            steps: [TourStep(instruction: "Click Archive", locator: locator)])
        let url = try TourStore.save(tour, in: directory)
        XCTAssertEqual(url.lastPathComponent, "Archive-mail.json")
        XCTAssertEqual(TourStore.all(in: directory), [tour])
        XCTAssertNil(TourStore.fileName(for: "../../"))
        XCTAssertEqual(TourStore.fileName(for: "a/b c"), "ab-c.json")

        let archive = TourCandidate(role: "AXButton", subrole: nil, title: "Archive", description: nil, identifier: nil)
        let delete = TourCandidate(role: "AXButton", subrole: nil, title: "Delete", description: nil, identifier: nil)
        XCTAssertTrue(tourCandidate(archive, matches: locator))
        XCTAssertFalse(tourCandidate(delete, matches: locator))
        var byIdentifier = locator
        byIdentifier.identifier = "archive-button"
        XCTAssertTrue(tourCandidate(
            TourCandidate(role: "AXButton", subrole: nil, title: "Archiver", description: nil, identifier: "archive-button"),
            matches: byIdentifier
        ))
        XCTAssertFalse(tourCandidate(
            TourCandidate(role: "AXButton", subrole: nil, title: "Archive", description: nil, identifier: "other"),
            matches: byIdentifier
        ))
    }

    func testAgentPreviewKeepsTheWindowShapeWithinItsCorner() {
        XCTAssertEqual(agentCamPreviewSize(for: CGSize(width: 1200, height: 800)), CGSize(width: 300, height: 200))
        XCTAssertEqual(agentCamPreviewSize(for: CGSize(width: 800, height: 1600)), CGSize(width: 100, height: 200))
        XCTAssertEqual(agentCamPreviewSize(for: CGSize(width: 200, height: 100)), CGSize(width: 200, height: 100))
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
