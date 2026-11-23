// Review notes: the person circles something on screen and leaves feedback.
// Notes have no owner. Every agent can read every note and filters by the
// facts captured with it (app, window, URL, element, nearby text), so the
// service never has to guess which agent a note is for.
import Foundation
import CoreGraphics

public struct NoteElement: Codable, Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var title: String?
    public var description: String?
    public var identifier: String?
    public var value: String?
    /// Quartz screen points when the note was made.
    public var frame: [Double]?
}

public struct ReviewNote: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case open, claimed, resolved
    }

    public struct Event: Codable, Equatable, Sendable {
        public var at: Date
        public var status: Status
        public var by: String?
        public var text: String?
    }

    public var version = 1
    public var id: String
    public var createdAt: Date
    public var reviewSession: String
    public var text: String

    // Where.
    public var bundleID: String?
    public var appName: String
    public var pid: Int32?
    public var windowID: UInt32?
    public var windowTitle: String?
    /// The window's Quartz frame when the note was made, so pins can follow it.
    public var windowBounds: [Double]?
    public var url: String?
    public var document: String?
    /// Quartz screen points: x, y, width, height.
    public var region: [Double]
    public var element: NoteElement?
    public var textNearby: [String]

    // State.
    public var status: Status = .open
    public var claimedBy: String?
    public var reply: String?
    public var history: [Event] = []

    public var regionRect: CGRect {
        region.count == 4 ? CGRect(x: region[0], y: region[1], width: region[2], height: region[3]) : .null
    }
}

/// Filters an agent passes to `list_notes`. Every set field must match.
public struct NoteFilter: Equatable, Sendable {
    public var urlPrefix: String?
    public var app: String?
    public var windowTitle: String?
    public var text: String?
    public var statuses: Set<ReviewNote.Status> = [.open, .claimed]
    public var since: Date?
    public var reviewSession: String?
    public var ids: Set<String>?

    public init() {}

    public func matches(_ note: ReviewNote) -> Bool {
        if let ids, !ids.contains(note.id) { return false }
        guard statuses.contains(note.status) else { return false }
        if let since, note.createdAt < since { return false }
        if let reviewSession, note.reviewSession != reviewSession { return false }
        if let urlPrefix {
            guard let url = note.url, normalizedURL(url).hasPrefix(normalizedURL(urlPrefix)) else { return false }
        }
        if let app {
            let needle = app.lowercased()
            guard note.bundleID?.lowercased() == needle || note.appName.lowercased().contains(needle) else { return false }
        }
        if let windowTitle {
            guard note.windowTitle?.localizedCaseInsensitiveContains(windowTitle) == true else { return false }
        }
        if let text {
            let haystack = ([note.text, note.element?.title, note.element?.description, note.element?.value]
                .compactMap { $0 } + note.textNearby).joined(separator: "\n")
            guard haystack.localizedCaseInsensitiveContains(text) else { return false }
        }
        return true
    }
}

/// Drops the scheme and a leading "www." so `localhost:3000/x` matches
/// `http://localhost:3000/x/y`.
func normalizedURL(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespaces).lowercased()
    if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
    if text.hasPrefix("www.") { text.removeFirst(4) }
    return text
}

public enum NoteError: Error, Equatable {
    case notFound
    case alreadyClaimed(by: String?)
    case invalid(String)
}

