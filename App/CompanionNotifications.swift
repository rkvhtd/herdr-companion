import Foundation
import SwiftUI
import UIKit
import UserNotifications
import HerdrKit

private func signedAPNSEnvironment() -> APNSEnvironment? {
    guard let value = Bundle.main.object(forInfoDictionaryKey: "HerdrAPNSEnvironment") as? String
    else { return nil }
    return APNSEnvironment(rawValue: value)
}

enum CompanionNotificationSyncPhase: String, Codable, Equatable {
    case disabled
    case requestingPermission
    case awaitingDeviceToken
    case pendingSync
    case enabled
    case permissionDenied
    case registrationFailed
    case helperMissing
    case helperUnconfigured
    case permissionRequired
}

enum CompanionNotificationAuthorizationState: String, Codable, Equatable {
    case unknown
    case notDetermined
    case denied
    case authorized
}

struct CompanionNotificationHostRecord: Codable, Equatable {
    var desiredEnabled = false
    var preferences = NotificationPreferences()
    var mutedWorkspaceIDs: [String] = []
    var appliedEnabled = false
    var appliedPreferences: NotificationPreferences?
    var appliedMutedWorkspaceIDs: [String] = []
    var helperConfigured: Bool?
    var authorization: CompanionNotificationAuthorizationState = .unknown
    var routingSecret: String?
    var mutationVersion: UInt64 = 0
    var phase: CompanionNotificationSyncPhase = .disabled
    var detail: String?
}

/// Pure, save-boundary policy shared by `SavedHostsStore` and its tests. Notification
/// settings are persisted synchronously, so reading the same defaults domain here observes
/// an enable/disable that happened after a host editor was opened without coupling the host
/// store to the main-actor controller singleton.
enum CompanionNotificationTargetEditPolicy {
    static let recordsKey = "com.elysium.herdrcompanion.notification-records.v2"

    static func blocksTargetChange(savedHostID: String, defaults: UserDefaults) -> Bool {
        guard let data = defaults.data(forKey: recordsKey),
              let records = try? JSONDecoder().decode(
                [String: CompanionNotificationHostRecord].self, from: data),
              let record = records[savedHostID.lowercased()] else { return false }
        return record.desiredEnabled || record.appliedEnabled || record.phase != .disabled
    }
}

@MainActor
final class CompanionNotificationSettingsStore: ObservableObject {
    static let shared = CompanionNotificationSettingsStore()

    @Published private(set) var records: [String: CompanionNotificationHostRecord]
    let deviceID: String

    private let defaults: UserDefaults
    // The helper/client protocol has not shipped. The v2 key deliberately starts
    // from a coherent desired/applied model instead of guessing how to migrate
    // the pre-review unversioned mutation state.
    private let recordsKey = CompanionNotificationTargetEditPolicy.recordsKey
    private let deviceIDKey = "com.elysium.herdrcompanion.notification-device-id.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: deviceIDKey), UUID(uuidString: stored) != nil {
            deviceID = stored.lowercased()
        } else {
            let created = UUID().uuidString.lowercased()
            deviceID = created
            defaults.set(created, forKey: deviceIDKey)
        }
        if let data = defaults.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode(
               [String: CompanionNotificationHostRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    var hasRequestedNotifications: Bool {
        records.values.contains(where: \.desiredEnabled)
    }

    func contains(savedHostID: String) -> Bool {
        records[savedHostID.lowercased()] != nil
    }

    func record(savedHostID: String) -> CompanionNotificationHostRecord {
        records[savedHostID.lowercased()] ?? CompanionNotificationHostRecord()
    }

    func update(savedHostID: String, _ body: (inout CompanionNotificationHostRecord) -> Void) {
        let key = savedHostID.lowercased()
        var record = records[key] ?? CompanionNotificationHostRecord()
        body(&record)
        records[key] = record
        persist()
    }

    func remove(savedHostID: String) {
        records[savedHostID.lowercased()] = nil
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: recordsKey)
    }
}

private actor CompanionNotificationRouteGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
final class CompanionNotificationController: ObservableObject {
    typealias HelperCaller = @Sendable (NotificationHelperRequest) async throws
        -> NotificationHelperResponse

    static let shared = CompanionNotificationController()

    @Published private(set) var pendingRoute: CompanionNotificationRoute?
    let settings: CompanionNotificationSettingsStore

    private struct DeviceTokenSnapshot: Equatable {
        let value: String
        let generation: UInt64
    }

    private enum RegistrationAttemptResult {
        case acknowledged
        case superseded
        case failed
    }

    private var deviceToken: DeviceTokenSnapshot?
    private var deviceTokenGeneration: UInt64 = 0
    private var pendingRegistrations: [String: PendingRegistration] = [:]
    private var registrationsNeedingSync: Set<String> = []
    private var routeGates: [String: CompanionNotificationRouteGate] = [:]
    private let registerForRemoteNotifications: @MainActor () -> Void
    private let requestAuthorization: @MainActor () async throws -> Bool
    private let authorizationStatus: @MainActor () async -> CompanionNotificationAuthorizationState
    private let environmentProvider: () -> APNSEnvironment?

