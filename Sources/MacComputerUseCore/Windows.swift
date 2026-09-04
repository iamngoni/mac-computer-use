import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - Window selection
struct WindowCandidate { let id: CGWindowID; let bounds: CGRect; let title: String?; let order: Int }

func windowCandidates(forPid pid: pid_t) -> [WindowCandidate] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [WindowCandidate] = []
    for (i, info) in list.enumerated() {
        guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let num = info[kCGWindowNumber as String] as? CGWindowID,
              let b = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
        out.append(WindowCandidate(id: num, bounds: rect, title: info[kCGWindowName as String] as? String, order: i))
    }
    return out
}

// Front-to-back order, skipping palettes and toolbars too small to be the real window.
// A title hint (from the AX focused window) wins unless the frontmost window overlaps it —
// that's a sheet or dialog sitting on its parent, and the sheet is what we want to see.
func preferredWindow(forPid pid: pid_t, titleHint: String?) -> WindowCandidate? {
    let all = windowCandidates(forPid: pid)
    let usable = all.filter { $0.bounds.width * $0.bounds.height >= 20_000 }.sorted { $0.order < $1.order }
    guard let frontmost = usable.first else {
        return all.sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }.first
    }
    guard let hint = titleHint, !hint.isEmpty, let hinted = usable.first(where: { $0.title == hint }) else {
        return frontmost
    }
    if frontmost.id != hinted.id, frontmost.bounds.intersects(hinted.bounds) { return frontmost }
    return hinted
}

func exactAccessibilityWindowIdentityAvailable() -> Bool {
    AccessibilityWindowIdentity.shared.available
}

private final class AccessibilityWindowIdentity: @unchecked Sendable {
    static let shared = AccessibilityWindowIdentity()
    private typealias Resolver = @convention(c) (
        AXUIElement,
        UnsafeMutablePointer<CGWindowID>
    ) -> AXError

    private let resolver: Resolver?
    var available: Bool { resolver != nil }

    private init() {
        let candidates = [
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
        ]
        var loaded: Resolver?
        for path in candidates {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL),
                  let symbol = dlsym(handle, "_AXUIElementGetWindow") else {
                continue
            }
            loaded = unsafeBitCast(symbol, to: Resolver.self)
            break
        }
        resolver = loaded
    }

    func windowID(for element: AXUIElement) -> CGWindowID? {
        guard let resolver else { return nil }
        var identifier: CGWindowID = 0
        guard resolver(element, &identifier) == .success, identifier > 0 else { return nil }
        return identifier
    }
}

func accessibilityWindow(matching candidate: WindowCandidate, in app: AXUIElement) -> AXUIElement? {
    let windows = axArr(app, "AXWindows")
    guard !windows.isEmpty else { return nil }

    let identity = AccessibilityWindowIdentity.shared
    if identity.available {
        return windows.first { identity.windowID(for: $0) == candidate.id }
    }

    // Compatibility fallback for a future macOS release that removes the private symbol.
    // It deliberately rejects ambiguity rather than mapping an exact WindowServer ID to a
    // merely nearby AX window.
    func frameDistance(_ window: AXUIElement) -> CGFloat {
        guard let frame = axFrame(window) else { return .greatestFiniteMagnitude }
        return abs(frame.minX - candidate.bounds.minX)
            + abs(frame.minY - candidate.bounds.minY)
            + abs(frame.width - candidate.bounds.width)
            + abs(frame.height - candidate.bounds.height)
    }

    let exactFrameMatches = windows.filter { frameDistance($0) <= 2 }
    if exactFrameMatches.count == 1 { return exactFrameMatches[0] }

    if let title = candidate.title, !title.isEmpty {
        let titleMatches = windows.filter { axStr($0, "AXTitle") == title }
        if titleMatches.count == 1 { return titleMatches[0] }
    }
    return windows.count == 1 ? windows[0] : nil
}
