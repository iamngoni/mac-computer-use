// Tools for communicating with the person through the cursor: point at
// things, draw on screen, ask a question, let the person pick, and hand a
// step over to them. They need the Mac Computer Use service, which owns the
// overlay; in-process development servers report that plainly.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func serviceRequiredResult(_ tool: String) -> [String: Any] {
    toolText(
        "[requires_service] \(tool) needs the Mac Computer Use app, which draws the overlay. This server is running in-process; connect through the app (the default) to use it.",
        isError: true
    )
}

/// Accepts an element index as a non-negative integer or integer string.
func parseElementIndex(_ value: Any?) -> Int?? {
    guard let value else { return .some(nil) }
    if let string = value as? String, let index = Int(string), index >= 0 { return .some(index) }
    if let index = strictJSONInteger(value), index >= 0 { return .some(index) }
    return .none
}

func elementSummary(_ element: AXUIElement) -> String {
    let role = axStr(element, "AXRole") ?? "element"
    let name = [axStr(element, "AXTitle"), axStr(element, "AXDescription"), axStr(element, "AXValue")]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    guard let name else { return role }
    return "\(role) “\(name.count > 60 ? String(name.prefix(57)) + "…" : name)”"
}

enum TargetResolution {
    case resolved(InteractionTarget)
    case failed([String: Any])
}

enum AnnotationItemResolution {
    case resolved([String: Any])
    case failed(String)
}

/// What a person would call an element: its label, or a plain role name.
func elementDisplayName(_ element: AXUIElement) -> String {
    let name = [axStr(element, "AXTitle"), axStr(element, "AXDescription"), axStr(element, "AXValue")]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    if let name { return "“\(name.count > 40 ? String(name.prefix(37)) + "…" : name)”" }
    let role = (axStr(element, "AXRoleDescription") ?? axStr(element, "AXRole") ?? "item")
    return role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role
}

struct InteractionTarget {
    let pid: pid_t
    let context: SnapshotContext
    let point: CGPoint      // Quartz screen point
    let frame: CGRect?      // Quartz screen rect of the element
    let element: AXUIElement?
    let index: Int?

    var summary: String {
        if let element, let index { return "[\(index)] \(elementSummary(element))" }
        return describePoint(point, context: context)
    }
}

/// Resolves `app` plus `element_index` or `x`,`y` against the app's current
/// snapshot, exactly like `click`: stale or out-of-bounds targets fail closed.
func resolveInteractionTarget(_ args: [String: Any], tool: String) -> TargetResolution {
    guard let pid = pidFor(args) else { return .failed(unresolvedAppError(args)) }
    guard let context = authorizedSnapshot(forPid: pid) else {
        return .failed(toolText("\(tool) needs a fresh get_app_state snapshot for this app first.", isError: true))
    }
    guard let parsed = parseElementIndex(args["element_index"]) else {
        return .failed(toolText("element_index must be a non-negative integer.", isError: true))
    }
    if let index = parsed {
        guard let element = registryElement(index, forPid: pid) else { return .failed(staleIndexError(index)) }
        guard let frame = axFrame(element) else {
            return .failed(toolText("Element [\(index)] has no on-screen frame.", isError: true))
        }
        return .resolved(InteractionTarget(
            pid: pid, context: context, point: CGPoint(x: frame.midX, y: frame.midY),
            frame: frame, element: element, index: index
        ))
    }
    guard let x = num(args, "x"), let y = num(args, "y") else {
        return .failed(toolText("\(tool) needs element_index or x,y from the last get_app_state.", isError: true))
    }
    guard let point = inputPoint(x: x, y: y, context: context) else {
        return .failed(toolText("\(tool) x,y must be inside the screenshot bounds.", isError: true))
    }
    return .resolved(InteractionTarget(pid: pid, context: context, point: point, frame: nil, element: nil, index: nil))
}

/// True when the snapshot's window is the frontmost window at a point, so
/// the person can actually see what the agent points at or draws on.
func snapshotWindowIsVisible(at point: CGPoint, context: SnapshotContext) -> Bool {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let overlays = Set(WorkerSession.shared.overlayWindowIDs)
    for window in info {
        guard let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              !overlays.contains(number),
              let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue, layer <= 0 || number == context.windowId,
              let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
              bounds.contains(point),
              (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01 else { continue }
        if layer < 0 { continue }
        return number == context.windowId
    }
    return false
}

func hiddenWindowResult(_ tool: String, context: SnapshotContext) -> [String: Any] {
    toolText(
        "[window_hidden] \(context.appLabel)'s window is covered by another window there, so the user cannot see what \(tool) would show. Bring it forward with open_app (or ask the user to), call get_app_state, and try again.",
        isError: true
    )
}

private func clampedMilliseconds(_ args: [String: Any], _ key: String, default value: Int, range: ClosedRange<Int>) -> Int {
    min(max(strictJSONInteger(args[key]) ?? value, range.lowerBound), range.upperBound)
}

private func trimmedText(_ args: [String: Any], _ key: String, limit: Int) -> String? {
    guard let text = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        return nil
    }
    return String(text.prefix(limit))
}

// MARK: - Voice

let voiceMutedResult = toolText(
    "[voice_muted] Speak Aloud is off in Mac Computer Use, so the user did not hear this. Say it in chat instead.",
    isError: true
)

/// Speaks a tool's text without waiting, and returns a note for its result
/// that says honestly whether the user could hear it.
func speakAloud(_ text: String?) -> String {
    guard let text else { return "" }
    guard WorkerSession.shared.isVoiceEnabled else {
        return " Speak Aloud is off in Mac Computer Use, so nothing was spoken."
    }
    OverlayController.shared.sendToService(["type": "speak", "text": text])
    return " Also spoken aloud."
}

