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
