// The setup window: a live stage where the agent cursor demonstrates itself,
// beside a three-step checklist (permissions, agents, approvals). It follows
// the system appearance; every colour is semantic or from the cursor art.
import AppKit
import ApplicationServices
import CoreGraphics
import MacComputerUseCore
import ServiceManagement
import SwiftUI

// MARK: - Model

@MainActor
final class SetupModel: ObservableObject {
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var screenRecordingGranted = CGPreflightScreenCaptureAccess()
    @Published var clientStates: [SupportedMCPClient: MCPClientRegistrationState] = [:]
    @Published var skillStates: [SkillTarget: SkillInstallationState] = [:]
    @Published var approved: [ApprovedServiceClient] = []
    @Published var denied: [ServiceClientIdentity] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var agentPreview = true
    @Published var speakAloud = true
    @Published var copiedClient: SupportedMCPClient?
    @Published var errorMessage: String?

    let registration: MCPClientRegistrationService
    let skills = SkillInstallationService.bundled()
    weak var host: ServiceHost?
    var runCursorDemo: () -> Void = {}
    private var timer: Timer?

    init(registration: MCPClientRegistrationService, host: ServiceHost?) {
        self.registration = registration
        self.host = host
        agentPreview = host?.agentPreviewEnabled ?? true
        speakAloud = host?.voiceEnabled ?? true
    }

