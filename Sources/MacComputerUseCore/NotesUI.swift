// The person's side of review notes: a composer for the note text and pins
// that mark open notes on screen.
import AppKit
import Foundation

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A small panel beside the circled region with one text field. Enter saves,
/// ⌘Enter saves and circles another, Esc cancels. System dictation works in
/// the field, so a note can be spoken.
@MainActor
final class NoteComposer: NSObject, NSTextFieldDelegate {
    enum Outcome { case save(String), saveAndAnother(String), cancel }

    private let panel: KeyPanel
    private let field = NSTextField()
    private let completion: (Outcome) -> Void
    private var finished = false

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init(near region: CGRect, noteNumber: Int, captureVisible: Bool, completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 112),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = captureVisible ? .readOnly : .none
        panel.onCancel = { [weak self] in self?.finish(.cancel) }

        let background = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.layer?.borderWidth = 1.5
        background.layer?.borderColor = accent.cgColor

        let title = NSTextField(labelWithString: "Note \(noteNumber) for your agents")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.frame = NSRect(x: 14, y: 84, width: 332, height: 16)

        field.placeholderString = "What should change here?"
        field.font = .systemFont(ofSize: 13)
        field.frame = NSRect(x: 14, y: 46, width: 332, height: 28)
        field.bezelStyle = .roundedBezel
        field.delegate = self

        let hint = NSTextField(labelWithString: "↩ save · ⌘↩ save and circle another · esc cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 14, y: 16, width: 332, height: 16)

        [title, field, hint].forEach(background.addSubview)
        panel.contentView = background

        // Beside the region (Quartz), kept on screen.
        let cocoa = quartzRectToCocoa(region)
        var origin = CGPoint(x: cocoa.maxX + 12, y: cocoa.maxY - panel.frame.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(cocoa) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.x + panel.frame.width > visible.maxX - 4 { origin.x = cocoa.minX - panel.frame.width - 12 }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - panel.frame.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - panel.frame.height - 4)
        }
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { NSSound.beep(); return true }
            let another = NSEvent.modifierFlags.contains(.command)
            finish(another ? .saveAndAnother(text) : .save(text))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finish(.cancel)
            return true
        default:
            return false
        }
    }

    func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        panel.orderOut(nil)
        completion(outcome)
    }
}

/// Click-through markers for notes that are still open. A pin follows its
/// window when the window moves and hides while the window is off screen.
/// Resolving a note shows the agent's reply beside the pin for a while.
@MainActor
final class NotePins {
    private final class Pin {
        let panel: NSPanel
        let label: NSTextField
        var noteID: String
        var windowID: UInt32?
        var windowOrigin: CGPoint?
        var region: CGRect
        var removeAt: Date?

        init(panel: NSPanel, label: NSTextField, noteID: String, windowID: UInt32?, windowOrigin: CGPoint?, region: CGRect) {
            self.panel = panel
            self.label = label
            self.noteID = noteID
            self.windowID = windowID
            self.windowOrigin = windowOrigin
            self.region = region
        }
    }

    private var pins: [String: Pin] = [:]
    private var timer: Timer?
    private let captureVisible: Bool

    init(captureVisible: Bool) {
        self.captureVisible = captureVisible
    }

    var windowIDs: [CGWindowID] { pins.values.map { CGWindowID($0.panel.windowNumber) } }

    private static func windowOrigins() -> [UInt32: CGPoint] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var out: [UInt32: CGPoint] = [:]
        for window in info {
            guard let number = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { continue }
            out[number] = bounds.origin
        }
        return out
    }

    /// Shows a pin for each unresolved note and drops pins for the rest.
    func sync(_ notes: [ReviewNote]) {
        let open = notes.filter { $0.status != .resolved }
        let keep = Set(open.map(\.id))
        for (id, pin) in pins where !keep.contains(id) && pin.removeAt == nil {
            pin.panel.orderOut(nil)
            pins.removeValue(forKey: id)
        }
        for (index, note) in open.enumerated() where pins[note.id] == nil {
            pins[note.id] = makePin(note, number: index + 1)
        }
        for (index, note) in open.enumerated() {
            pins[note.id]?.label.stringValue = note.status == .claimed ? "\(index + 1) ⋯" : "\(index + 1)"
        }
        refresh()
        startTimer()
    }

    /// Shows the agent's reply beside the note's pin for a few seconds.
    func showReply(_ note: ReviewNote) {
        let pin = pins[note.id] ?? makePin(note, number: 0)
        pins[note.id] = pin
        let text = "✓ " + (note.reply ?? "Done")
        pin.label.stringValue = text.count > 140 ? String(text.prefix(140)) + "…" : text
        pin.label.backgroundColor = .systemGreen
        let size = pin.label.sizeThatFits(NSSize(width: 320, height: 200))
        pin.panel.setContentSize(NSSize(width: min(max(size.width + 16, 28), 340), height: max(size.height + 8, 24)))
        pin.label.frame = NSRect(origin: .zero, size: pin.panel.frame.size)
        pin.removeAt = Date().addingTimeInterval(8)
        refresh()
        startTimer()
    }

    func removeAll() {
        pins.values.forEach { $0.panel.orderOut(nil) }
        pins.removeAll()
        timer?.invalidate()
        timer = nil
    }

    private func makePin(_ note: ReviewNote, number: Int) -> Pin {
        let origin = note.windowBounds.flatMap { $0.count == 4 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 28, height: 24), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = captureVisible ? .readOnly : .none
        let label = NSTextField(labelWithString: "\(number)")
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = accent
        label.wantsLayer = true
        label.layer?.cornerRadius = 8
        label.layer?.masksToBounds = true
        label.maximumNumberOfLines = 4
        label.preferredMaxLayoutWidth = 320
        label.frame = NSRect(x: 0, y: 0, width: 28, height: 24)
        panel.contentView = label
        return Pin(panel: panel, label: label, noteID: note.id, windowID: note.windowID, windowOrigin: origin, region: note.regionRect)
    }

    private func startTimer() {
        guard timer == nil, !pins.isEmpty else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let origins = Self.windowOrigins()
        let now = Date()
        for (id, pin) in pins {
            if let removeAt = pin.removeAt, now >= removeAt {
                pin.panel.orderOut(nil)
                pins.removeValue(forKey: id)
                continue
            }
            var region = pin.region
            if let windowID = pin.windowID {
                guard let current = origins[windowID] else { pin.panel.orderOut(nil); continue }
                if let original = pin.windowOrigin {
                    region = region.offsetBy(dx: current.x - original.x, dy: current.y - original.y)
                }
            }
            let cocoa = quartzRectToCocoa(region)
            pin.panel.setFrameOrigin(CGPoint(x: cocoa.maxX - 10, y: cocoa.maxY - pin.panel.frame.height + 10))
            pin.panel.orderFrontRegardless()
        }
        if pins.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}
