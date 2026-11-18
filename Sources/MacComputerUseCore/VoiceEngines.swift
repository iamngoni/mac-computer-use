// The voices agents can speak in, beyond the Mac's own: Kokoro, a free
// neural model that runs on this Mac, and ElevenLabs, a cloud service the
// person pays for with their own API key. Both hand back finished audio that
// ServiceVoice plays, so Esc, pause and captions work the same for all three.
import AVFoundation
import FluidAudio
import Foundation
import Security

/// Which engine speaks.
public enum VoiceEngineKind: String, CaseIterable, Sendable {
    case mac
    case kokoro
    case elevenlabs
}

/// One word's place in the spoken text and when it is heard.
struct SpokenWord: Equatable {
    let range: NSRange
    let start: TimeInterval
}

/// Audio ready to play, with word timings for the captions.
struct RenderedSpeech {
    let audio: Data
    /// Nil when the engine has no timings; the player then spreads the
    /// words over the clip.
    let words: [SpokenWord]?
}

// MARK: - Word timing

/// Word ranges in `text`, as UTF-16 ranges for the captions.
func wordRanges(in text: String) -> [NSRange] {
    let ns = text as NSString
    var ranges: [NSRange] = []
    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byWords, .substringNotRequired]) { _, range, _, _ in
        ranges.append(range)
    }
    return ranges
}

/// Spreads words over `duration` by their length, for engines that report
/// no timings. Longer words take longer; every word gets a moment.
func estimatedWordTimings(text: String, duration: TimeInterval) -> [SpokenWord] {
    let ranges = wordRanges(in: text)
    guard !ranges.isEmpty, duration.isFinite, duration > 0 else { return [] }
    let weights = ranges.map { Double($0.length) + 2 }
    let total = weights.reduce(0, +)
    var elapsed = 0.0
    return zip(ranges, weights).map { range, weight in
        defer { elapsed += duration * weight / total }
        return SpokenWord(range: range, start: elapsed)
    }
}

/// Word timings from ElevenLabs' per-character alignment. Each word starts
/// when its first character does.
func alignedWordTimings(text: String, characters: [String], starts: [Double]) -> [SpokenWord]? {
    guard !characters.isEmpty, characters.count == starts.count else { return nil }
    // Map every UTF-16 offset of the aligned string to the start time of the
    // character that covers it.
    var offsets: [Double] = []
    for (character, start) in zip(characters, starts) {
        offsets.append(contentsOf: Array(repeating: start, count: max(1, (character as NSString).length)))
    }
    guard offsets.count == (text as NSString).length else { return nil }
    return wordRanges(in: text).map { SpokenWord(range: $0, start: offsets[$0.location]) }
}

// MARK: - Kokoro

/// A Kokoro voice offered in Settings.
public struct KokoroVoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let accent: String
}

public enum KokoroCatalog {
    public static let voices: [KokoroVoice] = [
        KokoroVoice(id: "af_heart", name: "Heart", accent: "American"),
        KokoroVoice(id: "af_bella", name: "Bella", accent: "American"),
        KokoroVoice(id: "af_nicole", name: "Nicole", accent: "American, soft"),
        KokoroVoice(id: "am_michael", name: "Michael", accent: "American"),
        KokoroVoice(id: "am_adam", name: "Adam", accent: "American"),
        KokoroVoice(id: "am_fenrir", name: "Fenrir", accent: "American"),
        KokoroVoice(id: "bf_emma", name: "Emma", accent: "British"),
        KokoroVoice(id: "bf_isabella", name: "Isabella", accent: "British"),
        KokoroVoice(id: "bm_george", name: "George", accent: "British"),
    ]
    public static let defaultVoice = "af_heart"

    /// A voice by id ("bf_emma") or name ("Emma").
    public static func find(_ query: String?) -> KokoroVoice? {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return nil }
        return voices.first {
            $0.id.caseInsensitiveCompare(query) == .orderedSame || $0.name.caseInsensitiveCompare(query) == .orderedSame
        }
    }
}

