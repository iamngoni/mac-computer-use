// Facts gathered when the person circles something for a review note. Runs
// in the service, which holds Accessibility and Screen Recording.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct WindowUnderPoint {
    let id: CGWindowID
    let pid: pid_t
    let title: String?
    let bounds: CGRect
}

/// The frontmost ordinary window (layer 0) under a Quartz point, skipping
/// Mac Computer Use's own overlays.
func topWindowUnder(_ quartz: CGPoint) -> WindowUnderPoint? {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in info {
        guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              owner != getpid(),
              let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
              bounds.contains(quartz) else { continue }
        return WindowUnderPoint(id: number, pid: owner, title: window[kCGWindowName as String] as? String, bounds: bounds)
    }
    return nil
}

private func axElementAt(_ point: CGPoint, pid: pid_t) -> AXUIElement? {
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &element) == .success else {
        return nil
    }
    return element
}

private func clipped(_ text: String?, _ limit: Int) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text.count > limit ? String(text.prefix(limit)) + "…" : text
}

private func urlString(_ value: AnyObject?) -> String? {
    if let url = value as? URL { return url.absoluteString }
    if let text = value as? String, !text.isEmpty { return text }
    return nil
}

/// The page URL of the web area containing `element`, if it is web content.
private func webURL(containing element: AXUIElement) -> String? {
    var current: AXUIElement? = element
    for _ in 0..<40 {
        guard let node = current else { return nil }
        if axStr(node, "AXRole") == "AXWebArea", let url = urlString(axCopy(node, "AXURL")) { return url }
        current = axElement(node, "AXParent")
    }
    return nil
}

/// The AX window element for a WindowServer window, matched by frame.
private func axWindow(for window: WindowUnderPoint) -> AXUIElement? {
    let app = AXUIElementCreateApplication(window.pid)
    let windows = axArr(app, "AXWindows")
    return windows.first { axFrame($0).map { abs($0.minX - window.bounds.minX) < 2 && abs($0.minY - window.bounds.minY) < 2 } ?? false }
        ?? windows.first
}

private func visibleText(_ element: AXUIElement) -> String? {
    for attribute in ["AXValue", "AXTitle", "AXDescription", "AXPlaceholderValue"] {
        if let text = clipped(axCopy(element, attribute) as? String, 80) { return text }
    }
    return nil
}

/// Visible text inside the circle, sampled on a grid of hit tests.
private func textInside(_ region: CGRect, pid: pid_t, limit: Int = 12) -> [String] {
    var found: [String] = []
    let steps = 5
    for row in 0..<steps {
        for column in 0..<steps {
            let point = CGPoint(
                x: region.minX + region.width * (CGFloat(column) + 0.5) / CGFloat(steps),
                y: region.minY + region.height * (CGFloat(row) + 0.5) / CGFloat(steps)
            )
            guard let element = axElementAt(point, pid: pid), let text = visibleText(element), !found.contains(text) else { continue }
            found.append(text)
            if found.count >= limit { return found }
        }
    }
    return found
}

/// Builds a note from a freehand path in Quartz screen points.
func makeReviewNote(path points: [CGPoint], text: String, reviewSession: String, now: Date = Date()) -> (note: ReviewNote, image: Data?)? {
    guard !points.isEmpty else { return nil }
    let region = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -6, dy: -6)
    let center = CGPoint(x: region.midX, y: region.midY)
    let window = topWindowUnder(center)
    let pid = window?.pid ?? 0
    let app = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil

    var element: NoteElement?
    var url: String?
    var document: String?
    if pid > 0, let hit = axElementAt(center, pid: pid) {
        element = NoteElement(
            role: axStr(hit, "AXRole") ?? "AXUnknown",
            subrole: axStr(hit, "AXSubrole"),
            title: clipped(axStr(hit, "AXTitle"), 120),
            description: clipped(axStr(hit, "AXDescription"), 120),
            identifier: axStr(hit, "AXIdentifier"),
            value: clipped(axCopy(hit, "AXValue") as? String, 120),
            frame: axFrame(hit).map { [$0.minX, $0.minY, $0.width, $0.height].map(Double.init) }
        )
        url = webURL(containing: hit)
    }
    if let window, let axWin = axWindow(for: window), let doc = urlString(axCopy(axWin, "AXDocument")) {
        if doc.hasPrefix("file://") {
            document = URL(string: doc)?.path
        } else if url == nil, doc.hasPrefix("http") {
            url = doc
        }
    }

    var image: Data?
    if let crop = captureScreenRegion(region.insetBy(dx: -16, dy: -16)), let png = boundedPNG(crop) {
        image = png.data
    }
    let note = ReviewNote(
        id: "n-" + String(UUID().uuidString.lowercased().prefix(8)),
        createdAt: now,
        reviewSession: reviewSession,
        text: text,
        bundleID: app?.bundleIdentifier,
        appName: app?.localizedName ?? (pid > 0 ? "pid \(pid)" : "Desktop"),
        pid: pid > 0 ? pid : nil,
        windowID: window?.id,
        windowTitle: window?.title.flatMap { $0.isEmpty ? nil : $0 },
        windowBounds: window.map { [$0.bounds.minX, $0.bounds.minY, $0.bounds.width, $0.bounds.height].map(Double.init) },
        url: url,
        document: document,
        region: [region.minX, region.minY, region.width, region.height].map(Double.init),
        element: element,
        textNearby: pid > 0 ? textInside(region, pid: pid) : []
    )
    return (note, image)
}
