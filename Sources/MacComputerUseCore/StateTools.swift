import Foundation
import AppKit
import ApplicationServices

// MARK: - State verification

enum BoundedSearchResult: Equatable {
    case found
    case exhaustivelyAbsent
    case truncated
}

func boundedDepthFirstSearch<Node>(
    roots: [Node],
    maxNodes: Int,
    children: (Node) -> [Node],
    matches: (Node) -> Bool
) -> BoundedSearchResult {
    var stack = roots
    var visited = 0
    while let node = stack.popLast() {
        guard visited < maxNodes else { return .truncated }
        visited += 1
        if matches(node) { return .found }
        stack.append(contentsOf: children(node).reversed())
    }
    return .exhaustivelyAbsent
}

private func elementContains(
    _ root: AXUIElement,
    text needle: String,
    role expectedRole: String?,
    maxNodes: Int = 5_000
) -> BoundedSearchResult {
    let foldedNeedle = needle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let foldedRole = expectedRole?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    return boundedDepthFirstSearch(
        roots: [root],
        maxNodes: maxNodes,
        children: { axArr($0, "AXChildren") },
        matches: { element in
            let role = axStr(element, "AXRole") ?? ""
            let roleMatches = foldedRole == nil
                || role.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == foldedRole
            guard roleMatches else { return false }
            return ["AXTitle", "AXDescription", "AXValue", "AXHelp"]
                .compactMap { axCopy(element, $0) as? String }
                .contains(where: {
                    $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        .contains(foldedNeedle)
                })
            }
    )
}

func toolVerifyState(_ args: [String: Any]) -> [String: Any] {
    let appSpec = ((args["app"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !appSpec.isEmpty else { return toolText("verify_state needs 'app'.", isError: true) }
    guard let app = resolveApp(appSpec) else { return toolText(applicationTargetError(appSpec), isError: true) }
    guard AXIsProcessTrusted() else {
        _ = ensureTrusted()
        return toolText("Not Accessibility-trusted yet.", isError: true)
    }

    let needle = ((args["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return toolText("verify_state needs non-empty 'text'.", isError: true) }
    let condition: String
    if let supplied = args["condition"] {
        guard let value = supplied as? String else {
            return toolText("condition must be a string.", isError: true)
        }
        condition = value.lowercased()
    } else {
        condition = "exists"
    }
    guard ["exists", "not_exists"].contains(condition) else {
        return toolText("condition must be exists or not_exists.", isError: true)
    }
    let timeoutMs: Int
    if let supplied = args["timeout_ms"] {
        guard let value = strictJSONInteger(supplied) else {
            return toolText("timeout_ms must be an integer.", isError: true)
        }
        timeoutMs = value
    } else {
        timeoutMs = 5_000
    }
    guard (0...15_000).contains(timeoutMs) else {
        return toolText("timeout_ms must be between 0 and 15000.", isError: true)
    }
    let pollMs: Int
    if let supplied = args["poll_interval_ms"] {
        guard let value = strictJSONInteger(supplied) else {
            return toolText("poll_interval_ms must be an integer.", isError: true)
        }
        pollMs = value
    } else {
        pollMs = 100
    }
    guard (20...1_000).contains(pollMs) else {
        return toolText("poll_interval_ms must be between 20 and 1000.", isError: true)
    }
    let role: String?
    if let supplied = args["role"] {
        guard let value = supplied as? String else {
            return toolText("role must be a string.", isError: true)
        }
        role = value.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        role = nil
    }
    let deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMs) / 1_000.0
    let targetPid = app.processIdentifier
    let axApp = AXUIElementCreateApplication(targetPid)
    let targetHadOnScreenWindow = !windowCandidates(forPid: targetPid).isEmpty
    var observedPresent = false
    var observedTruncation = false
    var transitionedAbsentAt: Double?

    repeat {
        guard let liveApp = resolveApp(appSpec), liveApp.processIdentifier == targetPid else {
            return toolText("verify_state target exited or changed identity: \(appSpec).", isError: true)
        }
        if targetHadOnScreenWindow, windowCandidates(forPid: targetPid).isEmpty {
            return toolText("verify_state target exited or changed identity: \(appSpec).", isError: true)
        }
        let search = elementContains(axApp, text: needle, role: role?.isEmpty == true ? nil : role)
        if condition == "exists", search == .found {
            return toolText("Verified text \"\(needle)\" \(condition) in \(app.localizedName ?? appSpec).")
        }
        if condition == "not_exists" {
            if search == .found {
                observedPresent = true
                transitionedAbsentAt = nil
            } else if search == .truncated {
                observedTruncation = true
                transitionedAbsentAt = nil
            } else if !observedPresent {
                return toolText("Verified text \"\(needle)\" \(condition) in \(app.localizedName ?? appSpec).")
            } else if let transitionedAbsentAt,
                      ProcessInfo.processInfo.systemUptime - transitionedAbsentAt >= 0.5 {
                return toolText("Verified text \"\(needle)\" \(condition) in \(app.localizedName ?? appSpec).")
            } else if transitionedAbsentAt == nil {
                transitionedAbsentAt = ProcessInfo.processInfo.systemUptime
            }
        }
        if ProcessInfo.processInfo.systemUptime >= deadline { break }
        usleep(useconds_t(pollMs * 1_000))
    } while true

    if condition == "not_exists", observedTruncation {
        return toolText(
            "Could not verify text \"\(needle)\" not_exists because the accessibility traversal exceeded 5000 nodes.",
            isError: true
        )
    }
    return toolText("Timed out after \(timeoutMs) ms waiting for text \"\(needle)\" to \(condition) in \(app.localizedName ?? appSpec).", isError: true)
}
