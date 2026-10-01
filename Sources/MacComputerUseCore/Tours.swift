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
        let point: CGPoint
        let annotations: [[String: Any]]
    }
    var steps: [PreparedStep] = []
    for (offset, raw) in rawSteps.enumerated() {
        guard let instruction = (raw["instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !instruction.isEmpty else {
            return toolText("guide step \(offset + 1) needs an instruction.", isError: true)
        }
        var stepArgs = raw
        stepArgs["app"] = args["app"]
        let target: InteractionTarget
        switch resolveInteractionTarget(stepArgs, tool: "guide step \(offset + 1)") {
        case .resolved(let resolved): target = resolved
        case .failed(let error): return error
        }
        var annotations: [[String: Any]] = []
        for item in raw["annotate"] as? [[String: Any]] ?? [] {
            switch quartzAnnotationItem(item, context: context, pid: pid) {
            case .resolved(let value): annotations.append(value)
            case .failed(let message): return toolText("guide step \(offset + 1) annotation: \(message).", isError: true)
            }
        }
        steps.append(PreparedStep(
            instruction: String(instruction.prefix(140)),
            element: target.element,
            point: target.point,
            annotations: annotations
        ))
    }

    var savedNote = ""
    if let saveAs, !saveAs.isEmpty {
        guard steps.allSatisfy({ $0.element != nil }) else {
            return toolText("save_as needs every step to use element_index, because saved tours find elements, not pixels.", isError: true)
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
    }
    for (offset, step) in steps.enumerated() {
        let frame = step.element.flatMap(axFrame)
        if step.element != nil, frame == nil {
            return toolText("Completed \(offset) of \(steps.count) steps. Step \(offset + 1)'s element disappeared; call get_app_state and continue from there.", isError: true)
        }
        let point = frame.map { CGPoint(x: $0.midX, y: $0.midY) } ?? step.point
        guard snapshotWindowIsVisible(at: point, context: context) else {
            return toolText("Completed \(offset) of \(steps.count) steps. " + (toolResultText(hiddenWindowResult("guide", context: context)) ?? ""), isError: true)
        }
        OverlayController.shared.moveCursorQuartz(point, pace: .teach)
        OverlayController.shared.sendToService([
            "type": "bubble",
            "text": "Step \(offset + 1) of \(steps.count): \(step.instruction)",
            "style": "handoff",
            "hold_ms": 0,
        ])
        OverlayController.shared.sendToService(["type": "annotations_clear"])
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
        let rect = frame ?? CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
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
                return nil
            }
        )
        switch outcome {
        case .response(let response) where response["outcome"] as? String == "clicked":
            continue
        case .cancelled:
            return toolText("[user_dismissed] The user stopped the tour after \(offset) of \(steps.count) steps.\(savedNote)", isError: true)
        case .timedOut:
            return toolText("[timeout] The user did not finish step \(offset + 1) of \(steps.count) within \(Int(timeout)) s.\(savedNote)", isError: true)
        default:
            return serviceRequiredResult("guide")
        }
    }
    completed = true
    OverlayController.shared.sendToService(["type": "bubble", "text": "All done!", "style": "done", "hold_ms": 1500])
    return toolText("The user completed all \(steps.count) steps.\(savedNote) Re-read state before continuing.")
}