func toolSay(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("say") }
    if (args["voice"] as? String)?.lowercased() == "list" {
        let voices = availableSpeechVoices()
        let lines = voices.map { "\($0.name) (\($0.language)) — \($0.id)" }
        return toolText("\(voices.count) voices installed. Pass a name, language (en-GB) or identifier as voice:\n" + lines.joined(separator: "\n"))
    }
    guard let text = trimmedText(args, "text", limit: 400) else { return toolText("say needs text.", isError: true) }
    guard WorkerSession.shared.isVoiceEnabled else { return voiceMutedResult }
    if let voice = args["voice"] as? String, findSpeechVoice(voice) == nil {
        return toolText("No installed voice matches “\(voice)”. Call say with voice: \"list\" to see them.", isError: true)
    }
    let wait = strictJSONBoolean(args["wait"]) ?? true
    var request: [String: Any] = ["text": text, "wait": wait]
    if let rate = strictJSONDouble(args["rate"]) { request["rate"] = clampedSpeechRate(rate) }
    if let voice = args["voice"] as? String { request["voice"] = voice }
    // Speech runs at roughly 15 characters a second; leave room for slow voices.
    let timeout = 10 + Double(text.count) / 6
    switch WorkerSession.shared.interact("say", request, timeout: timeout / min(max(strictJSONDouble(args["rate"]) ?? 1, 0.5), 1.5)) {
    case .response(let response):
        switch response["outcome"] as? String {
        case "muted": return voiceMutedResult
        case "started": return toolText("Speaking aloud: “\(text)”. Not waiting for it to finish.")
        default: return toolText("Said aloud: “\(text)”.")
        }
    case .cancelled:
        return toolText("[user_interrupted] The user stopped the speech with Esc. Stop and ask the user before continuing.", isError: true)
    case .timedOut:
        return toolText("[timeout] The speech did not finish within \(Int(timeout)) s and was stopped.", isError: true)
    case .unavailable, .polled:
        return serviceRequiredResult("say")
    }
}

// MARK: - point_at

func toolPointAt(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("point_at") }
    let target: InteractionTarget
    switch resolveInteractionTarget(args, tool: "point_at") {
    case .resolved(let resolved): target = resolved
    case .failed(let error): return error
    }
    guard snapshotWindowIsVisible(at: target.point, context: target.context) else {
        return hiddenWindowResult("point_at", context: target.context)
    }
    let label = trimmedText(args, "label", limit: 160)
    let hold = clampedMilliseconds(args, "hold_ms", default: 4000, range: 500...15000)
    OverlayController.shared.updateControlledApplication(
        pid: target.pid,
        name: NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? target.context.appLabel
    )
    OverlayController.shared.moveCursorQuartz(target.point, pace: .teach)
    if let label {
        OverlayController.shared.sendToService(["type": "bubble", "text": label, "style": "teach", "hold_ms": hold])
    }
    let spoken = speakAloud(spokenText(args, default: label))
    let shown = label.map { " with “\($0)”" } ?? ""
    return toolText("Pointing at \(target.summary)\(shown) for \(String(format: "%.1f", Double(hold) / 1000)) s. Nothing was clicked.\(spoken)")
}

// MARK: - annotate

/// Converts one annotation item from screenshot pixels to Quartz screen
/// geometry. Returns an error message for an invalid item.
func quartzAnnotationItem(_ item: [String: Any], context: SnapshotContext, pid: pid_t) -> AnnotationItemResolution {
    guard let shapeName = item["shape"] as? String, let shape = AnnotationShape(rawValue: shapeName) else {
        return .failed("each item needs shape: rect, ellipse, arrow, line, path, or label")
    }
    func pixelPoint(_ value: Any?) -> CGPoint? {
        guard let pair = value as? [Any], pair.count == 2,
              let x = strictJSONDouble(pair[0]), let y = strictJSONDouble(pair[1]) else { return nil }
        return inputPoint(x: x, y: y, context: context)
    }
    func elementFrameFor(_ value: Any?) -> CGRect?? {
        guard let parsed = parseElementIndex(value) else { return .none }
        guard let index = parsed else { return .some(nil) }
        guard let element = registryElement(index, forPid: pid), let frame = axFrame(element) else { return .none }
        return .some(frame)
    }
    func encode(_ point: CGPoint) -> [Double] { [Double(point.x), Double(point.y)] }
    func encode(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }
    var output: [String: Any] = ["shape": shape.rawValue]
    if let color = item["color"] as? String { output["color"] = color }
    guard let elementFrame = elementFrameFor(item["element_index"]) else {
        return .failed("element_index is not from this app's current snapshot")
    }
    switch shape {
    case .rect, .ellipse:
        if let elementFrame {
            output["rect"] = encode(elementFrame)
        } else if let x = num(item, "x"), let y = num(item, "y"),
                  let width = num(item, "width"), let height = num(item, "height"),
                  width > 0, height > 0,
                  let origin = inputPoint(x: x, y: y, context: context),
                  let corner = inputPoint(
                    x: min(x + width, Double(context.pixelWidth) - 0.5),
                    y: min(y + height, Double(context.pixelHeight) - 0.5),
                    context: context
                  ) {
            output["rect"] = encode(CGRect(x: origin.x, y: origin.y, width: corner.x - origin.x, height: corner.y - origin.y))
        } else {
            return .failed("\(shape.rawValue) needs element_index or x, y, width, height inside the screenshot")
        }
    case .arrow, .line:
        let to = pixelPoint(item["to"]) ?? elementFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
        guard let to else { return .failed("\(shape.rawValue) needs to=[x,y] or element_index") }
        let from = pixelPoint(item["from"])
            ?? CGPoint(x: to.x - 70, y: to.y - 55)
        output["from"] = encode(from)
        output["to"] = encode(to)
    case .path:
        let points = (item["points"] as? [Any] ?? []).compactMap(pixelPoint)
        guard points.count >= 2, points.count <= 200 else {
            return .failed("path needs 2 to 200 points inside the screenshot")
        }
        output["points"] = points.map(encode)
    case .label:
        guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .failed("label needs text")
        }
        // Pinned to an element, the pill sits just above its top-left corner.
        let at = pixelPoint(item["at"]) ?? elementFrame.map { CGPoint(x: $0.minX, y: $0.minY - 14) }
        guard let at else { return .failed("label needs at=[x,y] or element_index") }
        output["at"] = encode(at)
        output["text"] = String(text.prefix(60))
    }
    return .resolved(output)
}

