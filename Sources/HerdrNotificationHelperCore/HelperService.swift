import Foundation
import HerdrKit

public final class NotificationHelperRPCService: @unchecked Sendable {
    public typealias SenderFactory = @Sendable (APNSConfiguration) -> any CompanionNotificationSending

    private let store: NotificationHelperStateStore
    private let senderFactory: SenderFactory
    private let now: @Sendable () -> UInt64

    public init(
        store: NotificationHelperStateStore,
        senderFactory: @escaping SenderFactory = { APNSClient(configuration: $0) },
        now: @escaping @Sendable () -> UInt64 = {
            UInt64(Date().timeIntervalSince1970)
        }
    ) {
        self.store = store
        self.senderFactory = senderFactory
        self.now = now
    }

    public func handle(_ data: Data) async -> NotificationHelperResponse {
        guard data.count <= NotificationHelperProtocol.maximumRequestBytes else {
            return Self.failure("request_too_large", "Request exceeded the helper limit.")
        }
        do {
            let request = try JSONDecoder().decode(NotificationHelperRequest.self, from: data)
            _ = try request.validated()
            let configuration = try store.loadConfiguration()
            switch request.operation {
            case .status:
                let status = try store.status(
                    deviceID: request.deviceID?.lowercased(),
                    savedHostID: request.savedHostID?.lowercased(),
                    session: request.session, configured: configuration != nil)
                return NotificationHelperResponse(
                    ok: true, code: configuration == nil ? "unconfigured" : "ready",
                    message: configuration == nil
                        ? "The helper is installed but APNs credentials are not configured."
                        : "The helper is ready.", status: status)

            case .register:
                let registration = try request.registration!.validated()
                try store.register(registration, nowUnixSeconds: now())
                let status = try store.status(
                    deviceID: registration.deviceID, savedHostID: registration.savedHostID,
                    session: registration.session, configured: configuration != nil)
                return NotificationHelperResponse(
                    ok: true, code: configuration == nil ? "registered_unconfigured" : "registered",
                    message: configuration == nil
                        ? "Registration saved; APNs credentials are not configured."
                        : "Notifications are registered.", status: status)

            case .unregisterRoute:
                try store.unregisterRoute(
                    deviceID: request.deviceID!.lowercased(),
                    savedHostID: request.savedHostID!.lowercased(), session: request.session!)
                return NotificationHelperResponse(
                    ok: true, code: "unregistered", message: "Notification route removed.")

            case .setPreferences:
                try store.setPreferences(
                    deviceID: request.deviceID!.lowercased(),
                    savedHostID: request.savedHostID!.lowercased(), session: request.session!,
                    preferences: request.preferences!)
                let status = try store.status(
                    deviceID: request.deviceID!.lowercased(),
                    savedHostID: request.savedHostID!.lowercased(),
                    session: request.session!, configured: configuration != nil)
                return NotificationHelperResponse(
                    ok: true, code: "preferences_updated", message: "Preferences updated.",
                    status: status)

            case .setWorkspaceMuted:
                try store.setWorkspaceMuted(
                    deviceID: request.deviceID!.lowercased(),
                    savedHostID: request.savedHostID!.lowercased(), session: request.session!,
                    workspaceID: request.workspaceID!, muted: request.muted!)
                let status = try store.status(
                    deviceID: request.deviceID!.lowercased(),
                    savedHostID: request.savedHostID!.lowercased(),
                    session: request.session!, configured: configuration != nil)
                return NotificationHelperResponse(
                    ok: true, code: "workspace_updated", message: "Workspace preference updated.",
                    status: status)

            case .testNotification:
                guard let configuration else {
                    return Self.failure(
                        "unconfigured", "APNs credentials are not configured on this Mac.")
                }
                let destination = try store.destinationForTest(
                    deviceID: request.deviceID!.lowercased(),
                    savedHostID: request.savedHostID!.lowercased(), session: request.session!)
                let result = await senderFactory(configuration).send(
                    destination, nowUnixSeconds: now())
                switch result {
                case .delivered:
                    return NotificationHelperResponse(
                        ok: true, code: "test_accepted", message: "APNs accepted the test notification.")
                case .permanentlyRejectedToken(let reason):
                    try store.removeToken(destination.token, environment: destination.environment)
                    return Self.failure("token_rejected", "APNs rejected this device token: \(reason).")
                case .authenticationFailed(let reason):
                    return Self.failure("apns_auth_failed", "APNs authentication failed: \(reason).")
                case .rejected(let reason), .retryExhausted(let reason):
                    return Self.failure("test_failed", "APNs did not accept the test: \(reason).")
                }
            }
        } catch is DecodingError {
            return Self.failure("invalid_json", "Request was not valid helper JSON.")
        } catch HelperStoreError.routeNotFound {
            return Self.failure("route_not_found", "This saved-host route is not registered.")
        } catch let error as NotificationProtocolError {
            return Self.failure("invalid_request", error.description)
        } catch APNSError.invalidSigningKey {
            return Self.failure(
                "configuration_invalid",
                "The APNs signing key is missing, unreadable, or not private.")
        } catch {
            return Self.failure("helper_error", "The helper could not complete the request.")
        }
    }

