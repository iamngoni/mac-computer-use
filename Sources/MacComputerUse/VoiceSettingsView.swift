import AppKit
import MacComputerUseCore
import SwiftUI

/// State for the Voice window: which engine speaks and each engine's options.
@MainActor
final class VoiceSettingsModel: ObservableObject {
    enum KokoroState: Equatable {
        case notInstalled
        case downloading(bytes: Int64)
        case installed(bytes: Int64)
        case failed(String)
    }

    enum KeyState: Equatable {
        case none
        case unverified
        case checking
        case verified
        case failed(String)
    }

    @Published var engine = CompanionPreferences.voiceEngine
    @Published var macVoices: [MacVoiceOption] = []
    @Published var macVoiceID = ""
    @Published var autoBest = CompanionPreferences.autoBestMacVoice
    @Published var kokoro: KokoroState = .notInstalled
    @Published var kokoroVoice = CompanionPreferences.kokoroVoice
    @Published var keyText = ""
    @Published var keyState: KeyState = .none
    @Published var elevenVoices = CompanionPreferences.elevenLabsVoices
    @Published var elevenVoiceID = CompanionPreferences.elevenLabsVoiceID ?? ""
    @Published var elevenModel = CompanionPreferences.elevenLabsModel
    @Published var fallback = CompanionPreferences.elevenLabsFallback
    @Published var speed = CompanionPreferences.speechRate
    @Published var phrase = "I'll click Publish once you say yes."
    @Published var playing = false

    private weak var host: ServiceHost?
    private var progressTimer: Timer?
    /// Called when the voice in use changes, so the menu can show it.
    var onChange: () -> Void = {}

    init(host: ServiceHost?) {
        self.host = host
    }

    func refresh() {
        engine = CompanionPreferences.voiceEngine
        macVoices = availableSpeechVoiceDetails().filter { $0.language.hasPrefix(String(Locale.current.language.languageCode?.identifier ?? "en")) }
        if macVoices.isEmpty { macVoices = availableSpeechVoiceDetails() }
        autoBest = CompanionPreferences.autoBestMacVoice
        macVoiceID = CompanionPreferences.voiceIdentifier ?? bestInstalledSpeechVoice()?.identifier ?? macVoices.first?.id ?? ""
        if case .downloading = kokoro {} else {
            kokoro = KokoroEngine.isInstalled ? .installed(bytes: KokoroEngine.diskSize()) : .notInstalled
        }
        kokoroVoice = CompanionPreferences.kokoroVoice
        let saved = ElevenLabsKey.read() ?? ""
        keyText = saved
        if saved.isEmpty {
            keyState = .none
        } else if keyState == .none || keyState == .checking {
            keyState = CompanionPreferences.elevenLabsVoices.isEmpty ? .unverified : .verified
        }
        elevenVoices = CompanionPreferences.elevenLabsVoices
        elevenVoiceID = CompanionPreferences.elevenLabsVoiceID ?? elevenVoices.first?.id ?? ""
        elevenModel = CompanionPreferences.elevenLabsModel
        fallback = CompanionPreferences.elevenLabsFallback
        speed = CompanionPreferences.speechRate
    }

    var bestVoice: MacVoiceOption? {
        guard let best = bestInstalledSpeechVoice() else { return nil }
        return availableSpeechVoiceDetails().first { $0.id == best.identifier }
    }

    var selectedMacVoice: MacVoiceOption? {
        autoBest ? bestVoice : macVoices.first { $0.id == macVoiceID }
    }

    var hasPremiumVoice: Bool {
        availableSpeechVoiceDetails().contains { $0.quality == "Premium" }
    }

    // MARK: Choices

    func choose(_ kind: VoiceEngineKind) {
        engine = kind
        CompanionPreferences.voiceEngine = kind
        if kind == .elevenlabs, !keyText.isEmpty, keyState == .unverified { verifyKey() }
        onChange()
    }

    func setAutoBest(_ on: Bool) {
        autoBest = on
        CompanionPreferences.autoBestMacVoice = on
        if !on { CompanionPreferences.voiceIdentifier = macVoiceID }
        onChange()
    }

