import XCTest
@testable import MacComputerUseCore

final class VoiceTests: XCTestCase {
    func testSpeakOptionReadsTheToolsTextOrSaysItsOwn() {
        XCTAssertNil(spokenText([:], default: "Settings"))
        XCTAssertNil(spokenText(["speak": false], default: "Settings"))
        XCTAssertEqual(spokenText(["speak": true], default: "Settings"), "Settings")
        XCTAssertNil(spokenText(["speak": true], default: nil), "nothing to read means nothing is spoken")
        XCTAssertNil(spokenText(["speak": true], default: "   "))
        XCTAssertEqual(spokenText(["speak": "I'll open Settings for you"], default: "Settings"), "I'll open Settings for you")
        XCTAssertNil(spokenText(["speak": "  "], default: nil))
        XCTAssertEqual(spokenText(["speak": String(repeating: "a", count: 900)], default: nil)?.count, 400)
        XCTAssertNil(spokenText(["speak": 1], default: "Settings"), "only JSON booleans and strings count")
    }

    @MainActor
    func testSilentVoiceCompletesAndStopAllInterrupts() {
        let voice = ServiceVoice(environment: ["MACCU_VOICE": "silent"])
        voice.isEnabled = { false }
        XCTAssertTrue(voice.canSpeak, "test mode ignores the user's preference")

        let spoken = expectation(description: "spoken")
        voice.speak("Hello") { outcome in
            XCTAssertEqual(outcome, .spoken)
            spoken.fulfill()
        }
        wait(for: [spoken], timeout: 2)

        var outcomes: [SpeechOutcome] = []
        voice.speak("First") { outcomes.append($0) }
        voice.speak("Second") { outcomes.append($0) }
        voice.stopAll()
        XCTAssertEqual(outcomes, [.interrupted, .interrupted])
        let settle = expectation(description: "no late completion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(outcomes, [.interrupted, .interrupted], "stopped speech never reports success later")
    }

    @MainActor
    func testMutedVoiceSpeaksNothing() {
        let off = ServiceVoice(environment: ["MACCU_VOICE": "off"])
        XCTAssertFalse(off.canSpeak)
        var outcome: SpeechOutcome?
        off.speak("Hello") { outcome = $0 }
        XCTAssertEqual(outcome, .muted)

        let audible = ServiceVoice(environment: [:])
        audible.isEnabled = { false }
        XCTAssertFalse(audible.canSpeak, "Speak Aloud off mutes the real voice")
        audible.speak("Hello") { outcome = $0 }
        XCTAssertEqual(outcome, .muted)
    }
}
