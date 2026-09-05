import Foundation
import Darwin

public let macComputerUseBundleIdentifier = "com.modestnerd.mac-computer-use"

private let updateGateName = "mac-computer-use-update-gate.lock"
private let updateMarkerName = "mac-computer-use-update-in-progress.json"
private let managerLockName = "mac-computer-use-manager.lock"
private let managerMarkerName = "mac-computer-use-manager.json"

public enum MacComputerUseLaunchMode: Equatable {
    case manager
    case mcp
    case overlay
}

public func macComputerUseLaunchMode(
    arguments: [String],
    standardInputIsPipe: Bool
) -> MacComputerUseLaunchMode {
    if arguments.contains("overlay") { return .overlay }
    if arguments.dropFirst().first == "mcp" { return .mcp }
    return standardInputIsPipe ? .mcp : .manager
}

public func standardInputIsPipe(fileDescriptor: Int32 = STDIN_FILENO) -> Bool {
    var status = stat()
    guard fstat(fileDescriptor, &status) == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFIFO || (status.st_mode & S_IFMT) == S_IFSOCK
}

private func updateGateURL(in temporaryDirectory: URL) -> URL {
    temporaryDirectory.appendingPathComponent(updateGateName)
}

private func updateMarkerURL(in temporaryDirectory: URL) -> URL {
    temporaryDirectory.appendingPathComponent(updateMarkerName)
}

public final class MCPProcessSessionLease {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public static func acquire(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> MCPProcessSessionLease? {
        guard !FileManager.default.fileExists(
            atPath: updateMarkerURL(in: temporaryDirectory).path
        ) else { return nil }
        let descriptor = open(
            updateGateURL(in: temporaryDirectory).path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        guard !FileManager.default.fileExists(
            atPath: updateMarkerURL(in: temporaryDirectory).path
        ) else {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            return nil
        }
        return MCPProcessSessionLease(descriptor: descriptor)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public final class ManagerProcessLease {
    private let descriptor: Int32
    private let markerURL: URL

    private init(descriptor: Int32, markerURL: URL) throws {
        self.descriptor = descriptor
        self.markerURL = markerURL
        let marker: [String: Any] = [
            "pid": Int(getpid()),
            "bundle_id": macComputerUseBundleIdentifier,
            "created_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
        try data.write(to: markerURL, options: .atomic)
    }

    public static func acquire(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> ManagerProcessLease? {
        let lockURL = temporaryDirectory.appendingPathComponent(managerLockName)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        let markerURL = temporaryDirectory.appendingPathComponent(managerMarkerName)
        do {
            return try ManagerProcessLease(descriptor: descriptor, markerURL: markerURL)
        } catch {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            return nil
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: markerURL)
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public func managerProcessIsRunning(
    in temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    isProcessAlive: (pid_t) -> Bool = { pid in
        guard pid > 0 else { return false }
        errno = 0
        return kill(pid, 0) == 0 || errno == EPERM
    }
) -> Bool {
    let markerURL = temporaryDirectory.appendingPathComponent(managerMarkerName)
    guard let data = try? Data(contentsOf: markerURL),
          let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          marker["bundle_id"] as? String == macComputerUseBundleIdentifier,
          let pid = marker["pid"] as? Int else {
        return false
    }
    return isProcessAlive(pid_t(pid))
}

public final class ExclusiveUpdateLease {
    private let descriptor: Int32
    private let markerURL: URL
    private let keepsMarkerAfterRelease: Bool

    private init(
        descriptor: Int32,
        markerURL: URL,
        version: String,
        keepsMarkerAfterRelease: Bool
    ) throws {
        self.descriptor = descriptor
        self.markerURL = markerURL
        self.keepsMarkerAfterRelease = keepsMarkerAfterRelease
        let marker: [String: Any] = [
            "pid": Int(getpid()),
            "version": version,
            "created_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
        try data.write(to: markerURL, options: .atomic)
    }

    public static func acquire(
        version: String,
        keepsMarkerAfterRelease: Bool = false,
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> ExclusiveUpdateLease? {
        let descriptor = open(
            updateGateURL(in: temporaryDirectory).path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        let markerURL = updateMarkerURL(in: temporaryDirectory)
        do {
            return try ExclusiveUpdateLease(
                descriptor: descriptor,
                markerURL: markerURL,
                version: version,
                keepsMarkerAfterRelease: keepsMarkerAfterRelease
            )
        } catch {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            return nil
        }
    }

    public static func recoverStaleMarker(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        guard let lease = ExclusiveUpdateLease.acquire(
            version: "recovery",
            in: temporaryDirectory
        ) else { return }
        try? FileManager.default.removeItem(at: lease.markerURL)
    }

    deinit {
        if !keepsMarkerAfterRelease {
            try? FileManager.default.removeItem(at: markerURL)
        }
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
