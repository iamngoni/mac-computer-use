import Foundation
import CoreGraphics

// MARK: - Key specs ("cmd+shift+t", "Return", "cmd++")
// Shared by press_key and desktop_press_key so app-scoped and desktop key handling agree.
// Named keys whose physical position never moves between layouts keep fixed keycodes;
// every character key is resolved through the current keyboard layout, and a character the
// layout cannot produce fails closed rather than falling back to a US keycode.

enum KeyModifier: Equatable {
    case command, shift, control, option

    init?(name: String) {
        switch name.lowercased() {
        case "cmd", "command", "super", "meta": self = .command
        case "shift": self = .shift
        case "ctrl", "control": self = .control
        case "alt", "option", "opt": self = .option
        default: return nil
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        }
    }

    /// Left-hand modifier keycode, for desktop delivery that presses modifiers physically.
    var keyCode: CGKeyCode {
        switch self {
        case .command: return 55
        case .shift: return 56
        case .control: return 59
        case .option: return 58
        }
    }
}

struct KeyCombo: Equatable {
    let keyCode: CGKeyCode
    /// In press order: the spec's modifiers, then any Shift/Option the layout needs to
    /// produce the requested character.
    let modifiers: [KeyModifier]

    var flags: CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { $0.insert($1.flag) }
    }
}

enum KeySpecError: Error, Equatable, CustomStringConvertible {
    case malformed(spec: String)
    case unknownModifier(String, spec: String)
    case unknownKey(String, spec: String)
    case unresolvableCharacter(Character, layoutID: String)
    case layoutUnavailable(Character, reason: String)

    var description: String {
        switch self {
        case .malformed(let spec):
            return "Malformed key spec '\(spec)'. Join modifiers and one key with '+', e.g. cmd+shift+t, cmd+- or cmd++."
        case .unknownModifier(let name, let spec):
            return "Unknown modifier '\(name)' in key spec '\(spec)'. Supported modifiers: cmd, shift, ctrl, alt/option."
        case .unknownKey(let name, let spec):
            return "Unknown key '\(name)' in key spec '\(spec)'. Use a single character or a named key "
                + "(Return, Tab, Escape, Space, Delete, ForwardDelete, Up/Down/Left/Right, Home, End, PageUp, PageDown, F1-F20, minus, plus, ...)."
        case .unresolvableCharacter(let character, let layoutID):
            return "Key '\(character)' cannot be produced by a single keystroke on the current keyboard layout (\(layoutID)); nothing was sent."
        case .layoutUnavailable(let character, let reason):
            return "Key '\(character)' was not sent: \(reason)."
        }
    }
}

/// Keys whose physical position is the same on every layout.
let layoutIndependentKeyCodes: [String: CGKeyCode] = [
    "return": 36, "enter": 36, "tab": 48, "space": 49,
    "delete": 51, "backspace": 51, "forwarddelete": 117, "escape": 53, "esc": 53,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
    "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
]

/// Names for punctuation keys; these are characters, so they still go through the layout.
let keyCharacterAliases: [String: Character] = [
    "minus": "-", "equal": "=", "plus": "+", "bracketleft": "[", "bracketright": "]",
    "quote": "'", "backslash": "\\", "grave": "`", "semicolon": ";", "comma": ",",
    "period": ".", "slash": "/",
]

/// Splits a spec into modifier names and the key. "+" separates parts, but a trailing "+"
/// after a separator is the plus key itself: "cmd++" is Command and "+", "+" alone is "+".
func splitKeySpec(_ spec: String) -> (modifiers: [String], key: String)? {
    if spec == "+" { return ([], "+") }
    let modifiers: [String]
    let key: String
    if spec.hasSuffix("++") {
        key = "+"
        modifiers = spec.dropLast(2).split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    } else {
        let parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        key = parts.last ?? ""
        modifiers = Array(parts.dropLast())
    }
    guard !key.isEmpty, !modifiers.contains(where: \.isEmpty) else { return nil }
    return (modifiers, key)
}

private enum KeyTarget {
    case fixed(CGKeyCode)
    case character(Character)
}

