import XCTest
@testable import MacComputerUseCore

final class ReviewNotesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func note(
        _ id: String,
        text: String = "fix this",
        app: String = "Safari",
        bundle: String? = "com.apple.Safari",
        url: String? = nil,
        title: String? = nil,
        nearby: [String] = [],
        windowID: UInt32? = 7,
        region: [Double] = [100, 100, 50, 40],
        at seconds: TimeInterval = 0
    ) -> ReviewNote {
        ReviewNote(
            id: id, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + seconds), reviewSession: "r-1", text: text,
            bundleID: bundle, appName: app, pid: 42, windowID: windowID, windowTitle: title, windowBounds: [0, 0, 800, 600],
            url: url, document: nil, region: region, element: nil, textNearby: nearby
        )
    }

    func testStoreRoundTripsThroughDisk() throws {
        let store = NoteStore(directory: directory)
        try store.add(note("n-1", url: "http://localhost:3000/checkout"), image: Data([1, 2, 3]))
        let reloaded = NoteStore(directory: directory)
        XCTAssertEqual(reloaded.note("n-1")?.url, "http://localhost:3000/checkout")
        XCTAssertEqual(reloaded.note("n-1")?.history.count, 1)
        XCTAssertEqual(try Data(contentsOf: reloaded.imageURL(for: "n-1")), Data([1, 2, 3]))
    }

    func testURLPrefixIgnoresSchemeAndWWW() {
        var filter = NoteFilter()
        filter.urlPrefix = "localhost:3000/checkout"
        XCTAssertTrue(filter.matches(note("a", url: "http://localhost:3000/checkout/pay")))
        XCTAssertFalse(filter.matches(note("b", url: "http://localhost:3000/admin")))
        XCTAssertFalse(filter.matches(note("c", url: nil)))
        filter.urlPrefix = "https://example.com/docs"
        XCTAssertTrue(filter.matches(note("d", url: "http://www.example.com/docs/intro")))
    }

    func testAppTitleAndTextFilters() {
        var filter = NoteFilter()
        filter.app = "com.apple.safari"
        XCTAssertTrue(filter.matches(note("a")))
        filter.app = "xcode"
        XCTAssertFalse(filter.matches(note("a")))
        filter = NoteFilter()
        filter.windowTitle = "shop"
        XCTAssertTrue(filter.matches(note("a", title: "Shop — Checkout")))
        filter = NoteFilter()
        filter.text = "pay now"
        XCTAssertTrue(filter.matches(note("a", nearby: ["Pay now", "Total"])))
        XCTAssertFalse(filter.matches(note("b", nearby: ["Total"])))
    }

    func testOnlyOneAgentCanClaim() throws {
        let store = NoteStore(directory: directory)
        try store.add(note("n-1"), image: nil)
        try store.claim("n-1", by: "Claude Code · shop")
        XCTAssertNoThrow(try store.claim("n-1", by: "Claude Code · shop"))
        XCTAssertThrowsError(try store.claim("n-1", by: "Codex · admin")) { error in
            XCTAssertEqual(error as? NoteError, .alreadyClaimed(by: "Claude Code · shop"))
        }
        XCTAssertThrowsError(try store.resolve("n-1", reply: "done", by: "Codex · admin"))
        let resolved = try store.resolve("n-1", reply: "Fixed the colour", by: "Claude Code · shop")
        XCTAssertEqual(resolved.status, .resolved)
        XCTAssertEqual(resolved.reply, "Fixed the colour")
        XCTAssertEqual(store.list().count, 0, "resolved notes are hidden by default")
        XCTAssertEqual(store.clearResolved(), 1)
        XCTAssertNil(NoteStore(directory: directory).note("n-1"))
    }

    func testReopenReleasesClaim() throws {
        let store = NoteStore(directory: directory)
        try store.add(note("n-1"), image: nil)
        try store.claim("n-1", by: "A")
        let reopened = try store.resolve("n-1", status: .open, reply: nil, by: "A")
        XCTAssertNil(reopened.claimedBy)
        XCTAssertNoThrow(try store.claim("n-1", by: "B"))
    }

    /// Property, pinned seed: for random notes and random claim races, each
    /// note ends with at most one claimant, list() is always oldest-first,
    /// and an empty filter returns exactly the unresolved notes.
    func testClaimAndListingProperties() throws {
        var rng = SeededGenerator(seed: 0x5EED_2026)
        for round in 0..<40 {
            let store = NoteStore(directory: directory.appendingPathComponent("\(round)"))
            let count = Int.random(in: 1...12, using: &rng)
            for index in 0..<count {
                try store.add(note("n-\(index)", at: Double.random(in: 0...1000, using: &rng)), image: nil)
            }
            let agents = ["A", "B", "C"]
            var winners: [String: String] = [:]
            for _ in 0..<(count * 3) {
                let id = "n-\(Int.random(in: 0..<count, using: &rng))"
                let agent = agents.randomElement(using: &rng)!
                if Bool.random(using: &rng) {
                    if (try? store.claim(id, by: agent)) != nil {
                        XCTAssert(winners[id] == nil || winners[id] == agent)
                        winners[id] = agent
                    }
                } else if (try? store.resolve(id, reply: "ok", by: agent)) != nil {
                    XCTAssert(winners[id] == nil || winners[id] == agent)
                    winners[id] = agent
                }
            }
            let listed = store.list()
            XCTAssertEqual(listed.map(\.createdAt), listed.map(\.createdAt).sorted())
            XCTAssertTrue(listed.allSatisfy { $0.status != .resolved })
            XCTAssertEqual(listed.count, store.list(.everything).filter { $0.status != .resolved }.count)
            XCTAssertEqual(store.openCount, listed.count)
        }
    }

    func testActivityLogMatchesWindowElementAndPage() {
        let log = ActivityLog()
        XCTAssertFalse(log.actedHere(windowID: 7, region: CGRect(x: 0, y: 0, width: 10, height: 10), url: nil))
        log.record(tool: "navigate", args: ["url": "http://localhost:3000"])
        XCTAssertTrue(log.actedHere(windowID: nil, region: .null, url: "localhost:3000/checkout"))
        XCTAssertFalse(log.actedHere(windowID: nil, region: .null, url: "localhost:4000"))
        log.record(tool: "list_apps", args: [:])
        XCTAssertFalse(log.actedHere(windowID: 99, region: .null, url: nil))
    }

    func testReviewPromptListsEveryNote() {
        let prompt = reviewPrompt([note("n-1", text: "Wrong colour", url: "http://localhost:3000"), note("n-2", text: "Typo", title: "Notes")])
        XCTAssertTrue(prompt.contains("n-1: \"Wrong colour\" · Safari http://localhost:3000"))
        XCTAssertTrue(prompt.contains("n-2: \"Typo\" · Safari “Notes”"))
        XCTAssertTrue(prompt.contains("claim_note"))
    }

    func testFilterArgumentsParse() {
        let filter = noteFilter(from: ["url_prefix": " localhost:3000 ", "status": "all", "app": ""])
        XCTAssertEqual(filter.urlPrefix, "localhost:3000")
        XCTAssertNil(filter.app)
        XCTAssertEqual(filter.statuses, Set(ReviewNote.Status.allCases))
    }
}

/// SplitMix64, so the property test is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
