import CoreGraphics
import XCTest
@testable import MacComputerUseCore

// MARK: - Fake layouts

private struct FakeKey {
    var plain: String?
    var shift: String?
    var option: String? = nil
    var optionShift: String? = nil
}

private func fakeTranslator(
    _ keys: [CGKeyCode: FakeKey],
    command: [CGKeyCode: FakeKey]? = nil
) -> KeyboardLayoutTranslator {
    return { keyCode, modifiers in
        let table = modifiers.contains(.command) ? (command ?? keys) : keys
        guard let key = table[keyCode] else { return nil }
        switch (modifiers.contains(.option), modifiers.contains(.shift)) {
        case (false, false): return key.plain
        case (false, true): return key.shift
        case (true, false): return key.option
        case (true, true): return key.optionShift
        }
    }
}

/// French-AZERTY-like: the US "Q" position (keycode 12) types "a", keycode 0 types "q",
/// digits need Shift, and keycode 42 is a dead key (no output).
private let azertyKeys: [CGKeyCode: FakeKey] = [
    0: FakeKey(plain: "q", shift: "Q"),
    1: FakeKey(plain: "s", shift: "S"),
    6: FakeKey(plain: "w", shift: "W"),
    12: FakeKey(plain: "a", shift: "A", option: "æ", optionShift: "Æ"),
    13: FakeKey(plain: "z", shift: "Z"),
    14: FakeKey(plain: "e", shift: "E"),
    18: FakeKey(plain: "&", shift: "1"),
    19: FakeKey(plain: "é", shift: "2"),
    23: FakeKey(plain: "(", shift: "5", option: "{", optionShift: "["),
    24: FakeKey(plain: "-", shift: "_"),
    27: FakeKey(plain: ")", shift: "°"),
    36: FakeKey(plain: "\r", shift: "\r"),
    42: FakeKey(plain: nil, shift: "£"),
    44: FakeKey(plain: "=", shift: "+"),
    50: FakeKey(plain: "<", shift: ">"),
]

private let usKeys: [CGKeyCode: FakeKey] = [
    0: FakeKey(plain: "a", shift: "A", option: "å"),
    8: FakeKey(plain: "c", shift: "C"),
    12: FakeKey(plain: "q", shift: "Q"),
    17: FakeKey(plain: "t", shift: "T"),
    18: FakeKey(plain: "1", shift: "!"),
    24: FakeKey(plain: "=", shift: "+"),
    27: FakeKey(plain: "-", shift: "_"),
    30: FakeKey(plain: "]", shift: "}"),
    33: FakeKey(plain: "[", shift: "{"),
    39: FakeKey(plain: "'", shift: "\""),
    41: FakeKey(plain: ";", shift: ":"),
    42: FakeKey(plain: "\\", shift: "|"),
    43: FakeKey(plain: ",", shift: "<"),
    44: FakeKey(plain: "/", shift: "?"),
    47: FakeKey(plain: ".", shift: ">"),
    50: FakeKey(plain: "`", shift: "~"),
]

private func fakeLayout(_ id: String, _ keys: [CGKeyCode: FakeKey], command: [CGKeyCode: FakeKey]? = nil) -> KeyboardLayoutCache {
    let translate = fakeTranslator(keys, command: command)
    return KeyboardLayoutCache { KeyboardLayoutCache.Current(id: id, translate: translate) }
}

/// A plain `[Character: (CGKeyCode, CGEventFlags)]` table as the layout.
private struct TableLayout: KeyboardLayoutSource {
    let map: KeyboardLayoutMap
    func layoutMap(holding held: KeyboardLayoutModifiers) throws -> KeyboardLayoutMap { map }
}

/// A layout that cannot be read; also proves named keys never consult the layout.
private struct UnreadableLayout: KeyboardLayoutSource {
    func layoutMap(holding held: KeyboardLayoutModifiers) throws -> KeyboardLayoutMap {
        throw KeyboardLayoutUnavailable(reason: "test layout is unreadable")
    }
}

private func installedLayout(_ id: String) throws -> SystemKeyboardLayout {
    guard let layout = SystemKeyboardLayout.installed(id: id) else {
        throw XCTSkip("\(id) is not installed on this machine")
    }
    return layout
}

private func cache(for layout: SystemKeyboardLayout) -> KeyboardLayoutCache {
    KeyboardLayoutCache {
        KeyboardLayoutCache.Current(id: layout.id, keyboardType: layout.keyboardType, translate: layout.translate)
    }
}

