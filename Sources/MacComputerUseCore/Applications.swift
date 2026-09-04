import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - App resolution
// NSWorkspace's application list is notification-backed. This process blocks its main
// thread on stdio, so that list can retain a terminated app and miss its replacement.
// WindowServer data is live even without an AppKit run loop; merge its owner PIDs into
// each snapshot and reject PIDs that no longer exist.
struct RunningAppSnapshot {
    let apps: [NSRunningApplication]
    let windowOwnerPIDs: Set<pid_t>
}

func processIsAlive(_ pid: pid_t) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

func liveExecutablePath(for pid: pid_t) -> String? {
    // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN but the macro is unavailable
    // to Swift because it contains a C expression.
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer))
        .resolvingSymlinksInPath()
        .standardizedFileURL.path
}

func applicationMatchesLiveProcess(_ app: NSRunningApplication) -> Bool {
    let pid = app.processIdentifier
    guard processIsAlive(pid),
          let reportedURL = app.executableURL,
          let livePath = liveExecutablePath(for: pid) else { return false }
    let reportedPath = reportedURL.resolvingSymlinksInPath().standardizedFileURL.path
    return reportedPath == livePath
}

func currentWindowOwnerPIDs() -> Set<pid_t> {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return Set(windows.compactMap { info in
        guard let number = info[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
        let pid = pid_t(number.int32Value)
        return processIsAlive(pid) ? pid : nil
    })
}

func refreshWorkspaceApplicationCache() {
    // NSWorkspace updates NSRunningApplication objects through the main run loop.
    // The stdio server normally blocks that loop in readLine(), so briefly drain it
    // at the boundary of each app lookup. The deadline keeps tool latency bounded.
    let deadline = Date(timeIntervalSinceNow: 0.02)
    while Date() < deadline && RunLoop.main.run(mode: .default, before: deadline) {}
}

func runningAppSnapshot() -> RunningAppSnapshot {
    refreshWorkspaceApplicationCache()
    let windowOwnerPIDs = currentWindowOwnerPIDs()
    var seenPIDs = Set<pid_t>()
    var apps: [NSRunningApplication] = []

    func appendIfLiveRegular(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular,
              applicationMatchesLiveProcess(app),
              seenPIDs.insert(pid).inserted else { return }
        apps.append(app)
    }

    // Preserve NSWorkspace's normal ordering for existing callers, then append apps
    // discovered from live windows that its stale cache omitted.
    NSWorkspace.shared.runningApplications.forEach(appendIfLiveRegular)
    for pid in windowOwnerPIDs.sorted() where !seenPIDs.contains(pid) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            appendIfLiveRegular(app)
        }
    }
    return RunningAppSnapshot(apps: apps, windowOwnerPIDs: windowOwnerPIDs)
}

func runningApps() -> [NSRunningApplication] { runningAppSnapshot().apps }

func resolveApp(_ spec: String) -> NSRunningApplication? {
    guard !spec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let snapshot = runningAppSnapshot()
    func bestMatch(_ predicate: (NSRunningApplication) -> Bool) -> NSRunningApplication? {
        let matches = snapshot.apps.filter(predicate)
        return matches.first(where: { snapshot.windowOwnerPIDs.contains($0.processIdentifier) }) ?? matches.first
    }

    if let app = bestMatch({ $0.bundleIdentifier?.caseInsensitiveCompare(spec) == .orderedSame }) { return app }
    if let app = bestMatch({ $0.localizedName?.caseInsensitiveCompare(spec) == .orderedSame }) { return app }
    if let app = bestMatch({ ($0.localizedName ?? "").lowercased().contains(spec.lowercased()) }) { return app }
    if let app = bestMatch({ $0.bundleURL?.path.caseInsensitiveCompare(spec) == .orderedSame }) { return app }
    return nil
}

// Bring an app to the front before synthesizing input, so keystrokes/clicks land in
// the right place. Without this, input goes to whatever app is currently frontmost.
func activateApp(_ spec: String) {
    guard let app = resolveApp(spec) else { return }
    if !app.isActive {
        app.activate(options: [.activateAllWindows])
        usleep(220_000) // let the window server bring it forward
    }
}