    var permissionsDone: Bool { accessibilityGranted && screenRecordingGranted }
    var connectedCount: Int { clientStates.values.filter { $0 == .installed }.count }
    var serviceRunning: Bool { host != nil }
    var isInstalledInApplications: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/MacComputerUse.app"
    }

    func refreshAll() {
        refreshPermissions()
        refreshClients()
        refreshSkills()
        refreshApprovals()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        agentPreview = host?.agentPreviewEnabled ?? agentPreview
        speakAloud = host?.voiceEnabled ?? speakAloud
    }

    /// Permissions change in System Settings, so poll while the window is open.
    func startLiveRefresh() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissions()
                self?.refreshApprovals()
            }
        }
    }

    func stopLiveRefresh() {
        timer?.invalidate()
        timer = nil
    }

    func refreshPermissions() {
        let accessibility = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        if screen != screenRecordingGranted { screenRecordingGranted = screen }
    }

    func refreshApprovals() {
        let approvedNow = host?.approvedClients ?? []
        if approvedNow != approved { approved = approvedNow }
        let deniedNow = host?.deniedClients ?? []
        if deniedNow.map(\.key) != denied.map(\.key) { denied = deniedNow }
    }

    func refreshClients() {
        for client in SupportedMCPClient.allCases {
            let registration = registration
            DispatchQueue.global(qos: .userInitiated).async {
                let state = registration.inspect(client)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.clientStates[client] = state }
                }
            }
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        openPrivacyPane("Privacy_Accessibility")
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    func connect(_ client: SupportedMCPClient, replacing: Bool) {
        clientStates.removeValue(forKey: client)
        let registration = registration
        DispatchQueue.global(qos: .userInitiated).async {
            let result = registration.install(client, replaceExisting: replacing)
            let state = registration.inspect(client)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.clientStates[client] = state
                    if case .failure(let error) = result { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    func refreshSkills() {
        guard let skills else { return }
        for target in SkillTarget.allCases {
            let state = skills.state(for: target)
            if skillStates[target] != state { skillStates[target] = state }
        }
    }

    /// Installs, updates or removes the skill for one agent. Replacing a
    /// skill this app did not install, or one the user edited, asks first.
    func toggleSkill(_ target: SkillTarget) {
        guard let skills else { return }
        let state = skills.state(for: target)
        let result: Result<Void, SkillInstallationError>
        switch state {
        case .absent, .outdated:
            result = skills.install(target)
        case .current:
            result = skills.remove(target)
        case .modified, .foreign:
            guard confirmSkillReplacement(target, edited: state == .modified, skills: skills) else { return }
            result = skills.install(target, replaceExisting: true)
        }
        if case .failure(let error) = result { errorMessage = error.localizedDescription }
        refreshSkills()
    }

    private func confirmSkillReplacement(_ target: SkillTarget, edited: Bool, skills: SkillInstallationService) -> Bool {
        let alert = NSAlert()
        alert.messageText = edited ? "Replace your edited skill?" : "Replace the existing skill?"
        alert.informativeText = edited
            ? "\(skills.displayPath(for: target)) was changed after Mac Computer Use installed it. Your copy will be moved to the Trash."
            : "\(skills.displayPath(for: target)) was not installed by Mac Computer Use. It will be moved to the Trash."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func copyCommand(_ client: SupportedMCPClient) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(registration.copyableInstallationCommand(for: client), forType: .string)
        copiedClient = client
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated {
                if self?.copiedClient == client { self?.copiedClient = nil }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorMessage = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setAgentPreview(_ enabled: Bool) {
        host?.agentPreviewEnabled = enabled
        agentPreview = enabled
    }

    func setSpeakAloud(_ enabled: Bool) {
        host?.voiceEnabled = enabled
        speakAloud = enabled
    }

    func revoke(_ key: String) {
        host?.revokeClient(key)
        refreshApprovals()
    }

    func allowDenied(_ key: String) {
        host?.allowDeniedClient(key)
        refreshApprovals()
    }

    func showAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func openToursFolder() {
        host?.openToursFolder()
    }
}

// MARK: - Palette

enum SetupPalette {
    static let cyan = Color(red: 0.0, green: 0.78, blue: 1.0)
    static let blue = Color(red: 0.31, green: 0.55, blue: 1.0)
    static let lavender = Color(red: 0.66, green: 0.55, blue: 1.0)
    static let brand = LinearGradient(colors: [cyan, blue, lavender], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let warning = Color.orange
    static let success = Color.green
}

private let cursorArt: NSImage? = AutomationCursorAssets.load()?.pointer

// MARK: - Root

struct SetupRootView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            SetupTopBar(model: model)
            Divider().opacity(0.6)
            HStack(alignment: .top, spacing: 18) {
                LiveStage(onTest: model.runCursorDemo)
                    .frame(width: 560)
                SetupChecklist(model: model)
            }
            .padding(18)
        }
        .frame(width: 1060, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "Setup could not be completed",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            actions: { Button("OK", role: .cancel) {} },
            message: { Text(model.errorMessage ?? "") }
        )
    }
}

// MARK: - Top bar

struct SetupTopBar: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        HStack(spacing: 12) {
            if let cursorArt {
                Image(nsImage: cursorArt)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .shadow(color: SetupPalette.cyan.opacity(0.55), radius: 6)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac Computer Use").font(.system(size: 17, weight: .semibold))
                Text("Version \(macComputerUseVersion())\(model.isInstalledInApplications ? "" : " · not in Applications")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(running: model.serviceRunning, ready: model.permissionsDone)
            Menu {
                Button("Show App in Finder") { model.showAppInFinder() }
                Button("Open Tours Folder") { model.openToursFolder() }
                Button("Refresh") { model.refreshAll() }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 84) // clear the traffic lights in the transparent title bar
        .padding(.trailing, 18)
        .frame(height: 64)
    }
}

struct StatusPill: View {
    let running: Bool
    let ready: Bool

    var body: some View {
        let color: Color = !running ? .red : (ready ? SetupPalette.success : SetupPalette.warning)
        let text = !running ? "Service stopped" : (ready ? "Service running" : "Needs permissions")
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Live stage

/// A looping demonstration: the cursor flies in on its arc, rests on Send
/// with the countdown ring and warning bubble, clicks, and resets.
struct LiveStage: View {
    let onTest: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                DotGrid()
                if reduceMotion {
                    StageScene(time: 2.2)
                } else {
                    TimelineView(.animation) { context in
                        StageScene(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: StageScene.period))
                    }
                }
            }
            .frame(height: 520)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Divider().opacity(0.6)
            HStack {
                Circle().fill(SetupPalette.success).frame(width: 8, height: 8)
                Text("Live preview").font(.system(size: 13, weight: .medium))
                Spacer()
                Button(action: onTest) {
                    Label("Test Cursor", systemImage: "cursorarrow.motionlines")
                }
                .controlSize(.large)
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Color.black.opacity(0.28) : Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 18
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)), with: .color(.primary.opacity(0.13)))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

private func smoothstep(_ t: Double) -> Double {
    let x = min(max(t, 0), 1)
    return x * x * (3 - 2 * x)
}

struct StageScene: View {
    static let period: Double = 6.4
    let time: Double

    // Stage geometry (points, y down), sized for the 560 x 520 stage.
    private let windowFrame = CGRect(x: 70, y: 120, width: 420, height: 260)
    // The cursor rests on the right of the Send button so its label stays readable.
    private var sendCenter: CGPoint { CGPoint(x: windowFrame.maxX - 34, y: windowFrame.maxY - 34) }
    private let start = CGPoint(x: 120, y: 60)

    // Timeline: fly 0-1.3 s, countdown 1.3-3.3 s, click at 3.3 s, sent until 4.8 s, fade to 6.4 s.
    private var flight: Double { smoothstep(time / 1.3) }
    private var countdownRemaining: Double { 1 - min(max((time - 1.3) / 2.0, 0), 1) }
    private var counting: Bool { time >= 1.3 && time < 3.3 }
    private var clicked: Bool { time >= 3.3 && time < 5.4 }
    private var cursorOpacity: Double { time < 5.4 ? 1 : max(0, 1 - (time - 5.4) / 0.5) }

    private var control: CGPoint {
        CGPoint(x: (start.x + sendCenter.x) / 2, y: min(start.y, sendCenter.y) - 70)
    }

    private func point(_ e: Double) -> CGPoint {
        let u = 1 - e
        return CGPoint(
            x: u * u * start.x + 2 * u * e * control.x + e * e * sendCenter.x,
            y: u * u * start.y + 2 * u * e * control.y + e * e * sendCenter.y
        )
    }

    private var pose: (point: CGPoint, rotation: Double, scale: Double) {
        let raw = min(max(time / 1.3, 0), 1)
        let e = flight
        let u = 1 - e
        let tangent = CGVector(
            dx: 2 * u * (control.x - start.x) + 2 * e * (sendCenter.x - control.x),
            dy: 2 * u * (control.y - start.y) + 2 * e * (sendCenter.y - control.y)
        )
        let resting = atan2(-1.0, -1.0) // the arrow points up and to the left
        var turn = atan2(tangent.dy, tangent.dx) - resting
        turn = atan2(sin(turn), cos(turn))
        let weight = sin(Double.pi * raw)
        var scale = 1 + 0.3 * weight
        if time >= 3.3 && time < 3.45 { scale *= 0.82 } // click press
        return (point(e), turn * weight, scale)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Faint windows behind give the stage some depth.
            GhostWindow()
                .frame(width: 300, height: 200)
                .offset(x: windowFrame.minX - 34, y: windowFrame.minY + 22)
                .opacity(0.55)
            GhostWindow()
                .frame(width: 260, height: 180)
                .offset(x: windowFrame.maxX - 200, y: windowFrame.minY + 36)
                .opacity(0.45)
            MiniComposeWindow(sent: clicked, pressed: time >= 3.3 && time < 3.45)
                .frame(width: windowFrame.width, height: windowFrame.height)
                .offset(x: windowFrame.minX, y: windowFrame.minY)

            // The dotted trail of the flight so far.
            Path { path in
                path.move(to: start)
                path.addQuadCurve(to: sendCenter, control: control)
            }
            .trim(from: 0, to: flight)
            .stroke(Color.primary.opacity(0.35), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [0.1, 9]))
            .opacity(cursorOpacity)

            if counting {
                Text("About to press Send · Esc to stop")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SetupPalette.warning)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
                    .overlay(Capsule().stroke(SetupPalette.warning.opacity(0.8), lineWidth: 1))
                    .fixedSize()
                    .position(x: sendCenter.x - 96, y: sendCenter.y - 48)
                    .transition(.opacity)

                Circle()
                    .trim(from: 0, to: countdownRemaining)
                    .stroke(SetupPalette.warning, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 28, height: 28)
                    .background(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2.5))
                    .position(sendCenter)
            }

            AgentCursor(rotation: pose.rotation, scale: pose.scale)
                .opacity(cursorOpacity)
                .position(x: pose.point.x, y: pose.point.y)
        }
        .frame(width: 560, height: 520, alignment: .topLeading)
    }
}