final class KeyboardLayoutTests: XCTestCase {
    private let azerty = fakeLayout("test.azerty", azertyKeys)
    private let us = fakeLayout("test.us", usKeys)

    // MARK: Layout resolution

    func testAZERTYResolvesCharactersToTheirOwnPhysicalKeys() throws {
        let map = try azerty.layoutMap(holding: [])
        XCTAssertEqual(map.stroke(for: "a"), KeyStroke(keyCode: 12, flags: []))
        XCTAssertNotEqual(map.stroke(for: "a")?.keyCode, 0)
        XCTAssertEqual(map.stroke(for: "q"), KeyStroke(keyCode: 0, flags: []))
        XCTAssertEqual(map.stroke(for: "A"), KeyStroke(keyCode: 12, flags: .maskShift))
        XCTAssertEqual(map.stroke(for: "&"), KeyStroke(keyCode: 18, flags: []))
        XCTAssertEqual(map.stroke(for: "1"), KeyStroke(keyCode: 18, flags: .maskShift))
        XCTAssertEqual(map.stroke(for: "é"), KeyStroke(keyCode: 19, flags: []))
        XCTAssertEqual(map.stroke(for: "æ"), KeyStroke(keyCode: 12, flags: .maskAlternate))
        XCTAssertEqual(map.stroke(for: "["), KeyStroke(keyCode: 23, flags: [.maskAlternate, .maskShift]))
    }

    func testCmdAOnAZERTYSendsTheAKeyNotCmdQ() throws {
        let combo = try parseKeySpec("cmd+a", layout: azerty)
        XCTAssertEqual(combo.keyCode, 12)
        XCTAssertNotEqual(combo.keyCode, 0, "keycode 0 is Q on AZERTY: cmd+a must never become cmd+q")
        XCTAssertEqual(combo.flags, .maskCommand)
        XCTAssertEqual(combo.modifiers, [.command])

        XCTAssertEqual(try parseKeySpec("cmd+q", layout: azerty).keyCode, 0)
        XCTAssertEqual(try parseKeySpec("CMD+A", layout: azerty), combo)

        let shiftZ = try parseKeySpec("cmd+shift+z", layout: azerty)
        XCTAssertEqual(shiftZ.keyCode, 13)
        XCTAssertEqual(shiftZ.flags, [.maskCommand, .maskShift])

        // A digit that needs Shift on this layout gets Shift added, after the spec's modifiers.
        let one = try parseKeySpec("cmd+1", layout: azerty)
        XCTAssertEqual(one.keyCode, 18)
        XCTAssertEqual(one.modifiers, [.command, .shift])

        // Same result through an injected [Character: (CGKeyCode, CGEventFlags)] table.
        let table = TableLayout(map: KeyboardLayoutMap(
            layoutID: "test.azerty.table",
            strokes: ["a": (12, []), "q": (0, []), "1": (18, .maskShift)]
        ))
        XCTAssertEqual(try parseKeySpec("cmd+a", layout: table), KeyCombo(keyCode: 12, modifiers: [.command]))
        XCTAssertEqual(try parseKeySpec("cmd+1", layout: table), KeyCombo(keyCode: 18, modifiers: [.command, .shift]))
    }

    func testUnresolvableCharacterFailsClosed() {
        XCTAssertThrowsError(try parseKeySpec("cmd+ß", layout: azerty)) { error in
            XCTAssertEqual(error as? KeySpecError, .unresolvableCharacter("ß", layoutID: "test.azerty"))
        }
        // Keycode 42 is a dead key on the fake AZERTY, so "`" has no single keystroke even
        // though the US layout has it on keycode 50.
        XCTAssertThrowsError(try parseKeySpec("cmd+grave", layout: azerty)) { error in
            XCTAssertEqual(error as? KeySpecError, .unresolvableCharacter("`", layoutID: "test.azerty"))
        }
        let problem = keySpecProblem("ß", layout: azerty)
        XCTAssertEqual(problem, .unresolvableCharacter("ß", layoutID: "test.azerty"))
        XCTAssertTrue(problem?.description.contains("nothing was sent") == true)
        XCTAssertTrue(problem?.description.contains("test.azerty") == true)

        let table = TableLayout(map: KeyboardLayoutMap(layoutID: "test.empty", strokes: [:]))
        XCTAssertThrowsError(try parseKeySpec("cmd+a", layout: table)) { error in
            XCTAssertEqual(error as? KeySpecError, .unresolvableCharacter("a", layoutID: "test.empty"))
        }
    }

