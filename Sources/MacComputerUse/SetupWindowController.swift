import AppKit
import MacComputerUseCore
import SwiftUI

/// Hosts the SwiftUI setup view (SetupView.swift) in a window with a
/// transparent title bar. It follows the system appearance;
/// MACCU_APPEARANCE=light|dark forces one for previews and screenshots.
@MainActor
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private let model: SetupModel
    var statusItemFrame: () -> CGRect? = { nil }

    init(executableURL: URL, serviceHost: ServiceHost? = nil) {
        model = SetupModel(
            registration: MCPClientRegistrationService(serverExecutableURL: executableURL),
            host: serviceHost
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Computer Use Setup"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        switch ProcessInfo.processInfo.environment["MACCU_APPEARANCE"]?.lowercased() {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
        window.contentView = NSHostingView(rootView: SetupRootView(model: model))
        super.init(window: window)
        window.delegate = self
        model.runCursorDemo = { [weak self] in
            guard let self else { return }
            self.window?.orderOut(nil)
            serviceHost?.runCursorDemo(statusItemFrame: self.statusItemFrame())
        }
    }

    required init?(coder: NSCoder) { nil }

    func showSetup() {
        model.refreshAll()
        model.startLiveRefresh()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showPermissions() {
        showSetup()
    }

    func refreshClientsIfVisible() {
        guard window?.isVisible == true else { return }
        model.refreshApprovals()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopLiveRefresh()
    }
}