/// Kokoro on this Mac. The model is downloaded once into Application Support
/// and loaded on first use; it is released again after a while unused.
public actor KokoroEngine {
    public static let shared = KokoroEngine()

    /// Roughly what the English model and its text frontend take on disk.
    public static let approximateDownloadBytes: Int64 = 100_000_000

    public nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Mac Computer Use/Voices/Kokoro", isDirectory: true)
    }

    private nonisolated static var marker: URL { directory.appendingPathComponent("installed") }

    /// True once a download has finished and loaded.
    public nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    /// Bytes the model currently takes on disk.
    public nonisolated static func diskSize() -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    private var manager: KokoroAneManager?
    private var installing: Task<Void, Error>?
    private var lastUse = Date()
    private var idleCheck: Task<Void, Never>?

    /// Downloads and loads the model. Safe to call again while it runs.
    public func install() async throws {
        if let installing { return try await installing.value }
        let task = Task { try await self.load() }
        installing = task
        defer { installing = nil }
        try await task.value
    }

    private func load() async throws {
        if manager != nil { return }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let kokoro = KokoroAneManager(directory: Self.directory)
        try await kokoro.initialize(preloadVoices: [CompanionPreferences.kokoroVoice])
        manager = kokoro
        FileManager.default.createFile(atPath: Self.marker.path, contents: Data())
        scheduleIdleRelease()
    }

    /// Removes the model from disk.
    public func remove() async {
        installing?.cancel()
        await manager?.cleanup()
        manager = nil
        try? FileManager.default.removeItem(at: Self.directory)
    }

    /// Speech for `text` as WAV audio. Loads the model if it is installed.
    func render(_ text: String, voice: String, speed: Double) async throws -> RenderedSpeech {
        guard Self.isInstalled else { throw VoiceEngineError.notInstalled }
        try await install()
        guard let manager else { throw VoiceEngineError.notInstalled }
        lastUse = Date()
        let audio = try await manager.synthesize(
            text: text,
            voice: KokoroCatalog.find(voice)?.id ?? KokoroCatalog.defaultVoice,
            speed: Float(clampedSpeechRate(speed))
        )
        lastUse = Date()
        return RenderedSpeech(audio: audio, words: nil)
    }

    /// Frees the loaded model after ten idle minutes; it reloads on demand.
    private func scheduleIdleRelease() {
        idleCheck?.cancel()
        idleCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self else { return }
                if await self.releaseIfIdle() { return }
            }
        }
    }

    private func releaseIfIdle() async -> Bool {
        guard manager != nil, Date().timeIntervalSince(lastUse) > 600 else { return manager == nil }
        await manager?.cleanup()
        manager = nil
        return true
    }
}

enum VoiceEngineError: Error, LocalizedError {
    case notInstalled
    case missingKey
    case rejectedKey
    case service(Int, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Kokoro isn't downloaded."
        case .missingKey: return "No ElevenLabs API key is saved."
        case .rejectedKey: return "ElevenLabs didn't accept that API key."
        case .service(let status, let message): return "ElevenLabs answered \(status): \(message)"
        case .malformedResponse: return "ElevenLabs sent a response this version can't read."
        }
    }
}

// MARK: - ElevenLabs

/// An ElevenLabs voice in the person's account.
public struct ElevenLabsVoice: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
}

public enum ElevenLabsModel: String, CaseIterable, Sendable {
    case flash = "eleven_flash_v2_5"
    case multilingual = "eleven_multilingual_v2"

    public var title: String {
        switch self {
        case .flash: return "Flash · fastest"
        case .multilingual: return "Multilingual · most natural"
        }
    }
}

/// The ElevenLabs API, called only when the person chose ElevenLabs and
/// saved a key. Only the words being spoken are sent.
public struct ElevenLabsClient: Sendable {
    public static let fallbackVoiceID = "21m00Tcm4TlvDq8EAFwM"
    let base: URL
    let session: URLSession

    public init(base: URL = URL(string: "https://api.elevenlabs.io")!, session: URLSession = .shared) {
        self.base = base
        self.session = session
    }

    /// The voices in the account; also proves the key works.
    public func voices(key: String) async throws -> [ElevenLabsVoice] {
        var request = URLRequest(url: base.appendingPathComponent("v1/voices"))
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15
        let data = try await send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["voices"] as? [[String: Any]] else { throw VoiceEngineError.malformedResponse }
        return list.compactMap { item in
            guard let id = item["voice_id"] as? String, let name = item["name"] as? String else { return nil }
            let labels = item["labels"] as? [String: Any] ?? [:]
            let detail = ["accent", "description", "gender"].compactMap { labels[$0] as? String }.prefix(2).joined(separator: ", ")
            return ElevenLabsVoice(id: id, name: name, detail: detail)
        }
    }

