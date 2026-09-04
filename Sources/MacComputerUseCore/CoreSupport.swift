import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import ImageIO
import ScreenCaptureKit
import Darwin

// MARK: - Logging (stderr only)
func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - Thread-safe cancel flag
final class Flag {
    private var v = false; private let l = NSLock()
    var value: Bool { l.lock(); defer { l.unlock() }; return v }
    func set(_ nv: Bool) { l.lock(); v = nv; l.unlock() }
}
let cancelFlag = Flag()

// Thread-safe one-shot box, for handing a value back out of a detached Task.
final class Box<T>: @unchecked Sendable {
    private var v: T?; private let l = NSLock()
    func set(_ x: T?) { l.lock(); v = x; l.unlock() }
    func get() -> T? { l.lock(); defer { l.unlock() }; return v }
}

// Run an async operation from our synchronous tool path. Returns nil on throw or timeout.
func blockingRun<T>(timeout: TimeInterval, _ op: @escaping @Sendable () async throws -> T) -> T? {
    let sem = DispatchSemaphore(value: 0)
    let box = Box<T>()
    Task.detached { box.set(try? await op()); sem.signal() }
    if sem.wait(timeout: .now() + timeout) == .timedOut { return nil }
    return box.get()
}

// MARK: - JSON / stdout
func toJSON(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8) }
let stdoutHandle = FileHandle.standardOutput
let stdoutLock = NSLock()
func writeMessage(_ obj: [String: Any]) {
    var data = toJSON(obj); data.append(0x0A)
    stdoutLock.lock(); stdoutHandle.write(data); stdoutLock.unlock()
}
func resultMsg(_ id: Any?, _ result: Any) {
    var m: [String: Any] = ["jsonrpc": "2.0", "result": result]; if let id = id { m["id"] = id }; writeMessage(m)
}
func errorMsg(_ id: Any?, _ code: Int, _ message: String) {
    var m: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]; if let id = id { m["id"] = id }; writeMessage(m)
}
func toolText(_ s: String, isError: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": s]], "isError": isError]
}
