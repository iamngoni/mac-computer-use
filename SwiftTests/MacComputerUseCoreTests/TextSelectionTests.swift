import Foundation
import XCTest
@testable import MacComputerUseCore

final class TextSelectionTests: XCTestCase {
    private func range(_ location: Int, _ length: Int) -> Result<NSRange, TextSelectionError> {
        .success(NSRange(location: location, length: length))
    }

    // MARK: - Matching

    func testSingleMatchSelectsItsUTF16Range() {
        XCTAssertEqual(textSelectionRange(in: "hello world", text: "world"), range(6, 5))
    }

    func testNoMatchIsAnErrorAndMatchingIsCaseSensitive() {
        XCTAssertEqual(textSelectionRange(in: "hello world", text: "planet"), .failure(.noMatch))
        XCTAssertEqual(textSelectionRange(in: "hello world", text: "World"), .failure(.noMatch))
        XCTAssertEqual(textSelectionRange(in: "", text: "x"), .failure(.noMatch))
    }

    func testEmptyTextIsRejected() {
        XCTAssertEqual(textSelectionRange(in: "hello", text: ""), .failure(.emptyText))
    }

    func testMultipleMatchesFailClosedWithCount() {
        let result = textSelectionRange(in: "foo bar foo baz foo", text: "foo")
        XCTAssertEqual(result, .failure(.ambiguous(count: 3)))
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(error.message.contains("3"), error.message)
        XCTAssertTrue(error.message.contains("prefix"), error.message)
        XCTAssertTrue(error.message.contains("occurrence"), error.message)
    }

    func testOverlappingMatchesCountTowardAmbiguity() {
        XCTAssertEqual(textSelectionRange(in: "aaa", text: "aa"), .failure(.ambiguous(count: 2)))
        XCTAssertEqual(textSelectionRange(in: "aaa", text: "aa", occurrence: 2), range(1, 2))
    }

    func testPrefixAndSuffixDisambiguate() {
        let value = "foo bar foo baz foo"
        XCTAssertEqual(textSelectionRange(in: value, text: "foo", prefix: "bar "), range(8, 3))
        XCTAssertEqual(textSelectionRange(in: value, text: "foo", suffix: " bar"), range(0, 3))
        XCTAssertEqual(textSelectionRange(in: value, text: "foo", prefix: "baz "), range(16, 3))
        XCTAssertEqual(textSelectionRange(in: value, text: "foo", prefix: "bar ", suffix: " baz"), range(8, 3))
    }

    func testPrefixAndSuffixMustBeImmediatelyAdjacent() {
        let value = "foo bar foo baz foo"
        XCTAssertEqual(textSelectionRange(in: value, text: "foo", prefix: "bar"), .failure(.noMatch))
        XCTAssertEqual(textSelectionRange(in: value, text: "foo", suffix: "bar"), .failure(.noMatch))
        // A prefix cannot match before the start of the value, nor a suffix past its end.
        XCTAssertEqual(textSelectionRange(in: "foo", text: "foo", prefix: " "), .failure(.noMatch))
        XCTAssertEqual(textSelectionRange(in: "foo", text: "foo", suffix: " "), .failure(.noMatch))
    }

    func testPrefixFilteringCanStillLeaveAmbiguity() {
        let value = "a: x, b: x, a: x"
        XCTAssertEqual(textSelectionRange(in: value, text: "x", prefix: "a: "), .failure(.ambiguous(count: 2)))
        XCTAssertEqual(textSelectionRange(in: value, text: "x", prefix: "a: ", occurrence: 2), range(15, 1))
    }

    func testEmptyPrefixAndSuffixAreNoConstraint() {
        XCTAssertEqual(textSelectionRange(in: "hello world", text: "world", prefix: "", suffix: ""), range(6, 5))
    }

    func testOccurrencePicksAmongMatches() {
        let value = "foo bar foo baz foo"
        XCTAssertEqual(textSelectionRange(in: value, text: "foo", occurrence: 1), range(0, 3))
        XCTAssertEqual(textSelectionRange(in: value, text: "foo", occurrence: 2), range(8, 3))
        XCTAssertEqual(textSelectionRange(in: value, text: "foo", occurrence: 3), range(16, 3))
        XCTAssertEqual(
            textSelectionRange(in: value, text: "foo", occurrence: 4),
            .failure(.occurrenceOutOfRange(requested: 4, matches: 3))
        )
        XCTAssertEqual(textSelectionRange(in: value, text: "foo", occurrence: 0), .failure(.invalidOccurrence(0)))
        XCTAssertEqual(textSelectionRange(in: "hello world", text: "world", occurrence: 1), range(6, 5))
    }

    func testCursorModesProduceZeroLengthRanges() {
        XCTAssertEqual(textSelectionRange(in: "hello world", text: "world", mode: .cursorBefore), range(6, 0))
        XCTAssertEqual(textSelectionRange(in: "hello world", text: "world", mode: .cursorAfter), range(11, 0))
        XCTAssertEqual(
            textSelectionRange(in: "foo bar foo", text: "foo", occurrence: 2, mode: .cursorAfter),
            range(11, 0)
        )
        // Cursor modes are still subject to the ambiguity guard.
        XCTAssertEqual(
            textSelectionRange(in: "foo bar foo", text: "foo", mode: .cursorBefore),
            .failure(.ambiguous(count: 2))
        )
    }