    private struct PendingRegistration {
        let savedHostID: String
        let session: String
        let mutationVersion: UInt64
        let call: HelperCaller
    }

    init(
        settings: CompanionNotificationSettingsStore? = nil,
        center: UNUserNotificationCenter = .current(),
        registerForRemoteNotifications: @escaping @MainActor () -> Void = {
            UIApplication.shared.registerForRemoteNotifications()
        },
        requestAuthorization: (@MainActor () async throws -> Bool)? = nil,
        authorizationStatus: (@MainActor () async -> CompanionNotificationAuthorizationState)? = nil,
        environmentProvider: @escaping () -> APNSEnvironment? = signedAPNSEnvironment
    ) {
        self.settings = settings ?? .shared
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.requestAuthorization = requestAuthorization ?? {
            try await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        self.authorizationStatus = authorizationStatus ?? {
            switch await center.notificationSettings().authorizationStatus {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .authorized, .provisional, .ephemeral: return .authorized
            @unknown default: return .unknown
            }
        }
        self.environmentProvider = environmentProvider
    }

    func restoreAPNsRegistrationIfNeeded() async {
        guard settings.hasRequestedNotifications else { return }
        let authorization = await authorizationStatus()
        for key in settings.records.keys where settings.records[key]?.desiredEnabled == true {
            settings.update(savedHostID: key) { record in
                record.authorization = authorization
                if authorization == .denied {
                    record.phase = .permissionDenied
                    record.detail = "Notifications are denied. Enable them in iOS Settings."
                }
            }
        }
        if authorization == .authorized { registerForRemoteNotifications() }
    }

    func enable(savedHostID: String, session: String, call: @escaping HelperCaller) async {
        let key = savedHostID.lowercased()
        var mutationVersion: UInt64 = 0
        settings.update(savedHostID: savedHostID) {
            $0.mutationVersion &+= 1
            mutationVersion = $0.mutationVersion
            $0.desiredEnabled = true
            if $0.routingSecret == nil {
                $0.routingSecret = NotificationAgentBinding.makeSecret()
            }
            $0.phase = .requestingPermission
            $0.detail = nil
        }
        do {
            let granted = try await requestAuthorization()
            guard isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
                return
            }
            guard granted else {
                settings.update(savedHostID: savedHostID) {
                    $0.authorization = .denied
                    $0.phase = .permissionDenied
                    $0.detail = "Notifications are denied. Enable them in iOS Settings."
                }
                return
            }
            settings.update(savedHostID: savedHostID) { $0.authorization = .authorized }
            guard environmentProvider() != nil else {
                settings.update(savedHostID: savedHostID) {
                    $0.phase = .registrationFailed
                    $0.detail = "This build is missing a valid APNs entitlement."
                }
                return
            }
            pendingRegistrations[key] = PendingRegistration(
                savedHostID: savedHostID, session: session,
                mutationVersion: mutationVersion, call: call)
            if let deviceToken {
                await syncRegistration(
                    savedHostID: savedHostID, session: session, token: deviceToken,
                    mutationVersion: mutationVersion, call: call)
            } else {
                settings.update(savedHostID: savedHostID) {
                    $0.phase = .awaitingDeviceToken
                    $0.detail = "Waiting for APNs to register this device."
                }
                registerForRemoteNotifications()
            }
        } catch {
            guard isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
                return
            }
            settings.update(savedHostID: savedHostID) {
                $0.phase = .registrationFailed
                $0.detail = "iOS could not request notification permission."
            }
        }
    }

    @discardableResult
    func disable(savedHostID: String, session: String, call: @escaping HelperCaller) async -> Bool {
        let key = savedHostID.lowercased()
        var mutationVersion: UInt64 = 0
        settings.update(savedHostID: savedHostID) {
            $0.mutationVersion &+= 1
            mutationVersion = $0.mutationVersion
            $0.desiredEnabled = false
            $0.phase = .pendingSync
            $0.detail = "Disabling on the Mac…"
        }
        pendingRegistrations[key] = nil
        registrationsNeedingSync.remove(key)
        return await withRouteLock(key: key) {
            await self.unregisterLocked(
                savedHostID: savedHostID, session: session,
                mutationVersion: mutationVersion, desiredEnabled: false,
                call: call, permissionDenied: false)
        }
    }

    func updatePreferences(
        savedHostID: String,
        session: String,
        preferences: NotificationPreferences,
        call: @escaping HelperCaller
    ) async {
        let key = savedHostID.lowercased()
        var mutationVersion: UInt64 = 0
        settings.update(savedHostID: savedHostID) {
            $0.mutationVersion &+= 1
            mutationVersion = $0.mutationVersion
            $0.preferences = preferences
            $0.phase = .pendingSync
            $0.detail = "Saving preferences on the Mac…"
        }
        let request = NotificationHelperRequest.routeOperation(
            .setPreferences, deviceID: settings.deviceID, savedHostID: savedHostID,
            session: session, preferences: preferences)
        await withRouteLock(key: key) {
            await self.applyPreferenceRequestLocked(
                request, savedHostID: savedHostID,
                mutationVersion: mutationVersion, call: call)
        }
    }

    func setWorkspaceMuted(
        savedHostID: String,
        session: String,
        workspaceID: String,
        muted: Bool,
        call: @escaping HelperCaller
    ) async {
        let key = savedHostID.lowercased()
        var mutationVersion: UInt64 = 0
        settings.update(savedHostID: savedHostID) {
            $0.mutationVersion &+= 1
            mutationVersion = $0.mutationVersion
            if muted, !$0.mutedWorkspaceIDs.contains(workspaceID) {
                $0.mutedWorkspaceIDs.append(workspaceID)
            } else if !muted {
                $0.mutedWorkspaceIDs.removeAll { $0 == workspaceID }
            }
            $0.mutedWorkspaceIDs.sort()
            $0.phase = .pendingSync
            $0.detail = "Saving workspace mute on the Mac…"
        }
        let request = NotificationHelperRequest.routeOperation(
            .setWorkspaceMuted, deviceID: settings.deviceID, savedHostID: savedHostID,
            session: session, workspaceID: workspaceID, muted: muted)
        await withRouteLock(key: key) {
            await self.applyPreferenceRequestLocked(
                request, savedHostID: savedHostID,
                mutationVersion: mutationVersion, call: call)
        }
    }

    func refresh(savedHostID: String, session: String, call: @escaping HelperCaller) async {
        await reconcile(savedHostID: savedHostID, session: session, call: call)
    }

    /// Central, non-prompting convergence point used by the settings screen,
    /// normal saved-host connection, and app foreground. It never overwrites
    /// desired choices with stale helper state.
    func reconcile(
        savedHostID: String,
        session: String,
        call: @escaping HelperCaller,
        isConnectionCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async {
        let key = savedHostID.lowercased()
        guard settings.contains(savedHostID: key) else { return }
        if settings.record(savedHostID: key).desiredEnabled,
           settings.record(savedHostID: key).routingSecret == nil {
            settings.update(savedHostID: key) {
                $0.routingSecret = NotificationAgentBinding.makeSecret()
            }
        }
        let mutationVersion = settings.record(savedHostID: key).mutationVersion
        let authorization = await authorizationStatus()
        guard isConnectionCurrent(),
              isCurrent(key: key, mutationVersion: mutationVersion) else { return }
        settings.update(savedHostID: key) { $0.authorization = authorization }

        switch authorization {
        case .denied:
            pendingRegistrations[key] = nil
            registrationsNeedingSync.remove(key)
            _ = await withRouteLock(key: key) {
                await self.unregisterLocked(
                    savedHostID: savedHostID, session: session,
                    mutationVersion: mutationVersion,
                    desiredEnabled: self.settings.record(savedHostID: key).desiredEnabled,
                    call: call, permissionDenied: true,
                    isConnectionCurrent: isConnectionCurrent)
            }
            return
        case .notDetermined:
            settings.update(savedHostID: key) {
                $0.phase = $0.desiredEnabled ? .permissionRequired : .disabled
                $0.detail = $0.desiredEnabled
                    ? "Notification permission is not granted. Toggle notifications off and on to request it."
                    : nil
            }
            return
        case .unknown:
            settings.update(savedHostID: key) {
                $0.phase = .pendingSync
                $0.detail = "iOS notification authorization could not be verified."
            }
            return
        case .authorized:
            break
        }

        let desired = settings.record(savedHostID: key).desiredEnabled
        if !desired {
            _ = await withRouteLock(key: key) {
                await self.unregisterLocked(
                    savedHostID: savedHostID, session: session,
                    mutationVersion: mutationVersion, desiredEnabled: false,
                    call: call, permissionDenied: false,
                    isConnectionCurrent: isConnectionCurrent)
            }
            return
        }

        guard environmentProvider() != nil else {
            settings.update(savedHostID: key) {
                $0.phase = .registrationFailed
                $0.detail = "This build is missing its APNs environment configuration."
            }
            return
        }
        guard let deviceToken else {
            pendingRegistrations[key] = PendingRegistration(
                savedHostID: savedHostID, session: session,
                mutationVersion: mutationVersion, call: call)
            registrationsNeedingSync.insert(key)
            settings.update(savedHostID: key) {
                $0.phase = .awaitingDeviceToken
                $0.detail = "Waiting for APNs to register this device."
            }
            registerForRemoteNotifications()
            return
        }

        await withRouteLock(key: key) {
            await self.reconcileAuthorizedLocked(
                savedHostID: savedHostID, session: session, token: deviceToken,
                mutationVersion: mutationVersion, call: call,
                isConnectionCurrent: isConnectionCurrent)
        }
    }

    func sendTest(savedHostID: String, session: String, call: @escaping HelperCaller) async {
        let key = savedHostID.lowercased()
        guard settings.contains(savedHostID: key) else { return }
        let mutationVersion = settings.record(savedHostID: key).mutationVersion
        let request = NotificationHelperRequest.routeOperation(
            .testNotification, deviceID: settings.deviceID,
            savedHostID: savedHostID, session: session)
        await withRouteLock(key: key) {
            guard self.isCurrent(key: key, mutationVersion: mutationVersion) else { return }
            do {
                let response = try await call(request)
                guard self.isCurrent(key: key, mutationVersion: mutationVersion) else { return }
                self.settings.update(savedHostID: savedHostID) {
                    $0.detail = response.ok
                        ? "APNs accepted a real push test. Delivery may take a moment."
                        : response.message
                    if !response.ok && response.code == "unconfigured" {
                        $0.phase = .helperUnconfigured
                    }
                }
            } catch {
                guard self.isCurrent(key: key, mutationVersion: mutationVersion) else { return }
                self.applyTransportFailure(
                    error, savedHostID: savedHostID,
                    fallback: "The real push test could not reach the helper.")
            }
        }
    }

    func didRegisterForRemoteNotifications(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        if deviceToken?.value != token { deviceTokenGeneration &+= 1 }
        let snapshot = DeviceTokenSnapshot(value: token, generation: deviceTokenGeneration)
        deviceToken = snapshot
        for (key, record) in settings.records where record.desiredEnabled
            && record.authorization != .denied
            && record.authorization != .notDetermined {
            registrationsNeedingSync.insert(key)
            settings.update(savedHostID: key) {
                $0.phase = .pendingSync
                $0.detail = "APNs registration must be synced with this Mac."
            }
        }
        // Tokens are deliberately not persisted, so every launch-time callback
        // may represent a rotation. Only still-current pending enables have a
        // caller here; other routes converge on normal connection/foreground.
        for pending in Array(pendingRegistrations.values) {
            Task {
                await syncRegistration(
                    savedHostID: pending.savedHostID,
                    session: pending.session, token: snapshot,
                    mutationVersion: pending.mutationVersion,
                    call: pending.call)
            }
        }
    }

    func didFailToRegisterForRemoteNotifications() {
        for (key, record) in settings.records where record.desiredEnabled
            && record.authorization != .denied {
            settings.update(savedHostID: key) {
                $0.phase = .registrationFailed
                $0.detail = "APNs did not register this device. Try again on a working network."
            }
        }
        pendingRegistrations.removeAll()
    }

    func receiveNotification(userInfo: [AnyHashable: Any], now: Date = Date()) {
        guard let object = userInfo["herdr"],
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let route = try? JSONDecoder().decode(CompanionNotificationRoute.self, from: data),
              let validated = try? route.validated(
                  nowUnixSeconds: UInt64(now.timeIntervalSince1970)) else { return }
        pendingRoute = validated
    }

    func consumePendingRoute() -> CompanionNotificationRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    private func syncRegistration(
        savedHostID: String,
        session: String,
        token: DeviceTokenSnapshot,
        mutationVersion: UInt64,
        call: @escaping HelperCaller
    ) async {
        let key = savedHostID.lowercased()
        await withRouteLock(key: key) {
            let record = self.settings.record(savedHostID: key)
            guard !record.appliedEnabled
                    || self.registrationsNeedingSync.contains(key)
                    || self.pendingRegistrations[key]?.mutationVersion == mutationVersion
            else { return }
            _ = await self.registerLatestLocked(
                savedHostID: savedHostID, session: session, initialToken: token,
                mutationVersion: mutationVersion, call: call)
        }
    }

    /// Registers the newest token while retaining the route gate. A callback can replace
    /// token A during either status or register; A's response can never clear B's work or
    /// transiently publish the route as converged.
    private func registerLatestLocked(
        savedHostID: String,
        session: String,
        initialToken: DeviceTokenSnapshot,
        mutationVersion: UInt64,
        call: @escaping HelperCaller,
        isConnectionCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async -> Bool {
        var candidate = deviceToken ?? initialToken
        while true {
            switch await registerLocked(
                savedHostID: savedHostID, session: session, token: candidate,
                mutationVersion: mutationVersion, call: call,
                isConnectionCurrent: isConnectionCurrent) {
            case .acknowledged:
                return true
            case .failed:
                return false
            case .superseded:
                guard isConnectionCurrent(),
                      isCurrent(
                        key: savedHostID.lowercased(), mutationVersion: mutationVersion,
                        desiredEnabled: true),
                      let latest = deviceToken else { return false }
                candidate = latest
            }
        }
    }

    private func registerLocked(
        savedHostID: String,
        session: String,
        token: DeviceTokenSnapshot,
        mutationVersion: UInt64,
        call: @escaping HelperCaller,
        isConnectionCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async -> RegistrationAttemptResult {
        let key = savedHostID.lowercased()
        guard isConnectionCurrent(),
              isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true),
              settings.record(savedHostID: key).authorization == .authorized else {
            clearPendingRegistration(key: key, mutationVersion: mutationVersion)
            return .failed
        }
        guard let environment = environmentProvider(),
              let routingSecret = settings.record(savedHostID: key).routingSecret else {
            settings.update(savedHostID: key) {
                $0.phase = .registrationFailed
                $0.detail = "This build or saved route is missing notification registration data."
            }
            clearPendingRegistration(key: key, mutationVersion: mutationVersion)
            return .failed
        }
        let registration = NotificationDeviceRegistration(
            deviceID: settings.deviceID, token: token.value, environment: environment,
            savedHostID: savedHostID, session: session,
            routingSecret: routingSecret,
            preferences: settings.record(savedHostID: key).preferences)
        do {
            let response = try await call(.register(registration))
            guard isConnectionCurrent(),
                  isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
                // The remote register may already have committed. Remove it while
                // still holding this route's serialization gate; a following
                // disable/delete also waits for this compensation before returning.
                if response.ok {
                    _ = try? await call(NotificationHelperRequest.routeOperation(
                        .unregisterRoute, deviceID: settings.deviceID,
                        savedHostID: savedHostID, session: session))
                }
                clearPendingRegistration(key: key, mutationVersion: mutationVersion)
                return .failed
            }
            let tokenWasSuperseded = deviceToken != token
            guard response.ok else {
                if tokenWasSuperseded {
                    registrationsNeedingSync.insert(key)
                    markTokenSyncPending(savedHostID: key)
                    return .superseded
                }
                applyFailure(response, savedHostID: savedHostID,
                             fallback: "The helper rejected this registration.")
                clearPendingRegistration(key: key, mutationVersion: mutationVersion)
                return .failed
            }
            applyRemoteStatus(response.status, savedHostID: key)
            if tokenWasSuperseded {
                registrationsNeedingSync.insert(key)
                markTokenSyncPending(savedHostID: key)
                return .superseded
            }
            registrationsNeedingSync.remove(key)
            publishConvergedPhase(savedHostID: key, fallback: response.message)
            clearPendingRegistration(key: key, mutationVersion: mutationVersion)
            return .acknowledged
        } catch {
            guard isConnectionCurrent(),
                  isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
                clearPendingRegistration(key: key, mutationVersion: mutationVersion)
                return .failed
            }
            if deviceToken != token {
                registrationsNeedingSync.insert(key)
                markTokenSyncPending(savedHostID: key)
                return .superseded
            }
            applyTransportFailure(error, savedHostID: savedHostID,
                                  fallback: "Registration is pending until the helper is reachable.")
            clearPendingRegistration(key: key, mutationVersion: mutationVersion)
            return .failed
        }
    }

    private func applyPreferenceRequestLocked(
        _ request: NotificationHelperRequest,
        savedHostID: String,
        mutationVersion: UInt64,
        call: @escaping HelperCaller
    ) async {
        let key = savedHostID.lowercased()
        guard isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
            return
        }
        do {
            let response = try await call(request)
            guard isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
                return
            }
            guard response.ok else {
                applyFailure(response, savedHostID: savedHostID,
                             fallback: "The change is pending; the Mac has not acknowledged it.")
                return
            }
            applyRemoteStatus(response.status, savedHostID: key)
            publishConvergedPhase(savedHostID: key, fallback: response.message)
        } catch {
            guard isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
                return
            }
            applyTransportFailure(error, savedHostID: savedHostID,
                                  fallback: "The change is pending; the Mac has not acknowledged it.")
        }
    }

    private func reconcileAuthorizedLocked(
        savedHostID: String,
        session: String,
        token: DeviceTokenSnapshot,
        mutationVersion: UInt64,
        call: @escaping HelperCaller,
        isConnectionCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async {
        let key = savedHostID.lowercased()
        guard isConnectionCurrent(),
              isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
            return
        }
        do {
            let response = try await call(NotificationHelperRequest(
                operation: .status, deviceID: settings.deviceID,
                savedHostID: savedHostID, session: session))
            guard isConnectionCurrent(),
                  isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
                return
            }
            guard response.ok, response.status != nil else {
                applyFailure(response, savedHostID: key,
                             fallback: "Could not read notification helper status.")
                return
            }
            applyRemoteStatus(response.status, savedHostID: key)
        } catch {
            guard isConnectionCurrent(),
                  isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
                return
            }
            applyTransportFailure(
                error, savedHostID: key,
                fallback: "Could not check notification helper status; desired changes remain pending.")
            return
        }

        if !settings.record(savedHostID: key).appliedEnabled
            || registrationsNeedingSync.contains(key) {
            guard await registerLatestLocked(
                savedHostID: savedHostID, session: session, initialToken: token,
                mutationVersion: mutationVersion, call: call,
                isConnectionCurrent: isConnectionCurrent) else { return }
        }

        guard isConnectionCurrent(),
              isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
            return
        }
        var record = settings.record(savedHostID: key)
        if record.appliedPreferences != record.preferences {
            let request = NotificationHelperRequest.routeOperation(
                .setPreferences, deviceID: settings.deviceID,
                savedHostID: savedHostID, session: session,
                preferences: record.preferences)
            await applyPreferenceRequestLocked(
                request, savedHostID: key,
                mutationVersion: mutationVersion, call: call)
        }

        guard isConnectionCurrent(),
              isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
            return
        }
        record = settings.record(savedHostID: key)
        let desiredMutes = Set(record.mutedWorkspaceIDs)
        let appliedMutes = Set(record.appliedMutedWorkspaceIDs)
        let changes = desiredMutes.subtracting(appliedMutes).sorted().map { ($0, true) }
            + appliedMutes.subtracting(desiredMutes).sorted().map { ($0, false) }
        for (workspaceID, muted) in changes {
            guard isConnectionCurrent(),
                  isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
                return
            }
            let request = NotificationHelperRequest.routeOperation(
                .setWorkspaceMuted, deviceID: settings.deviceID,
                savedHostID: savedHostID, session: session,
                workspaceID: workspaceID, muted: muted)
            await applyPreferenceRequestLocked(
                request, savedHostID: key,
                mutationVersion: mutationVersion, call: call)
        }
        guard isConnectionCurrent(),
              isCurrent(key: key, mutationVersion: mutationVersion, desiredEnabled: true) else {
            return
        }
        publishConvergedPhase(savedHostID: key)
    }

    private func unregisterLocked(
        savedHostID: String,
        session: String,
        mutationVersion: UInt64,
        desiredEnabled: Bool,
        call: @escaping HelperCaller,
        permissionDenied: Bool,
        isConnectionCurrent: @escaping @MainActor @Sendable () -> Bool = { true }
    ) async -> Bool {
        let key = savedHostID.lowercased()
        guard isConnectionCurrent(),
              isCurrent(
                key: key, mutationVersion: mutationVersion,
                desiredEnabled: desiredEnabled) else { return false }
        let request = NotificationHelperRequest.routeOperation(
            .unregisterRoute, deviceID: settings.deviceID,
            savedHostID: savedHostID, session: session)
        do {
            let response = try await call(request)
            guard isConnectionCurrent(),
                  isCurrent(
                    key: key, mutationVersion: mutationVersion,
                    desiredEnabled: desiredEnabled) else { return false }
            guard response.ok || response.code == "route_not_found" else {
                if permissionDenied {
                    settings.update(savedHostID: key) {
                        $0.phase = .permissionDenied
                        $0.detail = "iOS permission is denied; removing the Mac route is still pending."
                    }
                } else {
                    applyFailure(response, savedHostID: key,
                                 fallback: "Disable is pending; the Mac may still send alerts.")
                }
                return false
            }
            settings.update(savedHostID: key) {
                $0.appliedEnabled = false
                $0.appliedPreferences = nil
                $0.appliedMutedWorkspaceIDs = []
                $0.phase = permissionDenied ? .permissionDenied : .disabled
                $0.detail = permissionDenied
                    ? "Notifications are denied in iOS Settings; the Mac route was removed."
                    : nil
            }
            return true
        } catch {
            guard isConnectionCurrent(),
                  isCurrent(
                    key: key, mutationVersion: mutationVersion,
                    desiredEnabled: desiredEnabled) else { return false }
            if permissionDenied {
                settings.update(savedHostID: key) {
                    $0.phase = .permissionDenied
                    $0.detail = "iOS permission is denied; removing the Mac route is still pending."
                }
            } else {
                applyTransportFailure(
                    error, savedHostID: key,
                    fallback: "Disable is pending; connect to the Mac and retry.")
            }
            return false
        }
    }

    private func applyRemoteStatus(
        _ status: NotificationHelperStatus?,
        savedHostID: String
    ) {
        guard let status else { return }
        settings.update(savedHostID: savedHostID) {
            $0.helperConfigured = status.configured
            $0.appliedEnabled = status.routePresent
            $0.appliedPreferences = status.routePresent ? status.preferences : nil
            $0.appliedMutedWorkspaceIDs = status.routePresent
                ? status.mutedWorkspaceIDs.sorted() : []
        }
    }

    private func publishConvergedPhase(savedHostID: String, fallback: String? = nil) {
        let tokenSyncPending = registrationsNeedingSync.contains(savedHostID.lowercased())
        settings.update(savedHostID: savedHostID) { record in
            guard record.desiredEnabled, record.appliedEnabled,
                  !tokenSyncPending,
                  record.appliedPreferences == record.preferences,
                  Set(record.appliedMutedWorkspaceIDs) == Set(record.mutedWorkspaceIDs) else {
                record.phase = .pendingSync
                record.detail = fallback ?? "Desired notification changes are pending on the Mac."
                return
            }
            if record.helperConfigured == false {
                record.phase = .helperUnconfigured
                record.detail = fallback ?? "Saved on the helper, but APNs credentials are not configured."
            } else {
                record.phase = .enabled
                record.detail = "Connected and enabled."
            }
        }
    }

    private func markTokenSyncPending(savedHostID: String) {
        settings.update(savedHostID: savedHostID) {
            $0.phase = .pendingSync
            $0.detail = "The newest APNs registration is still pending on this Mac."
        }
    }

    private func clearPendingRegistration(key: String, mutationVersion: UInt64) {
        if pendingRegistrations[key]?.mutationVersion == mutationVersion {
            pendingRegistrations[key] = nil
        }
    }

    private func isCurrent(
        key: String,
        mutationVersion: UInt64,
        desiredEnabled: Bool? = nil
    ) -> Bool {
        guard !Task.isCancelled, settings.contains(savedHostID: key) else { return false }
        let record = settings.record(savedHostID: key)
        guard record.mutationVersion == mutationVersion else { return false }
        return desiredEnabled.map { record.desiredEnabled == $0 } ?? true
    }

    private func withRouteLock<T>(
        key: String,
        operation: @escaping @MainActor () async -> T
    ) async -> T {
        let gate = routeGates[key] ?? CompanionNotificationRouteGate()
        routeGates[key] = gate
        await gate.acquire()
        let result = await operation()
        await gate.release()
        return result
    }

    private func applyFailure(
        _ response: NotificationHelperResponse, savedHostID: String, fallback: String
    ) {
        settings.update(savedHostID: savedHostID) {
            switch response.code {
            case "unconfigured", "registered_unconfigured": $0.phase = .helperUnconfigured
            case "route_not_found": $0.phase = .pendingSync
            default: $0.phase = .registrationFailed
            }
            $0.detail = response.message.isEmpty ? fallback : response.message
        }
    }

    private func applyTransportFailure(_ error: Error, savedHostID: String, fallback: String) {
        settings.update(savedHostID: savedHostID) {
            if error as? NotificationHelperTransportError == .helperMissing {
                $0.phase = .helperMissing
                $0.detail = "Install the notification helper on this Mac, then retry."
            } else {
                $0.phase = .pendingSync
                $0.detail = fallback
            }
        }
    }

}

