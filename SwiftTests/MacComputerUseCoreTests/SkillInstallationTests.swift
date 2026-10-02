import XCTest
@testable import MacComputerUseCore

final class SkillInstallationTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var home: URL!
    private var discarded: DiscardLog!

    final class DiscardLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func append(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("maccu-skills-\(UUID().uuidString)")
        source = root.appendingPathComponent("source/mac-computer-use", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "---\nname: mac-computer-use\ndescription: test\n---\nv1\n".write(
            to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        discarded = DiscardLog()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func service() -> SkillInstallationService {
        let log = discarded!
        return SkillInstallationService(sourceDirectory: source, homeDirectory: home) { url in
            log.append(url)
            try FileManager.default.removeItem(at: url)
        }
    }

    private func skillFile(_ target: SkillTarget) -> URL {
        service().destination(for: target).appendingPathComponent("SKILL.md")
    }

    func testInstallsIntoEachAgentsSkillsFolder() throws {
        let skills = service()
        XCTAssertEqual(skills.destination(for: .codex).path, home.appendingPathComponent(".codex/skills/mac-computer-use").path)
        XCTAssertEqual(skills.destination(for: .claude).path, home.appendingPathComponent(".claude/skills/mac-computer-use").path)
        XCTAssertEqual(skills.destination(for: .global).path, home.appendingPathComponent(".agents/skills/mac-computer-use").path)
        for target in SkillTarget.allCases {
            XCTAssertEqual(skills.state(for: target), .absent)
            XCTAssertNoThrow(try skills.install(target).get())
            XCTAssertEqual(skills.state(for: target), .current)
            XCTAssertEqual(try String(contentsOf: skillFile(target), encoding: .utf8).hasSuffix("v1\n"), true)
            XCTAssertNoThrow(try skills.install(target).get(), "installing a current copy is a no-op")
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".codex/skills").path)
        XCTAssertEqual(leftovers, ["mac-computer-use"], "no staging folders are left behind")
    }

    func testUntouchedCopiesFollowTheBundledSkill() throws {
        let skills = service()
        try skills.install(.claude).get()
        try "---\nname: mac-computer-use\ndescription: test\n---\nv2\n".write(
            to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(skills.state(for: .claude), .outdated)
        XCTAssertEqual(skills.refreshOutdated(), [.claude], "only installed copies are refreshed")
        XCTAssertEqual(skills.state(for: .claude), .current)
        XCTAssertTrue(try String(contentsOf: skillFile(.claude), encoding: .utf8).hasSuffix("v2\n"))
        XCTAssertEqual(skills.state(for: .codex), .absent)
        XCTAssertTrue(discarded.all.isEmpty, "the app's own untouched copy is replaced, not trashed")
    }

    func testEditedCopiesAreNeverOverwrittenWithoutAsking() throws {
        let skills = service()
        try skills.install(.codex).get()
        try "my notes\n".write(to: skillFile(.codex), atomically: true, encoding: .utf8)
        try "---\nname: mac-computer-use\ndescription: test\n---\nv2\n".write(
            to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(skills.state(for: .codex), .modified)
        XCTAssertEqual(skills.refreshOutdated(), [])
        XCTAssertThrowsError(try skills.install(.codex).get())
        XCTAssertEqual(try String(contentsOf: skillFile(.codex), encoding: .utf8), "my notes\n")
        XCTAssertNoThrow(try skills.install(.codex, replaceExisting: true).get())
        XCTAssertEqual(skills.state(for: .codex), .current)
        XCTAssertEqual(discarded.all.map(\.lastPathComponent), ["mac-computer-use"], "the edited copy goes to the Trash")
    }

    func testForeignSkillsAndLinksAreLeftAloneUnlessReplaced() throws {
        let skills = service()
        let codex = skills.destination(for: .codex)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try "someone else's skill\n".write(to: codex.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(skills.state(for: .codex), .foreign)
        XCTAssertThrowsError(try skills.install(.codex).get())
        XCTAssertThrowsError(try skills.remove(.codex).get())
        XCTAssertEqual(try String(contentsOf: skillFile(.codex), encoding: .utf8), "someone else's skill\n")

        let claude = skills.destination(for: .claude)
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: codex)
        XCTAssertEqual(skills.state(for: .claude), .foreign, "a link, even to a valid skill, is not this app's copy")

        XCTAssertNoThrow(try skills.install(.claude, replaceExisting: true).get())
        XCTAssertEqual(skills.state(for: .claude), .current)
        XCTAssertEqual(try String(contentsOf: codex.appendingPathComponent("SKILL.md"), encoding: .utf8),
                       "someone else's skill\n", "replacing a link never touches what it pointed at")
    }

    func testRemovesOnlyItsOwnCopy() throws {
        let skills = service()
        XCTAssertNoThrow(try skills.remove(.global).get(), "removing nothing succeeds")
        try skills.install(.global).get()
        try skills.install(.claude).get()
        XCTAssertNoThrow(try skills.remove(.global).get())
        XCTAssertEqual(skills.state(for: .global), .absent)
        XCTAssertEqual(skills.state(for: .claude), .current)
        XCTAssertTrue(discarded.all.isEmpty)
    }

    func testDigestIgnoresHiddenFiles() throws {
        let skills = service()
        try skills.install(.codex).get()
        try Data([1, 2, 3]).write(to: skills.destination(for: .codex).appendingPathComponent(".DS_Store"))
        XCTAssertEqual(skills.state(for: .codex), .current)
    }

    func testBundledSkillMeetsAgentSkillLimits() throws {
        let skill = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Skills/mac-computer-use/SKILL.md")
        let text = try String(contentsOf: skill, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "---")
        guard let end = lines.dropFirst().firstIndex(of: "---") else { return XCTFail("frontmatter is not closed") }
        let fields = Dictionary(uniqueKeysWithValues: lines[1..<end].compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        })
        XCTAssertEqual(Set(fields.keys), ["name", "description"])
        XCTAssertEqual(fields["name"], SkillInstallationService.skillName, "the name matches the folder")
        let description = try XCTUnwrap(fields["description"])
        XCTAssertFalse(description.isEmpty)
        XCTAssertLessThanOrEqual(description.count, 1024)
        XCTAssertFalse(description.contains("<") || description.contains(">"))
    }
}
