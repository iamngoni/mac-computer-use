// Personal settings for how agents look and sound: the cursor's colour,
// size and trail, and the voice and speed agents speak in. Stored in the
// app's defaults so Setup and the service (one process) agree.
import AppKit
import AVFoundation
import Foundation

public enum CompanionPreferences {
    public static let tints = ["blue", "purple", "pink", "orange", "green", "graphite"]
    public static let trailStyles = ["glow", "subtle", "off"]

    private static var defaults: UserDefaults { .standard }

    public static var cursorTint: String {
        get { defaults.string(forKey: "cursorTint").flatMap { tints.contains($0) ? $0 : nil } ?? "blue" }
        set { defaults.set(newValue, forKey: "cursorTint") }
    }

    /// 0.8 to 1.6 times the standard cursor.
    public static var cursorScale: Double {
        get { clampedCursorScale(defaults.object(forKey: "cursorScale") as? Double ?? 1) }
        set { defaults.set(clampedCursorScale(newValue), forKey: "cursorScale") }
    }

    public static var trailStyle: String {
        get { defaults.string(forKey: "trailStyle").flatMap { trailStyles.contains($0) ? $0 : nil } ?? "glow" }
        set { defaults.set(newValue, forKey: "trailStyle") }
    }

    /// An AVSpeechSynthesisVoice identifier, or nil for the system voice.
    public static var voiceIdentifier: String? {
        get { defaults.string(forKey: "voiceIdentifier") }
        set { defaults.set(newValue, forKey: "voiceIdentifier") }
    }

    /// 0.5 to 1.5 times normal speaking speed.
    public static var speechRate: Double {
        get { clampedSpeechRate(defaults.object(forKey: "speechRate") as? Double ?? 1) }
        set { defaults.set(clampedSpeechRate(newValue), forKey: "speechRate") }
    }
}

func clampedCursorScale(_ value: Double) -> Double { value.isFinite ? min(max(value, 0.8), 1.6) : 1 }
func clampedSpeechRate(_ value: Double) -> Double { value.isFinite ? min(max(value, 0.5), 1.5) : 1 }

/// The tint for the cursor art; nil keeps the original blue art.
public func cursorTintColor(_ name: String) -> NSColor? {
    switch name {
    case "purple": return NSColor(calibratedRed: 0.49, green: 0.36, blue: 1, alpha: 1)
    case "pink": return NSColor(calibratedRed: 1, green: 0.30, blue: 0.55, alpha: 1)
    case "orange": return NSColor(calibratedRed: 1, green: 0.55, blue: 0.15, alpha: 1)
    case "green": return NSColor(calibratedRed: 0.13, green: 0.78, blue: 0.50, alpha: 1)
    case "graphite": return NSColor(calibratedWhite: 0.28, alpha: 1)
    default: return nil
    }
}

/// Maps a speaking-speed multiplier onto AVSpeechUtterance's rate range.
func utteranceRate(multiplier: Double) -> Float {
    let m = Float(clampedSpeechRate(multiplier))
    let base = AVSpeechUtteranceDefaultSpeechRate
    // Above 1, use half the distance to the maximum (which is very fast);
    // below 1, slow down linearly toward 60% of the default.
    return m >= 1
        ? base + (AVSpeechUtteranceMaximumSpeechRate - base) * (m - 1) * 0.5
        : base * (0.6 + 0.8 * (m - 0.5))
}

/// Finds a voice by identifier, name ("Samantha") or language ("en-GB").
public func findSpeechVoice(_ query: String?) -> AVSpeechSynthesisVoice? {
    guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else { return nil }
    if let exact = AVSpeechSynthesisVoice(identifier: query) { return exact }
    let voices = AVSpeechSynthesisVoice.speechVoices()
    let ranked = voices.sorted { $0.quality.rawValue > $1.quality.rawValue }
    if let named = ranked.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) { return named }
    return ranked.first { $0.language.caseInsensitiveCompare(query) == .orderedSame }
        ?? ranked.first { $0.language.lowercased().hasPrefix(query.lowercased()) }
}

/// Voices worth offering: one entry per name, best quality first.
public func availableSpeechVoices() -> [(id: String, name: String, language: String)] {
    var seen = Set<String>()
    return AVSpeechSynthesisVoice.speechVoices()
        .sorted { ($0.language, -$0.quality.rawValue, $0.name) < ($1.language, -$1.quality.rawValue, $1.name) }
        .filter { seen.insert($0.name + $0.language).inserted }
        .map { ($0.identifier, $0.name, $0.language) }
}
