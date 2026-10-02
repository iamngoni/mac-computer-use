// Locations shared by the service, its relays and its workers.
//
// The service socket and the coordination files live in the per-user Darwin
// temporary directory from confstr(_CS_DARWIN_USER_TEMP_DIR), not $TMPDIR, so a
// client that overrides TMPDIR cannot split relays from the service.
import Foundation
import Darwin

public enum MacComputerUseRuntime {
    static let directoryName = "com.modestnerd.mac-computer-use"

    /// Overrides the runtime directory. Only tests and isolated development
    /// services set it; production relays and services always agree on the
    /// Darwin user temporary directory.
    public static let directoryOverrideVariable = "MACCU_RUNTIME_DIR"

    public static func isOverridden(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !(environment[directoryOverrideVariable] ?? "").isEmpty
    }

    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[directoryOverrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = darwinUserTemporaryDirectory()
            ?? FileManager.default.temporaryDirectory.path
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func socketURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        directory(environment: environment).appendingPathComponent("service.sock")
    }

    /// Present after the user quits Mac Computer Use from its menu. Relays then
    /// refuse to relaunch the service until the user opens the app again.
    public static func stoppedMarkerURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if isOverridden(environment: environment) {
            return directory(environment: environment).appendingPathComponent("stopped-by-user")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacComputerUse", isDirectory: true)
            .appendingPathComponent("stopped-by-user")
    }

    public static func workerLogURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacComputerUse", isDirectory: true)
            .appendingPathComponent("sessions.log")
    }

    /// Creates the runtime directory with owner-only permissions and refuses a
    /// directory that another user owns or that others can write.
    @discardableResult
    public static func prepareDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let url = directory(environment: environment)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw RuntimeDirectoryError.unavailable(url.path)
        }
        guard (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == getuid() else {
            throw RuntimeDirectoryError.untrusted(url.path)
        }
        if status.st_mode & 0o077 != 0 {
            guard chmod(url.path, 0o700) == 0 else {
                throw RuntimeDirectoryError.untrusted(url.path)
            }
        }
        return url
    }

    public static func userStoppedService(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        FileManager.default.fileExists(atPath: stoppedMarkerURL(environment: environment).path)
    }

    public static func markStoppedByUser(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let url = stoppedMarkerURL(environment: environment)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }

    public static func clearStoppedByUser(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        try? FileManager.default.removeItem(at: stoppedMarkerURL(environment: environment))
    }
}

public enum RuntimeDirectoryError: Error, CustomStringConvertible {
    case unavailable(String)
    case untrusted(String)

    public var description: String {
        switch self {
        case .unavailable(let path): return "runtime directory is unavailable: \(path)"
        case .untrusted(let path): return "runtime directory is not owned exclusively by this user: \(path)"
        }
    }
}

func darwinUserTemporaryDirectory() -> String? {
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
    guard length > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: length)
    guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 else { return nil }
    let path = String(cString: buffer)
    return path.isEmpty ? nil : path
}
