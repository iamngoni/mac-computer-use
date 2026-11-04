import AVFoundation
import CoreGraphics
import XCTest
@testable import MacComputerUseCore

final class VisualLayoutTests: XCTestCase {
    let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let size = CGSize(width: 300, height: 200)

    func testBesidePrefersTheRightThenFallsBackLeft() {
        let right = visualLayout(placement: .beside, anchor: CGRect(x: 100, y: 300, width: 80, height: 30), window: nil, screen: screen, size: size)
        XCTAssertEqual(right.side, "left")
        XCTAssertEqual(right.frame.minX, 194)
        let left = visualLayout(placement: .beside, anchor: CGRect(x: 1300, y: 300, width: 80, height: 30), window: nil, screen: screen, size: size)
        XCTAssertEqual(left.side, "right")
        XCTAssertEqual(left.frame.maxX, 1286)
    }

    func testPanelsAlwaysStayOnScreen() {
        let anchors = [CGRect(x: -50, y: -50, width: 20, height: 20), CGRect(x: 1430, y: 870, width: 30, height: 30),
                       CGRect(x: 0, y: 25, width: 1440, height: 850)]
        for anchor in anchors {
            for placement in [VisualPlacement.beside, .center, .at, .over] {
                let frame = visualLayout(placement: placement, anchor: anchor, window: nil, screen: screen, size: size).frame
                XCTAssertTrue(screen.contains(frame), "\(placement) \(anchor) -> \(frame)")
            }
        }
    }

    func testWindowAndScreenPlacementsCoverTheirHost() {
        let window = CGRect(x: 200, y: 100, width: 800, height: 600)
        XCTAssertEqual(visualLayout(placement: .window, anchor: nil, window: window, screen: screen, size: size).frame, window)
        XCTAssertEqual(visualLayout(placement: .screen, anchor: nil, window: window, screen: screen, size: size).frame, screen)
        let centered = visualLayout(placement: .center, anchor: nil, window: window, screen: screen, size: size).frame
        XCTAssertEqual(centered.midX, window.midX)
        XCTAssertEqual(centered.midY, window.midY)
    }

    func testTargetsArriveInPanelCoordinates() {
        let local = visualLocalTargets(["save": CGRect(x: 150, y: 120, width: 40, height: 20)], panel: CGRect(x: 100, y: 100, width: 300, height: 200))
        XCTAssertEqual(local["save"]?["x"], 50)
        XCTAssertEqual(local["save"]?["cy"], 30)
    }

    func testJSONLiteralCannotBreakOutOfTheScript() {
        let literal = visualJSONLiteral(["t": "</script><script>alert(1)</script>\u{2028}"])
        XCTAssertFalse(literal.contains("</"))
        XCTAssertFalse(literal.contains("\u{2028}"))
        XCTAssertEqual(visualJSONLiteral(nil), "null")
    }
}

final class CompanionTests: XCTestCase {
    func testShortcutsNormaliseHoweverTheAgentWritesThem() {
        XCTAssertEqual(normalizedShortcutSpec("Command+Shift+S"), "cmd+shift+s")
        XCTAssertEqual(normalizedShortcutSpec("⌘⇧s"), "cmd+shift+s")
        XCTAssertEqual(normalizedShortcutSpec("shift + cmd + s"), "cmd+shift+s")
        XCTAssertEqual(normalizedShortcutSpec("alt+ctrl+Escape"), "ctrl+opt+esc")
    }

    func testPlainTypingIsNeverRecordedOnlyShortcutsAndNamedKeys() {
        XCTAssertNil(describeKeyPress(keyCode: 0, characters: "a", command: false, control: false, option: false, shift: false))
        XCTAssertNil(describeKeyPress(keyCode: 0, characters: "A", command: false, control: false, option: false, shift: true))
        XCTAssertNil(describeKeyPress(keyCode: 14, characters: "é", command: false, control: false, option: true, shift: false))
        XCTAssertNil(describeKeyPress(keyCode: 49, characters: " ", command: false, control: false, option: false, shift: false))
        XCTAssertEqual(describeKeyPress(keyCode: 1, characters: "s", command: true, control: false, option: false, shift: true), "cmd+shift+s")
        XCTAssertEqual(describeKeyPress(keyCode: 36, characters: "\r", command: false, control: false, option: false, shift: false), "return")
        XCTAssertEqual(describeKeyPress(keyCode: 49, characters: " ", command: true, control: false, option: false, shift: false), "cmd+space")
    }