    func testRangesAreUTF16OffsetsAfterEmojiAndCombiningCharacters() {
        // 👍 is one Character but two UTF-16 code units.
        XCTAssertEqual(textSelectionRange(in: "👍 hello", text: "hello"), range(3, 5))
        XCTAssertEqual(textSelectionRange(in: "👍 hello", text: "hello", mode: .cursorAfter), range(8, 0))
        // "e" + COMBINING ACUTE ACCENT is one Character but two UTF-16 code units.
        XCTAssertEqual(textSelectionRange(in: "e\u{301} hello", text: "hello"), range(3, 5))
        // A selected emoji with a skin-tone modifier spans four UTF-16 code units.
        XCTAssertEqual(textSelectionRange(in: "say 👋🏽 hi", text: "👋🏽"), range(4, 4))
        XCTAssertEqual(textSelectionRange(in: "👍👍 x 👍", text: "x", prefix: "👍👍 "), range(5, 1))
    }

    func testMatchesNeverSplitAComposedCharacter() {
        XCTAssertEqual(textSelectionRange(in: "e\u{301}", text: "e"), .failure(.noMatch))
        XCTAssertEqual(textSelectionRange(in: "e\u{301}x", text: "\u{301}x"), .failure(.noMatch))
        XCTAssertEqual(textSelectionRange(in: "e\u{301}x e", text: "e"), range(4, 1))
    }

    // MARK: - Argument parsing

    func testRequestParsingAppliesDefaults() {
        XCTAssertEqual(
            parseTextSelectionRequest(["text": "hello"]),
            .success(TextSelectionRequest(text: "hello", prefix: nil, suffix: nil, occurrence: nil, mode: .text))
        )
        XCTAssertEqual(
            parseTextSelectionRequest(["text": "hello", "prefix": NSNull(), "occurrence": NSNull()]),
            .success(TextSelectionRequest(text: "hello", prefix: nil, suffix: nil, occurrence: nil, mode: .text))
        )
    }

    func testRequestParsingAcceptsAllOptions() {
        XCTAssertEqual(
            parseTextSelectionRequest([
                "text": "foo",
                "prefix": "a ",
                "suffix": " b",
                "occurrence": 2,
                "selection": "cursor_after",
            ]),
            .success(TextSelectionRequest(text: "foo", prefix: "a ", suffix: " b", occurrence: 2, mode: .cursorAfter))
        )
        XCTAssertEqual(
            parseTextSelectionRequest(["text": "foo", "selection": "cursor_before"]),
            .success(TextSelectionRequest(text: "foo", prefix: nil, suffix: nil, occurrence: nil, mode: .cursorBefore))
        )
    }

    func testRequestParsingRejectsMalformedArguments() {
        func isInvalid(_ args: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
            guard case .failure = parseTextSelectionRequest(args) else {
                return XCTFail("expected \(args) to be rejected", file: file, line: line)
            }
        }
        isInvalid([:])
        isInvalid(["text": 5])
        isInvalid(["text": ""])
        isInvalid(["text": "foo", "prefix": 1])
        isInvalid(["text": "foo", "suffix": true])
        isInvalid(["text": "foo", "occurrence": 0])
        isInvalid(["text": "foo", "occurrence": -1])
        isInvalid(["text": "foo", "occurrence": 1.5])
        isInvalid(["text": "foo", "occurrence": true])
        isInvalid(["text": "foo", "occurrence": "2"])
        isInvalid(["text": "foo", "selection": "everything"])
        isInvalid(["text": "foo", "selection": 1])
    }

    func testElementIndexParsingIsStrict() {
        XCTAssertEqual(textElementIndex("3"), 3)
        XCTAssertEqual(textElementIndex(3), 3)
        XCTAssertEqual(textElementIndex("0"), 0)
        XCTAssertNil(textElementIndex("-1"))
        XCTAssertNil(textElementIndex("abc"))
        XCTAssertNil(textElementIndex(true))
        XCTAssertNil(textElementIndex(1.5))
        XCTAssertNil(textElementIndex(nil))
    }

    // MARK: - Schema

    func testSelectTextSchemaDescribesRealSelection() throws {
        let tool = try XCTUnwrap(toolSchemas().first { $0["name"] as? String == "select_text" })
        let description = try XCTUnwrap(tool["description"] as? String)
        XCTAssertFalse(description.hasPrefix("Focus"), description)
        let input = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(input["required"] as? [String], ["app", "element_index", "text"])
        XCTAssertEqual(input["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(input["properties"] as? [String: Any])
        XCTAssertEqual(
            Set(properties.keys),
            ["app", "element_index", "text", "prefix", "suffix", "occurrence", "selection"]
        )
        let selection = try XCTUnwrap(properties["selection"] as? [String: Any])
        XCTAssertEqual(selection["enum"] as? [String], ["text", "cursor_before", "cursor_after"])
        let occurrence = try XCTUnwrap(properties["occurrence"] as? [String: Any])
        XCTAssertEqual(occurrence["type"] as? String, "integer")
        XCTAssertEqual(occurrence["minimum"] as? Int, 1)
    }
}
