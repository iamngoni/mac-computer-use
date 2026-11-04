// Guided tours: an agent walks the person through steps, pointing at each
// element and advancing when the person clicks it. A tour can be saved as an
// element-based file (not pixels) and replayed later from the menu bar,
// without an agent.
import AppKit
import ApplicationServices
import Foundation

public struct TourLocator: Codable, Equatable, Sendable {
    public var bundleID: String?
    public var appName: String
    public var windowTitle: String?
    public var role: String
    public var subrole: String?
    public var title: String?
    public var description: String?
    public var identifier: String?
}

public struct TourStep: Codable, Equatable, Sendable {
    public var instruction: String
    public var locator: TourLocator
}

public struct TourFile: Codable, Equatable, Sendable {
    public var version = 1
    public var name: String
    public var title: String
    public var createdAt: Date
    public var steps: [TourStep]
}

public enum TourStore {
    public static func directory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacComputerUse/Tours", isDirectory: true)
    }

    /// A safe file name: letters, digits, spaces, dashes and underscores.
    public static func fileName(for name: String) -> String? {
        let allowed = name.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "_"
        }
        let cleaned = String(String.UnicodeScalarView(allowed))
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(60)) + ".json"
    }

    public static func save(_ tour: TourFile, in directory: URL = directory()) throws -> URL {
        guard let name = fileName(for: tour.name) else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tour).write(to: url, options: .atomic)
        return url
    }

    public static func all(in directory: URL = directory()) -> [TourFile] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(TourFile.self, from: Data(contentsOf: $0)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

/// Attribute view of an element, so matching is testable without AX.
struct TourCandidate {
    let role: String?
    let subrole: String?
    let title: String?
    let description: String?
    let identifier: String?
}

/// Identifier wins when both have one; otherwise role and a label must agree.
func tourCandidate(_ candidate: TourCandidate, matches locator: TourLocator) -> Bool {
    if let wanted = locator.identifier, !wanted.isEmpty, let actual = candidate.identifier, !actual.isEmpty {
        return wanted == actual
    }
    guard candidate.role == locator.role else { return false }
    if let subrole = locator.subrole, candidate.subrole != subrole { return false }
    let labels = [locator.title, locator.description].compactMap { $0 }.filter { !$0.isEmpty }
    guard !labels.isEmpty else { return false }
    return labels.contains { $0 == candidate.title || $0 == candidate.description }
}

func tourLocator(for element: AXUIElement, pid: pid_t, windowTitle: String?) -> TourLocator {
    let app = NSRunningApplication(processIdentifier: pid)
    return TourLocator(
        bundleID: app?.bundleIdentifier,
        appName: app?.localizedName ?? "pid \(pid)",
        windowTitle: windowTitle,
        role: axStr(element, "AXRole") ?? "AXUnknown",
        subrole: axStr(element, "AXSubrole"),
        title: axStr(element, "AXTitle"),
        description: axStr(element, "AXDescription"),
        identifier: axStr(element, "AXIdentifier")
    )
}

/// Finds a saved step's element in a running app, preferring the window
/// whose title matches. Bounded so a huge tree cannot stall the caller.
func findTourElement(_ locator: TourLocator, pid: pid_t, limit: Int = 4000) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    var windows = axArr(app, "AXWindows")
    if let title = locator.windowTitle,
       let index = windows.firstIndex(where: { axStr($0, "AXTitle") == title }) {
        windows.insert(windows.remove(at: index), at: 0)
    }
    var queue = windows
    var visited = 0
    while !queue.isEmpty, visited < limit {
        let element = queue.removeFirst()
        visited += 1
        let candidate = TourCandidate(
            role: axStr(element, "AXRole"),
            subrole: axStr(element, "AXSubrole"),
            title: axStr(element, "AXTitle"),
            description: axStr(element, "AXDescription"),
            identifier: axStr(element, "AXIdentifier")
        )
        if tourCandidate(candidate, matches: locator) { return element }
        queue.append(contentsOf: axArr(element, "AXChildren"))
    }
    return nil
}

// MARK: - guide (worker tool)

