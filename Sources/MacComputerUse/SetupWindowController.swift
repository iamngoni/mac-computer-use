import AppKit
import ApplicationServices
import CoreGraphics
import MacComputerUseCore
import ServiceManagement

@MainActor
final class SetupWindowController: NSWindowController {
    private let registrationService: MCPClientRegistrationService
    private var clientRows: [SupportedMCPClient: ClientRegistrationRow] = [:]
    private let accessibilityStatus = NSTextField(labelWithString: "Checking…")
    private let screenRecordingStatus = NSTextField(labelWithString: "Checking…")
    private let launchAtLoginSwitch = NSSwitch()
    private let installationStatus = NSTextField(labelWithString: "")
    private let allowedClientsStack = NSStackView()
    private weak var serviceHost: ServiceHost?

    init(executableURL: URL, serviceHost: ServiceHost? = nil) {
        registrationService = MCPClientRegistrationService(serverExecutableURL: executableURL)
        self.serviceHost = serviceHost
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac Computer Use Setup"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        super.init(window: window)
        buildInterface()
    }

    required init?(coder: NSCoder) { nil }

    func showSetup() {
        refresh()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showPermissions() {
        showSetup()
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 22
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 30),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -30),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -26),
        ])

        let header = NSTextField(wrappingLabelWithString: "Control your Mac, visibly and on your terms.")
        header.font = .systemFont(ofSize: 24, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Grant the two macOS permissions to Mac Computer Use once, then connect the clients you use. Clients work through Mac Computer Use, so they never need these permissions themselves.")
        intro.textColor = .secondaryLabelColor
        intro.maximumNumberOfLines = 2
        root.addArrangedSubview(header)
        root.setCustomSpacing(6, after: header)
        root.addArrangedSubview(intro)

        root.addArrangedSubview(sectionTitle("Installation"))
        let installRow = horizontalRow()
        installationStatus.lineBreakMode = .byTruncatingMiddle
        installRow.addArrangedSubview(installationStatus)
        let revealButton = button("Show Applications", action: #selector(showApplications))
        installRow.addArrangedSubview(revealButton)
        root.addArrangedSubview(installRow)

        root.addArrangedSubview(sectionTitle("Permissions"))
        root.addArrangedSubview(permissionRow(
            title: "Accessibility",
            status: accessibilityStatus,
            buttonTitle: "Grant Access",
            action: #selector(requestAccessibility)
        ))
        root.setCustomSpacing(8, after: root.arrangedSubviews.last!)
        root.addArrangedSubview(permissionRow(
            title: "Screen Recording",
            status: screenRecordingStatus,
            buttonTitle: "Grant Access",
            action: #selector(requestScreenRecording)
        ))

        root.addArrangedSubview(sectionTitle("MCP clients"))
        for client in SupportedMCPClient.allCases {
            let row = ClientRegistrationRow(client: client, owner: self)
            clientRows[client] = row
            root.addArrangedSubview(row.view)
            root.setCustomSpacing(8, after: row.view)
        }

        root.addArrangedSubview(sectionTitle("Allowed apps"))
        allowedClientsStack.orientation = .vertical
        allowedClientsStack.alignment = .leading
        allowedClientsStack.spacing = 6
        root.addArrangedSubview(allowedClientsStack)

        root.addArrangedSubview(sectionTitle("Background service"))
        let loginRow = horizontalRow()
        let loginText = NSTextField(wrappingLabelWithString: "Open the menu-bar manager when you sign in")
        loginText.font = .systemFont(ofSize: 13, weight: .medium)
        loginRow.addArrangedSubview(loginText)
        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(toggleLaunchAtLogin)
        loginRow.addArrangedSubview(launchAtLoginSwitch)
        root.addArrangedSubview(loginRow)

        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
    }

    private func refresh() {
        let installedPath = "/Applications/MacComputerUse.app"
        if Bundle.main.bundleURL.standardizedFileURL.path == installedPath {
            installationStatus.stringValue = "Installed in Applications"
            installationStatus.textColor = .systemGreen
        } else {
            installationStatus.stringValue = "Move MacComputerUse.app to Applications for reliable permissions and updates."
            installationStatus.textColor = .systemOrange
        }
        refreshPermissions()
        refreshLaunchAtLogin()
        refreshClients()
        refreshAllowedClients()
    }

    func refreshClientsIfVisible() {
        guard window?.isVisible == true else { return }
        refreshAllowedClients()
    }

    private func refreshAllowedClients() {
        for view in allowedClientsStack.arrangedSubviews {
            allowedClientsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let clients = serviceHost?.approvedClients ?? []
        guard !clients.isEmpty else {
            let empty = NSTextField(wrappingLabelWithString: "No apps yet. The first time a client such as Claude Code or Codex acts, Mac Computer Use asks whether to allow it.")
            empty.textColor = .secondaryLabelColor
            allowedClientsStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: allowedClientsStack.widthAnchor).isActive = true
            return
        }
        for client in clients.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) {
            let row = horizontalRow()
            let name = NSTextField(labelWithString: client.displayName)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            let detail = NSTextField(labelWithString: client.detail)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingMiddle
            detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let remove = RevokeButton(title: "Remove", target: self, action: #selector(revokeClient(_:)))
            remove.bezelStyle = .rounded
            remove.clientKey = client.key
            row.addArrangedSubview(name)
            row.addArrangedSubview(detail)
            row.addArrangedSubview(remove)
            allowedClientsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: allowedClientsStack.widthAnchor).isActive = true
        }
    }

    @objc private func revokeClient(_ sender: RevokeButton) {
        guard let key = sender.clientKey else { return }
        serviceHost?.revokeClient(key)
        refreshAllowedClients()
    }

    private func refreshPermissions() {
        setPermissionStatus(accessibilityStatus, granted: AXIsProcessTrusted())
        setPermissionStatus(screenRecordingStatus, granted: CGPreflightScreenCaptureAccess())
    }

    private func setPermissionStatus(_ label: NSTextField, granted: Bool) {
        label.stringValue = granted ? "Granted" : "Required"
        label.textColor = granted ? .systemGreen : .systemOrange
    }

    private func refreshLaunchAtLogin() {
        launchAtLoginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launchAtLoginSwitch.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
    }

    private func refreshClients() {
        for client in SupportedMCPClient.allCases {
            clientRows[client]?.showLoading()
            DispatchQueue.global(qos: .userInitiated).async { [weak self, registrationService] in
                let state = registrationService.inspect(client)
                DispatchQueue.main.async { [weak self] in
                    self?.clientRows[client]?.update(state: state)
                }
            }
        }
    }

    fileprivate func install(_ client: SupportedMCPClient, replaceExisting: Bool) {
        clientRows[client]?.showLoading()
        DispatchQueue.global(qos: .userInitiated).async { [weak self, registrationService] in
            let result = registrationService.install(client, replaceExisting: replaceExisting)
            let state = registrationService.inspect(client)
            DispatchQueue.main.async { [weak self] in
                self?.clientRows[client]?.update(state: state)
                if case .failure(let error) = result { self?.showError(error.localizedDescription) }
            }
        }
    }

    fileprivate func copyCommand(for client: SupportedMCPClient) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            registrationService.copyableInstallationCommand(for: client),
            forType: .string
        )
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        openPrivacyPane("Privacy_Accessibility")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshPermissions() }
    }

    @objc private func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacyPane("Privacy_ScreenCapture")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshPermissions() }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchAtLoginSwitch.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showError(error.localizedDescription)
            refreshLaunchAtLogin()
        }
    }

    @objc private func showApplications() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Setup could not be completed"
        alert.informativeText = message
        alert.runModal()
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func horizontalRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fill
        return row
    }

    private func permissionRow(
        title: String,
        status: NSTextField,
        buttonTitle: String,
        action: Selector
    ) -> NSStackView {
        let row = horizontalRow()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.alignment = .right
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(status)
        row.addArrangedSubview(button(buttonTitle, action: action))
        return row
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.bezelStyle = .rounded
        return control
    }
}

