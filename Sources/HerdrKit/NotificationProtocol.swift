import Foundation
import Crypto

/// The deliberately small protocol shared by the iOS client and the Mac helper.
/// Requests are newline-delimited JSON on stdin; replies are one JSON line on stdout.
public enum NotificationHelperProtocol {
    public static let version = 1
    public static let maximumRequestBytes = 16 * 1024
    public static let maximumResponseBytes = 16 * 1024
}

public enum APNSEnvironment: String, Codable, Sendable, CaseIterable {
    case development
    case production
}

public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var needsAttention: Bool
    public var finishedResponding: Bool

    public init(needsAttention: Bool = true, finishedResponding: Bool = false) {
        self.needsAttention = needsAttention
        self.finishedResponding = finishedResponding
    }
}

public struct NotificationDeviceRegistration: Codable, Equatable, Sendable {
    public let deviceID: String
    public let token: String
    public let environment: APNSEnvironment
    public let savedHostID: String
    public let session: String
    /// Per-saved-route secret used only to HMAC official agent-session identity.
    /// It is sent through pinned SSH and stored by the helper, but is never sent
    /// in an APNs payload.
    public let routingSecret: String
    public let preferences: NotificationPreferences

    public init(
        deviceID: String,
        token: String,
        environment: APNSEnvironment,
        savedHostID: String,
        session: String,
        routingSecret: String,
        preferences: NotificationPreferences = NotificationPreferences()
    ) {
        self.deviceID = deviceID
        self.token = token
        self.environment = environment
        self.savedHostID = savedHostID
        self.session = session
        self.routingSecret = routingSecret
        self.preferences = preferences
    }

    public func validated() throws -> Self {
        guard UUID(uuidString: deviceID) != nil else {
            throw NotificationProtocolError.invalidField("device_id")
        }
        guard UUID(uuidString: savedHostID) != nil else {
            throw NotificationProtocolError.invalidField("saved_host_id")
        }
        guard OfficialHerdrSession(name: session) != nil else {
            throw NotificationProtocolError.invalidField("session")
        }
        guard NotificationAgentBinding.isValidSecret(routingSecret) else {
            throw NotificationProtocolError.invalidField("routing_secret")
        }
        let normalized = token.lowercased()
        guard normalized.utf8.count >= 32, normalized.utf8.count <= 400,
              normalized.utf8.count.isMultiple(of: 2),
              normalized.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            throw NotificationProtocolError.invalidField("token")
        }
        return NotificationDeviceRegistration(
            deviceID: deviceID.lowercased(), token: normalized, environment: environment,
            savedHostID: savedHostID.lowercased(), session: session,
            routingSecret: routingSecret.lowercased(), preferences: preferences)
    }

    enum CodingKeys: String, CodingKey {
        case token, environment, session, preferences
        case routingSecret = "routing_secret"
        case deviceID = "device_id"
        case savedHostID = "saved_host_id"
    }
}

public enum NotificationHelperOperation: String, Codable, Sendable {
    case status
    case register
    case unregisterRoute = "unregister_route"
    case setPreferences = "set_preferences"
    case setWorkspaceMuted = "set_workspace_muted"
    case testNotification = "test_notification"
}

