// The service's half of review notes: the person leaves notes (hotkey or
// menu bar), and workers read, claim and resolve them over the control channel.
import AppKit
import Foundation

@MainActor
final class ServiceNotes {
    let store: NoteStore
    private let captureVisible: Bool
    private let pins: NotePins
    private var lasso: LassoSession?
    private var composer: NoteComposer?
    private var reviewSession: (id: String, lastNote: Date)?
    /// Sent to every worker whenever notes change, so waits wake up.
    var broadcast: (([String: Any]) -> Void)?
    var onChange: (() -> Void)?
    var onWindowsChanged: (() -> Void)?

    init(store: NoteStore = NoteStore(), captureVisible: Bool) {
        self.store = store
        self.captureVisible = captureVisible
        pins = NotePins(captureVisible: captureVisible)
        pins.sync(store.list())
    }

    var isComposing: Bool { lasso != nil || composer != nil }
    var openCount: Int { store.openCount }
    var windowIDs: [CGWindowID] { (lasso?.windowIDs ?? []) + (composer.map { [$0.windowID] } ?? []) }

    /// Notes left within ten minutes of each other belong to one review.
    private func currentReviewSession(now: Date = Date()) -> String {
        if let session = reviewSession, now.timeIntervalSince(session.lastNote) < 600 {
            reviewSession = (session.id, now)
            return session.id
        }
        let id = "r-" + String(UUID().uuidString.lowercased().prefix(6))
        reviewSession = (id, now)
        return id
    }

    // MARK: The person

    /// Circle something, then type (or dictate) the note.
    func leaveFeedback() {
        guard !isComposing else { return }
        lasso = LassoSession(prompt: "Circle what your note is about", captureVisible: captureVisible) { [weak self] points in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lasso = nil
                self.onWindowsChanged?()
                guard let points, !points.isEmpty else { return }
                self.compose(path: points)
            }
        }
        onWindowsChanged?()
    }

    private func compose(path points: [CGPoint]) {
        let region = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        // Gather the facts now, while the circled thing is still on screen and
        // before the composer covers anything.
        let session = currentReviewSession()
        guard let captured = makeReviewNote(path: points, text: "", reviewSession: session) else { return }
        composer = NoteComposer(near: region, noteNumber: store.openCount + 1, captureVisible: captureVisible) { [weak self] outcome in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.composer = nil
                self.onWindowsChanged?()
                switch outcome {
                case .cancel:
                    return
                case .save(let text), .saveAndAnother(let text):
                    var note = captured.note
                    note.text = String(text.prefix(2000))
                    do {
                        try self.store.add(note, image: captured.image)
                    } catch {
                        log("could not save review note: \(error)")
                        NSSound.beep()
                        return
                    }
                    self.changed()
                    if case .saveAndAnother = outcome {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            MainActor.assumeIsolated { self.leaveFeedback() }
                        }
                    }
                }
            }
        }
        onWindowsChanged?()
    }

    func cancelComposing() {
        lasso?.finish(nil)
        composer?.finish(.cancel)
    }

    @discardableResult
    func clearResolved() -> Int {
        let count = store.clearResolved()
        changed()
        return count
    }

    func openFolder() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.directory)
    }

    private func changed() {
        pins.sync(store.list(NoteFilter.everything))
        broadcast?(["type": "notes_changed", "open": store.openCount])
        onChange?()
    }

    func removeOverlays() {
        cancelComposing()
        pins.removeAll()
    }

    // MARK: Workers

    /// Answers a `notes_*` request from a worker.
    func handle(_ kind: String, _ message: [String: Any], reply: ([String: Any]) -> Void) {
        func failure(_ error: Error) -> [String: Any] {
            switch error {
            case NoteError.notFound: return ["outcome": "not_found"]
            case NoteError.alreadyClaimed(let by): return ["outcome": "claimed", "claimed_by": by ?? NSNull()]
            case NoteError.invalid(let reason): return ["outcome": "invalid", "message": reason]
            default: return ["outcome": "invalid", "message": "\(error)"]
            }
        }
        let id = message["note_id"] as? String ?? ""
        switch kind {
        case "notes_list":
            var filter = noteFilter(from: message)
            if let ids = message["ids"] as? [String] { filter.ids = Set(ids) }
            reply(["outcome": "ok", "notes": store.list(filter).map(noteWire)])
        case "notes_get":
            guard let note = store.note(id) else { return reply(["outcome": "not_found"]) }
            var payload: [String: Any] = ["outcome": "ok", "note": noteWire(note)]
            if let data = try? Data(contentsOf: store.imageURL(for: id)) { payload["image"] = data.base64EncodedString() }
            if let data = try? Data(contentsOf: store.imageURL(for: id, after: true)) { payload["after_image"] = data.base64EncodedString() }
            reply(payload)
        case "notes_claim":
            let label = String((message["label"] as? String ?? "an agent").prefix(80))
            do {
                let note = try store.claim(id, by: label)
                reply(["outcome": "ok", "note": noteWire(note)])
                changed()
            } catch { reply(failure(error)) }
        case "notes_resolve":
            let status = ReviewNote.Status(rawValue: message["status"] as? String ?? "resolved") ?? .resolved
            let label = (message["label"] as? String).map { String($0.prefix(80)) }
            let reply_ = (message["reply"] as? String).map { String($0.prefix(500)) }
            guard let existing = store.note(id) else { return reply(["outcome": "not_found"]) }
            var after: Data?
            if status == .resolved, let region = currentRegion(of: existing),
               let crop = captureScreenRegion(region.insetBy(dx: -16, dy: -16)), let png = boundedPNG(crop) {
                after = png.data
            }
            do {
                let note = try store.resolve(id, status: status, reply: reply_, by: label, afterImage: after)
                reply(["outcome": "ok", "note": noteWire(note)])
                if status == .resolved { pins.showReply(note) }
                changed()
            } catch { reply(failure(error)) }
        case "notes_count":
            reply(["outcome": "ok", "open": store.openCount])
        default:
            reply(["outcome": "invalid", "message": "unknown notes request"])
        }
    }

    /// The note's region, moved along with its window if the window moved.
    private func currentRegion(of note: ReviewNote) -> CGRect? {
        let region = note.regionRect
        guard !region.isNull else { return nil }
        guard let windowID = note.windowID, let bounds = note.windowBounds, bounds.count == 4,
              let window = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]])?.first,
              let current = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else {
            return region
        }
        return region.offsetBy(dx: current.minX - bounds[0], dy: current.minY - bounds[1])
    }

    /// Notes travel as JSON-ready dictionaries; `acted_here_by_you` is
    /// filled in by the worker, which alone knows what it did.
    private func noteWire(_ note: ReviewNote) -> [String: Any] {
        var out = note.dictionary(actedHere: false)
        out.removeValue(forKey: "acted_here_by_you")
        if let bounds = note.windowBounds { out["window_bounds"] = bounds }
        return out
    }
}

/// ⌃⌥⌘N leaves a review note.
let leaveFeedbackKeyCode: UInt16 = 45
let leaveFeedbackModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

extension NoteFilter {
    static var resolvedOnly: NoteFilter {
        var filter = NoteFilter()
        filter.statuses = [.resolved]
        return filter
    }

    static var everything: NoteFilter {
        var filter = NoteFilter()
        filter.statuses = Set(ReviewNote.Status.allCases)
        return filter
    }
}