/// The shipped cursor art, pivoting on its hotspot like the real overlay.
struct AgentCursor: View {
    let rotation: Double
    let scale: Double
    private let canvas: CGFloat = 28
    private let hotspot = CGPoint(x: 6.75, y: 6.5)

    var body: some View {
        let anchor = UnitPoint(x: hotspot.x / canvas, y: hotspot.y / canvas)
        Group {
            if let cursorArt {
                Image(nsImage: cursorArt).resizable()
            } else {
                Image(systemName: "location.north.fill").resizable().foregroundStyle(SetupPalette.brand)
            }
        }
        .frame(width: canvas, height: canvas)
        .shadow(color: .white.opacity(0.85), radius: 1.5)
        .shadow(color: SetupPalette.cyan.opacity(0.45), radius: 7)
        .rotationEffect(.radians(rotation), anchor: anchor)
        .scaleEffect(scale, anchor: anchor)
        // Place the hotspot (not the image centre) on the given position.
        .offset(x: canvas / 2 - hotspot.x, y: canvas / 2 - hotspot.y)
        .frame(width: 0, height: 0)
    }
}

struct GhostWindow: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.primary.opacity(0.18)).frame(width: 7, height: 7) }
            }
            .padding(.bottom, 4)
            ForEach([0.9, 0.7, 0.8, 0.5], id: \.self) { width in
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.1)).frame(height: 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .scaleEffect(x: width, y: 1, anchor: .leading)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

struct MiniComposeWindow: View {
    let sent: Bool
    let pressed: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, Color.yellow, Color.green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: 9, height: 9)
                }
                Image(systemName: "paperplane").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 10)
                Spacer()
                ForEach(["paperclip", "textformat", "list.bullet"], id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("To:").foregroundStyle(.secondary)
                    Text("team@example.com")
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(SetupPalette.blue.opacity(0.18)))
                }
                Divider()
                HStack(spacing: 8) {
                    Text("Subject:").foregroundStyle(.secondary)
                    Text("Project update")
                }
                Divider()
                Text("Hi team,")
                Text("Here's the latest update on the project. Looking good!")
                Text("Best,")
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 14)
            .padding(.top, 10)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                HStack(spacing: 5) {
                    if sent { Image(systemName: "checkmark") }
                    Text(sent ? "Sent" : "Send")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(sent ? SetupPalette.success : SetupPalette.blue))
                .scaleEffect(pressed ? 0.94 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(colorScheme == .dark ? Color(white: 0.13) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.12), radius: 18, y: 8)
    }
}

