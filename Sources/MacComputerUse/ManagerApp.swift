import AppKit
import MacComputerUseCore

@MainActor
final class ManagerApplicationController: NSObject, NSApplicationDelegate {
    private var managerLease: ManagerProcessLease?
    private var terminationLease: ExclusiveUpdateLease?
    private var statusCoordinator: AutomationStatusBarCoordinator?
    private var refreshTimer: Timer?
    private var setupWindowController: SetupWindowController?
    private var updateCoordinator: UpdateCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let lease = ManagerProcessLease.acquire() else {
            NSApp.terminate(nil)
            return
        }
        managerLease = lease
        ExclusiveUpdateLease.recoverStaleMarker()
        NSApp.setActivationPolicy(.accessory)

        let executableURL = Bundle.main.executableURL ?? URL(
            fileURLWithPath: CommandLine.arguments[0]
        )
        let setup = SetupWindowController(executableURL: executableURL)
        let updater = UpdateCoordinator()
        setupWindowController = setup
        updateCoordinator = updater

        let cursor = AutomationCursorAssets.load()?.pointer ?? NSImage(
            systemSymbolName: "cursorarrow",
            accessibilityDescription: "Mac Computer Use"
        ) ?? NSImage(size: NSSize(width: 18, height: 18))
        let actions = AutomationStatusBarActions(
            version: macComputerUseVersion(),
            setup: { [weak setup] in setup?.showSetup() },
            showPermissions: { [weak setup] in setup?.showPermissions() },
            checkForUpdates: { [weak updater] in updater?.checkForUpdates() },
            canCheckForUpdates: { [weak updater] in updater?.canCheckForUpdates == true },
            quit: { NSApp.terminate(nil) }
        )
        let coordinator = AutomationStatusBarCoordinator(
            cursorImage: cursor,
            actions: actions
        )
        statusCoordinator = coordinator
        coordinator.update(currentApp: nil, controlledApps: [])
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(refreshStatusItem),
            userInfo: nil,
            repeats: true
        )

        let defaults = UserDefaults.standard
        if !CommandLine.arguments.contains("--background") &&
            !defaults.bool(forKey: "hasPresentedSetup") {
            defaults.set(true, forKey: "hasPresentedSetup")
            setup.showSetup()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        setupWindowController?.showSetup()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard updateCoordinator?.hasPendingInstallation == true else { return .terminateNow }
        if updateCoordinator?.installationLease != nil { return .terminateNow }
        guard let lease = ExclusiveUpdateLease.acquire(version: "manager-quit") else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Mac Computer Use is still active"
            alert.informativeText = "Disconnect the active MCP clients before quitting or installing an update."
            alert.runModal()
            return .terminateCancel
        }
        terminationLease = lease
        return .terminateNow
    }

    @objc private func refreshStatusItem() {
        statusCoordinator?.update(currentApp: nil, controlledApps: [])
    }
}

@MainActor
func runMacComputerUseManager() -> Never {
    let application = NSApplication.shared
    let controller = ManagerApplicationController()
    application.delegate = controller
    application.run()
    exit(0)
}
