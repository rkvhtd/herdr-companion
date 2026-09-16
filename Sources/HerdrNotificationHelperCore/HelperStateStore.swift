import Foundation
import HerdrKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum HelperStoreError: Error, CustomStringConvertible {
    case unsafePath(String)
    case invalidPermissions(String)
    case invalidState(String)
    case routeNotFound

    public var description: String {
        switch self {
        case .unsafePath(let path): return "unsafe helper path: \(path)"
        case .invalidPermissions(let path): return "helper path is not private: \(path)"
        case .invalidState(let message): return "invalid helper state: \(message)"
        case .routeNotFound: return "notification route is not registered"
        }
    }
}

public struct NotificationHelperPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public static func standard(home: String = NSHomeDirectory()) -> Self {
        Self(root: URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Herdr Companion Notifications",
                                    isDirectory: true))
    }

    public var state: URL { root.appendingPathComponent("state.json") }
    public var lock: URL { root.appendingPathComponent("state.lock") }
    public var config: URL { root.appendingPathComponent("config.json") }
}

public struct APNSConfiguration: Codable, Equatable, Sendable {
    public let teamID: String
    public let keyID: String
    public let topic: String
    public let privateKeyPath: String

    public init(teamID: String, keyID: String, topic: String, privateKeyPath: String) {
        self.teamID = teamID
        self.keyID = keyID
        self.topic = topic
        self.privateKeyPath = privateKeyPath
    }

    public func validated() throws -> Self {
        guard Self.isIdentifier(teamID, maximum: 32), Self.isIdentifier(keyID, maximum: 32),
              !topic.isEmpty, topic.utf8.count <= 255,
              topic.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                      || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 46
              }), privateKeyPath.hasPrefix("/"), privateKeyPath.utf8.count <= 1024 else {
            throw HelperStoreError.invalidState("invalid APNs configuration")
        }
        return self
    }

    private static func isIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90)
                    || ($0 >= 97 && $0 <= 122)
            }
    }

    enum CodingKeys: String, CodingKey {
        case topic
        case teamID = "team_id"
        case keyID = "key_id"
        case privateKeyPath = "private_key_path"
    }
}

public struct HelperRouteRegistration: Codable, Equatable, Sendable {
    public var savedHostID: String
    public var routingSecret: String
    public var preferences: NotificationPreferences
    public var mutedWorkspaceIDs: [String]
    public var updatedAtUnixSeconds: UInt64

    public init(
        savedHostID: String,
        routingSecret: String,
        preferences: NotificationPreferences,
        mutedWorkspaceIDs: [String] = [],
        updatedAtUnixSeconds: UInt64
    ) {
        self.savedHostID = savedHostID
        self.routingSecret = routingSecret
        self.preferences = preferences
        self.mutedWorkspaceIDs = Array(Set(mutedWorkspaceIDs)).sorted()
        self.updatedAtUnixSeconds = updatedAtUnixSeconds
    }

    enum CodingKeys: String, CodingKey {
        case routingSecret = "routing_secret"
        case savedHostID = "saved_host_id"
        case preferences
        case mutedWorkspaceIDs = "muted_workspace_ids"
        case updatedAtUnixSeconds = "updated_at"
    }
}

public struct HelperSessionRegistration: Codable, Equatable, Sendable {
    public var session: String
    public var routes: [HelperRouteRegistration]
    public var preferredRouteID: String

    public init(
        session: String,
        routes: [HelperRouteRegistration],
        preferredRouteID: String
    ) {
        self.session = session
        self.routes = routes.sorted { $0.savedHostID < $1.savedHostID }
        self.preferredRouteID = preferredRouteID
    }

    enum CodingKeys: String, CodingKey {
        case session, routes
        case preferredRouteID = "preferred_route_id"
    }
}

