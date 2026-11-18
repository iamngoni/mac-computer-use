// Spoken output: agents can say things aloud. Speech runs inside the
// service, so Esc, pause and Quit silence every agent at once and two agents
// never talk over each other: utterances queue in order. The voice is the
// Mac's own, Kokoro on this Mac, or ElevenLabs (VoiceEngines.swift).
import AVFoundation
import Foundation

public enum VoicePreference {
    static let defaultsKey = "speakAloud"

    /// On by default: agents speak only when they ask to.
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

enum SpeechOutcome: Equatable {
    case spoken
    case muted
    case interrupted
}

/// What a tool should say aloud: `speak: true` reads the tool's own text, a
/// string says that instead. Nil when nothing should be spoken.
func spokenText(_ args: [String: Any], default text: String?) -> String? {
    if let custom = (args["speak"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
        return String(custom.prefix(400))
    }
    guard strictJSONBoolean(args["speak"]) == true,
          let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return String(text.prefix(400))
}

/// The service's voice. Every utterance joins one queue and is spoken in
/// order by the engine the person chose: the Mac's synthesizer, or audio
/// rendered by Kokoro or ElevenLabs. A rendered voice that fails falls back
/// to a Mac voice so agents are never silently mute.
/// `MACCU_VOICE=off` mutes it and `MACCU_VOICE=silent` completes utterances
/// without audio, for tests.
@MainActor
final class ServiceVoice: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    enum Mode {
        case audible, silent, off
    }

    private struct Utterance {
        let id = UUID()
        let text: String
        let rate: Double
        let voice: String?
        let engine: VoiceEngineKind
        let completion: (SpeechOutcome) -> Void
    }

    private let mode: Mode
    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [Utterance] = []
    private var current: Utterance?
    private var player: AVAudioPlayer?
    private var wordTimers: [DispatchWorkItem] = []
    private var rendering: Task<Void, Never>?
    var isEnabled: () -> Bool = { VoicePreference.isEnabled }
    var engine: () -> VoiceEngineKind = { CompanionPreferences.voiceEngine }
    /// Renders speech for Kokoro and ElevenLabs; replaced in tests.
    var render: (VoiceEngineKind, String, Double, String?) async throws -> RenderedSpeech = ServiceVoice.renderWithEngine
    /// Caption hooks: an utterance starts, reaches a word, or ends.
    var onStart: ((String) -> Void)?
    var onWord: ((NSRange) -> Void)?
    var onEnd: (() -> Void)?
    /// Reports a rendered voice that failed, once per failure.
    var onEngineFailure: ((VoiceEngineKind, Error) -> Void)?

    init(environment: [String: String]) {
        switch environment["MACCU_VOICE"]?.lowercased() {
        case "off": mode = .off
        case "silent": mode = .silent
        default: mode = .audible
        }
        super.init()
        synthesizer.delegate = self
    }

    /// True when a request to speak would be heard. Silent test mode ignores
    /// the user's preference so tests do not depend on it.
    var canSpeak: Bool {
        switch mode {
        case .off: return false
        case .silent: return true
        case .audible: return isEnabled()
        }
    }

    func speak(
        _ text: String,
        rate: Double? = nil,
        voice: String? = nil,
        completion: @escaping (SpeechOutcome) -> Void = { _ in }
    ) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSpeak, !text.isEmpty else {
            completion(.muted)
            return
        }
        queue.append(Utterance(
            text: text,
            rate: rate ?? CompanionPreferences.speechRate,
            voice: voice,
            engine: engine(),
            completion: completion
        ))
        speakNextIfIdle()
    }

    /// Cuts the current utterance and drops everything queued.
    func stopAll() {
        let pending = (current.map { [$0] } ?? []) + queue
        queue.removeAll()
        current = nil
        rendering?.cancel()
        rendering = nil
        stopPlayback()
        // The synthesizer's cancel callback must not end the captions twice.
        macUtterances.removeAll()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if !pending.isEmpty { onEnd?() }
        for utterance in pending { utterance.completion(.interrupted) }
    }

    // MARK: Queue

    private func speakNextIfIdle() {
        guard current == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next
        switch next.engine {
        case .mac: speakWithMac(next)
        case .kokoro, .elevenlabs: renderAndPlay(next)
        }
    }

    private func finish(_ id: UUID, _ outcome: SpeechOutcome) {
        guard let current, current.id == id else { return }
        self.current = nil
        current.completion(outcome)
        speakNextIfIdle()
    }

    // MARK: Mac voices

