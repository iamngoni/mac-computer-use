// Identifies the application on the other end of a service connection.
//
// macOS attributes privacy checks to a process's "responsible" process: the
// app that launched it. A relay started by Claude Code or Codex is therefore
// attributed to that client app, which is exactly the identity the user is
// asked to approve before it may drive the Mac through Mac Computer Use.
import Foundation
import Darwin
import Security

public struct ServiceClientIdentity: Equatable, Codable, Sendable {
    /// Stable approval key: the signing identity when the app is validly
    /// signed, otherwise its bundle or executable path.
    public let key: String
    public let displayName: String
    public let bundleIdentifier: String?
    public let teamIdentifier: String?
    public let signer: String?
    public let path: String

    public init(
        key: String,
        displayName: String,
        bundleIdentifier: String?,
        teamIdentifier: String?,
        signer: String?,
        path: String
    ) {
        self.key = key
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.signer = signer
        self.path = path
    }

    public var detail: String {
        if let signer, !signer.isEmpty { return signer }
        if let bundleIdentifier { return bundleIdentifier }
        return path
    }
}

/// Builds the approval key. A team identifier plus signing identifier survives
/// app updates and moves; an unsigned client is pinned to its location.
public func serviceClientApprovalKey(
    teamIdentifier: String?,
    signingIdentifier: String?,
    path: String
) -> String {
    if let team = teamIdentifier, !team.isEmpty,
       let identifier = signingIdentifier, !identifier.isEmpty {
        return "team:\(team):\(identifier)"
    }
    if let identifier = signingIdentifier, !identifier.isEmpty,
       identifier.hasPrefix("com.apple.") {
        // Apple platform binaries carry no team identifier.
        return "apple:\(identifier)"
    }
    return "path:\(path)"
}

/// The outermost `.app` bundle that contains an executable, so helper apps
/// nested inside a host app resolve to the host the user recognises.
public func outermostApplicationBundle(containingExecutable path: String) -> String? {
    let components = (path as NSString).pathComponents
    var accumulated: [String] = []
    for component in components {
        accumulated.append(component)
        if component.lowercased().hasSuffix(".app") {
            return NSString.path(withComponents: accumulated)
        }
    }
    return nil
}

typealias ResponsibilityLookup = @convention(c) (pid_t) -> pid_t

private let responsibilityLookup: ResponsibilityLookup? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    return unsafeBitCast(symbol, to: ResponsibilityLookup.self)
}()

/// The process macOS holds responsible for `pid` (the launching app), or `pid`
/// itself when the lookup is unavailable.
public func responsibleProcessIdentifier(for pid: pid_t) -> pid_t {
    guard pid > 0, let responsibilityLookup else { return pid }
    let responsible = responsibilityLookup(pid)
    return responsible > 0 ? responsible : pid
}

public func executablePath(forProcess pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(cString: buffer)
}

struct CodeSigningSummary {
    let teamIdentifier: String?
    let signingIdentifier: String?
    let signer: String?
}

/// Reads the dynamic code signature of a running process. Returns nil when
/// the process's signature is missing or invalid.
func codeSigningSummary(forProcess pid: pid_t) -> CodeSigningSummary? {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
          let code,
          SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
        return nil
    }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
        return nil
    }
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &information
    ) == errSecSuccess,
    let dictionary = information as? [String: Any] else {
        return nil
    }
    var signer: String?
    if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
       let leaf = certificates.first {
        signer = SecCertificateCopySubjectSummary(leaf) as String?
    }
    return CodeSigningSummary(
        teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
        signingIdentifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
        signer: signer
    )
}

/// Identifies the app responsible for a connected peer process.
public func identifyServiceClient(peerProcess pid: pid_t) -> ServiceClientIdentity {
    let responsible = responsibleProcessIdentifier(for: pid)
    let executable = executablePath(forProcess: responsible) ?? "unknown"
    let bundlePath = outermostApplicationBundle(containingExecutable: executable)
    let bundle = bundlePath.flatMap { Bundle(path: $0) }
    let signing = codeSigningSummary(forProcess: responsible)
    let bundleIdentifier = bundle?.bundleIdentifier ?? signing?.signingIdentifier
    let displayName: String = {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = bundle?.object(forInfoDictionaryKey: key) as? String,
               !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        if let bundlePath {
            return ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return (executable as NSString).lastPathComponent
    }()
    let location = bundlePath ?? executable
    return ServiceClientIdentity(
        key: serviceClientApprovalKey(
            teamIdentifier: signing?.teamIdentifier,
            signingIdentifier: signing?.signingIdentifier,
            path: location
        ),
        displayName: displayName,
        bundleIdentifier: bundleIdentifier,
        teamIdentifier: signing?.teamIdentifier,
        signer: signing?.signer,
        path: location
    )
}

// MARK: - Socket peer credentials

func socketPeerProcessIdentifier(_ descriptor: Int32) -> pid_t? {
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else {
        return nil
    }
    return pid
}

func socketPeerIsCurrentUser(_ descriptor: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(descriptor, &uid, &gid) == 0 else { return false }
    return uid == getuid()
}

/// True when the peer runs the same signed code as this process. Relays use it
/// so they only ever talk to a genuine Mac Computer Use service.
func socketPeerSharesCurrentCodeIdentity(_ descriptor: Int32) -> Bool {
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
        return false
    }
    let tokenData = withUnsafeBytes(of: &token) { Data($0) }
    var peer: SecCode?
    let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer) == errSecSuccess,
          let peer else {
        return false
    }
    var current: SecCode?
    guard SecCodeCopySelf([], &current) == errSecSuccess, let current else { return false }
    var currentStatic: SecStaticCode?
    guard SecCodeCopyStaticCode(current, [], &currentStatic) == errSecSuccess,
          let currentStatic else {
        return false
    }
    var requirement: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(currentStatic, [], &requirement) == errSecSuccess,
          let requirement else {
        return false
    }
    return SecCodeCheckValidity(peer, [], requirement) == errSecSuccess
}