    func setMacVoice(_ id: String) {
        macVoiceID = id
        CompanionPreferences.voiceIdentifier = id
        CompanionPreferences.autoBestMacVoice = false
        autoBest = false
        onChange()
        play()
    }

    func setKokoroVoice(_ id: String) {
        kokoroVoice = id
        CompanionPreferences.kokoroVoice = id
        onChange()
        play()
    }

    func setSpeed(_ value: Double) {
        CompanionPreferences.speechRate = value
        speed = CompanionPreferences.speechRate
    }

    func setElevenVoice(_ id: String) {
        elevenVoiceID = id
        CompanionPreferences.elevenLabsVoiceID = id
        CompanionPreferences.elevenLabsVoiceName = elevenVoices.first { $0.id == id }?.name
        onChange()
    }

    func setElevenModel(_ model: ElevenLabsModel) {
        elevenModel = model
        CompanionPreferences.elevenLabsModel = model
    }

    func setFallback(_ on: Bool) {
        fallback = on
        CompanionPreferences.elevenLabsFallback = on
    }

    func openVoiceDownloads() {
        let panes = [
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
            "x-apple.systempreferences:com.apple.preference.universalaccess?SpeechSettings",
        ]
        for pane in panes {
            if let url = URL(string: pane), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Kokoro

    func downloadKokoro() {
        kokoro = .downloading(bytes: KokoroEngine.diskSize())
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .downloading = self.kokoro else { return }
                self.kokoro = .downloading(bytes: KokoroEngine.diskSize())
            }
        }
        Task {
            do {
                try await KokoroEngine.shared.install()
                progressTimer?.invalidate()
                kokoro = .installed(bytes: KokoroEngine.diskSize())
                onChange()
            } catch {
                progressTimer?.invalidate()
                kokoro = .failed(error.localizedDescription)
            }
        }
    }

    func removeKokoro() {
        Task {
            await KokoroEngine.shared.remove()
            kokoro = .notInstalled
            if engine == .kokoro { choose(.mac) }
        }
    }

    // MARK: ElevenLabs

    func keyEdited(_ text: String) {
        keyText = text
        keyState = text.isEmpty ? .none : .unverified
    }

    func verifyKey() {
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyState = .checking
        Task {
            do {
                let voices = try await ElevenLabsClient().voices(key: key)
                ElevenLabsKey.save(key)
                CompanionPreferences.elevenLabsVoices = voices
                elevenVoices = voices
                if !voices.contains(where: { $0.id == elevenVoiceID }), let first = voices.first {
                    setElevenVoice(first.id)
                }
                keyState = .verified
                onChange()
            } catch {
                keyState = .failed(error.localizedDescription)
            }
        }
    }

    func forgetKey() {
        ElevenLabsKey.delete()
        CompanionPreferences.elevenLabsVoices = []
        keyText = ""
        keyState = .none
        elevenVoices = []
        if engine == .elevenlabs { choose(.mac) }
    }

    // MARK: Test phrase

    func play() {
        if playing {
            host?.stopSpeaking()
            playing = false
            return
        }
        guard let host else { return }
        playing = true
        host.previewVoice(phrase.isEmpty ? "Hi! This is how I'll sound." : phrase) { [weak self] _ in
            self?.playing = false
        }
    }

    func stop() {
        progressTimer?.invalidate()
        if playing { host?.stopSpeaking() }
        playing = false
    }
}

// MARK: - View