public struct HelperDeviceRegistration: Codable, Equatable, Sendable {
    public var deviceID: String
    public var token: String
    public var environment: APNSEnvironment
    public var sessions: [HelperSessionRegistration]
    public var updatedAtUnixSeconds: UInt64

    public init(
        deviceID: String,
        token: String,
        environment: APNSEnvironment,
        sessions: [HelperSessionRegistration],
        updatedAtUnixSeconds: UInt64
    ) {
        self.deviceID = deviceID
        self.token = token
        self.environment = environment
        self.sessions = sessions
        self.updatedAtUnixSeconds = updatedAtUnixSeconds
    }

    enum CodingKeys: String, CodingKey {
        case token, environment, sessions
        case deviceID = "device_id"
        case updatedAtUnixSeconds = "updated_at"
    }
}

public struct NotificationHelperPersistentState: Codable, Equatable, Sendable {
    public var version: Int
    public var installationID: String
    public var devices: [HelperDeviceRegistration]
    public var transitions: NotificationTransitionState

    public init(
        version: Int = NotificationHelperProtocol.version,
        installationID: String = UUID().uuidString.lowercased(),
        devices: [HelperDeviceRegistration] = [],
        transitions: NotificationTransitionState = NotificationTransitionState()
    ) {
        self.version = version
        self.installationID = installationID
        self.devices = devices
        self.transitions = transitions
    }

    enum CodingKeys: String, CodingKey {
        case version, devices, transitions
        case installationID = "installation_id"
    }
}

public struct NotificationDestination: Equatable, Sendable {
    public let deviceID: String
    public let token: String
    public let environment: APNSEnvironment
    public let savedHostID: String
    public let agentInstanceBinding: String
    public let event: CompanionNotificationEvent

    public init(
        deviceID: String,
        token: String,
        environment: APNSEnvironment,
        savedHostID: String,
        agentInstanceBinding: String,
        event: CompanionNotificationEvent
    ) {
        self.deviceID = deviceID
        self.token = token
        self.environment = environment
        self.savedHostID = savedHostID
        self.agentInstanceBinding = agentInstanceBinding
        self.event = event
    }
}

/// Cross-process state store used by both `run` and short-lived `rpc` helper modes.
/// A private flock file serializes read-modify-write and every JSON replacement is atomic.
public final class NotificationHelperStateStore: @unchecked Sendable {
    public let paths: NotificationHelperPaths
    private let fileManager: FileManager