// MARK: - Checklist

struct SetupChecklist: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set up in three steps")
                .font(.system(size: 22, weight: .semibold))
                .padding(.bottom, 18)

            SetupStep(number: 1, title: "Grant permissions", done: model.permissionsDone, isLast: false) {
                VStack(spacing: 8) {
                    PermissionRow(symbol: "accessibility", title: "Accessibility", detail: "Read and operate app controls",
                                  granted: model.accessibilityGranted, action: model.requestAccessibility)
                    PermissionRow(symbol: "display", title: "Screen Recording", detail: "See app windows",
                                  granted: model.screenRecordingGranted, action: model.requestScreenRecording)
                }
            }

            SetupStep(number: 2, title: "Connect your agents", done: model.connectedCount > 0, isLast: false) {
                VStack(spacing: 8) {
                    ForEach(SupportedMCPClient.allCases, id: \.self) { client in
                        ClientRow(client: client, state: model.clientStates[client], copied: model.copiedClient == client,
                                  connect: { model.connect(client, replacing: $0) },
                                  copy: { model.copyCommand(client) })
                    }
                    if let skills = model.skills {
                        SkillRow(states: model.skillStates, path: skills.displayPath(for:), toggle: model.toggleSkill)
                    }
                }
            }

            SetupStep(number: 3, title: "Allow on first use", done: !model.approved.isEmpty, isLast: true) {
                VStack(spacing: 8) {
                    if model.approved.isEmpty && model.denied.isEmpty {
                        RowCard {
                            Image(systemName: "lock").font(.system(size: 14)).frame(width: 30)
                            Text("Each agent asks once before it acts.")
                                .font(.system(size: 13))
                            Spacer()
                        }
                    }
                    ForEach(model.denied, id: \.key) { identity in
                        RowCard {
                            RowIcon(symbol: "hand.raised", tint: SetupPalette.warning)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(identity.displayName).font(.system(size: 13, weight: .medium))
                                Text("Not allowed this session").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Allow") { model.allowDenied(identity.key) }
                        }
                    }
                    ForEach(model.approved, id: \.key) { client in
                        RowCard {
                            RowIcon(symbol: "checkmark.shield", tint: SetupPalette.success)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(client.displayName).font(.system(size: 13, weight: .medium))
                                Text(client.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Remove") { model.revoke(client.key) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Spacer(minLength: 12)
            Divider().opacity(0.6)
            HStack(spacing: 12) {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .disabled(Bundle.main.bundleURL.pathExtension != "app")
                    .fixedSize()
                Divider().frame(height: 22)
                Toggle("Agent preview", isOn: Binding(get: { model.agentPreview }, set: { model.setAgentPreview($0) }))
                    .help("Show a live preview of windows an agent works in behind others")
                    .fixedSize()
                Divider().frame(height: 22)
                Toggle("Speak aloud", isOn: Binding(get: { model.speakAloud }, set: { model.setSpeakAloud($0) }))
                    .help("Let agents talk to you in the Mac's voice")
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 13))
            .padding(.top, 14)
        }
    }
}

struct SetupStep<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let isLast: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(done ? SetupPalette.success.opacity(0.16) : Color.clear)
                    Circle()
                        .stroke(done ? SetupPalette.success : SetupPalette.blue, lineWidth: 1.6)
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(SetupPalette.success)
                    } else {
                        Text("\(number)").font(.system(size: 14, weight: .semibold)).foregroundStyle(SetupPalette.blue)
                    }
                }
                .frame(width: 32, height: 32)
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 15, weight: .semibold)).padding(.top, 6)
                content()
            }
            .padding(.bottom, isLast ? 0 : 16)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct RowCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