struct VoiceSettingsView: View {
    @ObservedObject var model: VoiceSettingsModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose how agents sound when they talk to you.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                EngineCard(
                    kind: .mac, model: model, icon: "speaker.wave.2",
                    title: "Mac voices", blurb: "Apple’s built-in voices. Instant, no setup.", tag: "Free", free: true
                )
                EngineCard(
                    kind: .kokoro, model: model, icon: "cpu",
                    title: "Kokoro", blurb: "A neural model that runs on this Mac.", tag: "Free · about 100 MB", free: true
                )
                EngineCard(
                    kind: .elevenlabs, model: model, icon: "cloud",
                    title: "ElevenLabs", blurb: "The most lifelike voices, in the cloud.", tag: "Your API key", free: false
                )
            }

            VStack(alignment: .leading, spacing: 14) {
                switch model.engine {
                case .mac: MacVoicePane(model: model)
                case .kokoro: KokoroPane(model: model)
                case .elevenlabs: ElevenLabsPane(model: model)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))

            HStack(spacing: 12) {
                Text("Speed").foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                Slider(value: Binding(get: { model.speed }, set: { model.setSpeed($0) }), in: 0.5...1.5, step: 0.1)
                    .frame(width: 150)
                Text(String(format: "%.1f×", model.speed)).monospacedDigit().foregroundStyle(.secondary).frame(width: 34)
                TextField("Test phrase", text: $model.phrase)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.play() }
                Button(action: model.play) {
                    Image(systemName: model.playing ? "stop.fill" : "play.fill").frame(width: 16)
                }
                .help(model.playing ? "Stop" : "Play the test phrase")
                .accessibilityLabel(model.playing ? "Stop" : "Play the test phrase")
            }

            HStack {
                Text("Voice: \(currentVoiceSummary()) · Esc stops speech at any time.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(width: 720, height: 556)
    }
}

private struct EngineCard: View {
    let kind: VoiceEngineKind
    @ObservedObject var model: VoiceSettingsModel
    let icon: String
    let title: String
    let blurb: String
    let tag: String
    let free: Bool

    var body: some View {
        let selected = model.engine == kind
        Button { model.choose(kind) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
                    Spacer()
                    Circle()
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.25), lineWidth: selected ? 4 : 1)
                        .frame(width: 14, height: 14)
                }
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.top, 7)
                Text(blurb).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(tag)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(free ? Color.green : Color.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(free ? Color.green.opacity(0.12) : Color.primary.opacity(0.06)))
                    .padding(.top, 5)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: selected ? 2 : 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct MacVoicePane: View {
    @ObservedObject var model: VoiceSettingsModel

    var body: some View {
        HStack(spacing: 12) {
            Text("Voice").foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Picker("", selection: Binding(
                get: { model.autoBest ? (model.bestVoice?.id ?? model.macVoiceID) : model.macVoiceID },
                set: { model.setMacVoice($0) }
            )) {
                ForEach(model.macVoices) { voice in
                    Text("\(voice.name)\(voice.quality.map { " (\($0))" } ?? "") · \(voice.language)").tag(voice.id)
                }
            }
            .labelsHidden()
            .frame(width: 280)
            .disabled(model.autoBest)
            if let quality = model.selectedMacVoice?.quality {
                QualityBadge(text: quality)
            }
        }
        Toggle("Always use the best voice installed on this Mac", isOn: Binding(get: { model.autoBest }, set: { model.setAutoBest($0) }))
            .toggleStyle(.checkbox)
            .padding(.leading, 96)
        HStack(spacing: 12) {
            Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
            Text(model.hasPremiumVoice
                 ? "Premium voices sound far more natural. Apple offers more for free in Spoken Content settings."
                 : "No Premium voice is installed yet. They're free from Apple, about 200 MB each, and sound far more natural.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Get More Voices…", action: model.openVoiceDownloads)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.07)))
        Text("Free · works offline · nothing leaves your Mac.")
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
    }
}

private struct QualityBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.green)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.green.opacity(0.12)))
    }
}

private struct KokoroPane: View {
    @ObservedObject var model: VoiceSettingsModel

