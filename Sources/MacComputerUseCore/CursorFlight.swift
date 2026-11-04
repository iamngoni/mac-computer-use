// Arc flight for the automation cursor, plus the small per-action cues the
// cursor shows. Pure functions, so the service (which animates) and the
// worker (which waits for the cursor to land before acting) agree exactly.
import AppKit
import CoreGraphics
import QuartzCore

enum CursorPace: String {
    /// Ordinary actions: quick enough that agents never feel slow.
    case act
    /// Pointing and teaching: slow enough for a person to follow.
    case teach
}

/// Optional global multiplier from MACCU_CURSOR_PACE: off, natural (default) or showcase.
func cursorPaceMultiplier(environment: [String: String] = ProcessInfo.processInfo.environment) -> Double {
    switch environment["MACCU_CURSOR_PACE"]?.lowercased() {
    case "off": return 0
    case "showcase": return 2
    default: return 1
    }
}

func cursorFlightDuration(distance: CGFloat, pace: CursorPace, multiplier: Double = 1) -> TimeInterval {
    guard distance.isFinite, distance > 6, multiplier > 0 else { return 0 }
    let seconds: Double
    switch pace {
    case .act: seconds = min(max(Double(distance) / 1600, 0.18), 0.5)
    case .teach: seconds = min(max(Double(distance) / 800, 0.6), 1.4)
    }
    return seconds * multiplier
}

private func smoothstep(_ t: Double) -> Double {
    let x = min(max(t, 0), 1)
    return x * x * (3 - 2 * x)
}

/// A quadratic Bezier flight in Cocoa (y-up) coordinates.
struct CursorFlight {
    let from: CGPoint
    let to: CGPoint
    let control: CGPoint
    let start: CFTimeInterval
    let duration: TimeInterval
    let swell: CGFloat

    /// The cursor art points up and to the left at rest.
    static let restingAngle = CGFloat.pi * 3 / 4

    init(from: CGPoint, to: CGPoint, start: CFTimeInterval, pace: CursorPace, multiplier: Double = 1) {
        self.from = from
        self.to = to
        self.start = start
        let distance = hypot(to.x - from.x, to.y - from.y)
        duration = cursorFlightDuration(distance: distance, pace: pace, multiplier: multiplier)
        let lift = pace == .teach ? min(distance * 0.2, 80) : min(distance * 0.12, 40)
        control = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 + lift)
        swell = pace == .teach ? 0.3 : 0.12
    }

    struct Sample: Equatable {
        let point: CGPoint
        let rotation: CGFloat
        let scale: CGFloat
        let finished: Bool
    }

    func sample(at now: CFTimeInterval) -> Sample {
        guard duration > 0 else { return Sample(point: to, rotation: 0, scale: 1, finished: true) }
        let raw = (now - start) / duration
        if raw >= 1 { return Sample(point: to, rotation: 0, scale: 1, finished: true) }
        let t = max(raw, 0)
        let e = CGFloat(smoothstep(t))
        let u = 1 - e
        let point = CGPoint(
            x: u * u * from.x + 2 * u * e * control.x + e * e * to.x,
            y: u * u * from.y + 2 * u * e * control.y + e * e * to.y
        )
        let tangent = CGVector(
            dx: 2 * u * (control.x - from.x) + 2 * e * (to.x - control.x),
            dy: 2 * u * (control.y - from.y) + 2 * e * (to.y - control.y)
        )
        let weight = CGFloat(sin(Double.pi * t))
        var turn = atan2(tangent.dy, tangent.dx) - Self.restingAngle
        turn = atan2(sin(turn), cos(turn))
        return Sample(point: point, rotation: turn * weight, scale: 1 + swell * weight, finished: false)
    }
}

/// The small badge that shows what the cursor is doing, derived from the
/// action's status text. Clicking shows no badge; the click pulse says enough.
func cursorBadgeSymbol(forStatus status: String) -> String? {
    let text = status.lowercased()
    let badges: [(String, String)] = [
        ("typing", "keyboard"),
        ("pressing", "command"),
        ("scrolling", "arrow.up.and.down"),
        ("dragging", "hand.draw"),
        ("setting value", "pencil"),
        ("selecting", "character.cursor.ibeam"),
        ("opening", "arrow.up.forward.app"),
        ("moving window", "macwindow"),
        ("navigating", "safari"),
        ("menu", "filemenu.and.selection"),
    ]
    return badges.first { text.hasPrefix($0.0) }?.1
}