/// One bounded RPC. Fields not used by an operation must be absent and are rejected.
public struct NotificationHelperRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let operation: NotificationHelperOperation
    public let registration: NotificationDeviceRegistration?
    public let deviceID: String?
    public let savedHostID: String?
    public let session: String?
    public let preferences: NotificationPreferences?
    public let workspaceID: String?
    public let muted: Bool?

    public init(
        version: Int = NotificationHelperProtocol.version,
        operation: NotificationHelperOperation,
        registration: NotificationDeviceRegistration? = nil,
        deviceID: String? = nil,
        savedHostID: String? = nil,
        session: String? = nil,
        preferences: NotificationPreferences? = nil,
        workspaceID: String? = nil,
        muted: Bool? = nil
    ) {
        self.version = version
        self.operation = operation
        self.registration = registration
        self.deviceID = deviceID
        self.savedHostID = savedHostID
        self.session = session
        self.preferences = preferences
        self.workspaceID = workspaceID
        self.muted = muted
    }

    public static func register(_ registration: NotificationDeviceRegistration) -> Self {
        Self(operation: .register, registration: registration)
    }

    public static func routeOperation(
        _ operation: NotificationHelperOperation,
        deviceID: String,
        savedHostID: String,
        session: String,
        preferences: NotificationPreferences? = nil,
        workspaceID: String? = nil,
        muted: Bool? = nil
    ) -> Self {
        Self(operation: operation, deviceID: deviceID, savedHostID: savedHostID,
             session: session, preferences: preferences, workspaceID: workspaceID, muted: muted)
    }

    public func validated() throws -> Self {
        guard version == NotificationHelperProtocol.version else {
            throw NotificationProtocolError.unsupportedVersion
        }
        switch operation {
        case .status:
            let hasNoRoute = deviceID == nil && savedHostID == nil && session == nil
            let hasCompleteRoute = deviceID.flatMap(UUID.init(uuidString:)) != nil
                && savedHostID.flatMap(UUID.init(uuidString:)) != nil
                && session.flatMap(OfficialHerdrSession.init(name:)) != nil
            guard registration == nil, hasNoRoute || hasCompleteRoute,
                  preferences == nil, workspaceID == nil, muted == nil else {
                throw NotificationProtocolError.unexpectedField
            }
        case .register:
            guard let registration, deviceID == nil, savedHostID == nil, session == nil,
                  preferences == nil, workspaceID == nil, muted == nil else {
                throw NotificationProtocolError.missingOrUnexpectedField
            }
            _ = try registration.validated()
        case .unregisterRoute, .testNotification:
            try validateRouteFields()
            guard preferences == nil, workspaceID == nil, muted == nil else {
                throw NotificationProtocolError.unexpectedField
            }
        case .setPreferences:
            try validateRouteFields()
            guard preferences != nil, workspaceID == nil, muted == nil else {
                throw NotificationProtocolError.missingOrUnexpectedField
            }
        case .setWorkspaceMuted:
            try validateRouteFields()
            guard let workspaceID, Self.isSafeOpaqueID(workspaceID), muted != nil,
                  preferences == nil else {
                throw NotificationProtocolError.missingOrUnexpectedField
            }
        }
        return self
    }

    private func validateRouteFields() throws {
        guard let deviceID, UUID(uuidString: deviceID) != nil,
              let savedHostID, UUID(uuidString: savedHostID) != nil,
              let session, OfficialHerdrSession(name: session) != nil,
              registration == nil else {
            throw NotificationProtocolError.missingOrUnexpectedField
        }
    }

    public static func isSafeOpaqueID(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= 192
            && bytes.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
    }

    enum CodingKeys: String, CodingKey {
        case version, operation, registration, session, preferences, muted
        case deviceID = "device_id"
        case savedHostID = "saved_host_id"
        case workspaceID = "workspace_id"
    }
}

public enum NotificationProtocolError: Error, Equatable, CustomStringConvertible {
    case unsupportedVersion
    case invalidField(String)
    case missingOrUnexpectedField
    case unexpectedField

    public var description: String {
        switch self {
        case .unsupportedVersion: return "unsupported protocol version"
        case .invalidField(let field): return "invalid \(field)"
        case .missingOrUnexpectedField: return "missing or unexpected operation field"
        case .unexpectedField: return "unexpected operation field"
        }
    }
}

public enum NotificationHelperTransportError: Error, Equatable, CustomStringConvertible {
    case helperMissing
    case requestTooLarge
    case responseTooLarge
    case invalidResponse
    case transportFailed
    case timedOut

    public var description: String {
        switch self {
        case .helperMissing: return "The notification helper is not installed on this Mac."
        case .requestTooLarge: return "The notification request was too large."
        case .responseTooLarge: return "The notification helper returned too much data."
        case .invalidResponse: return "The notification helper returned an invalid response."
        case .transportFailed: return "The notification helper could not be reached."
        case .timedOut: return "The notification helper did not respond before the deadline."
        }
    }
}

/// Privacy-preserving binding between a push route and one official agent
/// instance. The canonical raw session value may be a local transcript path, so
/// only a keyed digest is persisted in transition state or placed in APNs.
public enum NotificationAgentBinding {
    public static let secretByteCount = 32
    public static let digestHexCount = 64