func toolAnnotate(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("annotate") }
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    guard let context = authorizedSnapshot(forPid: pid) else {
        return toolText("annotate needs a fresh get_app_state snapshot for this app first.", isError: true)
    }
    let items = args["items"] as? [[String: Any]] ?? []
    guard !items.isEmpty || trimmedText(args, "caption", limit: 200) != nil else {
        return toolText("annotate needs at least one item or a caption.", isError: true)
    }
    guard items.count <= 24 else { return toolText("annotate accepts at most 24 items.", isError: true) }
    var converted: [[String: Any]] = []
    for (offset, item) in items.enumerated() {
        switch quartzAnnotationItem(item, context: context, pid: pid) {
        case .resolved(let value): converted.append(value)
        case .failed(let message): return toolText("annotate item \(offset + 1): \(message).", isError: true)
        }
    }
    for point in annotationAnchorPoints(converted) where !snapshotWindowIsVisible(at: point, context: context) {
        return hiddenWindowResult("annotate", context: context)
    }
    let duration = clampedMilliseconds(args, "duration_ms", default: 8000, range: 1000...60000)
    let bounds = context.windowBounds
    OverlayController.shared.sendToService([
        "type": "annotate",
        "items": converted,
        "caption": trimmedText(args, "caption", limit: 200) ?? NSNull(),
        "duration_ms": duration,
        "window_id": Int(context.windowId),
        "window_bounds": [Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)],
    ])
    let spoken = speakAloud(spokenText(args, default: trimmedText(args, "caption", limit: 200)))
    return toolText("Drew \(converted.count) annotation(s) over \(context.appLabel) for \(duration / 1000) s. They clear early if the window moves; clear_annotations removes them.\(spoken)")
}

/// Points that must be visible for an annotation set to make sense.
func annotationAnchorPoints(_ items: [[String: Any]]) -> [CGPoint] {
    items.flatMap { item -> [CGPoint] in
        var points: [CGPoint] = []
        if let rect = quartzRect(item["rect"]) { points.append(CGPoint(x: rect.midX, y: rect.midY)) }
        if let to = quartzPoint(item["to"]) { points.append(to) }
        if let at = quartzPoint(item["at"]) { points.append(at) }
        if let first = (item["points"] as? [Any])?.first.flatMap(quartzPoint) { points.append(first) }
        return points
    }
}

func toolClearAnnotations(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("clear_annotations") }
    OverlayController.shared.sendToService(["type": "annotations_clear"])
    return toolText("Cleared annotations.")
}

// MARK: - ask_user

func toolAskUser(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("ask_user") }
    guard let question = trimmedText(args, "question", limit: 200) else {
        return toolText("ask_user needs a question.", isError: true)
    }
    let options = (args["options"] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard (2...4).contains(options.count), Set(options).count == options.count else {
        return toolText("ask_user needs 2 to 4 distinct options.", isError: true)
    }
    let timeout = Double(clampedMilliseconds(args, "timeout_s", default: 120, range: 5...600))
    OverlayController.shared.touchCursor()
    _ = speakAloud(spokenText(args, default: question))
    switch WorkerSession.shared.interact("ask", ["question": question, "options": options], timeout: timeout) {
    case .response(let response):
        guard let choice = response["choice"] as? String else {
            return toolText("ask_user could not show the question.", isError: true)
        }
        return toolText("The user chose “\(choice)” (option \((response["index"] as? Int ?? 0) + 1)).")
    case .cancelled:
        return toolText("[user_dismissed] The user dismissed the question. Do not assume an answer; ask in chat or stop.", isError: true)
    case .timedOut:
        return toolText("[timeout] The user did not answer within \(Int(timeout)) s.", isError: true)
    case .unavailable, .polled:
        return serviceRequiredResult("ask_user")
    }
}

// MARK: - pick_element

/// Describes what the person picked and maps it to the agent's snapshot.
func describePick(_ point: CGPoint, owner: pid_t, number: Int) -> String {
    let appName = NSRunningApplication(processIdentifier: owner)?.localizedName ?? "pid \(owner)"
    guard owner > 0 else { return "\(number). Nothing pickable at (\(Int(point.x)), \(Int(point.y))) on screen." }
    var element: AXUIElement?
    let found = AXUIElementCopyElementAtPosition(
        AXUIElementCreateApplication(owner), Float(point.x), Float(point.y), &element
    ) == .success
    var line = "\(number). \(appName)"
    if found, let element {
        line += " — \(elementSummary(element))"
        if let snapshot = lastSnapshot, snapshot.pid == owner {
            if let index = elementRegistry.first(where: { CFEqual($0.value, element) })?.key {
                line += " · element_index \(index)"
            }
            if inputScreenPointIsAuthorized(point, context: snapshot) {
                line += " · \(describePoint(point, context: snapshot)) in the last screenshot"
            }
        } else {
            line += " · not in your last snapshot; call get_app_state for \(appName) to act on it"
        }
    }
    return line
}

func toolPickElement(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("pick_element") }
    let prompt = trimmedText(args, "prompt", limit: 160) ?? "Click the item you mean"
    let multiple = strictJSONBoolean(args["multiple"]) ?? false
    let timeout = Double(clampedMilliseconds(args, "timeout_s", default: 120, range: 5...600))
    switch WorkerSession.shared.interact("pick", ["prompt": prompt, "multiple": multiple], timeout: timeout) {
    case .response(let response):
        let points = (response["points"] as? [Any] ?? []).compactMap(quartzPoint)
        let owners = (response["owners"] as? [NSNumber] ?? []).map { pid_t($0.int32Value) }
        guard !points.isEmpty else { return toolText("The user finished without picking anything.") }
        let lines = points.enumerated().map { offset, point in
            describePick(point, owner: offset < owners.count ? owners[offset] : 0, number: offset + 1)
        }
        return toolText("The user picked:\n" + lines.joined(separator: "\n"))
    case .cancelled:
        return toolText("[user_dismissed] The user cancelled picking.", isError: true)
    case .timedOut:
        return toolText("[timeout] The user did not pick within \(Int(timeout)) s.", isError: true)
    case .unavailable, .polled:
        return serviceRequiredResult("pick_element")
    }
}

// MARK: - wait_for_user (hand-off)