    public init(paths: NotificationHelperPaths = .standard(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func prepare() throws {
        if !fileManager.fileExists(atPath: paths.root.path) {
            try fileManager.createDirectory(
                at: paths.root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try validatePrivatePath(paths.root, allowDirectory: true)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: paths.root.path)
    }

    public func loadConfiguration() throws -> APNSConfiguration? {
        try prepare()
        guard fileManager.fileExists(atPath: paths.config.path) else { return nil }
        try validatePrivatePath(paths.config, allowDirectory: false)
        let data = try Data(contentsOf: paths.config, options: .mappedIfSafe)
        guard data.count <= 16 * 1024 else {
            throw HelperStoreError.invalidState("config is too large")
        }
        let configuration = try JSONDecoder().decode(
            APNSConfiguration.self, from: data).validated()
        _ = try secureAPNSPrivateKeyData(at: configuration.privateKeyPath)
        return configuration
    }

    public func load() throws -> NotificationHelperPersistentState {
        try withLock { try readStateLocked() }
    }

    @discardableResult
    public func mutate<T>(
        _ body: (inout NotificationHelperPersistentState) throws -> T
    ) throws -> T {
        try withLock {
            var state = try readStateLocked()
            let result = try body(&state)
            try validate(state)
            try writeStateLocked(state)
            return result
        }
    }

    public func register(
        _ unvalidated: NotificationDeviceRegistration,
        nowUnixSeconds: UInt64
    ) throws {
        let registration = try unvalidated.validated()
        try mutate { state in
            // A token is one physical app installation. If iOS restored an app and
            // supplied the same token with a new local id, keep the prior routes
            // while assigning that physical token to only the latest owner.
            let inheritedSessions = state.devices.filter {
                $0.deviceID != registration.deviceID
                    && $0.token == registration.token
                    && $0.environment == registration.environment
            }.flatMap(\.sessions)
            state.devices.removeAll {
                $0.deviceID != registration.deviceID
                    && $0.token == registration.token
                    && $0.environment == registration.environment
            }
            let deviceIndex: Int
            if let index = state.devices.firstIndex(where: { $0.deviceID == registration.deviceID }) {
                deviceIndex = index
                state.devices[index].token = registration.token
                state.devices[index].environment = registration.environment
                state.devices[index].updatedAtUnixSeconds = nowUnixSeconds
            } else {
                state.devices.append(HelperDeviceRegistration(
                    deviceID: registration.deviceID, token: registration.token,
                    environment: registration.environment, sessions: [],
                    updatedAtUnixSeconds: nowUnixSeconds))
                deviceIndex = state.devices.count - 1
            }

            for inherited in inheritedSessions {
                Self.merge(inherited, into: &state.devices[deviceIndex].sessions)
            }

            if let index = state.devices[deviceIndex].sessions.firstIndex(
                where: { $0.session == registration.session }
            ) {
                var session = state.devices[deviceIndex].sessions[index]
                if let routeIndex = session.routes.firstIndex(where: {
                    $0.savedHostID == registration.savedHostID
                }) {
                    session.routes[routeIndex].routingSecret = registration.routingSecret
                    session.routes[routeIndex].preferences = registration.preferences
                    session.routes[routeIndex].updatedAtUnixSeconds = nowUnixSeconds
                } else {
                    session.routes.append(HelperRouteRegistration(
                        savedHostID: registration.savedHostID,
                        routingSecret: registration.routingSecret,
                        preferences: registration.preferences,
                        updatedAtUnixSeconds: nowUnixSeconds))
                }
                session.routes.sort { $0.savedHostID < $1.savedHostID }
                session.preferredRouteID = registration.savedHostID
                state.devices[deviceIndex].sessions[index] = session
            } else {
                state.devices[deviceIndex].sessions.append(HelperSessionRegistration(
                    session: registration.session,
                    routes: [HelperRouteRegistration(
                        savedHostID: registration.savedHostID,
                        routingSecret: registration.routingSecret,
                        preferences: registration.preferences,
                        updatedAtUnixSeconds: nowUnixSeconds)],
                    preferredRouteID: registration.savedHostID))
            }
            state.devices[deviceIndex].sessions.sort { $0.session < $1.session }
        }
    }

    public func unregisterRoute(deviceID: String, savedHostID: String, session: String) throws {
        try mutate { state in
            guard let deviceIndex = state.devices.firstIndex(where: { $0.deviceID == deviceID }),
                  let sessionIndex = state.devices[deviceIndex].sessions.firstIndex(
                      where: {
                          $0.session == session
                              && $0.routes.contains(where: { $0.savedHostID == savedHostID })
                      }) else {
                throw HelperStoreError.routeNotFound
            }
            state.devices[deviceIndex].sessions[sessionIndex].routes.removeAll {
                $0.savedHostID == savedHostID
            }
            if state.devices[deviceIndex].sessions[sessionIndex].routes.isEmpty {
                state.devices[deviceIndex].sessions.remove(at: sessionIndex)
            } else if state.devices[deviceIndex].sessions[sessionIndex].preferredRouteID == savedHostID {
                let replacement = state.devices[deviceIndex].sessions[sessionIndex].routes
                    .max { lhs, rhs in
                        if lhs.updatedAtUnixSeconds == rhs.updatedAtUnixSeconds {
                            return lhs.savedHostID < rhs.savedHostID
                        }
                        return lhs.updatedAtUnixSeconds < rhs.updatedAtUnixSeconds
                    }!
                state.devices[deviceIndex].sessions[sessionIndex].preferredRouteID =
                    replacement.savedHostID
            }
            if state.devices[deviceIndex].sessions.isEmpty {
                state.devices.remove(at: deviceIndex)
            }
        }
    }

    public func setPreferences(
        deviceID: String,
        savedHostID: String,
        session: String,
        preferences: NotificationPreferences
    ) throws {
        try mutate { state in
            let indexes = try Self.routeIndexes(
                state: state, deviceID: deviceID, savedHostID: savedHostID, session: session)
            state.devices[indexes.device].sessions[indexes.session]
                .routes[indexes.route].preferences = preferences
            state.devices[indexes.device].sessions[indexes.session].preferredRouteID = savedHostID
        }
    }

    public func setWorkspaceMuted(
        deviceID: String,
        savedHostID: String,
        session: String,
        workspaceID: String,
        muted: Bool
    ) throws {
        guard NotificationHelperRequest.isSafeOpaqueID(workspaceID) else {
            throw HelperStoreError.invalidState("invalid workspace id")
        }
        try mutate { state in
            let indexes = try Self.routeIndexes(
                state: state, deviceID: deviceID, savedHostID: savedHostID, session: session)
            var mutedIDs = state.devices[indexes.device].sessions[indexes.session]
                .routes[indexes.route].mutedWorkspaceIDs
            if muted {
                if !mutedIDs.contains(workspaceID) { mutedIDs.append(workspaceID) }
            } else {
                mutedIDs.removeAll { $0 == workspaceID }
            }
            state.devices[indexes.device].sessions[indexes.session]
                .routes[indexes.route].mutedWorkspaceIDs =
                Array(Set(mutedIDs)).sorted()
            state.devices[indexes.device].sessions[indexes.session].preferredRouteID = savedHostID
        }
    }

    public func status(
        deviceID: String?, savedHostID: String?, session: String?, configured: Bool
    ) throws -> NotificationHelperStatus {
        let state = try load()
        guard let deviceID, let savedHostID, let session,
              let device = state.devices.first(where: { $0.deviceID == deviceID }) else {
            return NotificationHelperStatus(
                configured: configured, registrationPresent: false, routePresent: false)
        }
        guard let registration = device.sessions.first(where: { $0.session == session }) else {
            return NotificationHelperStatus(
                configured: configured, registrationPresent: true, routePresent: false)
        }
        guard let route = registration.routes.first(where: { $0.savedHostID == savedHostID }) else {
            return NotificationHelperStatus(
                configured: configured, registrationPresent: true, routePresent: false)
        }
        return NotificationHelperStatus(
            configured: configured, registrationPresent: true,
            routePresent: true, preferences: route.preferences,
            mutedWorkspaceIDs: route.mutedWorkspaceIDs)
    }

    public func sessions() throws -> [String] {
        Array(Set(try load().devices.flatMap { $0.sessions.map(\.session) })).sorted()
    }

    public func destinations(for event: CompanionNotificationEvent) throws -> [NotificationDestination] {
        let state = try load()
        var seenTokens: Set<String> = []
        var destinations: [NotificationDestination] = []
        guard let agentSession = event.observation.agentSession else { return [] }
        for device in state.devices {
            guard let session = device.sessions.first(where: {
                $0.session == event.observation.session
            }), let route = session.routes.first(where: {
                $0.savedHostID == session.preferredRouteID
            }), !route.mutedWorkspaceIDs.contains(event.observation.workspaceID),
            let binding = NotificationAgentBinding.routeBinding(
                for: agentSession, routingSecret: route.routingSecret) else { continue }
            switch event.kind {
            case .needsAttention where !route.preferences.needsAttention: continue
            case .finishedResponding where !route.preferences.finishedResponding: continue
            default: break
            }
            let tokenKey = device.environment.rawValue + "\u{1f}" + device.token
            guard seenTokens.insert(tokenKey).inserted else { continue }
            destinations.append(NotificationDestination(
                deviceID: device.deviceID, token: device.token,
                environment: device.environment, savedHostID: route.savedHostID,
                agentInstanceBinding: binding,
                event: event))
        }
        return destinations
    }

    public func ingest(
        _ agents: [AgentInfo],
        session: String,
        reason: NotificationTransitionEngine.SnapshotReason,
        nowUnixSeconds: UInt64
    ) throws -> [CompanionNotificationEvent] {
        try mutate { state in
            let observations = agents.compactMap {
                NotificationAgentObservation(
                    session: session, agent: $0, installationID: state.installationID)
            }
            var engine = NotificationTransitionEngine(state: state.transitions)
            let events = engine.ingest(
                observations, snapshotSession: session,
                reason: reason, nowUnixSeconds: nowUnixSeconds)
            state.transitions = engine.state
            return events
        }
    }

    public func hasTransitionState(session: String) throws -> Bool {
        try load().transitions.entries.values.contains {
            $0.observation.session == session
        }
    }

    public func destinationForTest(
        deviceID: String, savedHostID: String, session: String
    ) throws -> NotificationDestination {
        let state = try load()
        let indexes = try Self.routeIndexes(
            state: state, deviceID: deviceID, savedHostID: savedHostID, session: session)
        let device = state.devices[indexes.device]
        let route = device.sessions[indexes.session].routes[indexes.route]
        let agentSession = AgentSessionInfo(
            source: "herdr:test", agent: "test", kind: "id", value: "test")
        guard let instanceID = NotificationAgentBinding.transitionIdentity(
            for: agentSession, installationID: state.installationID),
              let binding = NotificationAgentBinding.routeBinding(
                  for: agentSession, routingSecret: route.routingSecret) else {
            throw HelperStoreError.invalidState("invalid test notification binding")
        }
        let observation = NotificationAgentObservation(
            session: session, workspaceID: "test", paneID: "test", terminalID: "test",
            agentInstanceID: instanceID, status: "blocked", stateChangeSequence: nil,
            agentSession: agentSession)
        return NotificationDestination(
            deviceID: device.deviceID, token: device.token, environment: device.environment,
            savedHostID: savedHostID, agentInstanceBinding: binding,
            event: CompanionNotificationEvent(kind: .needsAttention, observation: observation))
    }

    public func removeToken(_ token: String, environment: APNSEnvironment) throws {
        try mutate { state in
            state.devices.removeAll { $0.token == token && $0.environment == environment }
        }
    }

    private static func routeIndexes(
        state: NotificationHelperPersistentState,
        deviceID: String,
        savedHostID: String,
        session: String
    ) throws -> (device: Int, session: Int, route: Int) {
        guard let deviceIndex = state.devices.firstIndex(where: { $0.deviceID == deviceID }),
              let sessionIndex = state.devices[deviceIndex].sessions.firstIndex(where: {
                  $0.session == session
              }), let routeIndex = state.devices[deviceIndex].sessions[sessionIndex]
                .routes.firstIndex(where: { $0.savedHostID == savedHostID }) else {
            throw HelperStoreError.routeNotFound
        }
        return (deviceIndex, sessionIndex, routeIndex)
    }

    private static func merge(
        _ incoming: HelperSessionRegistration,
        into sessions: inout [HelperSessionRegistration]
    ) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.session == incoming.session }) else {
            sessions.append(incoming)
            return
        }
        for route in incoming.routes {
            if let routeIndex = sessions[sessionIndex].routes.firstIndex(where: {
                $0.savedHostID == route.savedHostID
            }) {
                if sessions[sessionIndex].routes[routeIndex].updatedAtUnixSeconds
                    <= route.updatedAtUnixSeconds {
                    sessions[sessionIndex].routes[routeIndex] = route
                }
            } else {
                sessions[sessionIndex].routes.append(route)
            }
        }
        sessions[sessionIndex].routes.sort { $0.savedHostID < $1.savedHostID }
        if incoming.routes.contains(where: { $0.savedHostID == incoming.preferredRouteID }) {
            sessions[sessionIndex].preferredRouteID = incoming.preferredRouteID
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try prepare()
        let fd = open(paths.lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw HelperStoreError.unsafePath(paths.lock.path) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw HelperStoreError.unsafePath(paths.lock.path)
        }
        defer { _ = flock(fd, LOCK_UN) }
        try validatePrivatePath(paths.lock, allowDirectory: false)
        return try body()
    }

    private func readStateLocked() throws -> NotificationHelperPersistentState {
        guard fileManager.fileExists(atPath: paths.state.path) else {
            return NotificationHelperPersistentState()
        }
        try validatePrivatePath(paths.state, allowDirectory: false)
        let data = try Data(contentsOf: paths.state, options: .mappedIfSafe)
        guard data.count <= 4 * 1024 * 1024 else {
            throw HelperStoreError.invalidState("state is too large")
        }
        let state = try JSONDecoder().decode(NotificationHelperPersistentState.self, from: data)
        try validate(state)
        return state
    }

    private func writeStateLocked(_ state: NotificationHelperPersistentState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: paths.state, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: paths.state.path)
        try validatePrivatePath(paths.state, allowDirectory: false)
    }

