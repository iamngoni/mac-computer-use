import Foundation
import Darwin

public let macComputerUseBundleIdentifier = "com.modestnerd.mac-computer-use"

private let updateGateName = "mac-computer-use-update-gate.lock"
private let updateMarkerName = "mac-computer-use-update-in-progress.json"
private let managerLockName = "mac-computer-use-manager.lock"
private let managerMarkerName = "mac-computer-use-manager.json"
private let globalInputLockName = "mac-computer-use-global-input.lock"

public enum MacComputerUseLaunchMode: Equatable {
    case manager
    case mcp
    case overlay
    case worker
}

public func macComputerUseLaunchMode(
    arguments: [String],
    standardInputIsPipe: Bool
) -> MacComputerUseLaunchMode {
    if arguments.contains("overlay") { return .overlay }
    switch arguments.dropFirst().first {
    case "worker": return .worker
    case "mcp": return .mcp
    case "manager": return .manager // explicit, even when stdin is a pipe
    default: break
    }
    return standardInputIsPipe ? .mcp : .manager
}

/// Where the update gate, manager lock and global input lock live. It is the
/// stable per-user runtime directory, so every relay, worker and service agrees
/// even when a client overrides $TMPDIR.
public func macComputerUseCoordinationDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    (try? MacComputerUseRuntime.prepareDirectory(environment: environment))
        ?? MacComputerUseRuntime.directory(environment: environment)
}

/// True while an update holds the exclusive gate and has not yet relaunched.
public func macComputerUseUpdateInProgress(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    FileManager.default.fileExists(
        atPath: updateMarkerURL(in: macComputerUseCoordinationDirectory(environment: environment)).path
    )
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
        in temporaryDirectory: URL = macComputerUseCoordinationDirectory()
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

/// A process-wide, nonblocking lease for the only APIs that can affect the
/// user's hardware pointer and the currently focused application. Application-
/// scoped events do not need this lease because they are delivered with
/// `postToPid`.
public final class GlobalInputLease {
    private var descriptor: Int32?

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public static func acquire(
        in temporaryDirectory: URL = macComputerUseCoordinationDirectory()
    ) -> GlobalInputLease? {
        let lockURL = temporaryDirectory.appendingPathComponent(globalInputLockName)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return GlobalInputLease(descriptor: descriptor)
    }

    /// Release explicitly so callers can guarantee the lease is relinquished
    /// with `defer`, even when an action fails part-way through.
    public func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit { release() }
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
        in temporaryDirectory: URL = macComputerUseCoordinationDirectory()
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
    in temporaryDirectory: URL = macComputerUseCoordinationDirectory(),
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
        in temporaryDirectory: URL = macComputerUseCoordinationDirectory()
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
        in temporaryDirectory: URL = macComputerUseCoordinationDirectory()
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