    func testUnreadableLayoutFailsClosedForCharactersOnly() throws {
        XCTAssertThrowsError(try parseKeySpec("cmd+a", layout: UnreadableLayout())) { error in
            XCTAssertEqual(error as? KeySpecError, .layoutUnavailable("a", reason: "test layout is unreadable"))
        }
        XCTAssertEqual(try parseKeySpec("cmd+shift+left", layout: UnreadableLayout()), KeyCombo(keyCode: 123, modifiers: [.command, .shift]))
    }

    func testCommandShortcutsResolveInTheLayoutsCommandKeyMap() throws {
        // Dvorak - QWERTY ⌘: keycode 34 types "c", but with ⌘ held keycode 8 types "c".
        let dvorak = fakeLayout(
            "test.dvorak-qwerty-cmd",
            [8: FakeKey(plain: "j", shift: "J"), 34: FakeKey(plain: "c", shift: "C")],
            command: [8: FakeKey(plain: "c", shift: "C"), 34: FakeKey(plain: "i", shift: "I")]
        )
        XCTAssertEqual(try parseKeySpec("cmd+c", layout: dvorak).keyCode, 8)
        XCTAssertEqual(try parseKeySpec("ctrl+c", layout: dvorak).keyCode, 34)
        XCTAssertEqual(typingStep(for: "c", layout: try dvorak.layoutMap(holding: [])), .key(KeyStroke(keyCode: 34, flags: [])))
    }

    func testCommandShortcutFallsBackToThePlainKeyWhenTheCommandMapIgnoresShift() throws {
        // US-style ⌘ map: ⌘⇧= still reads "=", so "+" is only reachable via the plain map.
        let ignoresShift = usKeys.mapValues { FakeKey(plain: $0.plain, shift: $0.plain, option: $0.option, optionShift: $0.option) }
        let layout = fakeLayout("test.us-cmd-ignores-shift", usKeys, command: ignoresShift)
        XCTAssertEqual(try parseKeySpec("cmd++", layout: layout), KeyCombo(keyCode: 24, modifiers: [.command, .shift]))
        XCTAssertEqual(try parseKeySpec("cmd+=", layout: layout), KeyCombo(keyCode: 24, modifiers: [.command]))
        XCTAssertEqual(try parseKeySpec("cmd+shift+/", layout: layout), KeyCombo(keyCode: 44, modifiers: [.command, .shift]))
        XCTAssertThrowsError(try parseKeySpec("cmd+ß", layout: layout)) { error in
            XCTAssertEqual(error as? KeySpecError, .unresolvableCharacter("ß", layoutID: "test.us-cmd-ignores-shift"))
        }
    }

    func testReverseMapPrefersSimpleMainBlockKeysAndSkipsNonText() {
        let map = KeyboardLayoutMap(layoutID: "test.rules", translate: fakeTranslator([
            83: FakeKey(plain: "1", shift: "1"),          // keypad 1: never chosen
            70: FakeKey(plain: nil, shift: "+"),           // no physical key: never chosen
            93: FakeKey(plain: "¥", shift: "|"),           // JIS ¥ key: a typing key
            18: FakeKey(plain: "&", shift: "1"),
            36: FakeKey(plain: "\r", shift: "\r"),        // Return: control output
            123: FakeKey(plain: "\u{1C}", shift: "\u{1C}"), // left arrow: control output
            122: FakeKey(plain: "\u{F704}", shift: "\u{F704}"), // F1: private-use output
            42: FakeKey(plain: nil, shift: nil),           // dead key
            1: FakeKey(plain: "x", shift: "X"),
            7: FakeKey(plain: "x", shift: "X"),            // duplicate: lowest keycode wins
            2: FakeKey(plain: nil, shift: nil, option: "y"),
            9: FakeKey(plain: nil, shift: "y"),            // Shift beats Option
        ]))
        XCTAssertEqual(map.stroke(for: "1"), KeyStroke(keyCode: 18, flags: .maskShift))
        XCTAssertNil(map.stroke(for: "+"))
        XCTAssertEqual(map.stroke(for: "¥"), KeyStroke(keyCode: 93, flags: []))
        XCTAssertNil(map.stroke(for: "\r"))
        XCTAssertNil(map.stroke(for: "\u{1C}"))
        XCTAssertNil(map.stroke(for: "\u{F704}"))
        XCTAssertEqual(map.stroke(for: "x"), KeyStroke(keyCode: 1, flags: []))
        XCTAssertEqual(map.stroke(for: "y"), KeyStroke(keyCode: 9, flags: .maskShift))
    }

