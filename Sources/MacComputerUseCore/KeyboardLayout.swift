import Foundation
import Carbon
import CoreGraphics

// MARK: - Keyboard layout resolution
// Virtual keycodes name physical key positions, not characters: keycode 0 types "a" on
// US/ABC but "q" on French AZERTY, so a hard-coded US table turns cmd+a into cmd+q there.
// Anything that turns a character into a keycode must ask the user's current layout which
// key (plus which Shift/Option) produces it.

/// Modifier state a layout translates a key under. `command` is only ever "held" context:
/// some layouts (Dvorak - QWERTY ⌘, Russian, …) switch to a different key map while ⌘ is down.
struct KeyboardLayoutModifiers: OptionSet, Hashable {
    let rawValue: UInt8
    static let shift = KeyboardLayoutModifiers(rawValue: 1 << 0)
    static let option = KeyboardLayoutModifiers(rawValue: 1 << 1)
    static let command = KeyboardLayoutModifiers(rawValue: 1 << 2)

    var eventFlags: CGEventFlags {
        var flags = CGEventFlags()
        if contains(.shift) { flags.insert(.maskShift) }
        if contains(.option) { flags.insert(.maskAlternate) }
        if contains(.command) { flags.insert(.maskCommand) }
        return flags
    }

    /// The `modifierKeyState` argument of UCKeyTranslate (EventRecord modifiers >> 8).
    var carbonModifierKeyState: UInt32 {
        var modifiers = 0
        if contains(.shift) { modifiers |= shiftKey }
        if contains(.option) { modifiers |= optionKey }
        if contains(.command) { modifiers |= cmdKey }
        return UInt32((modifiers >> 8) & 0xFF)
    }
}

/// One physical keystroke: a virtual keycode plus the modifier flags held while it is pressed.
struct KeyStroke: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

/// The text one key produces under a modifier state, or nil when it produces none
/// (dead key, unassigned key).
typealias KeyboardLayoutTranslator = (CGKeyCode, KeyboardLayoutModifiers) -> String?

/// Character -> keystroke table for one layout in one held-modifier context.
struct KeyboardLayoutMap {
    let layoutID: String
    private let strokes: [Character: KeyStroke]

    /// Extra modifiers tried, simplest first, so "1" prefers an unshifted key when one exists.
    static let searchOrder: [KeyboardLayoutModifiers] = [[], [.shift], [.option], [.option, .shift]]
    /// Keycodes 0...127 limited to the main typing block: ANSI/ISO keys 0...50 plus the JIS
    /// ¥ (93) and _ (94) keys. Keypad keys carry keypad semantics (application keypad mode
    /// in terminals, separate bindings) and some layouts fill unlabeled codes with no physical
    /// key (e.g. 70 types "+" under ⌥⇧ on US), so neither is ever chosen. Everything above 50
    /// that is a real key (arrows, F-keys, Home, ...) produces control output, not text.
    static let typingKeyCodes: [CGKeyCode] = Array(0...50) + [93, 94]

    /// A fixed table, e.g. a fake layout in tests.
    init(layoutID: String, strokes table: [Character: (CGKeyCode, CGEventFlags)]) {
        self.layoutID = layoutID
        self.strokes = table.mapValues { KeyStroke(keyCode: $0.0, flags: $0.1) }
    }

    /// Builds the reverse map by translating each typing key under each extra modifier set
    /// (with `held` also down). The first, simplest keystroke producing a character wins.
    init(layoutID: String, holding held: KeyboardLayoutModifiers = [], translate: KeyboardLayoutTranslator) {
        var strokes: [Character: KeyStroke] = [:]
        for extra in Self.searchOrder {
            for keyCode in Self.typingKeyCodes {
                guard let text = translate(keyCode, held.union(extra)),
                      let character = Self.typableCharacter(text),
                      strokes[character] == nil else { continue }
                strokes[character] = KeyStroke(keyCode: keyCode, flags: extra.eventFlags)
            }
        }
        self.layoutID = layoutID
        self.strokes = strokes
    }

    func stroke(for character: Character) -> KeyStroke? { strokes[character] }

    /// A single printable character; control output (Return, Tab, Delete, arrows) and the
    /// private-use function-key characters are not text.
    static func typableCharacter(_ text: String) -> Character? {
        guard text.count == 1, let character = text.first else { return nil }
        for scalar in character.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .surrogate, .unassigned: return nil
            default: continue
            }
        }
        return character
    }
}