    func render(_ text: String, voiceID: String, model: ElevenLabsModel, speed: Double, key: String) async throws -> RenderedSpeech {
        var components = URLComponents(
            url: base.appendingPathComponent("v1/text-to-speech/\(voiceID)/with-timestamps"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": model.rawValue,
            // ElevenLabs accepts 0.7 to 1.2.
            "voice_settings": ["speed": min(max(speed, 0.7), 1.2)],
        ])
        let data = try await send(request)
        return try Self.parseRendered(data, text: text)
    }

    static func parseRendered(_ data: Data, text: String) throws -> RenderedSpeech {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = root["audio_base64"] as? String,
              let audio = Data(base64Encoded: encoded) else { throw VoiceEngineError.malformedResponse }
        // `alignment` follows the text as sent, so its offsets match ours.
        let words = (root["alignment"] as? [String: Any]).flatMap { aligned in
            alignedWordTimings(
                text: text,
                characters: aligned["characters"] as? [String] ?? [],
                starts: (aligned["character_start_times_seconds"] as? [NSNumber])?.map(\.doubleValue) ?? []
            )
        }
        return RenderedSpeech(audio: audio, words: words)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 { throw VoiceEngineError.rejectedKey }
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { root -> String? in
                if let detail = root["detail"] as? [String: Any] { return detail["message"] as? String }
                return root["detail"] as? String
            }
            throw VoiceEngineError.service(status, detail ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return data
    }
}

/// The ElevenLabs key, kept in the login Keychain and never in a file.
public enum ElevenLabsKey {
    static let service = "com.modestnerd.mac-computer-use.elevenlabs"
    static let account = "api-key"

    public static func read() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        delete()
        return SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrLabel: "Mac Computer Use: ElevenLabs API key",
            kSecValueData: Data(key.utf8),
        ] as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }
}

// MARK: - Mac voices

/// The best voice installed for the person's language: Premium, then
/// Enhanced, then the rest.
public func bestInstalledSpeechVoice(language: String = AVSpeechSynthesisVoice.currentLanguageCode()) -> AVSpeechSynthesisVoice? {
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
    let prefix = String(language.prefix(2)).lowercased()
    func best(_ pool: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        pool.max { ($0.quality.rawValue, $0.name) < ($1.quality.rawValue, $1.name) }
    }
    let exact = voices.filter { $0.language.caseInsensitiveCompare(language) == .orderedSame }
    let sameLanguage = voices.filter { $0.language.lowercased().hasPrefix(prefix) }
    let candidates = [exact, sameLanguage].first { pool in pool.contains { $0.quality != .default } } ?? (exact.isEmpty ? sameLanguage : exact)
    return best(candidates) ?? best(voices)
}

/// "Premium", "Enhanced" or nil for a Mac voice's quality.
public func speechVoiceQualityLabel(_ voice: AVSpeechSynthesisVoice) -> String? {
    switch voice.quality {
    case .premium: return "Premium"
    case .enhanced: return "Enhanced"
    default: return nil
    }
}

/// The Mac voice used when the person hasn't picked one.
func preferredMacVoice() -> AVSpeechSynthesisVoice? {
    if !CompanionPreferences.autoBestMacVoice, let chosen = findSpeechVoice(CompanionPreferences.voiceIdentifier) {
        return chosen
    }
    return bestInstalledSpeechVoice()
}

/// What the menu shows beside "Voice…".
public func currentVoiceSummary() -> String {
    switch CompanionPreferences.voiceEngine {
    case .mac:
        guard let voice = preferredMacVoice() else { return "Mac voice" }
        return speechVoiceQualityLabel(voice).map { "\(voice.name) (\($0))" } ?? voice.name
    case .kokoro:
        guard KokoroEngine.isInstalled else { return "Kokoro · not downloaded" }
        return "Kokoro · " + (KokoroCatalog.find(CompanionPreferences.kokoroVoice)?.name ?? "Heart")
    case .elevenlabs:
        guard ElevenLabsKey.read() != nil else { return "ElevenLabs · no key yet" }
        return "ElevenLabs · " + (CompanionPreferences.elevenLabsVoiceName ?? "Rachel")
    }
}