    func testCaptionsScrollALineAtATime() {
        let text = String(repeating: "word ", count: 60)
        let window = captionWindow(text, highlighting: NSRange(location: 200, length: 4), maxCharacters: 90)
        XCTAssertLessThanOrEqual((window.text as NSString).length, 90)
        XCTAssertEqual((window.text as NSString).substring(with: window.range), "word")
        let short = captionWindow("Hello there", highlighting: NSRange(location: 6, length: 5))
        XCTAssertEqual(short.text, "Hello there")
    }

    func testLassoPathsAreSimplifiedButKeepTheirEnds() {
        let points = (0..<1000).map { CGPoint(x: Double($0), y: 0) }
        let simple = simplifiedPath(points, limit: 120)
        XCTAssertEqual(simple.count, 120)
        XCTAssertEqual(simple.first, points.first)
        XCTAssertEqual(simple.last, points.last)
    }

    func testEmotesSettleBackToRest() {
        for emote in CursorEmote.allCases {
            XCTAssertEqual(cursorEmotePose((emote, 0), now: cursorEmoteDuration(emote) + 0.01), .rest, emote.rawValue)
        }
        XCTAssertGreaterThan(cursorEmotePose((.celebrate, 0), now: 0.2).sparkle, 0)
    }

    func testFollowingConvergesOnThePointer() {
        var point = CGPoint.zero
        for _ in 0..<120 { point = buddyFollowStep(from: point, to: CGPoint(x: 100, y: 50), dt: 1.0 / 60) }
        XCTAssertEqual(point.x, 100, accuracy: 0.5)
        XCTAssertEqual(point.y, 50, accuracy: 0.5)
    }
}

final class WalkthroughAndPreferenceTests: XCTestCase {
    func testStepsAdvanceOnClickByDefaultAndNextWithoutATarget() {
        XCTAssertEqual(try? guideAdvance([:], hasTarget: true).get(), .click)
        XCTAssertEqual(try? guideAdvance([:], hasTarget: false).get(), .next)
        XCTAssertEqual(try? guideAdvance(["advance_on": "shortcut", "shortcut": "Command+S"], hasTarget: false).get(), .shortcut("cmd+s"))
        XCTAssertEqual(try? guideAdvance(["advance_on": "app", "target_app": "Safari"], hasTarget: true).get(), .app("Safari"))
        XCTAssertNil(try? guideAdvance(["advance_on": "click"], hasTarget: false).get())
        XCTAssertNil(try? guideAdvance(["advance_on": "shortcut"], hasTarget: true).get())
        XCTAssertNil(try? guideAdvance(["advance_on": "wave"], hasTarget: true).get())
    }

    func testSpeechRateMapsMonotonicallyAndClamps() {
        let rates = stride(from: 0.5, through: 1.5, by: 0.1).map { utteranceRate(multiplier: $0) }
        XCTAssertEqual(rates, rates.sorted())
        XCTAssertEqual(utteranceRate(multiplier: 1), AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertEqual(utteranceRate(multiplier: 9), utteranceRate(multiplier: 1.5))
        XCTAssertLessThanOrEqual(utteranceRate(multiplier: 1.5), AVSpeechUtteranceMaximumSpeechRate)
        XCTAssertGreaterThanOrEqual(utteranceRate(multiplier: 0.5), AVSpeechUtteranceMinimumSpeechRate)
    }

    func testCursorPreferencesClampAndKnowTheirTints() {
        XCTAssertEqual(clampedCursorScale(3), 1.6)
        XCTAssertEqual(clampedCursorScale(.nan), 1)
        XCTAssertNil(cursorTintColor("blue"))
        for tint in CompanionPreferences.tints where tint != "blue" { XCTAssertNotNil(cursorTintColor(tint), tint) }
    }
}