func toolWaitForUser(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("wait_for_user") }
    let target: InteractionTarget
    switch resolveInteractionTarget(args, tool: "wait_for_user") {
    case .resolved(let resolved): target = resolved
    case .failed(let error): return error
    }
    guard let instruction = trimmedText(args, "instruction", limit: 160) else {
        return toolText("wait_for_user needs an instruction for the user.", isError: true)
    }
    guard snapshotWindowIsVisible(at: target.point, context: target.context) else {
        return hiddenWindowResult("wait_for_user", context: target.context)
    }
    let until = (args["until"] as? String)?.lowercased() ?? "either"
    guard ["click", "value_change", "either"].contains(until) else {
        return toolText("until must be click, value_change, or either.", isError: true)
    }
    let timeout = Double(clampedMilliseconds(args, "timeout_s", default: 120, range: 5...600))
    let rect = target.frame ?? CGRect(x: target.point.x - 12, y: target.point.y - 12, width: 24, height: 24)

    // Watch the element's value, or only its length for a secure field, so
    // the agent learns the step is done without ever reading a secret.
    let element = target.element
    let secure = element.map { axStr($0, "AXSubrole") == "AXSecureTextField" || axStr($0, "AXRole") == "AXSecureTextField" } ?? false
    func fingerprint() -> String? {
        guard let element else { return nil }
        if secure { return (axCopy(element, "AXNumberOfCharacters") as? NSNumber)?.stringValue }
        return axCopy(element, "AXValue").map { "\($0)" }
    }
    let initial = until == "click" ? nil : fingerprint()

    OverlayController.shared.updateControlledApplication(
        pid: target.pid,
        name: NSRunningApplication(processIdentifier: target.pid)?.localizedName ?? target.context.appLabel
    )
    OverlayController.shared.moveCursorQuartz(target.point, pace: .teach)
    OverlayController.shared.sendToService(["type": "bubble", "text": "Your turn: \(instruction)", "style": "handoff", "hold_ms": 0])
    defer { OverlayController.shared.sendToService(["type": "bubble_clear"]) }
    _ = speakAloud(spokenText(args, default: instruction))

    var lastTouch = Date()
    let outcome = WorkerSession.shared.interact(
        "wait_click",
        ["rect": [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]],
        timeout: timeout,
        poll: {
            if Date().timeIntervalSince(lastTouch) > 2 {
                OverlayController.shared.touchCursor()
                lastTouch = Date()
            }
            guard until != "click", let initial, let now = fingerprint(), now != initial else { return nil }
            return ["how": "value_change"]
        }
    )
    switch outcome {
    case .response(let response) where response["outcome"] as? String == "clicked":
        if until == "value_change" {
            return toolText("The user clicked the target but the value has not changed yet; call wait_for_user again with until=value_change if you need to wait for their input.")
        }
        OverlayController.shared.sendToService(["type": "bubble", "text": "Thanks!", "style": "done", "hold_ms": 900])
        return toolText("The user clicked \(target.summary). Re-read state before continuing.")
    case .polled:
        OverlayController.shared.sendToService(["type": "bubble", "text": "Thanks!", "style": "done", "hold_ms": 900])
        return toolText("The user changed \(target.summary)\(secure ? " (secure field: only its length was observed)" : ""). Re-read state before continuing.")
    case .cancelled:
        return toolText("[user_dismissed] The user dismissed the hand-off.", isError: true)
    case .timedOut:
        return toolText("[timeout] The user did not complete the step within \(Int(timeout)) s.", isError: true)
    case .unavailable, .response:
        return serviceRequiredResult("wait_for_user")
    }
}

// MARK: - Risky actions and yielding

/// Words that mark an action as hard to undo. Matched as whole words.
let riskyActionPhrases = [
    "send", "delete", "remove", "erase", "empty trash", "move to trash", "discard",
    "buy", "purchase", "pay", "place order", "checkout", "check out", "submit",
    "post", "publish", "transfer", "confirm", "sign out", "log out", "uninstall",
    "format", "reset", "overwrite", "replace", "unsubscribe", "deactivate", "wipe",
]

/// The risky phrase an element's labels contain, if any.
func riskyActionPhrase(_ labels: [String?]) -> String? {
    for label in labels.compactMap({ $0?.lowercased() }) {
        let words = label.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let joined = " " + words.joined(separator: " ") + " "
        if let phrase = riskyActionPhrases.first(where: { joined.contains(" \($0) ") }) { return phrase }
    }
    return nil
}

func riskyConfirmationDelay(environment: [String: String] = ProcessInfo.processInfo.environment) -> TimeInterval {
    if let value = environment["MACCU_RISKY_CONFIRM_MS"], let milliseconds = Double(value) {
        return max(0, min(milliseconds, 10_000)) / 1000
    }
    return 2
}

/// Before pressing something like Send or Delete, the cursor rests on it with
/// a countdown ring so the person can stop it with Esc. Returns a result when
/// the person stopped it, nil to proceed.
func confirmRiskyAction(element: AXUIElement?, point: CGPoint?) -> [String: Any]? {
    let delay = riskyConfirmationDelay()
    guard OverlayController.shared.isServiceAttached, delay > 0, let element,
          let phrase = riskyActionPhrase([
              axStr(element, "AXTitle"), axStr(element, "AXDescription"), axStr(element, "AXHelp"),
              axStr(element, "AXRole") == "AXButton" ? axStr(element, "AXValue") : nil,
          ]) else { return nil }
    if let point { OverlayController.shared.moveCursorQuartz(point) }
    let name = elementSummary(element)
    OverlayController.shared.sendToService(["type": "countdown", "duration_ms": Int(delay * 1000)])
    OverlayController.shared.sendToService([
        "type": "bubble", "text": "About to press \(elementDisplayName(element)) · Esc to stop",
        "style": "nudge", "hold_ms": Int(delay * 1000),
    ])
    let deadline = Date().addingTimeInterval(delay)
    while Date() < deadline {
        if cancelFlag.value { return userInterruptedResult(actionReport: "Stopped before pressing \(name) (\(phrase)).") }
        usleep(20_000)
    }
    return nil
}

/// Seconds since the person last used the keyboard, mouse or trackpad.
func secondsSinceUserInput() -> Double {
    guard let anyInput = CGEventType(rawValue: UInt32.max) else { return .infinity }
    return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
}

/// The owner of the frontmost normal window, which is what the person is using.
func frontmostWindowOwner() -> pid_t? {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in info where (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 {
        if let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value { return owner }
    }
    return nil
}

func shouldYieldToUser(secondsSinceInput: Double, targetIsFrontmost: Bool) -> Bool {
    targetIsFrontmost && secondsSinceInput < 1.0
}

/// When the person is typing or pointing in the very app the agent is about
/// to drive, wait for a short pause instead of fighting over it. Returns a
/// result when they stay busy, nil to proceed.
func yieldToUser(targetPID: pid_t, appName: String?) -> [String: Any]? {
    guard OverlayController.shared.isServiceAttached,
          shouldYieldToUser(secondsSinceInput: secondsSinceUserInput(), targetIsFrontmost: frontmostWindowOwner() == targetPID) else {
        return nil
    }
    let name = appName ?? NSRunningApplication(processIdentifier: targetPID)?.localizedName ?? "this app"
    OverlayController.shared.sendToService(["type": "bubble", "text": "Waiting — you’re using \(name)", "style": "tag", "hold_ms": 1500])
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if cancelFlag.value { return userInterruptedResult(actionReport: "Waited while the user was using \(name).") }
        if secondsSinceUserInput() >= 1.5 || frontmostWindowOwner() != targetPID { return nil }
        usleep(100_000)
    }
    return toolText("[user_busy] The user kept using \(name) for 20 s, so nothing was done. Wait, or ask them before retrying.", isError: true)
}

