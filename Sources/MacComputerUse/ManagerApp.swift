import AppKit
import MacComputerUseCore

@MainActor
final class ManagerApplicationController: NSObject, NSApplicationDelegate {
    private var managerLease: ManagerProcessLease?
    private var statusCoordinator: AutomationStatusBarCoordinator?
    private var setupWindowController: SetupWindowController?
    private var updateCoordinator: UpdateCoordinator?
    private var serviceHost: ServiceHost?
    private var serviceStopped = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchedInBackground = CommandLine.arguments.contains("--background")
        if launchedInBackground, MacComputerUseRuntime.userStoppedService() {
            // A relay must not bring the service back after the user quit it.
            NSApp.terminate(nil)
            return
        }
        guard let lease = ManagerProcessLease.acquire() else {
            NSApp.terminate(nil)
            return
        }
        managerLease = lease
        if !launchedInBackground {
            // Opening the app is the user turning automation back on.
            MacComputerUseRuntime.clearStoppedByUser()
        }
        ExclusiveUpdateLease.recoverStaleMarker()
        NSApp.setActivationPolicy(.accessory)

        let executableURL = Bundle.main.executableURL ?? URL(
            fileURLWithPath: CommandLine.arguments[0]
        )
        let host = ServiceHost(executableURL: executableURL)
        serviceHost = host
        do {
            try host.start()
        } catch {
            NSLog("Mac Computer Use service failed to start: \(error)")
        }

        let setup = SetupWindowController(executableURL: executableURL, serviceHost: host)
        let updater = UpdateCoordinator(
            canInstall: { [weak host] in host?.hasBusySession != true },
            prepareForInstall: { [weak self] in self?.stopService(userInitiated: false) }
        )
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
            quit: { [weak self] in self?.quitFromMenu() },
            isPaused: { [weak host] in host?.isPaused == true },
            setPaused: { [weak host] paused in host?.setPaused(paused) },
            sessions: { [weak host] in host?.sessionSummaries ?? [] }
        )
        let coordinator = AutomationStatusBarCoordinator(
            cursorImage: cursor,
            actions: actions
        )
        statusCoordinator = coordinator
        host.onChange = { [weak self] in self?.refreshStatusItem() }
        refreshStatusItem()

        let defaults = UserDefaults.standard
        if !launchedInBackground && !defaults.bool(forKey: "hasPresentedSetup") {
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

    func applicationWillTerminate(_ notification: Notification) {
        stopService(userInitiated: false)
    }

    /// Quit from the menu: stop every session, remove every overlay, and keep
    /// automation off until the user opens the app again.
    private func quitFromMenu() {
        stopService(userInitiated: true)
        NSApp.terminate(nil)
    }

    private func stopService(userInitiated: Bool) {
        guard !serviceStopped else { return }
        serviceStopped = true
        serviceHost?.shutdown(userInitiated: userInitiated)
    }

    private func refreshStatusItem() {
        statusCoordinator?.update(
            currentApp: nil,
            controlledApps: serviceHost?.activeControlledApps ?? []
        )
        setupWindowController?.refreshClientsIfVisible()
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