    private var macUtterances: [ObjectIdentifier: UUID] = [:]

    private func speakWithMac(_ item: Utterance) {
        if mode == .silent {
            playSilently(item, words: nil)
            return
        }
        let utterance = AVSpeechUtterance(string: item.text)
        utterance.rate = utteranceRate(multiplier: item.rate)
        // A per-call voice only names a Mac voice when Mac voices speak.
        let named = item.engine == .mac ? findSpeechVoice(item.voice) : nil
        if let chosen = named ?? preferredMacVoice() {
            utterance.voice = chosen
        }
        macUtterances[ObjectIdentifier(utterance)] = item.id
        synthesizer.speak(utterance)
    }

    private func macFinished(_ identifier: ObjectIdentifier, _ outcome: SpeechOutcome) {
        guard let id = macUtterances.removeValue(forKey: identifier) else { return }
        onEnd?()
        finish(id, outcome)
    }

    // MARK: Rendered voices

    private func renderAndPlay(_ item: Utterance) {
        let render = self.render
        rendering = Task { [weak self] in
            do {
                let speech = try await render(item.engine, item.text, item.rate, item.voice)
                try Task.checkCancellation()
                await MainActor.run { self?.play(speech, for: item) }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { self?.renderFailed(item, error) }
            }
        }
    }

    private func renderFailed(_ item: Utterance, _ error: Error) {
        guard current?.id == item.id else { return }
        onEngineFailure?(item.engine, error)
        let fallBack = item.engine == .kokoro || CompanionPreferences.elevenLabsFallback
        if fallBack {
            speakWithMac(item)
        } else {
            finish(item.id, .muted)
        }
    }

    private func play(_ speech: RenderedSpeech, for item: Utterance) {
        guard current?.id == item.id else { return }
        rendering = nil
        if mode == .silent {
            playSilently(item, words: speech.words)
            return
        }
        do {
            let player = try AVAudioPlayer(data: speech.audio)
            player.delegate = self
            self.player = player
            guard player.play() else { throw VoiceEngineError.malformedResponse }
            onStart?(item.text)
            scheduleWords(speech.words ?? estimatedWordTimings(text: item.text, duration: player.duration))
        } catch {
            stopPlayback()
            renderFailed(item, error)
        }
    }

    /// Test mode: report the start, the words and the end without audio.
    private func playSilently(_ item: Utterance, words: [SpokenWord]?) {
        onStart?(item.text)
        for word in words ?? [] { onWord?(word.range) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.current?.id == item.id else { return }
                self.onEnd?()
                self.finish(item.id, .spoken)
            }
        }
    }

    private func scheduleWords(_ words: [SpokenWord]) {
        for word in words {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.onWord?(word.range) }
            }
            wordTimers.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + word.start, execute: work)
        }
    }

    private func stopPlayback() {
        wordTimers.forEach { $0.cancel() }
        wordTimers.removeAll()
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identifier = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.current, let playing = self.player,
                      ObjectIdentifier(playing) == identifier else { return }
                self.stopPlayback()
                self.onEnd?()
                self.finish(current.id, flag ? .spoken : .interrupted)
            }
        }
    }

    /// Kokoro or ElevenLabs, with the person's saved choices.
    nonisolated static func renderWithEngine(
        _ engine: VoiceEngineKind,
        _ text: String,
        _ rate: Double,
        _ voice: String?
    ) async throws -> RenderedSpeech {
        switch engine {
        case .mac:
            throw VoiceEngineError.notInstalled
        case .kokoro:
            let chosen = KokoroCatalog.find(voice)?.id ?? CompanionPreferences.kokoroVoice
            return try await KokoroEngine.shared.render(text, voice: chosen, speed: rate)
        case .elevenlabs:
            guard let key = ElevenLabsKey.read(), !key.isEmpty else { throw VoiceEngineError.missingKey }
            let voices = CompanionPreferences.elevenLabsVoices
            let named = voice.flatMap { query in
                voices.first { $0.id == query || $0.name.caseInsensitiveCompare(query) == .orderedSame }
            }
            let voiceID = named?.id ?? CompanionPreferences.elevenLabsVoiceID ?? ElevenLabsClient.fallbackVoiceID
            return try await ElevenLabsClient().render(
                text,
                voiceID: voiceID,
                model: CompanionPreferences.elevenLabsModel,
                speed: rate,
                key: key
            )
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onStart?(text) }
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onWord?(characterRange) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.macFinished(identifier, .spoken) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.macFinished(identifier, .interrupted) }
        }
    }
}
