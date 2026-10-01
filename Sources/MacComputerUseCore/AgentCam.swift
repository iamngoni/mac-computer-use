// Agent cam: agents mostly work in background windows the person cannot
// see. While a session acts on a window that is covered or on another Space,
// a small live preview of that window floats in a corner, with a dot where
// the agent's cursor is. It disappears when the window is visible again, when
// the agent goes idle, or when the person turns it off from the menu bar.
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import QuartzCore
import ScreenCaptureKit

public enum AgentCamPreference {
    static let defaultsKey = "showAgentPreview"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

/// True when another window covers the centre of `windowID`, or it is not
/// on screen (minimised or on another Space), so the person cannot see it.
func windowNeedsPreview(_ windowID: CGWindowID, ownPID: pid_t = getpid()) -> Bool {
    guard let all = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
          let target = all.first,
          let bounds = (target[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else {
        return false // the window is gone; nothing to preview
    }
    if (target[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue != true { return true }
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in onScreen {
        guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
              let frame = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
              frame.contains(center) else { continue }
        return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value != windowID
    }
    return false
}

/// Fits a window into the preview's maximum size, keeping its aspect ratio.
func agentCamPreviewSize(for window: CGSize, maxWidth: CGFloat = 300, maxHeight: CGFloat = 200) -> CGSize {
    guard window.width > 0, window.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
    let scale = min(maxWidth / window.width, maxHeight / window.height, 1)
    return CGSize(width: max(80, floor(window.width * scale)), height: max(50, floor(window.height * scale)))
}

@MainActor
final class AgentCam: NSObject {
    private let panel: NSPanel
    private let videoLayer = CALayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let cursorDot = CALayer()
    private var stream: SCStream?
    private var output: AgentCamOutput?
    private(set) var windowID: CGWindowID?
    private var startingWindowID: CGWindowID?
    private var windowBounds: CGRect = .zero
    private var sessionID: String?
    private var watchTimer: Timer?
    private var isVisibleFor: (String) -> Bool = { _ in false }
    private var cursorFor: (String) -> CGPoint? = { _ in nil }
    var onWindowsChanged: (() -> Void)?

    init(captureVisible: Bool) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 222),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = captureVisible ? .readOnly : .none

        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        videoLayer.contentsGravity = .resizeAspect
        container.layer?.addSublayer(videoLayer)
        cursorDot.backgroundColor = NSColor.systemBlue.cgColor
        cursorDot.borderColor = NSColor.white.cgColor
        cursorDot.borderWidth = 1.5
        cursorDot.cornerRadius = 5
        cursorDot.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        cursorDot.isHidden = true
        container.layer?.addSublayer(cursorDot)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(titleLabel)
        panel.contentView = container
    }

    var panelWindowID: CGWindowID? {
        panel.isVisible ? CGWindowID(panel.windowNumber) : nil
    }

    /// Called whenever a session's state changes. The preview follows the
    /// most recently active session whose window the person cannot see.
    func observe(
        sessionID: String,
        windowID: CGWindowID?,
        title: String,
        active: Bool,
        isVisible: @escaping (String) -> Bool,
        cursor: @escaping (String) -> CGPoint?
    ) {
        isVisibleFor = isVisible
        cursorFor = cursor
        if ProcessInfo.processInfo.environment["MACCU_DEBUG_AGENT_CAM"] == "1" {
            log("agent cam: session=\(sessionID) window=\(windowID.map(String.init) ?? "nil") active=\(active) enabled=\(AgentCamPreference.isEnabled) needs=\(windowID.map { windowNeedsPreview($0) } ?? false)")
        }
        guard AgentCamPreference.isEnabled else { hide(); return }
        guard active, let windowID, windowNeedsPreview(windowID) else {
            if self.sessionID == sessionID, !active || windowID.map({ !windowNeedsPreview($0) }) ?? true { hide() }
            return
        }
        titleLabel.stringValue = title
        if self.windowID == windowID, self.sessionID == sessionID, stream != nil || startingWindowID == windowID { return }
        self.sessionID = sessionID
        start(windowID: windowID)
    }

    func sessionEnded(_ sessionID: String) {
        if self.sessionID == sessionID { hide() }
    }

    func hide() {
        watchTimer?.invalidate()
        watchTimer = nil
        if let stream { stream.stopCapture { _ in } }
        stream = nil
        output = nil
        windowID = nil
        startingWindowID = nil
        sessionID = nil
        videoLayer.contents = nil
        if panel.isVisible {
            panel.orderOut(nil)
            onWindowsChanged?()
        }
    }

    private func start(windowID: CGWindowID) {
        if let stream { stream.stopCapture { _ in } }
        stream = nil
        self.windowID = windowID
        startingWindowID = windowID
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.startingWindowID == windowID { self.startingWindowID = nil } }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard self.windowID == windowID,
                      let window = content.windows.first(where: { $0.windowID == windowID }) else { return }
                self.windowBounds = window.frame
                let size = agentCamPreviewSize(for: window.frame.size)
                self.layout(previewSize: size)
                let configuration = SCStreamConfiguration()
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                configuration.width = Int(size.width * scale)
                configuration.height = Int(size.height * scale)
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = false
                configuration.queueDepth = 3
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let output = AgentCamOutput { [weak self] surface in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.videoLayer.contents = surface }
                    }
                }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
                try await stream.startCapture()
                guard self.windowID == windowID else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                self.output = output
                self.show()
                if ProcessInfo.processInfo.environment["MACCU_DEBUG_AGENT_CAM"] == "1" {
                    log("agent cam: streaming window \(windowID) into \(self.panel.frame)")
                }
            } catch {
                log("agent preview unavailable: \(error.localizedDescription)")
                self.hide()
            }
        }
    }

    private func layout(previewSize: CGSize) {
        let header: CGFloat = 22
        let frame = NSRect(x: 0, y: 0, width: previewSize.width, height: previewSize.height + header)
        panel.setContentSize(frame.size)
        panel.contentView?.frame = frame
        videoLayer.frame = CGRect(x: 0, y: 0, width: previewSize.width, height: previewSize.height)
        titleLabel.frame = NSRect(x: 9, y: previewSize.height + 3, width: previewSize.width - 18, height: 16)
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: visible.maxX - frame.width - 16, y: visible.minY + 16))
        }
    }

    private func show() {
        if !panel.isVisible {
            panel.orderFrontRegardless()
            onWindowsChanged?()
        }
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Hides once the session idles or the window is visible again, and keeps
    /// the cursor dot in place.
    private func refresh() {
        guard let sessionID, let windowID else { hide(); return }
        guard AgentCamPreference.isEnabled, isVisibleFor(sessionID), windowNeedsPreview(windowID) else {
            hide()
            return
        }
        guard let cursor = cursorFor(sessionID), windowBounds.width > 0 else {
            cursorDot.isHidden = true
            return
        }
        let quartz = CGPoint(x: cursor.x, y: primaryScreen().frame.height - cursor.y)
        let relative = CGPoint(
            x: (quartz.x - windowBounds.minX) / windowBounds.width,
            y: (quartz.y - windowBounds.minY) / windowBounds.height
        )
        guard (0...1).contains(relative.x), (0...1).contains(relative.y) else {
            cursorDot.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorDot.isHidden = false
        cursorDot.position = CGPoint(
            x: videoLayer.frame.minX + relative.x * videoLayer.frame.width,
            y: videoLayer.frame.maxY - relative.y * videoLayer.frame.height
        )
        CATransaction.commit()
    }
}

/// Receives frames off the main thread and hands their IOSurface to the layer.
final class AgentCamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "mac-computer-use.agent-cam")
    private let deliver: (IOSurface) -> Void

    init(deliver: @escaping (IOSurface) -> Void) {
        self.deliver = deliver
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        deliver(unsafeBitCast(surface, to: IOSurface.self))
    }
}