    public static func makeSecret() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { bytes in
            bytes.map { String(format: "%02x", $0) }.joined()
        }
    }

    public static func isValidSecret(_ value: String) -> Bool {
        isLowercaseHex(value, count: secretByteCount * 2)
    }

    public static func isValidDigest(_ value: String) -> Bool {
        isLowercaseHex(value, count: digestHexCount)
    }

    public static func routeBinding(
        for session: AgentSessionInfo,
        routingSecret: String
    ) -> String? {
        guard session.isSupportedNotificationIdentity,
              isValidSecret(routingSecret),
              let keyData = Data(hexString: routingSecret) else { return nil }
        return digest(message: canonical(session), key: keyData)
    }

    public static func transitionIdentity(
        for session: AgentSessionInfo,
        installationID: String
    ) -> String? {
        guard session.isSupportedNotificationIdentity,
              UUID(uuidString: installationID) != nil else { return nil }
        return digest(message: canonical(session), key: Data(installationID.utf8))
    }

    private static func canonical(_ session: AgentSessionInfo) -> Data {
        var data = Data()
        for value in [session.source, session.agent, session.kind, session.value] {
            let bytes = Data(value.utf8)
            var count = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return data
    }

    private static func digest(message: Data, key: Data) -> String {
        let authentication = HMAC<SHA256>.authenticationCode(
            for: message, using: SymmetricKey(data: key))
        return authentication.map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.utf8.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hexString.utf8.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}

public struct NotificationHelperStatus: Codable, Equatable, Sendable {
    public let configured: Bool
    public let registrationPresent: Bool
    public let routePresent: Bool
    public let preferences: NotificationPreferences?
    public let mutedWorkspaceIDs: [String]

    public init(
        configured: Bool,
        registrationPresent: Bool,
        routePresent: Bool,
        preferences: NotificationPreferences? = nil,
        mutedWorkspaceIDs: [String] = []
    ) {
        self.configured = configured
        self.registrationPresent = registrationPresent
        self.routePresent = routePresent
        self.preferences = preferences
        self.mutedWorkspaceIDs = mutedWorkspaceIDs.sorted()
    }

    enum CodingKeys: String, CodingKey {
        case configured, preferences
        case registrationPresent = "registration_present"
        case routePresent = "route_present"
        case mutedWorkspaceIDs = "muted_workspace_ids"
    }
}

public struct NotificationHelperResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let code: String
    public let message: String
    public let status: NotificationHelperStatus?

    public init(ok: Bool, code: String, message: String, status: NotificationHelperStatus? = nil) {
        self.ok = ok
        self.code = code
        self.message = message
        self.status = status
    }
}

public enum CompanionNotificationKind: String, Codable, Sendable, Equatable {
    case needsAttention = "needs_attention"
    case finishedResponding = "finished_responding"

    public var message: String {
        switch self {
        case .needsAttention: return "Needs your attention"
        case .finishedResponding: return "Finished responding"
        }
    }
}

/// Minimal opaque routing data placed in an APNs payload. No hostnames, paths,
/// user names, prompt text, output, commands, or credentials are permitted here.
public struct CompanionNotificationRoute: Codable, Equatable, Sendable {
    public let version: Int
    public let kind: CompanionNotificationKind
    public let savedHostID: String
    public let workspaceID: String
    public let paneID: String
    public let terminalID: String
    public let agentInstanceBinding: String
    public let stateChangeSequence: UInt64?
    public let emittedAtUnixSeconds: UInt64

    public init(
        version: Int = NotificationHelperProtocol.version,
        kind: CompanionNotificationKind,
        savedHostID: String,
        workspaceID: String,
        paneID: String,
        terminalID: String,
        agentInstanceBinding: String,
        stateChangeSequence: UInt64?,
        emittedAtUnixSeconds: UInt64
    ) {
        self.version = version
        self.kind = kind
        self.savedHostID = savedHostID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.terminalID = terminalID
        self.agentInstanceBinding = agentInstanceBinding
        self.stateChangeSequence = stateChangeSequence
        self.emittedAtUnixSeconds = emittedAtUnixSeconds
    }

    public func validated(nowUnixSeconds: UInt64, maximumAgeSeconds: UInt64 = 15 * 60) throws -> Self {
        guard version == NotificationHelperProtocol.version else {
            throw NotificationProtocolError.unsupportedVersion
        }
        guard UUID(uuidString: savedHostID) != nil else {
            throw NotificationProtocolError.invalidField("saved_host_id")
        }
        for (name, value) in [
            ("workspace_id", workspaceID), ("pane_id", paneID), ("terminal_id", terminalID),
        ] where !NotificationHelperRequest.isSafeOpaqueID(value) {
            throw NotificationProtocolError.invalidField(name)
        }
        guard NotificationAgentBinding.isValidDigest(agentInstanceBinding) else {
            throw NotificationProtocolError.invalidField("agent_instance_binding")
        }
        guard emittedAtUnixSeconds <= nowUnixSeconds + 60,
              nowUnixSeconds <= emittedAtUnixSeconds + maximumAgeSeconds else {
            throw NotificationProtocolError.invalidField("emitted_at")
        }
        return self
    }

    enum CodingKeys: String, CodingKey {
        case version, kind
        case savedHostID = "saved_host_id"
        case workspaceID = "workspace_id"
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case agentInstanceBinding = "agent_instance_binding"
        case stateChangeSequence = "state_change_seq"
        case emittedAtUnixSeconds = "emitted_at"
    }
}