// MARK: - Live visuals

private func visualID(_ args: [String: Any]) -> String? {
    guard let raw = args["id"] else { return "main" }
    guard let id = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !id.isEmpty, id.count <= 64 else { return nil }
    return id
}

private func encodeQuartzRect(_ rect: CGRect) -> [Double] {
    [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
}

/// Resolves an element index or an [x, y, width, height] rect (screenshot
/// pixels with an app snapshot, screen points without) to Quartz.
private func visualRect(_ value: Any?, context: SnapshotContext?, pid: pid_t?) -> CGRect? {
    if let array = value as? [Any] {
        guard array.count == 4 else { return nil }
        let numbers = array.compactMap(strictJSONDouble)
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        guard let context else { return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) }
        let origin = pixelToScreen(CGPoint(x: numbers[0], y: numbers[1]), context)
        return CGRect(x: origin.x, y: origin.y, width: numbers[2] / context.pixelScale, height: numbers[3] / context.pixelScale)
    }
    guard let pid, let parsed = parseElementIndex(value), let index = parsed,
          let element = registryElement(index, forPid: pid) else { return nil }
    return axFrame(element)
}

struct VisualArgumentError: Error { let message: String }

private func visualTargets(_ value: Any?, context: SnapshotContext?, pid: pid_t?) -> Result<[String: [Double]], VisualArgumentError> {
    guard let value else { return .success([:]) }
    guard let map = value as? [String: Any], map.count <= 48 else { return .failure(VisualArgumentError(message: "targets must be an object of at most 48 entries")) }
    var output: [String: [Double]] = [:]
    for (name, raw) in map {
        guard let rect = visualRect(raw, context: context, pid: pid) else {
            return .failure(VisualArgumentError(message: "target “\(name)” needs an element_index from the current snapshot or [x, y, width, height]"))
        }
        output[name] = encodeQuartzRect(rect)
    }
    return .success(output)
}

private func visualSummary(_ response: [String: Any]) -> String {
    var lines: [String] = []
    if let events = response["events"] as? [Any], !events.isEmpty,
       let text = visualResultText(events) {
        lines.append("Events from the visual: \(text)")
    }
    if let result = response["result"] as? String { lines.append("Script returned: \(result)") }
    if let error = response["script_error"] as? String { lines.append("Script error: \(error)") }
    if let errors = response["errors"] as? [String], !errors.isEmpty {
        lines.append("Page errors:\n- " + errors.joined(separator: "\n- "))
    }
    return lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n")
}

func toolShowVisual(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("show_visual") }
    guard let id = visualID(args) else { return toolText("show_visual id must be 1 to 64 characters.", isError: true) }
    var template: VisualTemplate?
    if let name = args["template"] as? String {
        guard let found = visualTemplates[name] else {
            return toolText("Unknown template “\(name)”. Templates: \(visualTemplates.keys.sorted().joined(separator: ", ")).", isError: true)
        }
        template = found
    }
    let rawHTML = (args["html"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    guard rawHTML != nil || template != nil else {
        return toolText("show_visual needs html (a page or fragment: HTML, CSS, SVG, canvas, WebGL, scripts) or a template.", isError: true)
    }
    let html = template.map { visualTemplatePage($0, extra: rawHTML) } ?? rawHTML ?? ""
    guard html.utf8.count <= VisualStage.maxHTMLBytes else {
        return toolText("show_visual html is limited to \(VisualStage.maxHTMLBytes / 1_000_000) MB; load big libraries from a CDN with <script src>.", isError: true)
    }
    var context: SnapshotContext?
    var pid: pid_t?
    if let spec = args["app"] as? String, !spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        guard let resolved = pidFor(args) else { return unresolvedAppError(args) }
        guard let snapshot = authorizedSnapshot(forPid: resolved) else {
            return toolText("show_visual over an app needs a fresh get_app_state snapshot for it first.", isError: true)
        }
        pid = resolved
        context = snapshot
    }
    var anchor: CGRect?
    if args["element_index"] != nil {
        guard let rect = visualRect(args["element_index"], context: context, pid: pid) else {
            return toolText("element_index is not from this app's current snapshot.", isError: true)
        }
        anchor = rect
    } else if let x = args["x"], let y = args["y"] {
        let width = args["width"] ?? NSNumber(value: 1), height = args["height"] ?? NSNumber(value: 1)
        guard let rect = visualRect([x, y, width, height], context: context, pid: pid) else {
            return toolText("x, y, width, height must be numbers; width and height above 0.", isError: true)
        }
        anchor = rect
    }
    let targets: [String: [Double]]
    switch visualTargets(args["targets"], context: context, pid: pid) {
    case .success(let value): targets = value
    case .failure(let error): return toolText("show_visual: \(error.message).", isError: true)
    }
    var allTargets = targets
    if let anchor { allTargets["anchor"] = encodeQuartzRect(anchor) }
    if let context { allTargets["window"] = encodeQuartzRect(context.windowBounds) }

    if let template, template.needsAnchor, anchor == nil {
        return toolText("The \(template.name) template needs an anchor: element_index or x, y, width, height.", isError: true)
    }
    let defaultPlacement: VisualPlacement = template?.placement ?? (anchor != nil ? .beside : .center)
    let placementName = args["placement"] as? String
    guard let placement = placementName.map({ VisualPlacement(rawValue: $0) }) ?? defaultPlacement else {
        return toolText("placement must be beside, over, center, window, screen or at.", isError: true)
    }
    if placement == .window, context == nil {
        return toolText("placement window needs app (and its get_app_state snapshot).", isError: true)
    }
    if let anchor, let context, !snapshotWindowIsVisible(at: CGPoint(x: anchor.midX, y: anchor.midY), context: context) {
        return hiddenWindowResult("show_visual", context: context)
    }
    let templateSize = template.map { $0.size == .zero ? CGSize(width: 380, height: 240) : $0.size }
    let width = min(max(strictJSONDouble(args["panel_width"]) ?? Double(templateSize?.width ?? 380), 40), 4000)
    let height = min(max(strictJSONDouble(args["panel_height"]) ?? Double(templateSize?.height ?? 240), 30), 3000)
    let durationValue = strictJSONInteger(args["duration_ms"]) ?? 30000
    let duration = durationValue <= 0 ? 0 : min(max(durationValue, 1000), 1_800_000)
    let interactive = strictJSONBoolean(args["interactive"]) ?? template?.interactive ?? false
    let backdrop = args["backdrop"] as? String ?? "none"
    guard ["none", "glass", "dark"].contains(backdrop) else {
        return toolText("backdrop must be none, glass or dark.", isError: true)
    }
    var message: [String: Any] = [
        "visual_id": id,
        "html": html,
        "placement": placement.rawValue,
        "size": [width, height],
        "targets": allTargets,
        "interactive": interactive,
        "backdrop": backdrop,
        "follow_window": strictJSONBoolean(args["follow_window"]) ?? true,
        "duration_ms": duration,
    ]
    if let anchor { message["anchor"] = encodeQuartzRect(anchor) }
    if let context {
        message["window_bounds"] = encodeQuartzRect(context.windowBounds)
        message["window_id"] = Int(context.windowId)
    }
    if let data = args["data"] { message["data"] = data }
    OverlayController.shared.touchCursor()
    switch WorkerSession.shared.interact("visual_show", message, timeout: 15) {
    case .response(let response):
        guard response["outcome"] as? String == "shown" else {
            return toolText("show_visual failed: \(response["message"] as? String ?? "the overlay refused it").", isError: true)
        }
        let frame = (response["frame"] as? [Double]).map { $0.map { String(Int($0)) }.joined(separator: ", ") } ?? "?"
        let life = duration == 0 ? "until cleared" : "for \(duration / 1000) s"
        let spoken = speakAloud(spokenText(args, default: nil))
        return toolText(
            "Showing visual “\(id)” at [\(frame)] (screen points, side \(response["side"] as? String ?? "none")) \(life)\(interactive ? ", interactive" : ", click-through"). It is hidden from your screenshots; use update_visual with snapshot: true to see it.\(visualSummary(response))\(spoken)"
        )
    case .timedOut:
        return toolText("[timeout] The overlay did not confirm the visual.", isError: true)
    case .cancelled:
        return toolText("[cancelled] The user stopped the agent.", isError: true)
    case .unavailable, .polled:
        return serviceRequiredResult("show_visual")
    }
}