    func testLayoutCacheRebuildsWhenTheInputSourceChanges() throws {
        var currentID = "test.us"
        var keyboardType: UInt32 = 0
        let usTranslate = fakeTranslator(usKeys)
        let azertyTranslate = fakeTranslator(azertyKeys)
        let cache = KeyboardLayoutCache {
            KeyboardLayoutCache.Current(
                id: currentID,
                keyboardType: keyboardType,
                translate: currentID == "test.us" ? usTranslate : azertyTranslate
            )
        }
        XCTAssertEqual(try parseKeySpec("cmd+a", layout: cache).keyCode, 0)
        XCTAssertEqual(cache.buildCount, 1)
        XCTAssertEqual(try parseKeySpec("cmd+q", layout: cache).keyCode, 12)
        XCTAssertEqual(cache.buildCount, 1, "same input source: cached")
        _ = try cache.layoutMap(holding: [])
        XCTAssertEqual(cache.buildCount, 2, "plain and ⌘ maps are separate")

        currentID = "test.azerty"
        XCTAssertEqual(try parseKeySpec("cmd+a", layout: cache).keyCode, 12)
        XCTAssertEqual(cache.buildCount, 3, "new input source: rebuilt")
        XCTAssertEqual(try cache.layoutMap(holding: []).layoutID, "test.azerty")

        keyboardType = 41
        _ = try cache.layoutMap(holding: [])
        XCTAssertEqual(cache.buildCount, 5, "keyboard type change: rebuilt")
    }

    // MARK: Key spec parsing

    func testPunctuationKeysAndThePlusKeyParse() throws {
        XCTAssertEqual(try parseKeySpec("cmd+-", layout: us), KeyCombo(keyCode: 27, modifiers: [.command]))
        XCTAssertEqual(try parseKeySpec("cmd+minus", layout: us), KeyCombo(keyCode: 27, modifiers: [.command]))
        XCTAssertEqual(try parseKeySpec("cmd++", layout: us), KeyCombo(keyCode: 24, modifiers: [.command, .shift]))
        XCTAssertEqual(try parseKeySpec("cmd+plus", layout: us), KeyCombo(keyCode: 24, modifiers: [.command, .shift]))
        XCTAssertEqual(try parseKeySpec("cmd+shift++", layout: us), KeyCombo(keyCode: 24, modifiers: [.command, .shift]))
        XCTAssertEqual(try parseKeySpec("cmd+=", layout: us), KeyCombo(keyCode: 24, modifiers: [.command]))
        XCTAssertEqual(try parseKeySpec("cmd+equal", layout: us), KeyCombo(keyCode: 24, modifiers: [.command]))
        XCTAssertEqual(try parseKeySpec("+", layout: us), KeyCombo(keyCode: 24, modifiers: [.shift]))

        let aliases: [(String, CGKeyCode)] = [
            ("bracketleft", 33), ("[", 33), ("bracketright", 30), ("]", 30), ("quote", 39), ("'", 39),
            ("backslash", 42), ("\\", 42), ("grave", 50), ("`", 50), ("semicolon", 41), (";", 41),
            ("comma", 43), (",", 43), ("period", 47), (".", 47), ("slash", 44), ("/", 44),
        ]
        for (spec, keyCode) in aliases {
            XCTAssertEqual(try parseKeySpec("cmd+\(spec)", layout: us), KeyCombo(keyCode: keyCode, modifiers: [.command]), spec)
        }

        // Zoom shortcuts land on AZERTY's own keys.
        XCTAssertEqual(try parseKeySpec("cmd++", layout: azerty), KeyCombo(keyCode: 44, modifiers: [.command, .shift]))
        XCTAssertEqual(try parseKeySpec("cmd+=", layout: azerty), KeyCombo(keyCode: 44, modifiers: [.command]))
        XCTAssertEqual(try parseKeySpec("cmd+-", layout: azerty), KeyCombo(keyCode: 24, modifiers: [.command]))
    }