final class CompanionAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
#if DEBUG
        if CompanionNotificationVisualFixture.requested != nil {
            return true
        }
#endif
        let launchNotification = launchOptions?[.remoteNotification] as? [AnyHashable: Any]
        Task { @MainActor in
            await CompanionNotificationController.shared.restoreAPNsRegistrationIfNeeded()
            if let launchNotification {
                CompanionNotificationController.shared.receiveNotification(
                    userInfo: launchNotification)
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            CompanionNotificationController.shared.didRegisterForRemoteNotifications(
                deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            CompanionNotificationController.shared.didFailToRegisterForRemoteNotifications()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            CompanionNotificationController.shared.receiveNotification(
                userInfo: response.notification.request.content.userInfo)
        }
    }
}

struct CompanionNotificationWorkspace: Identifiable, Equatable {
    let id: String
    let label: String
}

struct CompanionNotificationSettingsView: View {
    let savedHostID: String
    let session: String
    let workspaces: [CompanionNotificationWorkspace]
    let call: CompanionNotificationController.HelperCaller
    let refreshOnAppear: Bool

    @ObservedObject private var settings: CompanionNotificationSettingsStore
    private let controller: CompanionNotificationController
    @State private var busy = false

    @MainActor
    init(
        savedHostID: String,
        session: String,
        workspaces: [CompanionNotificationWorkspace],
        call: @escaping CompanionNotificationController.HelperCaller,
        settings: CompanionNotificationSettingsStore? = nil,
        controller: CompanionNotificationController? = nil,
        refreshOnAppear: Bool = true
    ) {
        let settings = settings ?? .shared
        self.savedHostID = savedHostID
        self.session = session
        self.workspaces = workspaces
        self.call = call
        self.controller = controller ?? .shared
        self.refreshOnAppear = refreshOnAppear
        _settings = ObservedObject(wrappedValue: settings)
    }

