import XCTest
@testable import MacComputerUseCore

/// Downloads the real Kokoro model and renders speech. Opt in with
/// MACCU_RUN_KOKORO=1; MACCU_KOKORO_WAV=<path> keeps the audio to listen to.
final class KokoroLiveTests: XCTestCase {
    func testKokoroInstallsAndSpeaks() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["MACCU_RUN_KOKORO"] == "1", "set MACCU_RUN_KOKORO=1 to download Kokoro")
        let began = Date()
        try await KokoroEngine.shared.install()
        XCTAssertTrue(KokoroEngine.isInstalled)
        print("Kokoro installed in \(Int(Date().timeIntervalSince(began)))s, \(KokoroEngine.diskSize()) bytes on disk")

        let rendered = Date()
        let speech = try await KokoroEngine.shared.render("Hi! I'll click Publish once you say yes.", voice: "af_heart", speed: 1)
        print("Rendered \(speech.audio.count) bytes in \(Int(Date().timeIntervalSince(rendered) * 1000))ms")
        XCTAssertGreaterThan(speech.audio.count, 24_000, "at least half a second of 24 kHz audio")
        XCTAssertEqual(speech.audio.prefix(4), Data("RIFF".utf8))
        if let path = environment["MACCU_KOKORO_WAV"] {
            try speech.audio.write(to: URL(fileURLWithPath: path))
        }
    }
}