    func testNamedKeysKeepFixedKeycodesWithoutReadingTheLayout() throws {
        let layout = UnreadableLayout()
        let named: [(String, CGKeyCode)] = [
            ("forwarddelete", 117), ("ForwardDelete", 117), ("F13", 105), ("f14", 107), ("F15", 113),
            ("F16", 106), ("F17", 64), ("F18", 79), ("F19", 80), ("F20", 90), ("F1", 122), ("F12", 111),
            ("Return", 36), ("enter", 36), ("Tab", 48), ("Space", 49), ("Escape", 53), ("esc", 53),
            ("Delete", 51), ("BackSpace", 51), ("Up", 126), ("Down", 125), ("Left", 123), ("Right", 124),
            ("Home", 115), ("End", 119), ("PageUp", 116), ("PageDown", 121),
        ]
        for (spec, keyCode) in named {
            XCTAssertEqual(try parseKeySpec(spec, layout: layout), KeyCombo(keyCode: keyCode, modifiers: []), spec)
        }
        XCTAssertEqual(
            try parseKeySpec("ctrl+alt+shift+cmd+F13", layout: layout),
            KeyCombo(keyCode: 105, modifiers: [.control, .option, .shift, .command])
        )
        XCTAssertEqual(try parseKeySpec("cmd+command+left", layout: layout), KeyCombo(keyCode: 123, modifiers: [.command]))
    }

    func testMalformedSpecsUnknownModifiersAndUnknownKeysAreRejected() {
        for spec in ["", "cmd+", "+a", "cmd++shift", "++"] {
            XCTAssertEqual(keySpecProblem(spec, layout: us), .malformed(spec: spec), spec)
        }
        XCTAssertEqual(keySpecProblem("fn+left", layout: us), .unknownModifier("fn", spec: "fn+left"))
        XCTAssertEqual(keySpecProblem("a+b", layout: us), .unknownModifier("a", spec: "a+b"))
        XCTAssertEqual(keySpecProblem("not-a-key", layout: us), .unknownKey("not-a-key", spec: "not-a-key"))
        XCTAssertEqual(keySpecProblem("cmd+F21", layout: us), .unknownKey("F21", spec: "cmd+F21"))
        XCTAssertNil(keySpecProblem("cmd++", layout: us))
    }

    func testAppScopedAndDesktopKeyHandlingShareOneParser() {
        // App-scoped press_key used to ignore unknown modifiers; it now rejects them before
        // anything is posted, exactly like desktop_press_key.
        guard case .failure(let error) = sendKeyCombo("fn+left", pid: -1) else {
            return XCTFail("fn+left must not be delivered")
        }
        XCTAssertEqual(error, .unknownModifier("fn", spec: "fn+left"))
        XCTAssertFalse(pressKeyCombo("not-a-key", pid: -1))
        XCTAssertFalse(desktopKeySpecIsKnown("fn+left"))
        XCTAssertFalse(desktopKeySpecIsKnown("not-a-key"))
        XCTAssertFalse(desktopKeySpecIsKnown("cmd+"))
        XCTAssertTrue(desktopKeySpecIsKnown("forwarddelete"))
        XCTAssertTrue(desktopKeySpecIsKnown("F13"))
        XCTAssertTrue(desktopKeySpecIsKnown("cmd+shift+F20"))
    }

    // MARK: Typing

    func testTypingUsesLayoutKeystrokesAndFallsBackToUnicodeInjection() throws {
        let map = try azerty.layoutMap(holding: [])
        XCTAssertEqual(typingStep(for: "a", layout: map), .key(KeyStroke(keyCode: 12, flags: [])))
        XCTAssertEqual(typingStep(for: "q", layout: map), .key(KeyStroke(keyCode: 0, flags: [])))
        XCTAssertEqual(typingStep(for: "1", layout: map), .key(KeyStroke(keyCode: 18, flags: .maskShift)))
        XCTAssertEqual(typingStep(for: "ß", layout: map), .unicode("ß"))
        XCTAssertEqual(typingStep(for: "😀", layout: map), .unicode("😀"))
        XCTAssertEqual(typingStep(for: "\n", layout: map), .key(KeyStroke(keyCode: 36, flags: [])))
        XCTAssertEqual(typingStep(for: "\r", layout: map), .key(KeyStroke(keyCode: 36, flags: [])))
        XCTAssertEqual(typingStep(for: "\t", layout: map), .key(KeyStroke(keyCode: 48, flags: [])))
        XCTAssertEqual(typingStep(for: " ", layout: map), .key(KeyStroke(keyCode: 49, flags: [])))

        // Unreadable layout: never guess a keycode for text.
        XCTAssertEqual(typingStep(for: "a", layout: nil), .unicode("a"))
        XCTAssertEqual(typingStep(for: "\n", layout: nil), .key(KeyStroke(keyCode: 36, flags: [])))
    }

