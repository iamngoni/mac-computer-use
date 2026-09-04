import Foundation
import AppKit
import ApplicationServices

// MARK: - State verification

private func elementContains(
    _ root: AXUIElement,
    text needle: String,
    role expectedRole: String?,
    maxNodes: Int = 5_000
) -> Bool {
    let foldedNeedle = needle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let foldedRole = expectedRole?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    var stack = [root]
    var visited = 0

    while let element = stack.popLast(), visited < maxNodes {
        visited += 1
        let role = axStr(element, "AXRole") ?? ""
        let roleMatches = foldedRole == nil
            || role.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == foldedRole
        if roleMatches {
            let values = ["AXTitle", "AXDescription", "AXValue", "AXHelp"]
                .compactMap { axCopy(element, $0) as? String }
            if values.contains(where: {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(foldedNeedle)
            }) {
                return true
            }
        }
        stack.append(contentsOf: axArr(element, "AXChildren").reversed())
    }
    return false
}

func toolVerifyState(_ args: [String: Any]) -> [String: Any] {
    let appSpec = ((args["app"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !appSpec.isEmpty else { return toolText("verify_state needs 'app'.", isError: true) }
    guard let app = resolveApp(appSpec) else { return toolText("App not found: \(appSpec). Try list_apps.", isError: true) }
    guard AXIsProcessTrusted() else {
        _ = ensureTrusted()
        return toolText("Not Accessibility-trusted yet.", isError: true)
    }

    let needle = ((args["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return toolText("verify_state needs non-empty 'text'.", isError: true) }
    let condition = ((args["condition"] as? String) ?? "exists").lowercased()
    guard ["exists", "not_exists"].contains(condition) else {
        return toolText("condition must be exists or not_exists.", isError: true)
    }
    let timeoutMs = (args["timeout_ms"] as? Int) ?? 5_000
    guard (0...15_000).contains(timeoutMs) else {
        return toolText("timeout_ms must be between 0 and 15000.", isError: true)
    }
    let pollMs = (args["poll_interval_ms"] as? Int) ?? 100
    guard (20...1_000).contains(pollMs) else {
        return toolText("poll_interval_ms must be between 20 and 1000.", isError: true)
    }
    let role = (args["role"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMs) / 1_000.0
    let targetPid = app.processIdentifier
    let axApp = AXUIElementCreateApplication(targetPid)
    let targetHadOnScreenWindow = !windowCandidates(forPid: targetPid).isEmpty
    var observedPresent = false
    var transitionedAbsentAt: Double?

    repeat {
        guard let liveApp = resolveApp(appSpec), liveApp.processIdentifier == targetPid else {
            return toolText("verify_state target exited or changed identity: \(appSpec).", isError: true)
        }
        if targetHadOnScreenWindow, windowCandidates(forPid: targetPid).isEmpty {
            return toolText("verify_state target exited or changed identity: \(appSpec).", isError: true)
        }
        let found = elementContains(axApp, text: needle, role: role?.isEmpty == true ? nil : role)
        if condition == "exists", found {
            return toolText("Verified text \"\(needle)\" \(condition) in \(app.localizedName ?? appSpec).")
        }
        if condition == "not_exists" {
            if found {
                observedPresent = true
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

    return toolText("Timed out after \(timeoutMs) ms waiting for text \"\(needle)\" to \(condition) in \(app.localizedName ?? appSpec).", isError: true)
}
