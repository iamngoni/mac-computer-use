import Foundation
import AppKit
import CoreGraphics

// MARK: - Window tools

func toolListWindows(_ args: [String: Any]) -> [String: Any] {
    let requested = (args["app"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    let apps: [NSRunningApplication]
    if let requested {
        guard !requested.isEmpty else {
            return toolText("list_windows 'app' must be non-empty when supplied.", isError: true)
        }
        guard let app = resolveApp(requested) else {
            return toolText("App not found: \(requested). Try list_apps.", isError: true)
        }
        apps = [app]
    } else {
        apps = runningApps()
    }

    var lines: [String] = []
    for app in apps {
        let appName = app.localizedName ?? "?"
        for window in windowCandidates(forPid: app.processIdentifier) {
            let title = window.title ?? ""
            let bounds = window.bounds
            lines.append(
                "- window_id=\(window.id) app=\"\(appName)\" pid=\(app.processIdentifier) "
                + "title=\"\(title)\" bounds=(x:\(Int(bounds.minX)), y:\(Int(bounds.minY)), "
                + "width:\(Int(bounds.width)), height:\(Int(bounds.height))) order=\(window.order)"
            )
        }
    }

    if lines.isEmpty {
        let scope = requested.map { " for \($0)" } ?? ""
        return toolText("No on-screen windows found\(scope).")
    }
    return toolText("On-screen windows:\n" + lines.joined(separator: "\n"))
}

func toolSetWindowFrame(_ args: [String: Any]) -> [String: Any] {
    let appSpec = ((args["app"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !appSpec.isEmpty else { return toolText("set_window_frame needs 'app'.", isError: true) }
    guard let app = resolveApp(appSpec) else { return toolText("App not found: \(appSpec). Try list_apps.", isError: true) }
    guard let rawWindowId = args["window_id"] as? Int,
          let windowId = UInt32(exactly: rawWindowId), windowId > 0 else {
        return toolText("set_window_frame needs a positive integer window_id from list_windows.", isError: true)
    }
    guard let candidate = windowCandidates(forPid: app.processIdentifier).first(where: { $0.id == windowId }) else {
        return toolText("Window not found for \(appSpec): window_id=\(windowId). Call list_windows again.", isError: true)
    }
    guard AXIsProcessTrusted() else {
        _ = ensureTrusted()
        return toolText("Not Accessibility-trusted yet.", isError: true)
    }
    guard let x = num(args, "x"), let y = num(args, "y"),
          let width = num(args, "width"), let height = num(args, "height"),
          x.isFinite, y.isFinite, width.isFinite, height.isFinite,
          width >= 64, height >= 64, width <= 20_000, height <= 20_000 else {
        return toolText("set_window_frame needs finite x,y and width,height between 64 and 20000.", isError: true)
    }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let window = accessibilityWindow(matching: candidate, in: axApp) else {
        return toolText("Accessibility window not found for window_id=\(windowId).", isError: true)
    }
    guard let originalPositionValue = axCopy(window, "AXPosition"),
          let originalSizeValue = axCopy(window, "AXSize") else {
        return toolText("Could not preserve the original frame for window_id=\(windowId).", isError: true)
    }
    var positionSettable = DarwinBoolean(false)
    var sizeSettable = DarwinBoolean(false)
    let positionSettableResult = AXUIElementIsAttributeSettable(
        window, "AXPosition" as CFString, &positionSettable
    )
    let sizeSettableResult = AXUIElementIsAttributeSettable(
        window, "AXSize" as CFString, &sizeSettable
    )
    guard positionSettableResult == .success, sizeSettableResult == .success,
          positionSettable.boolValue, sizeSettable.boolValue else {
        return toolText(
            "Window does not expose both position and size as settable attributes.",
            isError: true
        )
    }
    var position = CGPoint(x: x, y: y)
    var size = CGSize(width: width, height: height)
    guard let positionValue = AXValueCreate(.cgPoint, &position),
          let sizeValue = AXValueCreate(.cgSize, &size) else {
        return toolText("Could not encode the requested window frame.", isError: true)
    }

    return controlled("Moving window", appPID: app.processIdentifier, targetQuartz: candidate.bounds) {
        func matches(_ actual: CGRect, _ expected: CGRect) -> Bool {
            abs(actual.minX - expected.minX) <= 2
                && abs(actual.minY - expected.minY) <= 2
                && abs(actual.width - expected.width) <= 2
                && abs(actual.height - expected.height) <= 2
        }

        func rollback() -> String? {
            let sizeRollback = AXUIElementSetAttributeValue(
                window, "AXSize" as CFString, originalSizeValue
            )
            let positionRollback = AXUIElementSetAttributeValue(
                window, "AXPosition" as CFString, originalPositionValue
            )
            guard sizeRollback == .success, positionRollback == .success else {
                return "setter rollback failed (position=\(positionRollback.rawValue), size=\(sizeRollback.rawValue))"
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.0
            repeat {
                if let actual = windowCandidates(forPid: app.processIdentifier)
                    .first(where: { $0.id == windowId })?.bounds,
                   matches(actual, candidate.bounds) {
                    return nil
                }
                if ProcessInfo.processInfo.systemUptime >= deadline { break }
                usleep(20_000)
            } while true
            return "original frame was not observed after rollback"
        }

        let sizeResult = AXUIElementSetAttributeValue(window, "AXSize" as CFString, sizeValue)
        let positionResult = AXUIElementSetAttributeValue(window, "AXPosition" as CFString, positionValue)
        if lastSnapshot?.windowId == windowId {
            lastSnapshot = nil
            elementRegistry.removeAll()
        }
        guard sizeResult == .success, positionResult == .success else {
            let failure = "Window frame update failed (position=\(positionResult.rawValue), size=\(sizeResult.rawValue))"
            if let rollbackError = rollback() {
                return toolText("\(failure); rollback failed: \(rollbackError).", isError: true)
            }
            return toolText("\(failure); original frame restored.", isError: true)
        }
        let requested = CGRect(x: x, y: y, width: width, height: height)
        let deadline = ProcessInfo.processInfo.systemUptime + 1.0
        var actual: CGRect?
        repeat {
            actual = windowCandidates(forPid: app.processIdentifier)
                .first(where: { $0.id == windowId })?.bounds
            if let actual, matches(actual, requested) {
                return toolText(
                    "Set window_id=\(windowId) frame. Actual bounds=(x:\(Int(actual.minX)), "
                    + "y:\(Int(actual.minY)), width:\(Int(actual.width)), height:\(Int(actual.height)))."
                )
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            usleep(20_000)
        } while true

        let observed = actual.map {
            "(x:\(Int($0.minX)), y:\(Int($0.minY)), width:\(Int($0.width)), height:\(Int($0.height)))"
        } ?? "missing"
        let failure = "Window frame verification failed for window_id=\(windowId). Requested "
            + "(x:\(Int(x)), y:\(Int(y)), width:\(Int(width)), height:\(Int(height))); observed \(observed)"
        if let rollbackError = rollback() {
            return toolText("\(failure); rollback failed: \(rollbackError).", isError: true)
        }
        return toolText("\(failure); original frame restored.", isError: true)
    }
}