func toolUpdateVisual(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("update_visual") }
    guard let id = visualID(args) else { return toolText("update_visual id must be 1 to 64 characters.", isError: true) }
    var message: [String: Any] = ["visual_id": id]
    if let script = args["script"] as? String, !script.isEmpty {
        guard script.utf8.count <= VisualStage.maxHTMLBytes else { return toolText("script is too large.", isError: true) }
        message["script"] = script
    }
    if let html = args["html"] as? String, !html.isEmpty {
        guard html.utf8.count <= VisualStage.maxHTMLBytes else { return toolText("html is too large.", isError: true) }
        message["html"] = html
    }
    if args.keys.contains("data") { message["data"] = args["data"] ?? NSNull() }
    if args["targets"] != nil {
        var context: SnapshotContext?
        let pid = pidFor(args)
        if let pid { context = authorizedSnapshot(forPid: pid) }
        switch visualTargets(args["targets"], context: context, pid: pid) {
        case .success(let value): message["targets"] = value
        case .failure(let error): return toolText("update_visual: \(error.message).", isError: true)
        }
    }
    let snapshot = strictJSONBoolean(args["snapshot"]) ?? false
    message["snapshot"] = snapshot
    let wait = min(max(strictJSONInteger(args["wait_event_ms"]) ?? 0, 0), 600_000)
    message["wait_event_ms"] = wait
    switch WorkerSession.shared.interact("visual_update", message, timeout: Double(wait) / 1000 + 20) {
    case .response(let response):
        if response["outcome"] as? String == "missing" {
            return toolText("No visual “\(id)” is showing. It may have expired, been closed, or been cleared by the user.", isError: true)
        }
        let summary = visualSummary(response)
        var result = toolText("Updated visual “\(id)”.\(summary.isEmpty ? (wait > 0 ? "\nNo events arrived." : "") : summary)")
        if let png = response["png"] as? String, var content = result["content"] as? [[String: Any]] {
            content.append(["type": "image", "data": png, "mimeType": "image/png"])
            result["content"] = content
        }
        return result
    case .timedOut:
        return toolText("[timeout] The visual did not answer.", isError: true)
    case .cancelled:
        return toolText("[cancelled] The user stopped the agent.", isError: true)
    case .unavailable, .polled:
        return serviceRequiredResult("update_visual")
    }
}

func toolClearVisuals(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("clear_visuals") }
    var message: [String: Any] = [:]
    if let id = args["id"] as? String { message["visual_id"] = id }
    switch WorkerSession.shared.interact("visual_clear", message, timeout: 5) {
    case .response(let response):
        return toolText("Cleared \((response["count"] as? NSNumber)?.intValue ?? 0) visual(s).")
    default:
        return serviceRequiredResult("clear_visuals")
    }
}


// MARK: - buddy

func toolBuddy(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("buddy") }
    var message: [String: Any] = ["type": "buddy"]
    var parts: [String] = []
    if let follow = strictJSONBoolean(args["follow"]) {
        let ms = follow ? clampedMilliseconds(args, "follow_ms", default: 120_000, range: 1000...1_800_000) : 0
        message["follow_ms"] = ms
        parts.append(follow ? "following the user's pointer for \(ms / 1000) s (your actions still fly the cursor to their targets)" : "stopped following")
    }
    if let thinking = strictJSONBoolean(args["thinking"]) {
        let ms = thinking ? clampedMilliseconds(args, "thinking_ms", default: 30_000, range: 500...600_000) : 0
        message["thinking_ms"] = ms
        parts.append(thinking ? "showing thinking dots" : "cleared thinking dots")
    }
    if let emote = args["emote"] as? String {
        guard CursorEmote(rawValue: emote) != nil else {
            return toolText("emote must be one of: \(CursorEmote.allCases.map(\.rawValue).joined(separator: ", ")).", isError: true)
        }
        message["emote"] = emote
        parts.append("\(emote)")
    }
    guard !parts.isEmpty else { return toolText("buddy needs follow, thinking or emote.", isError: true) }
    OverlayController.shared.sendToService(message)
    let spoken = speakAloud(spokenText(args, default: nil))
    return toolText("Cursor: " + parts.joined(separator: "; ") + ".\(spoken)")
}

