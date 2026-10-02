// Newline-delimited JSON over file descriptors, shared by the relay, the
// service and its workers.
import Foundation
import Darwin

/// Writes every byte, retrying on EINTR and partial writes.
@discardableResult
func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard var pointer = raw.baseAddress else { return true }
        var remaining = raw.count
        while remaining > 0 {
            let written = Darwin.write(descriptor, pointer, remaining)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            remaining -= written
            pointer = pointer.advanced(by: written)
        }
        return true
    }
}

/// Buffered newline-delimited reader. A line may be arbitrarily long, for
/// example a tool result that carries a base64 screenshot.
final class LineReader {
    private let descriptor: Int32
    private var buffer = Data()
    private var scanned = 0

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// The next line without its terminator, or nil on end of file, error or
    /// timeout. A timeout of nil waits indefinitely.
    func readLine(timeout: TimeInterval? = nil) -> Data? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if let newline = buffer[(buffer.startIndex + scanned)...].firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                let result = Data(line)
                buffer.removeSubrange(buffer.startIndex...newline)
                scanned = 0
                return result
            }
            scanned = buffer.count
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }
                var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, Int32(min(remaining, 3600) * 1000))
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { return nil }
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// Bytes already read past the last returned line.
    var pendingByteCount: Int { buffer.count }
}

func decodeJSONLine(_ line: Data) -> [String: Any]? {
    guard !line.isEmpty else { return nil }
    return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
}

func encodeJSONLine(_ object: [String: Any]) -> Data {
    var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    data.append(0x0A)
    return data
}

/// A bidirectional JSON-lines channel over one descriptor, with a dedicated
/// reader thread and a locked writer.
final class JSONLineChannel: @unchecked Sendable {
    let descriptor: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var open = true

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    var isOpen: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return open
    }

    @discardableResult
    func send(_ object: [String: Any]) -> Bool {
        let line = encodeJSONLine(object)
        // The reader thread closes the descriptor under this lock, so a write
        // can never land on a closed (or reused) descriptor.
        writeLock.lock()
        defer { writeLock.unlock() }
        guard isOpen else { return false }
        let delivered = writeAll(descriptor, line)
        if !delivered { markClosed() }
        return delivered
    }

    /// Reads messages on a background thread until the peer closes, then
    /// closes the descriptor. The reader owns it, so every channel's
    /// descriptor is released exactly once.
    func startReading(
        onMessage: @escaping ([String: Any]) -> Void,
        onClose: @escaping () -> Void
    ) {
        let reader = LineReader(descriptor: descriptor)
        // The thread holds the channel until end of file, so the descriptor
        // is always closed even if every other reference is already gone.
        let thread = Thread { [self] in
            while let line = reader.readLine() {
                autoreleasepool {
                    if let message = decodeJSONLine(line) { onMessage(message) }
                }
            }
            markClosed()
            onClose()
            closeDescriptor()
        }
        thread.name = "mac-computer-use.channel"
        thread.start()
    }

    private func markClosed() {
        stateLock.lock(); open = false; stateLock.unlock()
    }

    /// Ends the conversation. The reader thread sees end of file and closes
    /// the descriptor itself.
    func close() {
        stateLock.lock()
        let wasOpen = open
        open = false
        stateLock.unlock()
        if wasOpen { shutdown(descriptor, SHUT_RDWR) }
    }

    private func closeDescriptor() {
        writeLock.lock()
        Darwin.close(descriptor)
        writeLock.unlock()
    }
}

// MARK: - Unix domain sockets

func makeUnixSocketAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let bytes = Array(path.utf8)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}

/// Connects to a Unix domain socket, or returns nil.
func connectUnixSocket(path: String) -> Int32? {
    guard var address = makeUnixSocketAddress(path) else { return nil }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        close(descriptor)
        return nil
    }
    var enabled: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    return descriptor
}

/// Binds and listens on a Unix domain socket with owner-only permissions.
func listenUnixSocket(path: String, backlog: Int32 = 32) throws -> Int32 {
    guard var address = makeUnixSocketAddress(path) else {
        throw ServiceSocketError.pathTooLong(path)
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ServiceSocketError.system("socket", errno) }
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    unlink(path)
    let previousMask = umask(0o077)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    umask(previousMask)
    guard bound == 0 else {
        let code = errno
        close(descriptor)
        throw ServiceSocketError.system("bind", code)
    }
    chmod(path, 0o600)
    guard listen(descriptor, backlog) == 0 else {
        let code = errno
        close(descriptor)
        throw ServiceSocketError.system("listen", code)
    }
    return descriptor
}

enum ServiceSocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case system(String, Int32)

    var description: String {
        switch self {
        case .pathTooLong(let path): return "socket path is too long: \(path)"
        case .system(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}
