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

    // MARK: Engines

    /// Deterministic pseudo-random text so the timing properties run on the
    /// same inputs everywhere.
    private struct SeededWords {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
        mutating func sentence() -> String {
            let pool = ["I'll", "click", "Publish", "once", "you", "say", "yes", "—", "naïve", "café", "👋", "0.10.1", "OK,", "done."]
            return (0..<(1 + Int(next() % 14))).map { _ in pool[Int(next() % UInt64(pool.count))] }.joined(separator: " ")
        }
    }

    func testEstimatedTimingsCoverEveryWordInOrderWithinTheClip() {
        var words = SeededWords(state: 0x5EED_2026)
        for _ in 0..<300 {
            let text = words.sentence()
            let duration = Double(1 + words.next() % 900) / 100
            let timings = estimatedWordTimings(text: text, duration: duration)
            XCTAssertEqual(timings.map(\.range), wordRanges(in: text), text)
            XCTAssertEqual(timings.first?.start ?? 0, 0, accuracy: 1e-9)
            XCTAssertEqual(timings.map(\.start), timings.map(\.start).sorted(), "words are heard in order")
            XCTAssertTrue(timings.allSatisfy { $0.start >= 0 && $0.start < duration }, text)
        }
        XCTAssertTrue(estimatedWordTimings(text: "Hello", duration: 0).isEmpty)
        XCTAssertTrue(estimatedWordTimings(text: "   ", duration: 2).isEmpty)
    }

    func testAlignedTimingsFollowTheFirstCharacterOfEachWord() {
        let text = "Hi café 👋 there"
        let characters = text.map(String.init)
        let starts = characters.indices.map { Double($0) * 0.1 }
        let words = alignedWordTimings(text: text, characters: characters, starts: starts)
        XCTAssertEqual(words?.map { (text as NSString).substring(with: $0.range) }, ["Hi", "café", "there"])
        for (start, expected) in zip(words?.map(\.start) ?? [], [0, 0.3, 1.0]) {
            XCTAssertEqual(start, expected, accuracy: 1e-9)
        }
        XCTAssertEqual(words?.count, 3)
        XCTAssertNil(alignedWordTimings(text: text, characters: ["H"], starts: [0]), "a mismatched alignment is ignored")
        XCTAssertNil(alignedWordTimings(text: text, characters: characters, starts: [0]))
    }

    func testElevenLabsResponseParsesAudioAndTimings() throws {
        let body: [String: Any] = [
            "audio_base64": Data("mp3".utf8).base64EncodedString(),
            "alignment": [
                "characters": ["O", "k", " ", "g", "o"],
                "character_start_times_seconds": [0, 0.1, 0.2, 0.3, 0.4],
                "character_end_times_seconds": [0.1, 0.2, 0.3, 0.4, 0.5],
            ],
        ]
        let speech = try ElevenLabsClient.parseRendered(try JSONSerialization.data(withJSONObject: body), text: "Ok go")
        XCTAssertEqual(speech.audio, Data("mp3".utf8))
        XCTAssertEqual(speech.words?.map(\.start), [0, 0.3])
        XCTAssertThrowsError(try ElevenLabsClient.parseRendered(Data("{}".utf8), text: "Ok"))
    }

    func testKokoroVoicesMatchByIdOrName() {
        XCTAssertEqual(KokoroCatalog.find("bf_emma")?.name, "Emma")
        XCTAssertEqual(KokoroCatalog.find(" george ")?.id, "bm_george")
        XCTAssertNil(KokoroCatalog.find("Samantha"))
        XCTAssertNil(KokoroCatalog.find(nil))
        XCTAssertTrue(voiceMatches("Heart", engine: .kokoro))
        XCTAssertFalse(voiceMatches("Nobody", engine: .kokoro))
        XCTAssertTrue(voiceListText(.kokoro).contains("af_heart"))
    }

    @MainActor
    func testRenderedVoiceSpeaksInOrderAndReportsWords() {
        let voice = ServiceVoice(environment: ["MACCU_VOICE": "silent"])
        voice.engine = { .kokoro }
        voice.render = { _, text, _, _ in
            RenderedSpeech(audio: Data(), words: estimatedWordTimings(text: text, duration: 1))
        }
        var started: [String] = []
        var words = 0
        voice.onStart = { started.append($0) }
        voice.onWord = { _ in words += 1 }
        let done = expectation(description: "both spoken")
        done.expectedFulfillmentCount = 2
        var outcomes: [SpeechOutcome] = []
        voice.speak("One two") { outcomes.append($0); done.fulfill() }
        voice.speak("Three") { outcomes.append($0); done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(started, ["One two", "Three"])
        XCTAssertEqual(words, 3)
        XCTAssertEqual(outcomes, [.spoken, .spoken])
    }

    @MainActor
    func testFailingRenderedVoiceFallsBackToAMacVoice() {
        let voice = ServiceVoice(environment: ["MACCU_VOICE": "silent"])
        voice.engine = { .kokoro }
        voice.render = { _, _, _, _ in throw VoiceEngineError.notInstalled }
        var failures: [VoiceEngineKind] = []
        voice.onEngineFailure = { kind, _ in failures.append(kind) }
        let spoken = expectation(description: "spoken by the fallback")
        voice.speak("Still heard") { outcome in
            XCTAssertEqual(outcome, .spoken)
            spoken.fulfill()
        }
        wait(for: [spoken], timeout: 3)
        XCTAssertEqual(failures, [.kokoro])
    }

    @MainActor
    func testStopAllCancelsARenderInFlight() {
        let voice = ServiceVoice(environment: ["MACCU_VOICE": "silent"])
        voice.engine = { .elevenlabs }
        voice.render = { _, _, _, _ in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return RenderedSpeech(audio: Data(), words: nil)
        }
        var outcomes: [SpeechOutcome] = []
        voice.speak("Slow") { outcomes.append($0) }
        voice.stopAll()
        XCTAssertEqual(outcomes, [.interrupted])
        let settle = expectation(description: "no late completion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(outcomes, [.interrupted])
    }
}