/// One JSON file per note, plus `<id>.png` (what was circled) and
/// `<id>-after.png` (the same region when the note was resolved).
public final class NoteStore: @unchecked Sendable {
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["MACCU_NOTES_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacComputerUse/Notes", isDirectory: true)
    }

    public let directory: URL
    private let lock = NSLock()
    private var notes: [String: ReviewNote] = [:]

    public init(directory: URL = NoteStore.defaultDirectory()) {
        self.directory = directory
        load()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let note = try? decoder.decode(ReviewNote.self, from: data) {
                notes[note.id] = note
            }
        }
    }

    private func write(_ note: ReviewNote) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(note).write(to: directory.appendingPathComponent("\(note.id).json"), options: .atomic)
    }

    public func imageURL(for id: String, after: Bool = false) -> URL {
        directory.appendingPathComponent(after ? "\(id)-after.png" : "\(id).png")
    }

    public func add(_ note: ReviewNote, image: Data?) throws {
        lock.lock(); defer { lock.unlock() }
        var stored = note
        stored.history = [.init(at: note.createdAt, status: .open, by: nil, text: nil)]
        try write(stored)
        if let image { try image.write(to: imageURL(for: note.id), options: .atomic) }
        notes[note.id] = stored
    }

    public func note(_ id: String) -> ReviewNote? {
        lock.lock(); defer { lock.unlock() }
        return notes[id]
    }

    /// Oldest first, so an agent works through a review in the order it was given.
    public func list(_ filter: NoteFilter = NoteFilter()) -> [ReviewNote] {
        lock.lock(); defer { lock.unlock() }
        return notes.values.filter(filter.matches).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public var openCount: Int {
        lock.lock(); defer { lock.unlock() }
        return notes.values.filter { $0.status != .resolved }.count
    }

    /// Exactly one claimant wins. Re-claiming with the same label is a no-op.
    @discardableResult
    public func claim(_ id: String, by label: String, at date: Date = Date()) throws -> ReviewNote {
        lock.lock(); defer { lock.unlock() }
        guard var note = notes[id] else { throw NoteError.notFound }
        switch note.status {
        case .resolved: throw NoteError.invalid("the note is already resolved")
        case .claimed where note.claimedBy != label: throw NoteError.alreadyClaimed(by: note.claimedBy)
        default: break
        }
        note.status = .claimed
        note.claimedBy = label
        note.history.append(.init(at: date, status: .claimed, by: label, text: nil))
        try write(note)
        notes[id] = note
        return note
    }

    /// Resolves (or reopens) a note. A note claimed by someone else cannot be
    /// resolved by another label.
    @discardableResult
    public func resolve(
        _ id: String,
        status: ReviewNote.Status = .resolved,
        reply: String?,
        by label: String?,
        afterImage: Data? = nil,
        at date: Date = Date()
    ) throws -> ReviewNote {
        lock.lock(); defer { lock.unlock() }
        guard var note = notes[id] else { throw NoteError.notFound }
        if note.status != .open, let owner = note.claimedBy, let label, owner != label {
            throw NoteError.alreadyClaimed(by: owner)
        }
        note.status = status
        if status == .open {
            note.claimedBy = nil
        } else if note.claimedBy == nil {
            note.claimedBy = label
        }
        if let reply, !reply.isEmpty { note.reply = reply }
        note.history.append(.init(at: date, status: status, by: label, text: reply))
        try write(note)
        if let afterImage { try afterImage.write(to: imageURL(for: id, after: true), options: .atomic) }
        notes[id] = note
        return note
    }

    /// Removes resolved notes and their images.
    @discardableResult
    public func clearResolved() -> Int {
        lock.lock(); defer { lock.unlock() }
        let resolved = notes.values.filter { $0.status == .resolved }.map(\.id)
        for id in resolved {
            notes.removeValue(forKey: id)
            for suffix in [".json", ".png", "-after.png"] {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + suffix))
            }
        }
        return resolved.count
    }
}

// MARK: - Wire format

extension ReviewNote {
    func dictionary(actedHere: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "id": id,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "review_session": reviewSession,
            "text": text,
            "app": appName,
            "region": region,
            "text_nearby": textNearby,
            "status": status.rawValue,
            "acted_here_by_you": actedHere,
        ]
        if let bundleID { out["bundle_id"] = bundleID }
        if let pid { out["pid"] = Int(pid) }
        if let windowID { out["window_id"] = Int(windowID) }
        if let windowTitle { out["window_title"] = windowTitle }
        if let url { out["url"] = url }
        if let document { out["document"] = document }
        if let claimedBy { out["claimed_by"] = claimedBy }
        if let reply { out["reply"] = reply }
        if let element {
            var e: [String: Any] = ["role": element.role]
            if let v = element.subrole { e["subrole"] = v }
            if let v = element.title { e["title"] = v }
            if let v = element.description { e["description"] = v }
            if let v = element.identifier { e["identifier"] = v }
            if let v = element.value { e["value"] = v }
            if let v = element.frame { e["frame"] = v }
            out["element"] = e
        }
        return out
    }
}

/// Parses `list_notes` / `wait_for_notes` arguments.
func noteFilter(from args: [String: Any]) -> NoteFilter {
    var filter = NoteFilter()
    func text(_ key: String) -> String? {
        (args[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    filter.urlPrefix = text("url_prefix")
    filter.app = text("app")
    filter.windowTitle = text("window_title")
    filter.text = text("text")
    filter.reviewSession = text("review_session")
    if let since = text("since") { filter.since = ISO8601DateFormatter().date(from: since) }
    if let status = text("status") {
        filter.statuses = status == "all"
            ? Set(ReviewNote.Status.allCases)
            : Set(status.split(separator: ",").compactMap { ReviewNote.Status(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }
    return filter
}

/// The filter as it travels from a worker to the service.
func noteFilterMessage(_ args: [String: Any]) -> [String: Any] {
    var message: [String: Any] = [:]
    for key in ["url_prefix", "app", "window_title", "text", "review_session", "since", "status"] {
        if let value = args[key] as? String { message[key] = value }
    }
    return message
}