// Launch an app if not running, otherwise just activate it. Returns a status string.
func launchOrActivate(_ spec: String) -> (ok: Bool, msg: String) {
    if let app = resolveApp(spec) {
        app.activate(options: [.activateAllWindows]); usleep(150_000)
        return (true, "Activated \(app.localizedName ?? spec).")
    }
    let ws = NSWorkspace.shared
    // by bundle id
    if let url = ws.urlForApplication(withBundleIdentifier: spec) {
        ws.open(url); usleep(600_000); return (true, "Launched \(spec).")
    }
    // by app name / path via `open -a`
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", spec]
    do { try p.run(); p.waitUntilExit() } catch { return (false, "Could not launch \(spec).") }
    usleep(700_000)
    return (p.terminationStatus == 0, p.terminationStatus == 0 ? "Launched \(spec)." : "App not found: \(spec).")
}

func toolOpenApp(_ args: [String: Any]) -> [String: Any] {
    guard let spec = args["app"] as? String, !spec.isEmpty else { return toolText("open_app needs 'app'.", isError: true) }
    let r = launchOrActivate(spec)
    return toolText(r.msg, isError: !r.ok)
}

// Run AppleScript and return (output, error). Used for reliable browser navigation and
// other scriptable-app control. First use prompts for Automation permission.
func runAppleScript(_ script: String, timeout: TimeInterval = 30) -> (out: String, err: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    let outPipe = Pipe(); let errPipe = Pipe()
    p.standardOutput = outPipe; p.standardError = errPipe
    do { try p.run() } catch { return ("", "Failed to run osascript: \(error)") }
    let watchdog = Thread { Thread.sleep(forTimeInterval: timeout); if p.isRunning { p.terminate() } }
    watchdog.start()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: outData, encoding: .utf8) ?? ""
    let err = String(data: errData, encoding: .utf8) ?? ""
    return (out.trimmingCharacters(in: .whitespacesAndNewlines), err.trimmingCharacters(in: .whitespacesAndNewlines))
}

// Set a browser's active-tab URL directly (background-safe, no keystroke/omnibox dance).
// Works for Safari and any Chromium browser (Chrome, Brave, Edge, Arc, …).
func toolNavigate(_ args: [String: Any]) -> [String: Any] {
    let appSpec = (args["app"] as? String) ?? "Google Chrome"
    guard var url = args["url"] as? String, !url.isEmpty else { return toolText("navigate needs 'url'.", isError: true) }
    if !url.contains("://") { url = "https://" + url }
    let appName = resolveApp(appSpec)?.localizedName ?? appSpec
    let esc = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    let isSafari = appName.lowercased().contains("safari")
    let tabExpr = isSafari ? "URL of current tab of front window" : "URL of active tab of front window"
    let newTab = isSafari
        ? "tell application \"\(appName)\" to tell front window to set current tab to (make new tab with properties {URL:\"\(esc)\"})"
        : "tell application \"\(appName)\" to tell front window to make new tab with properties {URL:\"\(esc)\"}"
    let openWin = "tell application \"\(appName)\" to make new window"
    let wantNewTab = (args["new_tab"] as? Bool) ?? false
    // Ensure the app is running first (launch if needed, no foregrounding required for scripting).
    if resolveApp(appSpec) == nil { _ = launchOrActivate(appSpec); usleep(700_000) }
    return controlled("Navigating \(appName)") {
        let script = wantNewTab
            ? "try\n\(newTab)\non error\n\(openWin)\nend try"
            : "try\ntell application \"\(appName)\" to set \(tabExpr) to \"\(esc)\"\non error\n\(openWin)\ntell application \"\(appName)\" to set \(tabExpr) to \"\(esc)\"\nend try"
        let r = runAppleScript(script)
        if r.err.isEmpty { return toolText("Navigated \(appName) to \(url).") }
        return toolText("Navigate failed: \(r.err). (If this is an Automation-permission prompt, approve it and retry.)", isError: true)
    }
}