    private var record: CompanionNotificationHostRecord {
        settings.record(savedHostID: savedHostID)
    }

    var body: some View {
        List {
            Section {
                Toggle("Notifications", isOn: Binding(
                    get: { record.desiredEnabled },
                    set: { enabled in
                        busy = true
                        Task {
                            if enabled {
                                await controller.enable(
                                    savedHostID: savedHostID, session: session, call: call)
                            } else {
                                _ = await controller.disable(
                                    savedHostID: savedHostID, session: session, call: call)
                            }
                            busy = false
                        }
                    }))
                    .disabled(busy)
                Label(statusTitle, systemImage: statusIcon)
                    .font(Typography.app(13))
                    .foregroundStyle(statusColor)
                if let detail = record.detail {
                    Text(detail)
                        .font(Typography.app(12))
                        .foregroundStyle(Palette.textDim)
                }
                if record.phase == .permissionDenied {
                    Button("Open iOS Settings") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
            } header: { Text("DELIVERY") }

            Section("ALERTS") {
                Toggle("Needs your attention", isOn: preferenceBinding(\.needsAttention))
                Toggle("Finished responding", isOn: preferenceBinding(\.finishedResponding))
                Text("Needs your attention is on by default. Finished responding is optional and never claims the task is complete.")
                    .font(Typography.app(11))
                    .foregroundStyle(Palette.textFaint)
            }
            .disabled(!record.desiredEnabled || busy)

            if !workspaces.isEmpty {
                Section("WORKSPACE MUTE") {
                    ForEach(workspaces) { workspace in
                        Toggle(workspace.label, isOn: Binding(
                            get: { record.mutedWorkspaceIDs.contains(workspace.id) },
                            set: { muted in
                                busy = true
                                Task {
                                    await controller.setWorkspaceMuted(
                                        savedHostID: savedHostID, session: session,
                                        workspaceID: workspace.id, muted: muted, call: call)
                                    busy = false
                                }
                            }))
                    }
                }
                .disabled(!record.desiredEnabled || busy)
            }

            Section {
                Button("Send Test Notification") {
                    busy = true
                    Task {
                        await controller.sendTest(
                            savedHostID: savedHostID, session: session, call: call)
                        busy = false
                    }
                }
                .disabled(record.phase != .enabled || busy)
                Text("This asks the Mac helper to send a real APNs push; it is not a local preview.")
                    .font(Typography.app(11))
                    .foregroundStyle(Palette.textFaint)
            }
        }
        .companionScreen()
        .navigationTitle("Notifications")
        .task {
            guard refreshOnAppear else { return }
            await controller.refresh(
                savedHostID: savedHostID, session: session, call: call)
        }
    }

    private func preferenceBinding(
        _ keyPath: WritableKeyPath<NotificationPreferences, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { record.preferences[keyPath: keyPath] },
            set: { value in
                var preferences = record.preferences
                preferences[keyPath: keyPath] = value
                busy = true
                Task {
                    await controller.updatePreferences(
                        savedHostID: savedHostID, session: session,
                        preferences: preferences, call: call)
                    busy = false
                }
            })
    }