/// How a walkthrough step advances.
enum GuideAdvance: Equatable {
    case click                 // the person clicks the step's target
    case shortcut(String)      // canonical, e.g. cmd+s
    case app(String)           // the person switches to this app
    case next                  // the person presses Next on the timeline
}

/// What a step waits for before it shows: an app running (and a window
/// whose title contains some text).
struct GuideWait: Equatable {
    var app: String
    var window: String?
}

/// Parses a step's advance_on; nil with a message on bad input.
func guideAdvance(_ raw: [String: Any], hasTarget: Bool) -> Result<GuideAdvance, VisualArgumentError> {
    switch raw["advance_on"] as? String ?? (hasTarget ? "click" : "next") {
    case "click":
        return hasTarget ? .success(.click) : .failure(VisualArgumentError(message: "advance_on click needs element_index or x, y"))
    case "shortcut":
        guard let spec = raw["shortcut"] as? String, let shortcut = normalizedShortcutSpec(spec) else {
            return .failure(VisualArgumentError(message: "advance_on shortcut needs shortcut, like cmd+s"))
        }
        return .success(.shortcut(shortcut))
    case "app":
        guard let app = (raw["target_app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else {
            return .failure(VisualArgumentError(message: "advance_on app needs target_app"))
        }
        return .success(.app(app))
    case "next":
        return .success(.next)
    default:
        return .failure(VisualArgumentError(message: "advance_on must be click, shortcut, app or next"))
    }
}

/// True once the app is running and, if asked, has a window with that title.
func guideWaitSatisfied(_ wait: GuideWait) -> Bool {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName?.caseInsensitiveCompare(wait.app) == .orderedSame || $0.bundleIdentifier == wait.app
    }) else { return false }
    guard let window = wait.window?.lowercased(), !window.isEmpty else { return true }
    return windowCandidates(forPid: app.processIdentifier).contains { $0.title?.lowercased().contains(window) == true }
}