    private func validate(_ state: NotificationHelperPersistentState) throws {
        guard state.version == NotificationHelperProtocol.version,
              UUID(uuidString: state.installationID) != nil,
              state.devices.count <= 128,
              state.transitions.entries.count <= NotificationTransitionEngine.maximumEntries else {
            throw HelperStoreError.invalidState("unsupported or oversized state")
        }
        for device in state.devices {
            guard UUID(uuidString: device.deviceID) != nil,
                  !device.sessions.isEmpty, device.sessions.count <= 64 else {
                throw HelperStoreError.invalidState("invalid device")
            }
            guard let firstSession = device.sessions.first,
                  let firstRoute = firstSession.routes.first else {
                throw HelperStoreError.invalidState("empty route registration")
            }
            _ = try NotificationDeviceRegistration(
                deviceID: device.deviceID, token: device.token, environment: device.environment,
                savedHostID: firstRoute.savedHostID, session: firstSession.session,
                routingSecret: firstRoute.routingSecret).validated()
            for session in device.sessions {
                guard OfficialHerdrSession(name: session.session) != nil,
                      !session.routes.isEmpty, session.routes.count <= 32,
                      session.routes.contains(where: {
                          $0.savedHostID == session.preferredRouteID
                      }) else {
                    throw HelperStoreError.invalidState("invalid session registration")
                }
                for route in session.routes {
                    guard UUID(uuidString: route.savedHostID) != nil,
                          NotificationAgentBinding.isValidSecret(route.routingSecret),
                          route.mutedWorkspaceIDs.count <= 1024,
                          route.mutedWorkspaceIDs.allSatisfy(
                              NotificationHelperRequest.isSafeOpaqueID) else {
                        throw HelperStoreError.invalidState("invalid route registration")
                    }
                }
            }
        }
    }

    private func validatePrivatePath(_ url: URL, allowDirectory: Bool) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw HelperStoreError.unsafePath(url.path)
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw HelperStoreError.unsafePath(url.path)
        }
        let expectedType = allowDirectory ? S_IFDIR : S_IFREG
        guard (info.st_mode & S_IFMT) == expectedType, info.st_uid == getuid() else {
            throw HelperStoreError.unsafePath(url.path)
        }
        let permissions = info.st_mode & 0o777
        let allowed: mode_t = allowDirectory ? 0o700 : 0o600
        guard permissions & ~allowed == 0 else {
            throw HelperStoreError.invalidPermissions(url.path)
        }
    }
}