    // MARK: Real installed layouts (read-only; never changes the selected layout)

    func testRealFrenchLayoutPutsAOnTheUSQKey() throws {
        let french = try installedLayout("com.apple.keylayout.French")
        let layout = cache(for: french)
        let map = try layout.layoutMap(holding: [])
        XCTAssertEqual(map.stroke(for: "a"), KeyStroke(keyCode: 12, flags: []))
        XCTAssertEqual(map.stroke(for: "q"), KeyStroke(keyCode: 0, flags: []))
        XCTAssertEqual(map.stroke(for: "1"), KeyStroke(keyCode: 18, flags: .maskShift))
        XCTAssertEqual(try parseKeySpec("cmd+a", layout: layout), KeyCombo(keyCode: 12, modifiers: [.command]))
        XCTAssertEqual(try parseKeySpec("cmd+-", layout: layout).keyCode, 24)
    }

    func testRealUSLayoutMatchesTheFormerHardCodedTable() throws {
        let usLayout = cache(for: try installedLayout("com.apple.keylayout.US"))
        XCTAssertEqual(try parseKeySpec("cmd+a", layout: usLayout), KeyCombo(keyCode: 0, modifiers: [.command]))
        XCTAssertEqual(try parseKeySpec("cmd++", layout: usLayout), KeyCombo(keyCode: 24, modifiers: [.command, .shift]))
        XCTAssertEqual(try parseKeySpec("cmd+-", layout: usLayout), KeyCombo(keyCode: 27, modifiers: [.command]))
        let map = try usLayout.layoutMap(holding: [])
        XCTAssertEqual(map.stroke(for: "Z"), KeyStroke(keyCode: 6, flags: .maskShift))
        XCTAssertEqual(map.stroke(for: "?"), KeyStroke(keyCode: 44, flags: .maskShift))

        // The former hard-coded US table, minus "`"/"~" whose keycode depends on ANSI vs ISO
        // hardware: US typing and US shortcuts must be unchanged.
        let letters: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46]
        let unshifted: [Character: CGKeyCode] = ["1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29, "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44]
        let shifted: [Character: CGKeyCode] = ["!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22, "&": 26, "*": 28, "(": 25, ")": 29, "_": 27, "+": 24, "{": 33, "}": 30, "|": 42, ":": 41, "\"": 39, "<": 43, ">": 47, "?": 44]
        for (character, keyCode) in letters {
            XCTAssertEqual(map.stroke(for: character), KeyStroke(keyCode: keyCode, flags: []), "\(character)")
            XCTAssertEqual(map.stroke(for: Character(character.uppercased())), KeyStroke(keyCode: keyCode, flags: .maskShift), "\(character)")
            XCTAssertEqual(try parseKeySpec("cmd+\(character)", layout: usLayout), KeyCombo(keyCode: keyCode, modifiers: [.command]), "\(character)")
        }
        for (character, keyCode) in unshifted {
            XCTAssertEqual(map.stroke(for: character), KeyStroke(keyCode: keyCode, flags: []), "\(character)")
            XCTAssertEqual(try parseKeySpec("cmd+\(character)", layout: usLayout), KeyCombo(keyCode: keyCode, modifiers: [.command]), "\(character)")
        }
        for (character, keyCode) in shifted {
            XCTAssertEqual(map.stroke(for: character), KeyStroke(keyCode: keyCode, flags: .maskShift), "\(character)")
        }
    }

    func testRealLayoutsThatRemapUnderCommand() throws {
        let dvorak = cache(for: try installedLayout("com.apple.keylayout.DVORAK-QWERTYCMD"))
        XCTAssertEqual(try parseKeySpec("cmd+c", layout: dvorak).keyCode, 8)
        XCTAssertEqual(try dvorak.layoutMap(holding: []).stroke(for: "c")?.keyCode, 34)

        let russian = cache(for: try installedLayout("com.apple.keylayout.Russian"))
        XCTAssertEqual(try parseKeySpec("cmd+c", layout: russian).keyCode, 8)
        XCTAssertNil(try russian.layoutMap(holding: []).stroke(for: "c"))
        XCTAssertEqual(keySpecProblem("ctrl+c", layout: russian), .unresolvableCharacter("c", layoutID: "com.apple.keylayout.Russian"))
    }
}