    private static func failure(_ code: String, _ message: String) -> NotificationHelperResponse {
        NotificationHelperResponse(ok: false, code: code, message: message)
    }
}

public protocol NotificationEventClient: Sendable {
    func agentList() async throws -> [AgentInfo]
    nonisolated func subscribe(
        _ subscriptions: [Subscription]
    ) -> AsyncThrowingStream<StreamLine, Error>
}

extension HerdrClient: NotificationEventClient {}

/// Watches one registered official Herdr session. There is no terminal read: an
/// event only triggers a fresh `agent.list`, whose stable ids and official status
/// feed the transition engine.
public final class HerdrNotificationSessionWatcher: @unchecked Sendable {
    public typealias ClientFactory = @Sendable () -> any NotificationEventClient
    public typealias Sleep = @Sendable (UInt64) async throws -> Void

    private let session: String
    private let store: NotificationHelperStateStore
    private let clientFactory: ClientFactory
    private let sender: any CompanionNotificationSending
    private let now: @Sendable () -> UInt64
    private let sleep: Sleep

    public init(
        session: String,
        store: NotificationHelperStateStore,
        clientFactory: @escaping ClientFactory,
        sender: any CompanionNotificationSending,
        now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) },
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.session = session
        self.store = store
        self.clientFactory = clientFactory
        self.sender = sender
        self.now = now
        self.sleep = sleep
    }

    public func run() async {
        var retrySeconds: UInt64 = 1
        var connectedBefore = false
        while !Task.isCancelled {
            let client = clientFactory()
            do {
                let initial = try await client.agentList()
                let reason: NotificationTransitionEngine.SnapshotReason
                let hasPersistedState = try store.hasTransitionState(session: session)
                if connectedBefore || hasPersistedState {
                    reason = .reconnect
                } else {
                    reason = .initial
                }
                try await process(initial, reason: reason)
                connectedBefore = true
                retrySeconds = 1

                var paneIDs = Set(initial.map(\.paneID))
                while !Task.isCancelled {
                    let subscriptions = Self.subscriptions(paneIDs: paneIDs)
                    var resubscribe = false
                    for try await line in client.subscribe(subscriptions) {
                        guard !Task.isCancelled else { return }
                        guard case .event = line else { continue }
                        let current = try await client.agentList()
                        try await process(current, reason: .liveEvent)
                        let currentPaneIDs = Set(current.map(\.paneID))
                        if currentPaneIDs != paneIDs {
                            paneIDs = currentPaneIDs
                            resubscribe = true
                            break
                        }
                    }
                    if !resubscribe { throw WatcherError.streamEnded }
                }
            } catch is CancellationError {
                return
            } catch {
                do {
                    try await sleep(retrySeconds * 1_000_000_000)
                } catch { return }
                retrySeconds = min(retrySeconds * 2, 30)
            }
        }
    }

    private func process(
        _ agents: [AgentInfo],
        reason: NotificationTransitionEngine.SnapshotReason
    ) async throws {
        let timestamp = now()
        let events = try store.ingest(
            agents, session: session, reason: reason, nowUnixSeconds: timestamp)
        for event in events {
            for destination in try store.destinations(for: event) {
                let result = await sender.send(destination, nowUnixSeconds: timestamp)
                if case .permanentlyRejectedToken = result {
                    try store.removeToken(destination.token, environment: destination.environment)
                }
            }
        }
    }

    public static func subscriptions(paneIDs: Set<String>) -> [Subscription] {
        var subscriptions = [
            Subscription(.paneUpdated), Subscription(.paneClosed), Subscription(.paneExited),
            Subscription(.paneAgentDetected), Subscription(.layoutUpdated),
        ]
        subscriptions += paneIDs.sorted().map {
            Subscription(.paneAgentStatusChanged, paneID: $0)
        }
        return subscriptions
    }

    private enum WatcherError: Error { case streamEnded }
}

public final class NotificationHelperDaemon: @unchecked Sendable {
    public typealias WatcherFactory = @Sendable (String) -> HerdrNotificationSessionWatcher
    public typealias Sleep = @Sendable (UInt64) async throws -> Void

    private let store: NotificationHelperStateStore
    private let watcherFactory: WatcherFactory
    private let sleep: Sleep

    public init(
        store: NotificationHelperStateStore,
        watcherFactory: @escaping WatcherFactory,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.store = store
        self.watcherFactory = watcherFactory
        self.sleep = sleep
    }

    public func run() async throws {
        var tasks: [String: Task<Void, Never>] = [:]
        defer { tasks.values.forEach { $0.cancel() } }
        while !Task.isCancelled {
            let wanted = Set(try store.sessions())
            for (session, task) in tasks where !wanted.contains(session) {
                task.cancel()
                tasks[session] = nil
            }
            for session in wanted where tasks[session] == nil {
                let watcher = watcherFactory(session)
                tasks[session] = Task { await watcher.run() }
            }
            try await sleep(5 * 1_000_000_000)
        }
    }
}
