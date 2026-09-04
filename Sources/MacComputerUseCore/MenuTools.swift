import Foundation
import AppKit
import ApplicationServices

// MARK: - Menu tools

private func normalizedMenuTitle(_ title: String) -> String {
    title
        .replacingOccurrences(of: "…", with: "")
        .replacingOccurrences(of: "...", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
}

private func menuElements(titled title: String, atNextLevelUnder root: AXUIElement) -> [AXUIElement] {
    let expected = normalizedMenuTitle(title)
    let children = axArr(root, "AXChildren")
    let candidates = children.flatMap { child -> [AXUIElement] in
        let role = axStr(child, "AXRole") ?? ""
        if role == "AXMenuItem" || role == "AXMenuBarItem" {
            return [child]
        }
        if role == "AXMenu" {
            return axArr(child, "AXChildren").filter {
                let nestedRole = axStr($0, "AXRole") ?? ""
                return nestedRole == "AXMenuItem" || nestedRole == "AXMenuBarItem"
            }
        }
        return []
    }
    return candidates.filter {
        normalizedMenuTitle(axStr($0, "AXTitle") ?? "") == expected
    }
}

func toolInvokeMenu(_ args: [String: Any]) -> [String: Any] {
    let appSpec = ((args["app"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !appSpec.isEmpty else { return toolText("invoke_menu needs 'app'.", isError: true) }
    guard let app = resolveApp(appSpec) else { return toolText(applicationTargetError(appSpec), isError: true) }
    guard let rawPath = args["path"] as? [Any] else {
        return toolText("invoke_menu needs a path array.", isError: true)
    }
    let path = rawPath.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard path.count == rawPath.count, !path.isEmpty, path.count <= 8, path.allSatisfy({ !$0.isEmpty }) else {
        return toolText("invoke_menu path must contain 1 to 8 non-empty strings.", isError: true)
    }
    guard AXIsProcessTrusted() else {
        _ = ensureTrusted()
        return toolText("Not Accessibility-trusted yet.", isError: true)
    }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let menuBar = axElement(axApp, "AXMenuBar") else {
        return toolText("No accessibility menu bar found for \(app.localizedName ?? appSpec).", isError: true)
    }
    return controlled(
        "Invoking menu " + path.joined(separator: " > "),
        appPID: app.processIdentifier
    ) {
        var root = menuBar
        for (index, segment) in path.enumerated() {
            let matches = menuElements(titled: segment, atNextLevelUnder: root)
            guard !matches.isEmpty else {
                return toolText("Menu item not found at path segment \(index + 1): \(segment).", isError: true)
            }
            guard matches.count == 1, let item = matches.first else {
                return toolText("Menu item has ambiguous path segment \(index + 1): \(segment).", isError: true)
            }
            let result = AXUIElementPerformAction(item, "AXPress" as CFString)
            guard result == .success else {
                return toolText("Could not press menu item \(segment) (AX error \(result.rawValue)).", isError: true)
            }
            if index < path.count - 1 {
                usleep(80_000)
                root = item
            }
        }

        return toolText("Invoked menu: " + path.joined(separator: " > "))
    }
}
