// Spoken output: agents can say things aloud in the Mac's own voice. Speech
// runs on-device with AVSpeechSynthesizer inside the service, so Esc, pause
// and Quit silence every agent at once and two agents never talk over each
// other: utterances queue in order.
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

/// The service's voice. `MACCU_VOICE=off` mutes it and `MACCU_VOICE=silent`
/// completes utterances without audio, for tests.
@MainActor
final class ServiceVoice: NSObject, AVSpeechSynthesizerDelegate {
    enum Mode {
        case audible, silent, off
    }

    private let mode: Mode
    private let synthesizer = AVSpeechSynthesizer()
    private var completions: [ObjectIdentifier: (SpeechOutcome) -> Void] = [:]
    private var silentCompletions: [UUID: (SpeechOutcome) -> Void] = [:]
    var isEnabled: () -> Bool = { VoicePreference.isEnabled }

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

    func speak(_ text: String, completion: @escaping (SpeechOutcome) -> Void = { _ in }) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSpeak, !text.isEmpty else {
            completion(.muted)
            return
        }
        if mode == .silent {
            let token = UUID()
            silentCompletions[token] = completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                MainActor.assumeIsolated { self?.silentCompletions.removeValue(forKey: token)?(.spoken) }
            }
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        completions[ObjectIdentifier(utterance)] = completion
        synthesizer.speak(utterance)
    }

    /// Cuts the current utterance and drops everything queued.
    func stopAll() {
        let pending = Array(completions.values) + Array(silentCompletions.values)
        completions.removeAll()
        silentCompletions.removeAll()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        for completion in pending { completion(.interrupted) }
    }

    private func finish(_ identifier: ObjectIdentifier, _ outcome: SpeechOutcome) {
        completions.removeValue(forKey: identifier)?(outcome)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.finish(identifier, .spoken) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.finish(identifier, .interrupted) }
        }
    }
}
