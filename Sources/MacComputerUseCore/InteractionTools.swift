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
    let shown = label.map { " with “\($0)”" } ?? ""
    return toolText("Pointing at \(target.summary)\(shown) for \(String(format: "%.1f", Double(hold) / 1000)) s. Nothing was clicked.")
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
    return toolText("Drew \(converted.count) annotation(s) over \(context.appLabel) for \(duration / 1000) s. They clear early if the window moves; clear_annotations removes them.")
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