// MARK: - watch_user

/// Resolves an element index or [x, y, width, height] (screenshot pixels) in
/// the given app to a Quartz rect, for watch and magnify targets.
private func appRegion(_ args: [String: Any], tool: String) -> Result<(rect: CGRect, context: SnapshotContext?), VisualArgumentError> {
    var context: SnapshotContext?
    var pid: pid_t?
    if let spec = args["app"] as? String, !spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        guard let resolved = pidFor(args) else { return .failure(VisualArgumentError(message: "unknown app “\(spec)”")) }
        guard let snapshot = authorizedSnapshot(forPid: resolved) else {
            return .failure(VisualArgumentError(message: "\(tool) needs a fresh get_app_state snapshot of \(spec) first"))
        }
        pid = resolved
        context = snapshot
    }
    if args["element_index"] != nil {
        guard let rect = visualRect(args["element_index"], context: context, pid: pid) else {
            return .failure(VisualArgumentError(message: "element_index is not from this app's current snapshot"))
        }
        return .success((rect, context))
    }
    if let x = args["x"], let y = args["y"] {
        guard let rect = visualRect([x, y, args["width"] ?? NSNumber(value: 40), args["height"] ?? NSNumber(value: 40)], context: context, pid: pid) else {
            return .failure(VisualArgumentError(message: "x, y, width, height must be numbers"))
        }
        return .success((rect, context))
    }
    return .failure(VisualArgumentError(message: "\(tool) needs element_index or x, y (with app: screenshot pixels; without: screen points)"))
}

func toolWatchUser(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("watch_user") }
    var message: [String: Any] = [:]
    let until = args["until"] as? String ?? "idle"
    switch until {
    case "click":
        message["any_click"] = true
    case "click_element":
        switch appRegion(args, tool: "watch_user until click_element") {
        case .success(let region): message["click_in"] = [Double(region.rect.minX), Double(region.rect.minY), Double(region.rect.width), Double(region.rect.height)]
        case .failure(let error): return toolText("watch_user: \(error.message).", isError: true)
        }
    case "app":
        guard let name = (args["target_app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return toolText("watch_user until app needs target_app.", isError: true)
        }
        message["app"] = name
    case "shortcut":
        guard let spec = args["shortcut"] as? String, let shortcut = normalizedShortcutSpec(spec) else {
            return toolText("watch_user until shortcut needs shortcut, for example cmd+s.", isError: true)
        }
        message["shortcut"] = shortcut
    case "idle", "duration":
        break
    default:
        return toolText("until must be click, click_element, app, shortcut, idle or duration.", isError: true)
    }
    if until == "idle" || args["idle_ms"] != nil {
        message["idle_ms"] = clampedMilliseconds(args, "idle_ms", default: 4000, range: 500...120_000)
    }
    let duration = clampedMilliseconds(args, "duration_ms", default: 60_000, range: 2000...600_000)
    message["duration_ms"] = duration
    OverlayController.shared.touchCursor()
    if let prompt = trimmedText(args, "prompt", limit: 160) {
        OverlayController.shared.sendToService(["type": "bubble", "text": prompt, "style": "handoff", "hold_ms": min(duration, 15000)])
    }
    _ = speakAloud(spokenText(args, default: trimmedText(args, "prompt", limit: 160)))
    switch WorkerSession.shared.interact("watch", message, timeout: Double(duration) / 1000 + 5) {
    case .response(let response):
        let events = response["events"] as? [[String: Any]] ?? []
        let outcome = response["outcome"] as? String ?? "?"
        let headline: String
        switch outcome {
        case "matched": headline = "The user did it (\(until))"
        case "idle": headline = "The user paused for \((message["idle_ms"] as? Int ?? 0) / 1000) s"
        case "time_up": headline = "Watch time ran out without the expected action"
        case "cancelled_watch": headline = "The watch was cancelled"
        default: headline = "Watch ended (\(outcome))"
        }
        var lines: [String] = []
        for event in events {
            let t = String(format: "+%.1fs", (event["t"] as? Double) ?? 0)
            switch event["kind"] as? String {
            case "click":
                let point = quartzPoint(event["point"]) ?? .zero
                let owner = pid_t((event["owner"] as? NSNumber)?.int32Value ?? 0)
                let button = event["button"] as? String == "right" ? "right-clicked" : ((event["count"] as? Int ?? 1) > 1 ? "double-clicked" : "clicked")
                let described = describePick(point, owner: owner, number: 0).replacingOccurrences(of: "0. ", with: "", options: .anchored)
                lines.append("\(t) \(button) \(described) at (\(Int(point.x)), \(Int(point.y))) screen points")
            case "key":
                lines.append("\(t) pressed \(event["shortcut"] as? String ?? "?")")
            case "typing":
                lines.append("\(t) typed \(event["count"] as? Int ?? 0) character(s) (content not recorded)")
            case "app":
                lines.append("\(t) switched to \(event["app"] as? String ?? "?")")
            default:
                break
            }
        }
        let body = lines.isEmpty ? "No input from the user." : lines.joined(separator: "\n")
        let elapsed = String(format: "%.1f", response["elapsed"] as? Double ?? 0)
        return toolText("\(headline) after \(elapsed) s.\n\(body)")
    case .cancelled:
        return toolText("[user_dismissed] The watch was cancelled.", isError: true)
    case .timedOut:
        return toolText("[timeout] The watch did not finish.", isError: true)
    case .unavailable, .polled:
        return serviceRequiredResult("watch_user")
    }
}

// MARK: - lasso_region

