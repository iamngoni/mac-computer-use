// Produces a permission-free, machine-readable health snapshot without exposing
// application names, window titles, or the user's absolute home-directory path.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private func redactedHomePath(_ rawPath: String?) -> String {
    guard let rawPath, !rawPath.isEmpty else { return "unknown" }
    let path = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

private func resolutionHealth() -> [String: Any] {
    let apps = runningApps()
    let knownPids = Set(apps.map(\.processIdentifier))
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    var windowOwners = Set<pid_t>()
    var windowCount = 0

    for info in windowInfo {
        guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              knownPids.contains(owner),
              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true else {
            continue
        }
        windowOwners.insert(owner)
        windowCount += 1
    }

    return [
        "running_app_count": apps.count,
        "app_with_window_count": windowOwners.count,
        "on_screen_window_count": windowCount,
        "exact_ax_window_id_available": exactAccessibilityWindowIdentityAvailable(),
    ]
}

func toolHealthReport() -> [String: Any] {
    let bundle = Bundle.main
    let executable = bundle.executablePath ?? CommandLine.arguments.first
    let bundleIdentifier = bundle.bundleIdentifier ?? "unknown"
    let report: [String: Any] = [
        "accessibility": [
            "trusted": AXIsProcessTrusted(),
        ],
        "screen_recording": [
            "granted": CGPreflightScreenCaptureAccess(),
        ],
        "process": [
            "pid": Int(getpid()),
            "executable": redactedHomePath(executable),
            "mode": "stdio_mcp",
        ],
        "bundle": [
            "identifier": bundleIdentifier,
            "version": macComputerUseVersion(),
            "build": (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown",
            "path": redactedHomePath(bundle.bundlePath),
        ],
        "overlay": OverlayController.shared.healthSnapshot(),
        "resolution": resolutionHealth(),
        "input": [
            "default_scope": "application_scoped",
            "global_pointer_opt_in": "disabled",
            "hardware_pointer_moves_by_default": false,
        ],
    ]

    guard let data = try? JSONSerialization.data(
        withJSONObject: report,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ), let text = String(data: data, encoding: .utf8) else {
        return toolText("Could not serialize health report.", isError: true)
    }
    return toolText(text)
}
