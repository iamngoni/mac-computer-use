import Foundation

/// Where an agent looks for skills. Global is the shared ~/.agents/skills
/// folder that several agents read.
public enum SkillTarget: String, CaseIterable, Sendable {
    case codex = "Codex"
    case claude = "Claude Code"
    case global = "Global"

    var skillsDirectory: String {
        switch self {
        case .codex: return ".codex/skills"
        case .claude: return ".claude/skills"
        case .global: return ".agents/skills"
        }
    }
}

public enum SkillInstallationState: Equatable, Sendable {
    /// Nothing named mac-computer-use is there.
    case absent
    /// This app's copy, identical to the bundled skill.
    case current
    /// This app's copy from an older version, untouched since.
    case outdated
    /// This app's copy, edited since it was installed.
    case modified
    /// A folder or link of the same name that this app did not install.
    case foreign
}

public struct SkillInstallationError: Error, Equatable, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Installs the bundled mac-computer-use skill into agents' skills folders.
/// Each copy carries a marker with the digest it was installed with, so the
/// app updates only its own untouched copies and never overwrites a skill it
/// did not install (or one the user edited) unless asked to.
public struct SkillInstallationService: Sendable {
    public static let skillName = "mac-computer-use"
    static let markerName = ".installed-by-mac-computer-use"

    public let sourceDirectory: URL
    public let homeDirectory: URL
    /// Disposes of a copy that is not an untouched one of ours. Defaults to
    /// moving it to the Trash so nothing the user wrote is lost.
    public let discard: @Sendable (URL) throws -> Void

    public init(
        sourceDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        discard: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) {
        self.sourceDirectory = sourceDirectory
        self.homeDirectory = homeDirectory
        self.discard = discard
    }

    /// The skill inside the app bundle, if this build ships one.
    public static func bundled(in bundle: Bundle = .main) -> SkillInstallationService? {
        guard let resources = bundle.resourceURL else { return nil }
        let source = resources.appendingPathComponent("Skills/\(skillName)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else { return nil }
        return SkillInstallationService(sourceDirectory: source)
    }

    public func destination(for target: SkillTarget) -> URL {
        homeDirectory
            .appendingPathComponent(target.skillsDirectory, isDirectory: true)
            .appendingPathComponent(Self.skillName, isDirectory: true)
    }

    /// Display form of the destination, with ~ for the home folder.
    public func displayPath(for target: SkillTarget) -> String {
        "~/\(target.skillsDirectory)/\(Self.skillName)"
    }

    public func state(for target: SkillTarget) -> SkillInstallationState {
        let destination = destination(for: target)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path) else { return .absent }
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let marker = readMarker(in: destination) else { return .foreign }
        guard let installed = try? digest(of: destination), installed == marker.digest else { return .modified }
        guard let bundled = try? digest(of: sourceDirectory) else { return .current }
        return installed == bundled ? .current : .outdated
    }

    public func install(_ target: SkillTarget, replaceExisting: Bool = false) -> Result<Void, SkillInstallationError> {
        let current = state(for: target)
        if current == .current { return .success(()) }
        if (current == .foreign || current == .modified) && !replaceExisting {
            return .failure(SkillInstallationError(
                "\(displayPath(for: target)) already exists and was not installed by Mac Computer Use, or was edited."
            ))
        }
        let destination = destination(for: target)
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".\(Self.skillName).installing-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceDirectory, to: staging)
            try writeMarker(Marker(version: macComputerUseVersion(), digest: digest(of: staging)), in: staging)
            switch current {
            case .absent:
                break
            case .current, .outdated:
                try FileManager.default.removeItem(at: destination)
            case .modified, .foreign:
                try discard(destination)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            return .success(())
        } catch {
            try? FileManager.default.removeItem(at: staging)
            return .failure(SkillInstallationError("Could not install into \(displayPath(for: target)): \(error.localizedDescription)"))
        }
    }

    /// Removes this app's copy. A skill it did not install is left alone.
    public func remove(_ target: SkillTarget) -> Result<Void, SkillInstallationError> {
        let destination = destination(for: target)
        do {
            switch state(for: target) {
            case .absent:
                return .success(())
            case .foreign:
                return .failure(SkillInstallationError("\(displayPath(for: target)) was not installed by Mac Computer Use."))
            case .current, .outdated:
                try FileManager.default.removeItem(at: destination)
            case .modified:
                try discard(destination)
            }
            return .success(())
        } catch {
            return .failure(SkillInstallationError("Could not remove \(displayPath(for: target)): \(error.localizedDescription)"))
        }
    }

    /// Brings this app's untouched copies up to the bundled skill. Run at
    /// launch so installed skills follow app updates. Returns what changed.
    @discardableResult
    public func refreshOutdated() -> [SkillTarget] {
        SkillTarget.allCases.filter { target in
            guard state(for: target) == .outdated else { return false }
            if case .success = install(target) { return true }
            return false
        }
    }

    // MARK: - Marker and digest

    struct Marker: Codable, Equatable {
        let version: String
        let digest: String
    }

    private func readMarker(in directory: URL) -> Marker? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.markerName)) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    private func writeMarker(_ marker: Marker, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: directory.appendingPathComponent(Self.markerName))
    }

    /// SHA-256 over every visible file's relative path and contents, so the
    /// marker and Finder's .DS_Store files never change the result.
    func digest(of directory: URL) throws -> String {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { throw SkillInstallationError("Could not read \(directory.path).") }
        var files: [(String, URL)] = []
        for case let url as URL in enumerator {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(root.path.count + 1))
            files.append((relative, url))
        }
        var combined = Data()
        for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
            combined.append(Data(relative.utf8))
            combined.append(0)
            combined.append(sha256(try Data(contentsOf: url)))
        }
        return sha256(combined).map { String(format: "%02x", $0) }.joined()
    }
}