/// A short horizontal shake after an action fails.
func cursorShakeOffset(now: CFTimeInterval, startedAt: CFTimeInterval?) -> CGFloat {
    guard let startedAt else { return 0 }
    let age = now - startedAt
    guard age >= 0, age < 0.4 else { return 0 }
    return CGFloat(sin(age * 48) * 4 * (1 - age / 0.4))
}

/// Remaining fraction of a countdown ring, from 1 down to 0.
func cursorCountdownRemaining(now: CFTimeInterval, start: CFTimeInterval, duration: TimeInterval) -> CGFloat {
    guard duration > 0 else { return 0 }
    return CGFloat(min(max(1 - (now - start) / duration, 0), 1))
}

/// Distinct, accessible glow colours for telling concurrent agents apart.
let cursorIdentityPalette: [NSColor] = [
    .systemBlue, .systemPink, .systemGreen, .systemOrange, .systemPurple, .systemTeal,
]

func cursorIdentityColorIndex(forClientKey key: String) -> Int {
    var hash: UInt64 = 1469598103934665603
    for byte in key.utf8 {
        hash = (hash ^ UInt64(byte)) &* 1099511628211
    }
    return Int(hash % UInt64(cursorIdentityPalette.count))
}

// MARK: - Reactions

enum CursorEmote: String, CaseIterable {
    case nod, shake, sparkle, celebrate
}

/// How a reaction displaces the cursor at one instant.
struct CursorEmotePose: Equatable {
    var lift: CGFloat = 0     // points, y-up
    var tilt: CGFloat = 0     // radians
    var scale: CGFloat = 1
    var sparkle: CGFloat = 0  // 0 = none, else burst progress in (0, 1]
    static let rest = CursorEmotePose()
}

func cursorEmoteDuration(_ emote: CursorEmote) -> TimeInterval {
    switch emote {
    case .nod: return 0.8
    case .shake: return 0.45
    case .sparkle: return 0.9
    case .celebrate: return 1.1
    }
}

func cursorEmotePose(_ emote: (kind: CursorEmote, start: CFTimeInterval)?, now: CFTimeInterval) -> CursorEmotePose {
    guard let emote else { return .rest }
    let duration = cursorEmoteDuration(emote.kind)
    let t = (now - emote.start) / duration
    guard t >= 0, t < 1 else { return .rest }
    let fade = CGFloat(1 - t)
    switch emote.kind {
    case .nod:
        // Two quick dips, like a nod.
        return CursorEmotePose(lift: -CGFloat(abs(sin(t * .pi * 2))) * 5 * fade, tilt: CGFloat(sin(t * .pi * 2)) * 0.08 * fade)
    case .shake:
        return .rest // the view's own shake offset handles this
    case .sparkle:
        return CursorEmotePose(scale: 1 + CGFloat(sin(min(t * 3, 1) * .pi)) * 0.12, sparkle: CGFloat(t))
    case .celebrate:
        let hop = CGFloat(abs(sin(t * .pi * 3))) * 9 * fade
        return CursorEmotePose(lift: hop, tilt: CGFloat(sin(t * .pi * 4)) * 0.18 * fade, scale: 1 + 0.1 * fade, sparkle: CGFloat(t))
    }
}

/// Where a following cursor rests relative to the person's pointer (Cocoa,
/// y-up): just below and to the right, out of the way of what they click.
let buddyFollowOffset = CGPoint(x: 30, y: -30)

/// One spring step toward `target`; frame-rate independent.
func buddyFollowStep(from current: CGPoint, to target: CGPoint, dt: CFTimeInterval) -> CGPoint {
    let k = CGFloat(1 - exp(-dt * 12))
    return CGPoint(x: current.x + (target.x - current.x) * k, y: current.y + (target.y - current.y) * k)
}