private final class RevokeButton: NSButton {
    var clientKey: String?
}

@MainActor
private final class ClientRegistrationRow: NSObject {
    let client: SupportedMCPClient
    let view = NSStackView()
    private weak var owner: SetupWindowController?
    private let status = NSTextField(labelWithString: "Checking…")
    private let primary = NSButton()
    private var replaceExisting = false

    init(client: SupportedMCPClient, owner: SetupWindowController) {
        self.client = client
        self.owner = owner
        super.init()
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = 10
        let name = NSTextField(labelWithString: client.rawValue)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.alignment = .right
        primary.target = self
        primary.action = #selector(install)
        primary.bezelStyle = .rounded
        let copy = NSButton(title: "Copy command", target: self, action: #selector(copyCommand))
        copy.bezelStyle = .rounded
        view.addArrangedSubview(name)
        view.addArrangedSubview(status)
        view.addArrangedSubview(primary)
        view.addArrangedSubview(copy)
    }

    func showLoading() {
        status.stringValue = "Checking…"
        status.textColor = .secondaryLabelColor
        primary.isEnabled = false
    }

    func update(state: MCPClientRegistrationState) {
        replaceExisting = false
        primary.isHidden = false
        primary.isEnabled = true
        switch state {
        case .unavailable:
            status.stringValue = "Client not found"
            status.textColor = .secondaryLabelColor
            primary.isHidden = true
        case .absent:
            status.stringValue = "Not connected"
            status.textColor = .systemOrange
            primary.title = "Connect"
        case .installed:
            status.stringValue = "Connected"
            status.textColor = .systemGreen
            primary.isHidden = true
        case .different:
            status.stringValue = "Uses another copy"
            status.textColor = .systemOrange
            primary.title = "Replace"
            replaceExisting = true
        case .failed:
            status.stringValue = "Could not inspect"
            status.textColor = .systemRed
            primary.title = "Retry"
        }
    }

    @objc private func install() {
        owner?.install(client, replaceExisting: replaceExisting)
    }

    @objc private func copyCommand() {
        owner?.copyCommand(for: client)
    }
}
