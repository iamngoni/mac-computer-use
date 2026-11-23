// Agent side of review notes. Every agent can read every note; it narrows
// the list with filters, and `acted_here_by_you` tells it, from its own
// record of what it touched, whether a note is about its work.
import CoreGraphics
import Foundation

/// What this session has acted on, recorded at tool dispatch.
final class ActivityLog: @unchecked Sendable {
    static let shared = ActivityLog()
    private let lock = NSLock()
    private var windows: Set<UInt32> = []
    private var elementFrames: [CGRect] = []
    private var urls: [String] = []

    static let actionTools: Set<String> = [
        "click", "type_text", "press_key", "scroll", "set_value", "drag", "perform_secondary_action",
        "select_text", "navigate", "invoke_menu", "set_window_frame", "point_at", "annotate",
    ]

    func record(tool: String, args: [String: Any]) {
        guard Self.actionTools.contains(tool) else { return }
        var frame: CGRect?
        if case .some(.some(let index)) = parseElementIndex(args["element_index"]) { frame = elementFrame(index) }
        lock.lock(); defer { lock.unlock() }
        if let snapshot = lastSnapshot { windows.insert(snapshot.windowId) }
        if let frame, !frame.isNull, frame.width > 0, frame.height > 0 {
            elementFrames.append(frame)
            if elementFrames.count > 500 { elementFrames.removeFirst(elementFrames.count - 500) }
        }
        if tool == "navigate", let url = args["url"] as? String { urls.append(url) }
    }

    /// True when this session acted in the note's window, on an element inside
    /// the circled region, or navigated to the note's page.
    func actedHere(windowID: UInt32?, region: CGRect, url: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let windowID, windows.contains(windowID) { return true }
        if !region.isNull, elementFrames.contains(where: { $0.intersects(region) }) { return true }
        if let url {
            let page = normalizedURL(url)
            if urls.contains(where: { page.hasPrefix(normalizedURL($0)) }) { return true }
        }
        return false
    }

    func actedHere(_ note: [String: Any]) -> Bool {
        let region = (note["region"] as? [NSNumber]).flatMap { $0.count == 4 ? CGRect(x: $0[0].doubleValue, y: $0[1].doubleValue, width: $0[2].doubleValue, height: $0[3].doubleValue) : nil } ?? .null
        return actedHere(windowID: (note["window_id"] as? NSNumber)?.uint32Value, region: region, url: note["url"] as? String)
    }
}

/// Appended to tool results while notes are waiting, so a busy agent sees them.
func pendingNotesFooter(tool: String) -> [String: Any]? {
    guard WorkerSession.shared.isAttached, !tool.hasSuffix("_note"), !tool.hasSuffix("_notes") else { return nil }
    let open = WorkerSession.shared.openNoteCount
    guard open > 0 else { return nil }
    return ["type": "text", "text": "pending_notes: \(open) — the user left review notes; list_notes shows them."]
}

/// A notes call either answers or carries the tool result that refuses it.
enum NoteCall<Value> {
    case ok(Value)
    case refused([String: Any])
}

private func notesRequest(_ kind: String, _ message: [String: Any], tool: String) -> NoteCall<[String: Any]> {
    guard OverlayController.shared.isServiceAttached else { return .refused(serviceRequiredResult(tool)) }
    switch WorkerSession.shared.interact(kind, message, timeout: 10) {
    case .response(let response):
        switch response["outcome"] as? String {
        case "ok": return .ok(response)
        case "not_found": return .refused(toolText("[not_found] No note with id \(message["note_id"] as? String ?? "?").", isError: true))
        case "claimed":
            let by = response["claimed_by"] as? String ?? "another agent"
            return .refused(toolText("[already_claimed] \(by) is already working on this note. Leave it to them.", isError: true))
        default:
            return .refused(toolText("[invalid] \(response["message"] as? String ?? "The service refused the request.")", isError: true))
        }
    case .cancelled: return .refused(userInterruptedResult())
    default: return .refused(serviceRequiredResult(tool))
    }
}