func toolLassoRegion(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("lasso_region") }
    let prompt = trimmedText(args, "prompt", limit: 160) ?? "Circle what you mean"
    let timeout = Double(clampedMilliseconds(args, "timeout_s", default: 120, range: 5...600))
    _ = speakAloud(spokenText(args, default: prompt))
    switch WorkerSession.shared.interact("lasso", ["prompt": prompt], timeout: timeout) {
    case .response(let response):
        let points = (response["points"] as? [Any] ?? []).compactMap(quartzPoint)
        guard !points.isEmpty else { return toolText("The user finished without drawing.") }
        let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -6, dy: -6)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let owner = windowOwnerUnder(center) ?? 0
        let what = describePick(center, owner: owner, number: 1).replacingOccurrences(of: "1. ", with: "", options: .anchored)
        let closed = hypot(points[0].x - points[points.count - 1].x, points[0].y - points[points.count - 1].y) < max(bounds.width, bounds.height) * 0.35
        var text = """
        The user \(closed ? "circled" : "drew a stroke over") a region at [\(Int(bounds.minX)), \(Int(bounds.minY)), \(Int(bounds.width)), \(Int(bounds.height))] (screen points).
        At its centre: \(what).
        """
        var content: [[String: Any]] = []
        if let crop = captureScreenRegion(bounds.insetBy(dx: -16, dy: -16)), let png = boundedPNG(crop) {
            text += "\nAttached: what is inside the region (\(png.width)×\(png.height) px)."
            content.append(["type": "image", "data": png.data.base64EncodedString(), "mimeType": "image/png"])
        }
        return ["content": [["type": "text", "text": text]] + content, "isError": false]
    case .cancelled:
        return toolText("[user_dismissed] The user cancelled drawing.", isError: true)
    case .timedOut:
        return toolText("[timeout] The user did not draw within \(Int(timeout)) s.", isError: true)
    case .unavailable, .polled:
        return serviceRequiredResult("lasso_region")
    }
}

/// Captures a Quartz screen rect from the display containing its centre.
func captureScreenRegion(_ rect: CGRect) -> CGImage? {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    guard let display = activeDisplayIDs().first(where: { CGDisplayBounds($0).contains(center) }),
          let image = captureDesktopDisplay(display) else { return nil }
    let bounds = CGDisplayBounds(display)
    let scale = CGFloat(image.width) / bounds.width
    let local = rect.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY)
    guard !local.isNull, local.width >= 1, local.height >= 1 else { return nil }
    return image.cropping(to: CGRect(x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale).integral)
}

// MARK: - magnify

func toolMagnify(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("magnify") }
    if strictJSONBoolean(args["clear"]) == true {
        OverlayController.shared.sendToService(["type": "magnify_clear"])
        return toolText("Closed the magnifier.")
    }
    let region: (rect: CGRect, context: SnapshotContext?)
    switch appRegion(args, tool: "magnify") {
    case .success(let value): region = value
    case .failure(let error): return toolText("magnify: \(error.message).", isError: true)
    }
    if let context = region.context,
       !snapshotWindowIsVisible(at: CGPoint(x: region.rect.midX, y: region.rect.midY), context: context) {
        return hiddenWindowResult("magnify", context: context)
    }
    let zoom = min(max(strictJSONDouble(args["zoom"]) ?? 3, 1.5), 8)
    let duration = clampedMilliseconds(args, "duration_ms", default: 8000, range: 1000...120_000)
    var message: [String: Any] = [
        "type": "magnify",
        "rect": [Double(region.rect.minX), Double(region.rect.minY), Double(region.rect.width), Double(region.rect.height)],
        "zoom": zoom,
        "duration_ms": duration,
    ]
    if let label = trimmedText(args, "label", limit: 80) { message["label"] = label }
    OverlayController.shared.sendToService(message)
    let spoken = speakAloud(spokenText(args, default: trimmedText(args, "label", limit: 80)))
    return toolText("Magnifying [\(Int(region.rect.minX)), \(Int(region.rect.minY)), \(Int(region.rect.width)), \(Int(region.rect.height))] at \(String(format: "%.1f", zoom))× for \(duration / 1000) s, live.\(spoken)")
}

// MARK: - suggest

func toolSuggest(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("suggest") }
    guard let title = trimmedText(args, "title", limit: 90) else { return toolText("suggest needs a title.", isError: true) }
    let actions = (args["actions"] as? [Any] ?? ["Do it", "Not now"]).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard (1...3).contains(actions.count), Set(actions).count == actions.count else {
        return toolText("suggest needs 1 to 3 distinct actions.", isError: true)
    }
    var message: [String: Any] = ["title": title, "actions": actions]
    if let body = trimmedText(args, "body", limit: 240) { message["body"] = body }
    if let symbol = args["symbol"] as? String, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
        message["symbol"] = symbol
    }
    let timeout = Double(clampedMilliseconds(args, "timeout_s", default: 120, range: 5...900))
    _ = speakAloud(spokenText(args, default: title))
    switch WorkerSession.shared.interact("suggest", message, timeout: timeout) {
    case .response(let response):
        let choice = response["choice"] as? String ?? "?"
        let index = (response["index"] as? NSNumber)?.intValue ?? -1
        return toolText("The user chose “\(choice)”\(index == 0 ? " (your primary action)" : "").")
    case .cancelled:
        return toolText("[user_dismissed] The user dismissed the suggestion.", isError: true)
    case .timedOut:
        return toolText("[timeout] The user did not answer within \(Int(timeout)) s. Treat it as not now.", isError: true)
    case .unavailable, .polled:
        return serviceRequiredResult("suggest")
    }
}

// MARK: - job

func toolJob(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("job") }
    let id = (args["id"] as? String).map { String($0.prefix(64)) } ?? "main"
    if strictJSONBoolean(args["clear"]) == true {
        OverlayController.shared.sendToService(["type": "job", "job_id": id, "clear": true])
        return toolText("Removed job card “\(id)”.")
    }
    guard let title = trimmedText(args, "title", limit: 80) else { return toolText("job needs a title.", isError: true) }
    let state = args["state"] as? String ?? "running"
    guard ["running", "done", "failed"].contains(state) else { return toolText("state must be running, done or failed.", isError: true) }
    var message: [String: Any] = ["type": "job", "job_id": id, "title": title, "state": state]
    if let step = trimmedText(args, "step", limit: 120) { message["step"] = step }
    if let progress = strictJSONDouble(args["progress"]) { message["progress"] = min(max(progress, 0), 1) }
    OverlayController.shared.sendToService(message)
    let percent = (message["progress"] as? Double).map { " \(Int($0 * 100))%" } ?? ""
    return toolText("Job card “\(title)”: \(state)\(percent). The user can Pause or Stop you from it; finished cards fade after 6 s.")
}