    private var statusTitle: String {
        switch record.phase {
        case .disabled: return "Disabled"
        case .requestingPermission: return "Requesting iOS permission…"
        case .awaitingDeviceToken: return "Waiting for APNs registration…"
        case .pendingSync: return "Pending sync"
        case .enabled: return "Connected and enabled"
        case .permissionDenied: return "Permission denied"
        case .registrationFailed: return "Registration failed"
        case .helperMissing: return "Helper missing"
        case .helperUnconfigured: return "Helper not configured"
        case .permissionRequired: return "Permission required"
        }
    }

    private var statusIcon: String {
        record.phase == .enabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        record.phase == .enabled ? Palette.done : Palette.waiting
    }
}

#if DEBUG
/// Deterministic screenshot-only entry point. It does not request permission,
/// register with APNs, contact a helper, or contain a real saved-host route.
struct CompanionNotificationVisualFixture: View {
    enum Mode: String {
        case enabled
        case permissionDenied = "permission-denied"
        case helperMissing = "helper-missing"
    }

    static var requested: Mode? {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--notification-visual-fixture=")
        }) else { return nil }
        return Mode(rawValue: String(argument.dropFirst("--notification-visual-fixture=".count)))
    }

    private static let savedHostID = "60d95eba-73f8-4b46-86e2-d938fc83c40f"
    @ObservedObject private var settings: CompanionNotificationSettingsStore
    private let controller: CompanionNotificationController

    init(mode: Mode) {
        let settings = CompanionNotificationSettingsStore.shared
        self.controller = CompanionNotificationController(
            settings: settings,
            registerForRemoteNotifications: {},
            environmentProvider: { .development })
        _settings = ObservedObject(wrappedValue: settings)
        settings.update(savedHostID: Self.savedHostID) { record in
            record.desiredEnabled = true
            record.preferences = NotificationPreferences(
                needsAttention: true,
                finishedResponding: false)
            record.mutedWorkspaceIDs = mode == .enabled ? ["workspace-docs"] : []
            record.authorization = mode == .permissionDenied ? .denied : .authorized
            record.routingSecret = String(repeating: "a", count: 64)
            record.appliedEnabled = mode == .enabled
            record.appliedPreferences = mode == .enabled ? record.preferences : nil
            record.appliedMutedWorkspaceIDs = mode == .enabled
                ? record.mutedWorkspaceIDs : []
            switch mode {
            case .enabled:
                record.phase = .enabled
                record.detail = "Connected to the helper on Example Mac."
            case .permissionDenied:
                record.phase = .permissionDenied
                record.detail = "Notifications are denied. Enable them in iOS Settings."
            case .helperMissing:
                record.phase = .helperMissing
                record.detail = "Install the notification helper on this Mac, then retry."
            }
        }
    }

    var body: some View {
        NavigationStack {
            CompanionNotificationSettingsView(
                savedHostID: Self.savedHostID,
                session: "default",
                workspaces: [
                    CompanionNotificationWorkspace(id: "workspace-app", label: "Companion App"),
                    CompanionNotificationWorkspace(id: "workspace-docs", label: "Docs & Release"),
                ],
                call: { _ in
                    NotificationHelperResponse(
                        ok: false,
                        code: "fixture",
                        message: "Screenshot fixture does not contact the Mac helper.")
                },
                settings: settings,
                controller: controller,
                refreshOnAppear: false)
        }
        .tint(Palette.accent)
    }
}
#endif