private func noteID(_ args: [String: Any]) -> String? {
    (args["note_id"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
}

private func listedNotes(_ args: [String: Any], tool: String) -> NoteCall<[[String: Any]]> {
    switch notesRequest("notes_list", noteFilterMessage(args), tool: tool) {
    case .refused(let error): return .refused(error)
    case .ok(let response):
        var notes = response["notes"] as? [[String: Any]] ?? []
        for index in notes.indices { notes[index]["acted_here_by_you"] = ActivityLog.shared.actedHere(notes[index]) }
        if strictJSONBoolean(args["acted_here_by_me"]) == true {
            notes = notes.filter { $0["acted_here_by_you"] as? Bool == true }
        }
        return .ok(notes)
    }
}

private func noteLine(_ note: [String: Any]) -> String {
    var parts = ["\(note["id"] as? String ?? "?") [\(note["status"] as? String ?? "open")\((note["claimed_by"] as? String).map { " by \($0)" } ?? "")]"]
    parts.append("\"\(note["text"] as? String ?? "")\"")
    var place = note["app"] as? String ?? "?"
    if let url = note["url"] as? String { place += " \(url)" } else if let title = note["window_title"] as? String { place += " “\(title)”" }
    parts.append(place)
    if let element = note["element"] as? [String: Any], let role = element["role"] as? String {
        let label = ["title", "description", "value"].compactMap { element[$0] as? String }.first { !$0.isEmpty }
        parts.append(label.map { "\(role) “\($0.prefix(60))”" } ?? role)
    }
    if note["acted_here_by_you"] as? Bool == true { parts.append("you acted here") }
    return parts.joined(separator: " · ")
}

func toolListNotes(_ args: [String: Any]) -> [String: Any] {
    switch listedNotes(args, tool: "list_notes") {
    case .refused(let error): return error
    case .ok(let notes):
        guard !notes.isEmpty else { return toolText("No review notes match.") }
        return toolText((["\(notes.count) note\(notes.count == 1 ? "" : "s") (oldest first). get_note shows one in full with its image:"] + notes.map(noteLine)).joined(separator: "\n"))
    }
}

func toolGetNote(_ args: [String: Any]) -> [String: Any] {
    guard let id = noteID(args) else { return toolText("[invalid] note_id is required.", isError: true) }
    switch notesRequest("notes_get", ["note_id": id], tool: "get_note") {
    case .refused(let error): return error
    case .ok(let response):
        var note = response["note"] as? [String: Any] ?? [:]
        note["acted_here_by_you"] = ActivityLog.shared.actedHere(note)
        let json = (try? JSONSerialization.data(withJSONObject: note, options: [.sortedKeys, .prettyPrinted]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var content: [[String: Any]] = [["type": "text", "text": json]]
        if let image = response["image"] as? String {
            content.append(["type": "text", "text": "What the user circled:"])
            content.append(["type": "image", "data": image, "mimeType": "image/png"])
        }
        if let after = response["after_image"] as? String {
            content.append(["type": "text", "text": "The same region when the note was resolved:"])
            content.append(["type": "image", "data": after, "mimeType": "image/png"])
        }
        return ["content": content, "isError": false]
    }
}

func toolClaimNote(_ args: [String: Any]) -> [String: Any] {
    guard let id = noteID(args) else { return toolText("[invalid] note_id is required.", isError: true) }
    let label = (args["label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? WorkerSession.shared.clientLabel
    switch notesRequest("notes_claim", ["note_id": id, "label": label], tool: "claim_note") {
    case .refused(let error): return error
    case .ok: return toolText("Claimed \(id) as “\(label)”. Other agents now see it as yours. Call resolve_note with the same label when it is done.")
    }
}

func toolResolveNote(_ args: [String: Any]) -> [String: Any] {
    guard let id = noteID(args) else { return toolText("[invalid] note_id is required.", isError: true) }
    let status = args["status"] as? String ?? "resolved"
    guard ["resolved", "open"].contains(status) else {
        return toolText("[invalid] status must be resolved or open.", isError: true)
    }
    let label = (args["label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? WorkerSession.shared.clientLabel
    var message: [String: Any] = ["note_id": id, "status": status, "label": label]
    if let reply = args["reply"] as? String, !reply.isEmpty { message["reply"] = String(reply.prefix(500)) }
    switch notesRequest("notes_resolve", message, tool: "resolve_note") {
    case .refused(let error): return error
    case .ok:
        return toolText(status == "open"
            ? "Reopened \(id) and released your claim."
            : "Resolved \(id). The user sees your reply beside the note.")
    }
}

func toolWaitForNotes(_ args: [String: Any]) -> [String: Any] {
    let timeout = Double(min(max(strictJSONInteger(args["timeout_s"]) ?? 120, 5), 600))
    let deadline = Date().addingTimeInterval(timeout)
    var query = args
    if query["since"] == nil { query["since"] = ISO8601DateFormatter().string(from: Date()) }
    while true {
        let version = WorkerSession.shared.noteChangeVersion
        switch listedNotes(query, tool: "wait_for_notes") {
        case .refused(let error): return error
        case .ok(let notes) where !notes.isEmpty:
            return toolText((["\(notes.count) new note\(notes.count == 1 ? "" : "s"):"] + notes.map(noteLine)).joined(separator: "\n"))
        case .ok:
            break
        }
        if cancelFlag.value { return userInterruptedResult() }
        guard WorkerSession.shared.waitForNoteChange(after: version, until: deadline) else {
            if cancelFlag.value { return userInterruptedResult() }
            return toolText("[timeout] No matching notes arrived within \(Int(timeout)) s.", isError: true)
        }
    }
}

func noteToolDefinitions() -> [ToolDefinition] {
    func obj(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    let filters: [String: Any] = [
        "url_prefix": ["type": "string", "description": "Only notes on pages under this URL, e.g. localhost:3000/checkout. Scheme and www. are ignored."],
        "app": ["type": "string", "description": "Bundle id or app name."],
        "window_title": ["type": "string", "description": "Window title contains this."],
        "text": ["type": "string", "description": "The note, its element or the text inside the circle contains this."],
        "acted_here_by_me": ["type": "boolean", "description": "Only notes on windows, elements or pages this session acted on."],
        "status": ["type": "string", "description": "open, claimed, resolved, a comma list, or all. Default open,claimed."],
        "since": ["type": "string", "description": "ISO 8601 time; only notes made after it."],
        "review_session": ["type": "string", "description": "Only notes from one review (notes made within minutes of each other)."],
    ]
    let label: [String: Any] = ["type": "string", "maxLength": 80, "description": "How the user and other agents see you, e.g. \"Claude Code · shop-web checkout\". Default: your client name and working folder."]
    return [
        ToolDefinition(
            name: "list_notes",
            description: "Review notes the user left by circling something on screen (⌃⌥⌘N). Notes are not addressed to any agent: filter to the ones about your work (url_prefix, app, window_title, text, acted_here_by_me). One line per note; get_note shows one in full.",
            inputSchema: obj(filters, []),
            handler: toolListNotes
        ),
        ToolDefinition(
            name: "get_note",
            description: "One review note in full: where it is (app, window, URL, element, nearby text), the user's text, and an image of what they circled.",
            inputSchema: obj(["note_id": ["type": "string"]], ["note_id"]),
            handler: toolGetNote
        ),
        ToolDefinition(
            name: "claim_note",
            description: "Mark a note as yours before working on it. Only one agent can hold it; if someone else has, you are told who.",
            inputSchema: obj(["note_id": ["type": "string"], "label": label], ["note_id"]),
            handler: toolClaimNote
        ),
        ToolDefinition(
            name: "resolve_note",
            description: "Finish a note: the user sees your reply beside it and an after image is kept. status \"open\" releases it instead.",
            inputSchema: obj([
                "note_id": ["type": "string"],
                "reply": ["type": "string", "maxLength": 500, "description": "What you did, in a sentence."],
                "status": ["type": "string", "enum": ["resolved", "open"]],
                "label": label,
            ], ["note_id"]),
            handler: toolResolveNote
        ),
        ToolDefinition(
            name: "wait_for_notes",
            description: "Wait until the user leaves a note matching the filters (from now, unless since is given). Use when you are idle and waiting for review. Esc ends it.",
            inputSchema: obj(filters.merging(["timeout_s": ["type": "integer", "minimum": 5, "maximum": 600, "description": "Default 120."]]) { $1 }, []),
            handler: toolWaitForNotes
        ),
    ]
}
