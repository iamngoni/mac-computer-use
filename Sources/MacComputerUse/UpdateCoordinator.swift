import AppKit
import MacComputerUseCore
import Sparkle

@MainActor
final class UpdateCoordinator: NSObject, SPUUpdaterDelegate {
    private let isConfigured: Bool
    private var pendingInstallHandler: (() -> Void)?
    private var pendingVersion = "update"
    private var retryTimer: Timer?
    private(set) var installationLease: ExclusiveUpdateLease?

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        isConfigured = !feed.isEmpty && !key.isEmpty &&
            ProcessInfo.processInfo.environment["MACCU_DISABLE_UPDATES"] != "1"
        super.init()
        if isConfigured { controller.startUpdater() }
    }

    var canCheckForUpdates: Bool {
        isConfigured && controller.updater.canCheckForUpdates
    }

    var hasPendingInstallation: Bool {
        pendingInstallHandler != nil || installationLease != nil
    }

    func checkForUpdates() {
        guard isConfigured else {
            let alert = NSAlert()
            alert.messageText = "Updates are unavailable in this build"
            alert.informativeText = "Install a signed release build to receive automatic updates."
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        postponeInstall(version: item.displayVersionString, handler: installHandler)
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        postponeInstall(version: item.displayVersionString, handler: immediateInstallHandler)
    }

    private func postponeInstall(version: String, handler: @escaping () -> Void) -> Bool {
        pendingInstallHandler = handler
        pendingVersion = version
        attemptPendingInstall()
        if pendingInstallHandler != nil, retryTimer == nil {
            retryTimer = Timer.scheduledTimer(
                withTimeInterval: 1,
                repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.attemptPendingInstall() }
            }
        }
        return true
    }

    private func attemptPendingInstall() {
        guard installationLease == nil, let handler = pendingInstallHandler else { return }
        guard let lease = ExclusiveUpdateLease.acquire(
            version: pendingVersion,
            keepsMarkerAfterRelease: true
        ) else { return }
        installationLease = lease
        pendingInstallHandler = nil
        retryTimer?.invalidate()
        retryTimer = nil
        handler()
    }
}