private func keyTarget(_ name: String) -> KeyTarget? {
    let lowered = name.lowercased()
    if let code = layoutIndependentKeyCodes[lowered] { return .fixed(code) }
    if let character = keyCharacterAliases[lowered] { return .character(character) }
    guard name.count == 1, let original = name.first else { return nil }
    // Specs are case-insensitive as before: "cmd+A" means the A key, not Shift+A.
    if lowered.count == 1, let character = lowered.first { return .character(character) }
    return .character(original)
}

/// Parses and resolves a key spec. Never guesses: anything unknown or not producible on the
/// current layout throws `KeySpecError`.
func parseKeySpec(_ spec: String, layout: KeyboardLayoutSource) throws -> KeyCombo {
    guard let parts = splitKeySpec(spec) else { throw KeySpecError.malformed(spec: spec) }
    var modifiers: [KeyModifier] = []
    for name in parts.modifiers {
        guard let modifier = KeyModifier(name: name) else {
            throw KeySpecError.unknownModifier(name, spec: spec)
        }
        if !modifiers.contains(modifier) { modifiers.append(modifier) }
    }
    switch keyTarget(parts.key) {
    case nil:
        throw KeySpecError.unknownKey(parts.key, spec: spec)
    case .fixed(let keyCode):
        return KeyCombo(keyCode: keyCode, modifiers: modifiers)
    case .character(let character):
        func map(holding held: KeyboardLayoutModifiers) throws -> KeyboardLayoutMap {
            do {
                return try layout.layoutMap(holding: held)
            } catch let error as KeyboardLayoutUnavailable {
                throw KeySpecError.layoutUnavailable(character, reason: error.reason)
            } catch {
                throw KeySpecError.layoutUnavailable(character, reason: "\(error)")
            }
        }
        // With ⌘ down some layouts switch key maps (Dvorak - QWERTY ⌘ types QWERTY shortcuts,
        // Russian types Latin ones), so a shortcut is first resolved in that context. Other
        // layouts' ⌘ maps ignore Shift (US: ⌘⇧= still reads "="), so a character missing there
        // falls back to the key a person would press, e.g. ⇧= for "+" in cmd++.
        let stroke: KeyStroke
        if modifiers.contains(.command), let commandStroke = try map(holding: .command).stroke(for: character) {
            stroke = commandStroke
        } else {
            let plain = try map(holding: [])
            guard let plainStroke = plain.stroke(for: character) else {
                throw KeySpecError.unresolvableCharacter(character, layoutID: plain.layoutID)
            }
            stroke = plainStroke
        }
        var resolved = modifiers
        for extra in [KeyModifier.shift, .option] where stroke.flags.contains(extra.flag) && !resolved.contains(extra) {
            resolved.append(extra)
        }
        return KeyCombo(keyCode: stroke.keyCode, modifiers: resolved)
    }
}

/// nil when `spec` resolves on `layout`, otherwise the reason nothing would be sent.
func keySpecProblem(_ spec: String, layout: KeyboardLayoutSource = KeyboardLayoutCache.system) -> KeySpecError? {
    do {
        _ = try parseKeySpec(spec, layout: layout)
        return nil
    } catch let error as KeySpecError {
        return error
    } catch {
        return .malformed(spec: spec)
    }
}

// MARK: - Typing

enum TypingStep: Equatable {
    /// A real keystroke (accepted by fields, e.g. browser omniboxes, that ignore unicode injection).
    case key(KeyStroke)
    /// Unicode-string injection for characters the layout cannot type with one keystroke.
    case unicode(String)
}

/// Characters typed with layout-independent keys; newlines are typed as Return.
let layoutIndependentTypingKeys: [Character: CGKeyCode] = [" ": 49, "\t": 48, "\n": 36, "\r": 36]

func typingStep(for character: Character, layout: KeyboardLayoutMap?) -> TypingStep {
    if let keyCode = layoutIndependentTypingKeys[character] {
        return .key(KeyStroke(keyCode: keyCode, flags: []))
    }
    if let stroke = layout?.stroke(for: character) { return .key(stroke) }
    return .unicode(String(character))
}