struct KeyboardLayoutUnavailable: Error, Equatable {
    let reason: String
}

/// Where key resolution reads layout tables from. Production uses `KeyboardLayoutCache.system`;
/// tests inject fake layouts.
protocol KeyboardLayoutSource {
    /// The current layout's table with `held` modifiers down. Throws `KeyboardLayoutUnavailable`.
    func layoutMap(holding held: KeyboardLayoutModifiers) throws -> KeyboardLayoutMap
}

/// Caches reverse maps for the current layout and rebuilds them when the layout changes.
final class KeyboardLayoutCache: KeyboardLayoutSource {
    struct Current {
        let id: String
        var keyboardType: UInt32 = 0
        let translate: KeyboardLayoutTranslator
    }

    static let system = KeyboardLayoutCache {
        SystemKeyboardLayout.currentOnMainThread().map {
            Current(id: $0.id, keyboardType: $0.keyboardType, translate: $0.translate)
        }
    }

    private let current: () -> Current?
    private let lock = NSLock()
    private var cachedID: String?
    private var cachedKeyboardType: UInt32 = 0
    private var maps: [KeyboardLayoutModifiers: KeyboardLayoutMap] = [:]
    /// Number of reverse maps built; lets tests observe cache hits and invalidation.
    private(set) var buildCount = 0

    init(current: @escaping () -> Current?) { self.current = current }

    func layoutMap(holding held: KeyboardLayoutModifiers) throws -> KeyboardLayoutMap {
        guard let layout = current() else {
            throw KeyboardLayoutUnavailable(reason: "the current keyboard layout could not be read")
        }
        // Only ⌘ selects a different key map; Shift/Option are searched per character.
        let context: KeyboardLayoutModifiers = held.contains(.command) ? .command : []
        lock.lock(); defer { lock.unlock() }
        if layout.id != cachedID || layout.keyboardType != cachedKeyboardType {
            cachedID = layout.id
            cachedKeyboardType = layout.keyboardType
            maps = [:]
        }
        if let map = maps[context] { return map }
        let map = KeyboardLayoutMap(layoutID: layout.id, holding: context, translate: layout.translate)
        maps[context] = map
        buildCount += 1
        return map
    }
}

/// One installed keyboard layout's Unicode ('uchr') data, translated with UCKeyTranslate.
struct SystemKeyboardLayout {
    let id: String
    let keyboardType: UInt32
    private let layoutData: Data

    /// The layout keystrokes currently go through (also while an input method is active).
    /// Text Input Sources calls belong on the main thread; tools already run there.
    static func current() -> SystemKeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return SystemKeyboardLayout(source: source)
    }

    /// TIS has been reported to assert off the main thread on some macOS releases, and the
    /// stdio loop may be parked in readLine() on main, so off-main callers hop with a timeout
    /// instead of risking a crash or a deadlock. A timeout reads as "layout unavailable".
    static func currentOnMainThread(timeout: TimeInterval = 1) -> SystemKeyboardLayout? {
        if Thread.isMainThread { return current() }
        final class Box { var layout: SystemKeyboardLayout? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            box.layout = current()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.layout
    }

    /// Any installed layout by input source ID (e.g. "com.apple.keylayout.French"), enabled
    /// or not. Read-only; never changes the user's selected layout.
    static func installed(id: String) -> SystemKeyboardLayout? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return nil }
        return SystemKeyboardLayout(source: source)
    }

    private init?(source: TISInputSource) {
        guard let id: String = Self.property(source, kTISPropertyInputSourceID),
              let data: Data = Self.property(source, kTISPropertyUnicodeKeyLayoutData),
              !data.isEmpty else { return nil }
        self.id = id
        self.keyboardType = UInt32(LMGetKbdType())
        self.layoutData = data
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? T
    }

    func translate(_ keyCode: CGKeyCode, _ modifiers: KeyboardLayoutModifiers) -> String? {
        layoutData.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            // Dead-key processing stays on: a dead key leaves deadKeyState set and emits
            // nothing, which marks it as not typable with one keystroke.
            let status = UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keyCode,
                UInt16(kUCKeyActionDown),
                modifiers.carbonModifierKeyState,
                keyboardType,
                0,
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, deadKeyState == 0, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}