func toolGuide(_ args: [String: Any]) -> [String: Any] {
    guard OverlayController.shared.isServiceAttached else { return serviceRequiredResult("guide") }
    guard let pid = pidFor(args) else { return unresolvedAppError(args) }
    guard let context = authorizedSnapshot(forPid: pid) else {
        return toolText("guide needs a fresh get_app_state snapshot for this app first.", isError: true)
    }
    let rawSteps = args["steps"] as? [[String: Any]] ?? []
    guard (1...20).contains(rawSteps.count) else { return toolText("guide needs 1 to 20 steps.", isError: true) }
    let timeout = Double(min(max(strictJSONInteger(args["timeout_s"]) ?? 120, 5), 600))
    let saveAs = (args["save_as"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = (args["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    struct PreparedStep {
        let instruction: String
        let element: AXUIElement?
        let point: CGPoint?
        let annotations: [[String: Any]]
        let speech: String?
        let advance: GuideAdvance
        let wait: GuideWait?
    }
    // speak on the guide reads every step; a step's own speak overrides it.
    let speakAll = strictJSONBoolean(args["speak"]) == true
    var steps: [PreparedStep] = []
    for (offset, raw) in rawSteps.enumerated() {
        guard let instruction = (raw["instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !instruction.isEmpty else {
            return toolText("guide step \(offset + 1) needs an instruction.", isError: true)
        }
        var stepArgs = raw
        stepArgs["app"] = args["app"]
        let hasTarget = raw["element_index"] != nil || raw["x"] != nil
        var target: InteractionTarget?
        if hasTarget {
            switch resolveInteractionTarget(stepArgs, tool: "guide step \(offset + 1)") {
            case .resolved(let resolved): target = resolved
            case .failed(let error): return error
            }
        }
        let advance: GuideAdvance
        switch guideAdvance(raw, hasTarget: hasTarget) {
        case .success(let value): advance = value
        case .failure(let error): return toolText("guide step \(offset + 1): \(error.message).", isError: true)
        }
        var wait: GuideWait?
        if let rawWait = raw["wait_for"] as? [String: Any] {
            guard let app = (rawWait["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty else {
                return toolText("guide step \(offset + 1): wait_for needs app.", isError: true)
            }
            wait = GuideWait(app: app, window: rawWait["window"] as? String)
        }
        var annotations: [[String: Any]] = []
        for item in raw["annotate"] as? [[String: Any]] ?? [] {
            switch quartzAnnotationItem(item, context: context, pid: pid) {
            case .resolved(let value): annotations.append(value)
            case .failed(let message): return toolText("guide step \(offset + 1) annotation: \(message).", isError: true)
            }
        }
        let shortInstruction = String(instruction.prefix(140))
        let stepSpeech: String?
        if raw["speak"] != nil {
            stepSpeech = spokenText(raw, default: shortInstruction)
        } else {
            stepSpeech = speakAll ? shortInstruction : nil
        }
        steps.append(PreparedStep(
            instruction: shortInstruction,
            element: target?.element,
            point: target?.point,
            annotations: annotations,
            speech: stepSpeech,
            advance: advance,
            wait: wait
        ))
    }

    var savedNote = ""
    if let saveAs, !saveAs.isEmpty {
        guard steps.allSatisfy({ $0.element != nil && $0.advance == .click && $0.wait == nil }) else {
            return toolText("save_as needs every step to use element_index and advance on click, because saved tours find elements, not pixels.", isError: true)
        }
        let windowTitle = windowCandidates(forPid: pid).first { $0.id == context.windowId }?.title
        let tour = TourFile(
            name: saveAs,
            title: title ?? saveAs,
            createdAt: Date(),
            steps: steps.map { TourStep(instruction: $0.instruction, locator: tourLocator(for: $0.element!, pid: pid, windowTitle: windowTitle)) }
        )
        do {
            let url = try TourStore.save(tour)
            savedNote = " Saved as “\(tour.title)” (\(url.lastPathComponent)); the user can replay it from the Mac Computer Use menu."
        } catch {
            return toolText("Could not save the tour: \(error.localizedDescription)", isError: true)
        }
    }

    OverlayController.shared.updateControlledApplication(
        pid: pid,
        name: NSRunningApplication(processIdentifier: pid)?.localizedName ?? context.appLabel
    )
    var completed = false
    defer {
        if !completed { OverlayController.shared.sendToService(["type": "bubble_clear"]) }
        OverlayController.shared.sendToService(["type": "annotations_clear"])
        OverlayController.shared.sendToService(["type": "timeline_clear"])
    }
    let titles = steps.map(\.instruction)
    var index = 0
    var skipped: [Int] = []
    var lastTouch = Date()
    let keepAlive: () -> Void = {
        if Date().timeIntervalSince(lastTouch) > 2 {
            OverlayController.shared.touchCursor()
            lastTouch = Date()
        }
    }
    while index < steps.count {
        let step = steps[index]
        OverlayController.shared.sendToService([
            "type": "timeline", "steps": titles, "current": index, "manual": step.advance == .next,
        ])
        OverlayController.shared.sendToService(["type": "annotations_clear"])

        // Wait for an app or window first, if the step needs one.
        if let wait = step.wait, !guideWaitSatisfied(wait) {
            OverlayController.shared.sendToService([
                "type": "bubble",
                "text": "Step \(index + 1) of \(steps.count): \(step.instruction)\nWaiting for \(wait.window.map { "“\($0)” in " } ?? "")\(wait.app)…",
                "style": "handoff", "hold_ms": 0,
            ])
            _ = speakAloud(step.speech)
            let waited = WorkerSession.shared.interact("wait_next", [:], timeout: timeout, poll: {
                keepAlive()
                return guideWaitSatisfied(wait) ? ["outcome": "ready"] : nil
            })
            switch waited {
            case .polled: break
            case .response(let response) where response["outcome"] as? String == "nav":
                switch response["action"] as? String {
                case "back": index = max(index - 1, 0); continue
                case "skip": skipped.append(index + 1); index += 1; continue
                default: continue // replay: wait again
                }
            case .cancelled:
                return toolText("[user_dismissed] The user stopped the walkthrough at step \(index + 1) of \(steps.count).\(savedNote)", isError: true)
            case .timedOut:
                return toolText("[timeout] \(wait.app) did not appear within \(Int(timeout)) s (step \(index + 1) of \(steps.count)).\(savedNote)", isError: true)
            default:
                return serviceRequiredResult("guide")
            }
        }

        // Point at the target, if the step has one.
        var rect: CGRect?
        if step.element != nil || step.point != nil {
            let frame = step.element.flatMap(axFrame)
            if step.element != nil, frame == nil {
                return toolText("Completed \(index) of \(steps.count) steps. Step \(index + 1)'s element disappeared; call get_app_state and continue from there.", isError: true)
            }
            let point = frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? step.point!
            guard snapshotWindowIsVisible(at: point, context: context) else {
                return toolText("Completed \(index) of \(steps.count) steps. " + (toolResultText(hiddenWindowResult("guide", context: context)) ?? ""), isError: true)
            }
            OverlayController.shared.moveCursorQuartz(point, pace: .teach)
            rect = frame ?? CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
        } else {
            OverlayController.shared.touchCursor()
        }
        let hint: String
        switch step.advance {
        case .click: hint = ""
        case .shortcut(let keys): hint = "\nPress \(keys)"
        case .app(let app): hint = "\nSwitch to \(app)"
        case .next: hint = "\nPress Next when you're ready"
        }
        OverlayController.shared.sendToService([
            "type": "bubble",
            "text": "Step \(index + 1) of \(steps.count): \(step.instruction)\(hint)",
            "style": "handoff",
            "hold_ms": 0,
        ])
        if step.wait == nil || guideWaitSatisfied(step.wait!) { _ = speakAloud(step.speech) }
        if !step.annotations.isEmpty {
            let bounds = context.windowBounds
            OverlayController.shared.sendToService([
                "type": "annotate",
                "items": step.annotations,
                "duration_ms": Int(timeout * 1000),
                "window_id": Int(context.windowId),
                "window_bounds": [Double(bounds.minX), Double(bounds.minY), Double(bounds.width), Double(bounds.height)],
            ])
        }

        let outcome: WorkerSession.InteractionOutcome
        switch step.advance {
        case .click:
            let r = rect!
            outcome = WorkerSession.shared.interact(
                "wait_click",
                ["rect": [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)], "navigable": true],
                timeout: timeout,
                poll: { keepAlive(); return nil }
            )
        case .shortcut(let keys):
            outcome = WorkerSession.shared.interact("watch", ["shortcut": keys, "duration_ms": Int(timeout * 1000), "navigable": true], timeout: timeout + 2, poll: { keepAlive(); return nil })
        case .app(let app):
            outcome = WorkerSession.shared.interact("watch", ["app": app, "duration_ms": Int(timeout * 1000), "navigable": true], timeout: timeout + 2, poll: { keepAlive(); return nil })
        case .next:
            outcome = WorkerSession.shared.interact("wait_next", [:], timeout: timeout, poll: { keepAlive(); return nil })
        }
        switch outcome {
        case .response(let response):
            switch response["outcome"] as? String {
            case "clicked", "matched":
                index += 1
            case "nav":
                switch response["action"] as? String {
                case "back": index = max(index - 1, 0)
                case "skip":
                    if step.advance != .next { skipped.append(index + 1) }
                    index += 1
                default: break // replay re-shows the same step
                }
            case "time_up":
                return toolText("[timeout] The user did not finish step \(index + 1) of \(steps.count) within \(Int(timeout)) s.\(savedNote)", isError: true)
            default:
                return serviceRequiredResult("guide")
            }
        case .cancelled:
            return toolText("[user_dismissed] The user stopped the walkthrough after \(index) of \(steps.count) steps.\(savedNote)", isError: true)
        case .timedOut:
            return toolText("[timeout] The user did not finish step \(index + 1) of \(steps.count) within \(Int(timeout)) s.\(savedNote)", isError: true)
        default:
            return serviceRequiredResult("guide")
        }
    }
    completed = true
    OverlayController.shared.sendToService(["type": "bubble", "text": "All done!", "style": "done", "hold_ms": 1500])
    OverlayController.shared.sendToService(["type": "buddy", "emote": "celebrate"])
    let skippedNote = skipped.isEmpty ? "" : " They skipped step\(skipped.count > 1 ? "s" : "") \(Array(Set(skipped)).sorted().map(String.init).joined(separator: ", "))."
    return toolText("The user completed the walkthrough (\(steps.count) steps).\(skippedNote)\(savedNote) Re-read state before continuing.")
}