    private func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        switch model.kokoro {
        case .notInstalled, .failed:
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Kokoro isn’t downloaded yet").fontWeight(.semibold)
                    Text("An open neural voice model that runs on this Mac. About 100 MB, downloaded once.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if case .failed(let message) = model.kokoro {
                        Text("The download stopped: \(message)")
                            .font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
                Spacer()
                Button(model.kokoro == .notInstalled ? "Download" : "Try Again", action: model.downloadKokoro)
                    .buttonStyle(.borderedProminent)
            }
        case .downloading(let bytes):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Downloading Kokoro…")
                    Spacer()
                    Text("\(megabytes(bytes)) of about \(megabytes(KokoroEngine.approximateDownloadBytes))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                ProgressView(value: min(Double(bytes) / Double(KokoroEngine.approximateDownloadBytes), 0.98))
            }
        case .installed(let bytes):
            HStack(spacing: 8) {
                Image(systemName: "checkmark").foregroundStyle(Color.green).font(.system(size: 12, weight: .bold))
                Text("Installed · \(megabytes(bytes)) · English voices").font(.system(size: 12))
                Spacer()
                Button("Remove", action: model.removeKokoro).buttonStyle(.link).font(.system(size: 12))
            }
            Text("Voice").font(.system(size: 12)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(KokoroCatalog.voices) { voice in
                    let on = model.kokoroVoice == voice.id
                    Button { model.setKokoroVoice(voice.id) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(voice.name).fontWeight(.medium)
                            Text(voice.accent).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.1) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: on ? 1.5 : 0.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
        }
        Text("Free · works offline · nothing leaves your Mac.")
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
    }
}

private struct ElevenLabsPane: View {
    @ObservedObject var model: VoiceSettingsModel

    private var note: (String, Bool) {
        switch model.keyState {
        case .none, .unverified: return ("Stored in your Keychain, never in a file. Get a key at elevenlabs.io.", false)
        case .checking: return ("Checking the key…", false)
        case .verified: return ("Key works · stored in your Keychain", true)
        case .failed(let message): return (message, false)
        }
    }

    var body: some View {
        let locked = model.keyState != .verified
        HStack(spacing: 12) {
            Text("API key").foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            SecureField("Paste your ElevenLabs key", text: Binding(get: { model.keyText }, set: { model.keyEdited($0) }))
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.verifyKey() }
            if model.keyState == .verified {
                Button("Forget", action: model.forgetKey)
            } else {
                Button(model.keyState == .checking ? "Checking…" : "Verify", action: model.verifyKey)
                    .disabled(model.keyText.isEmpty || model.keyState == .checking)
            }
        }
        HStack(spacing: 6) {
            if note.1 {
                Image(systemName: "checkmark").foregroundStyle(Color.green).font(.system(size: 11, weight: .bold))
            }
            Text(note.0)
                .foregroundStyle(model.keyState.isFailure ? Color.red : Color.secondary)
        }
        .font(.system(size: 11.5))
        .padding(.leading, 96)
        HStack(spacing: 12) {
            Text("Voice").foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Picker("", selection: Binding(get: { model.elevenVoiceID }, set: { model.setElevenVoice($0) })) {
                if model.elevenVoices.isEmpty { Text("Verify your key first").tag("") }
                ForEach(model.elevenVoices) { voice in
                    Text(voice.detail.isEmpty ? voice.name : "\(voice.name) · \(voice.detail)").tag(voice.id)
                }
            }
            .labelsHidden()
            .frame(width: 220)
            .disabled(locked)
            Text("Model").foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { model.elevenModel }, set: { model.setElevenModel($0) })) {
                ForEach(ElevenLabsModel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .disabled(locked)
        }
        Toggle("Use Mac voices when ElevenLabs can’t be reached", isOn: Binding(get: { model.fallback }, set: { model.setFallback($0) }))
            .toggleStyle(.checkbox)
            .padding(.leading, 96)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.orange)
            Text("Everything agents say aloud is sent to ElevenLabs and billed to your account. Screen contents are never sent.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
    }
}

private extension VoiceSettingsModel.KeyState {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Window

/// The Voice window, opened from the menu bar's "Voice…" item and from
/// Setup's Personalize panel.
@MainActor
final class VoiceSettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: VoiceSettingsModel

    init(host: ServiceHost?) {
        model = VoiceSettingsModel(host: host)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 556),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Voice"
        window.isReleasedWhenClosed = false
        switch ProcessInfo.processInfo.environment["MACCU_APPEARANCE"]?.lowercased() {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
        super.init(window: window)
        window.contentView = NSHostingView(rootView: VoiceSettingsView(model: model) { [weak window] in window?.performClose(nil) })
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        model.refresh()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
    }
}