struct RowIcon: View {
    let symbol: String
    var tint: Color = .primary

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
    }
}

struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        RowCard {
            RowIcon(symbol: symbol, tint: SetupPalette.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(SetupPalette.success)
            } else {
                Button("Grant Access", action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// The agent skill, installable per agent: one chip each for Codex, Claude
/// Code and the shared ~/.agents/skills folder.
struct SkillRow: View {
    let states: [SkillTarget: SkillInstallationState]
    let path: (SkillTarget) -> String
    let toggle: (SkillTarget) -> Void

    var body: some View {
        RowCard {
            RowIcon(symbol: "book.closed")
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent skill").font(.system(size: 13, weight: .medium))
                Text("Teaches the tools").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(SkillTarget.allCases, id: \.self) { target in
                SkillChip(target: target, state: states[target], path: path(target)) { toggle(target) }
            }
        }
    }
}

struct SkillChip: View {
    let target: SkillTarget
    let state: SkillInstallationState?
    let path: String
    let action: () -> Void

    private var label: String { target == .claude ? "Claude" : target.rawValue }

    private var symbol: String {
        switch state {
        case .current?: return "checkmark"
        case .outdated?: return "arrow.clockwise"
        case .modified?, .foreign?: return "exclamationmark"
        case .absent?, nil: return "plus"
        }
    }

    private var tint: Color {
        switch state {
        case .current?: return SetupPalette.success
        case .outdated?, .modified?, .foreign?: return SetupPalette.warning
        case .absent?, nil: return .secondary
        }
    }

    private var help: String {
        switch state {
        case .current?: return "Installed in \(path). Click to remove."
        case .outdated?: return "An older version is in \(path). Click to update."
        case .modified?: return "\(path) was edited after install. Click to replace it; your copy goes to the Trash."
        case .foreign?: return "Another skill is at \(path). Click to replace it; it goes to the Trash."
        case .absent?, nil: return "Install into \(path)"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(tint.opacity(state == .current ? 0.14 : 0)))
            .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel("\(target.rawValue) skill")
        .accessibilityValue(state == .current ? "Installed" : "Not installed")
    }
}

struct ClientRow: View {
    let client: SupportedMCPClient
    let state: MCPClientRegistrationState?
    let copied: Bool
    let connect: (Bool) -> Void
    let copy: () -> Void

    private var appIcon: NSImage? {
        let identifiers: [String]
        switch client {
        case .codex: identifiers = ["com.openai.codex", "com.openai.chat"]
        case .claude: identifiers = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        }
        for identifier in identifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }

    var body: some View {
        RowCard {
            if let appIcon {
                Image(nsImage: appIcon).resizable().frame(width: 30, height: 30)
            } else {
                RowIcon(symbol: client == .codex ? "terminal" : "sparkle")
            }
            Text(client.rawValue).font(.system(size: 13, weight: .medium))
            Spacer()
            status
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 16)
            }
            .help(copied ? "Copied" : "Copy the registration command")
        }
    }

    @ViewBuilder private var status: some View {
        switch state {
        case nil:
            ProgressView().controlSize(.small)
        case .installed?:
            HStack(spacing: 6) {
                Circle().fill(SetupPalette.success).frame(width: 7, height: 7)
                Text("Connected").font(.system(size: 12.5, weight: .medium)).foregroundStyle(SetupPalette.success)
            }
        case .absent?:
            Button("Connect") { connect(false) }.buttonStyle(.borderedProminent)
        case .different?:
            Text("Uses another copy").font(.caption).foregroundStyle(SetupPalette.warning)
            Button("Replace") { connect(true) }
        case .unavailable?:
            Text("Not installed").font(.caption).foregroundStyle(.secondary)
        case .failed?:
            Button("Retry") { connect(false) }
        }
    }
}
