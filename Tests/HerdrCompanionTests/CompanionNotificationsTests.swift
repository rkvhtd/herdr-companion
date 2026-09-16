import XCTest
import Foundation
import HerdrKit
@testable import HerdrCompanion

@MainActor
final class CompanionNotificationsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "hc-companion-test-notification-ui-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testNeedsAttentionDefaultsOnAndFinishedRespondingDefaultsOff() {
        let store = CompanionNotificationSettingsStore(defaults: defaults)
        let record = store.record(savedHostID: UUID().uuidString)
        XCTAssertTrue(record.preferences.needsAttention)
        XCTAssertFalse(record.preferences.finishedResponding)
        XCTAssertFalse(record.desiredEnabled)
        XCTAssertEqual(record.phase, .disabled)
    }

    func testDeviceIdentityAndPendingStatePersistWithoutToken() {
        let hostID = UUID().uuidString
        let first = CompanionNotificationSettingsStore(defaults: defaults)
        first.update(savedHostID: hostID) {
            $0.desiredEnabled = true
            $0.phase = .pendingSync
            $0.detail = "Mac has not acknowledged this yet."
        }

        let restored = CompanionNotificationSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.deviceID, first.deviceID)
        XCTAssertEqual(restored.record(savedHostID: hostID).phase, .pendingSync)
        XCTAssertTrue(restored.hasRequestedNotifications)
        let encodedDefaults = defaults.dictionaryRepresentation().description.lowercased()
        XCTAssertFalse(encodedDefaults.contains(String(repeating: "ab", count: 32)),
                       "an APNs token fixture must not be persisted by settings")
    }

    func testLaunchRegistrationReflectsCurrentDeniedAuthorization() async {
        let deniedHost = UUID().uuidString
        let helperHost = UUID().uuidString
        let store = CompanionNotificationSettingsStore(defaults: defaults)
        store.update(savedHostID: deniedHost) {
            $0.desiredEnabled = true
            $0.authorization = .denied
            $0.phase = .permissionDenied
            $0.detail = "Enable notifications in iOS Settings."
        }
        store.update(savedHostID: helperHost) {
            $0.desiredEnabled = true
            $0.phase = .helperMissing
            $0.detail = "Install the helper."
        }
        var registrationRequests = 0
        let controller = CompanionNotificationController(
            settings: store,
            registerForRemoteNotifications: { registrationRequests += 1 },
            authorizationStatus: { .denied },
            environmentProvider: { .development })

        await controller.restoreAPNsRegistrationIfNeeded()
        controller.didFailToRegisterForRemoteNotifications()

        XCTAssertEqual(registrationRequests, 0)
        XCTAssertEqual(store.record(savedHostID: deniedHost).authorization, .denied)
        XCTAssertEqual(store.record(savedHostID: helperHost).authorization, .denied)
        XCTAssertEqual(store.record(savedHostID: deniedHost).phase, .permissionDenied)
        XCTAssertEqual(store.record(savedHostID: helperHost).phase, .permissionDenied)
    }

    func testTokenRotationCannotRegisterOrRelabelPermissionDeniedHost() async {
        let deniedHost = UUID().uuidString
        let enabledHost = UUID().uuidString
        let store = CompanionNotificationSettingsStore(defaults: defaults)
        store.update(savedHostID: deniedHost) {
            $0.desiredEnabled = true
            $0.phase = .permissionDenied
            $0.detail = "Enable notifications in iOS Settings."
        }
        store.update(savedHostID: enabledHost) {
            $0.desiredEnabled = true
            $0.phase = .enabled
        }
        let controller = CompanionNotificationController(
            settings: store, registerForRemoteNotifications: {},
            authorizationStatus: { .denied },
            environmentProvider: { .development })

        controller.didRegisterForRemoteNotifications(deviceToken: Data(repeating: 0xcd, count: 32))
        let recorder = NotificationRequestRecorder()
        await controller.refresh(savedHostID: deniedHost, session: "default") {
            await recorder.handle($0)
        }

        let operations = await recorder.operations
        XCTAssertEqual(operations, [.unregisterRoute])
        XCTAssertEqual(store.record(savedHostID: deniedHost).phase, .permissionDenied)
        XCTAssertEqual(store.record(savedHostID: enabledHost).phase, .pendingSync)
    }

    func testTokenCallbackDuringEnableQueuesOtherHostForRotationSync() async {
        let existingHost = UUID().uuidString
        let newHost = UUID().uuidString
        let store = CompanionNotificationSettingsStore(defaults: defaults)
        store.update(savedHostID: existingHost) {
            $0.desiredEnabled = true
            $0.phase = .enabled
        }
        let controller = CompanionNotificationController(
            settings: store,
            registerForRemoteNotifications: {},
            requestAuthorization: { true },
            authorizationStatus: { .authorized },
            environmentProvider: { .development })

        await controller.enable(savedHostID: newHost, session: "default") { _ in
            NotificationHelperResponse(
                ok: true, code: "registered", message: "registered",
                status: NotificationHelperStatus(
                    configured: true, registrationPresent: true, routePresent: true))
        }
        XCTAssertEqual(store.record(savedHostID: newHost).phase, .awaitingDeviceToken)

        controller.didRegisterForRemoteNotifications(
            deviceToken: Data(repeating: 0xef, count: 32))

        XCTAssertEqual(store.record(savedHostID: existingHost).phase, .pendingSync)
    }

    func testNotificationRouteAcceptsFreshOpaqueIdentityAndRejectsStaleOrMalformed() throws {
        let store = CompanionNotificationSettingsStore(defaults: defaults)
        let controller = CompanionNotificationController(
            settings: store, registerForRemoteNotifications: {},
            environmentProvider: { .development })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hostID = UUID().uuidString.lowercased()
        let route = CompanionNotificationRoute(
            kind: .needsAttention, savedHostID: hostID, workspaceID: "w1",
            paneID: "w1:p2", terminalID: "terminal-9",
            agentInstanceBinding: String(repeating: "a", count: 64), stateChangeSequence: 22,
            emittedAtUnixSeconds: 1_800_000_000)

        controller.receiveNotification(userInfo: ["herdr": try object(route)], now: now)
        XCTAssertEqual(controller.consumePendingRoute(), route)

        let stale = CompanionNotificationRoute(
            kind: .needsAttention, savedHostID: hostID, workspaceID: "w1",
            paneID: "w1:p2", terminalID: "terminal-9",
            agentInstanceBinding: String(repeating: "a", count: 64), stateChangeSequence: 22,
            emittedAtUnixSeconds: 1_799_999_000)
        controller.receiveNotification(userInfo: ["herdr": try object(stale)], now: now)
        XCTAssertNil(controller.consumePendingRoute())
        controller.receiveNotification(userInfo: ["herdr": [
            "version": 1, "kind": "needs_attention", "saved_host_id": hostID,
            "workspace_id": "w1", "pane_id": "w1:p2", "terminal_id": "bad\nvalue",
            "agent_instance_binding": String(repeating: "a", count: 64),
            "emitted_at": 1_800_000_000,
        ]], now: now)
        XCTAssertNil(controller.consumePendingRoute())
    }

    func testRestoredAPNsTokenMarksEnabledHostPendingThenRefreshRegistersIt() async {
        let hostID = UUID().uuidString.lowercased()
        let store = CompanionNotificationSettingsStore(defaults: defaults)
        store.update(savedHostID: hostID) {
            $0.desiredEnabled = true
            $0.phase = .enabled
        }
        let controller = CompanionNotificationController(
            settings: store, registerForRemoteNotifications: {},
            authorizationStatus: { .authorized },
            environmentProvider: { .development })
        controller.didRegisterForRemoteNotifications(deviceToken: Data(repeating: 0xab, count: 32))
        XCTAssertEqual(store.record(savedHostID: hostID).phase, .pendingSync)

        let recorder = NotificationRequestRecorder()
        await controller.refresh(savedHostID: hostID, session: "default") {
            await recorder.handle($0)
        }
        let operations = await recorder.operations
        XCTAssertEqual(operations, [.status, .register])
        XCTAssertEqual(store.record(savedHostID: hostID).phase, .enabled)
    }

    func testLateTokenAfterDisableAndDeletionCannotRecreateRoute() async {
        let hostID = UUID().uuidString.lowercased()
        let store = CompanionNotificationSettingsStore(defaults: defaults)
        let recorder = NotificationRequestRecorder()
        let controller = CompanionNotificationController(
            settings: store,
            registerForRemoteNotifications: {},
            requestAuthorization: { true },
            authorizationStatus: { .authorized },
            environmentProvider: { .development })

        await controller.enable(savedHostID: hostID, session: "default") {
            await recorder.handle($0)
        }
        XCTAssertEqual(store.record(savedHostID: hostID).phase, .awaitingDeviceToken)

        let disabled = await controller.disable(savedHostID: hostID, session: "default") {
            await recorder.handle($0)
        }
        XCTAssertTrue(disabled)
        store.remove(savedHostID: hostID)

        controller.didRegisterForRemoteNotifications(
            deviceToken: Data(repeating: 0xa1, count: 32))
        await Task.yield()

        XCTAssertFalse(store.contains(savedHostID: hostID))
        let operations = await recorder.operations
        XCTAssertEqual(operations, [.unregisterRoute])
    }

    func testInFlightRegisterIsCompensatedBeforeDisableCompletes() async {
        let hostID = UUID().uuidString.lowercased()
        let store = CompanionNotificationSettingsStore(defaults: defaults)
        let gate = NotificationTestGate()
        let recorder = GatedNotificationRequestRecorder(gate: gate)
        let controller = CompanionNotificationController(
            settings: store,
            registerForRemoteNotifications: {},
            requestAuthorization: { true },
            authorizationStatus: { .authorized },
            environmentProvider: { .development })
        controller.didRegisterForRemoteNotifications(
            deviceToken: Data(repeating: 0xa2, count: 32))

        let enabling = Task {
            await controller.enable(savedHostID: hostID, session: "default") {
                await recorder.handle($0)
            }
        }
        await gate.waitUntilEntered()
        let disabling = Task {
            await controller.disable(savedHostID: hostID, session: "default") {
                await recorder.handle($0)
            }
        }
        await Task.yield()
        let operationsWhileBlocked = await recorder.operations
        XCTAssertEqual(operationsWhileBlocked, [.register],
                       "unregister must wait behind the in-flight register")

        await gate.release()
        await enabling.value
        let disabled = await disabling.value
        XCTAssertTrue(disabled)

        let operations = await recorder.operations
        XCTAssertEqual(
            operations,
            [.register, .unregisterRoute, .unregisterRoute],
            "the stale register is compensated before the explicit disable")
        let record = store.record(savedHostID: hostID)
        XCTAssertFalse(record.desiredEnabled)
        XCTAssertFalse(record.appliedEnabled)
        XCTAssertEqual(record.phase, .disabled)
    }

    func testOfflinePreferencesAndMuteRemainDesiredAndConvergeOnReopen() async {
        let hostID = UUID().uuidString.lowercased()
        let desiredPreferences = NotificationPreferences(
            needsAttention: false, finishedResponding: true)
        let store = CompanionNotificationSettingsStore(defaults: defaults)
        let controller = CompanionNotificationController(
            settings: store, registerForRemoteNotifications: {},
            authorizationStatus: { .authorized },
            environmentProvider: { .development })
        controller.didRegisterForRemoteNotifications(
            deviceToken: Data(repeating: 0xa3, count: 32))
        store.update(savedHostID: hostID) {
            $0.desiredEnabled = true
            $0.preferences = NotificationPreferences()
            $0.appliedEnabled = true
            $0.appliedPreferences = NotificationPreferences()
            $0.authorization = .authorized
            $0.routingSecret = String(repeating: "a", count: 64)
            $0.phase = .enabled
        }

        await controller.updatePreferences(
            savedHostID: hostID, session: "default",
            preferences: desiredPreferences) { _ in throw NotificationFixtureError.offline }
        await controller.setWorkspaceMuted(
            savedHostID: hostID, session: "default",
            workspaceID: "workspace-1", muted: true
        ) { _ in throw NotificationFixtureError.offline }

        var pending = store.record(savedHostID: hostID)
        XCTAssertEqual(pending.preferences, desiredPreferences)
        XCTAssertEqual(pending.mutedWorkspaceIDs, ["workspace-1"])
        XCTAssertEqual(pending.appliedPreferences, NotificationPreferences())
        XCTAssertEqual(pending.appliedMutedWorkspaceIDs, [])
        XCTAssertEqual(pending.phase, .pendingSync)

        let remote = ConvergingNotificationRequestRecorder()
        await controller.reconcile(savedHostID: hostID, session: "default") {
            await remote.handle($0)
        }

        pending = store.record(savedHostID: hostID)
        let operations = await remote.operations
        XCTAssertEqual(operations, [.status, .setPreferences, .setWorkspaceMuted])
        XCTAssertEqual(pending.preferences, desiredPreferences)
        XCTAssertEqual(pending.appliedPreferences, desiredPreferences)
        XCTAssertEqual(pending.mutedWorkspaceIDs, ["workspace-1"])
        XCTAssertEqual(pending.appliedMutedWorkspaceIDs, ["workspace-1"])
        XCTAssertEqual(pending.phase, .enabled)
    }

    func testOfflineDisableRemainsDesiredAndRetriesOnReopen() async {
        let hostID = UUID().uuidString.lowercased()
        let store = CompanionNotificationSettingsStore(defaults: defaults)
        store.update(savedHostID: hostID) {
            $0.desiredEnabled = true
            $0.appliedEnabled = true
            $0.appliedPreferences = $0.preferences
            $0.authorization = .authorized
            $0.routingSecret = String(repeating: "b", count: 64)
            $0.phase = .enabled
        }
        let controller = CompanionNotificationController(
            settings: store, registerForRemoteNotifications: {},
            authorizationStatus: { .authorized },
            environmentProvider: { .development })

        let first = await controller.disable(
            savedHostID: hostID, session: "default"
        ) { _ in throw NotificationFixtureError.offline }
        XCTAssertFalse(first)
        XCTAssertFalse(store.record(savedHostID: hostID).desiredEnabled)
        XCTAssertTrue(store.record(savedHostID: hostID).appliedEnabled)

        let recorder = NotificationRequestRecorder()
        await controller.reconcile(savedHostID: hostID, session: "default") {
            await recorder.handle($0)
        }

        let operations = await recorder.operations
        XCTAssertEqual(operations, [.unregisterRoute])
        XCTAssertFalse(store.record(savedHostID: hostID).desiredEnabled)
        XCTAssertFalse(store.record(savedHostID: hostID).appliedEnabled)
        XCTAssertEqual(store.record(savedHostID: hostID).phase, .disabled)
    }

    func testExternalPermissionRevokeThenGrantConvergesWithoutPrompting() async {
        let hostID = UUID().uuidString.lowercased()
        let store = CompanionNotificationSettingsStore(defaults: defaults)
        store.update(savedHostID: hostID) {
            $0.desiredEnabled = true
            $0.appliedEnabled = true
            $0.appliedPreferences = $0.preferences
            $0.authorization = .authorized
            $0.routingSecret = String(repeating: "c", count: 64)
            $0.phase = .enabled
        }
        let authorization = NotificationAuthorizationFixture(.denied)
        var apnsRegistrationRequests = 0
        let recorder = NotificationRequestRecorder()
        let controller = CompanionNotificationController(
            settings: store,
            registerForRemoteNotifications: { apnsRegistrationRequests += 1 },
            requestAuthorization: {
                XCTFail("reconciliation must never prompt")
                return false
            },
            authorizationStatus: { await authorization.value },
            environmentProvider: { .development })

        await controller.reconcile(savedHostID: hostID, session: "default") {
            await recorder.handle($0)
        }
        let revokeOperations = await recorder.operations
        XCTAssertEqual(revokeOperations, [.unregisterRoute])
        XCTAssertTrue(store.record(savedHostID: hostID).desiredEnabled)
        XCTAssertFalse(store.record(savedHostID: hostID).appliedEnabled)
        XCTAssertEqual(store.record(savedHostID: hostID).phase, .permissionDenied)

        await authorization.set(.authorized)
        await controller.reconcile(savedHostID: hostID, session: "default") {
            await recorder.handle($0)
        }
        XCTAssertEqual(apnsRegistrationRequests, 1)
        XCTAssertEqual(store.record(savedHostID: hostID).phase, .awaitingDeviceToken)

        controller.didRegisterForRemoteNotifications(
            deviceToken: Data(repeating: 0xa4, count: 32))
        await waitUntil {
            store.record(savedHostID: hostID).phase == .enabled
        }
        let operations = await recorder.operations
        XCTAssertEqual(operations, [.unregisterRoute, .register])
        XCTAssertEqual(store.record(savedHostID: hostID).authorization, .authorized)
        XCTAssertTrue(store.record(savedHostID: hostID).appliedEnabled)
    }

    func testSavedTargetEditGuardBlocksSessionEndpointUserAndEditorRaceBeforeCredentialWrite() throws {
        let services = "hc-companion-target-guard-\(UUID().uuidString)"
        let hosts = SavedHostsStore(
            defaults: defaults,
            credentialService: services + ".key",
            passwordCredentialService: services + ".password")
        XCTAssertTrue(hosts.add(
            nickname: "Old Mac", host: "mac.example", username: "fixture",
            session: "default", secret: .password("old-secret")))
        let editorSnapshot = try XCTUnwrap(hosts.hosts.first)
        defer { _ = hosts.delete(editorSnapshot) }

        // This happens after the editor opened: the update boundary must observe it.
        let settings = CompanionNotificationSettingsStore(defaults: defaults)
        settings.update(savedHostID: editorSnapshot.id.uuidString) {
            $0.desiredEnabled = true
            $0.appliedEnabled = true
            $0.authorization = .authorized
            $0.phase = .enabled
        }

        let changedSession = hosts.update(
            editorSnapshot, nickname: "Old Mac", host: "mac.example", username: "fixture",
            session: "other", secret: .password("must-not-be-written"))
        XCTAssertEqual(changedSession, .notificationRouteMustBeDisabled)
        XCTAssertEqual(hosts.password(for: editorSnapshot), "old-secret")

        for (host, user, session) in [
            ("other.example", "fixture", "default"),
            ("mac.example:2222", "fixture", "default"),
            ("mac.example", "other-user", "default"),
        ] {
            XCTAssertEqual(
                hosts.update(
                    editorSnapshot, nickname: "Old Mac", host: host, username: user,
                    session: session, secret: nil),
                .notificationRouteMustBeDisabled)
        }

        // Even if both booleans have been cleared, a pending phase means removal
        // has not been acknowledged and the old target must remain addressable.
        settings.update(savedHostID: editorSnapshot.id.uuidString) {
            $0.desiredEnabled = false
            $0.appliedEnabled = false
            $0.phase = .pendingSync
        }
        XCTAssertEqual(
            hosts.update(
                editorSnapshot, nickname: "Old Mac", host: "offline.example",
                username: "fixture", session: "default", secret: nil),
            .notificationRouteMustBeDisabled)

        let retained = try XCTUnwrap(hosts.hosts.first)
        XCTAssertEqual(retained.id, editorSnapshot.id)
        XCTAssertEqual(retained.host, "mac.example")
        XCTAssertEqual(retained.username, "fixture")
        XCTAssertEqual(retained.herdrSession, "default")
        XCTAssertEqual(hosts.password(for: retained), "old-secret")
    }

    func testSavedTargetEditGuardAllowsSameTargetNicknameAndCredentialRecovery() throws {
        let services = "hc-companion-target-recovery-\(UUID().uuidString)"
        let hosts = SavedHostsStore(
            defaults: defaults,
            credentialService: services + ".key",
            passwordCredentialService: services + ".password")
        XCTAssertTrue(hosts.add(
            nickname: "Old label", host: "mac.example", username: "fixture",
            session: "default", secret: .password("rotated-old")))
        let saved = try XCTUnwrap(hosts.hosts.first)
        defer { _ = hosts.delete(saved) }
        let settings = CompanionNotificationSettingsStore(defaults: defaults)
        settings.update(savedHostID: saved.id.uuidString) {
            $0.desiredEnabled = true
            $0.appliedEnabled = true
            $0.phase = .enabled
        }

        let result = hosts.update(
            saved, nickname: "Recovered Mac", host: "MAC.EXAMPLE.:22",
            username: " fixture ", session: "default",
            secret: .password("rotated-new"))

        XCTAssertEqual(result, .updated)
        let updated = try XCTUnwrap(hosts.hosts.first)
        XCTAssertEqual(updated.id, saved.id)
        XCTAssertEqual(updated.nickname, "Recovered Mac")
        XCTAssertEqual(updated.host, "MAC.EXAMPLE.:22")
        XCTAssertEqual(updated.username, "fixture")
        XCTAssertEqual(hosts.password(for: updated), "rotated-new")
    }

    func testAcknowledgedDisableAllowsTargetEditAndSubsequentDelete() async throws {
        let services = "hc-companion-target-disabled-\(UUID().uuidString)"
        let hosts = SavedHostsStore(
            defaults: defaults,
            credentialService: services + ".key",
            passwordCredentialService: services + ".password")
        XCTAssertTrue(hosts.add(
            nickname: "Old Mac", host: "old.example", username: "fixture",
            session: "default", secret: .password("old-secret")))
        let saved = try XCTUnwrap(hosts.hosts.first)
        defer {
            if let retained = hosts.hosts.first(where: { $0.id == saved.id }) {
                _ = hosts.delete(retained)
            }
        }
        let settings = CompanionNotificationSettingsStore(defaults: defaults)
        settings.update(savedHostID: saved.id.uuidString) {
            $0.desiredEnabled = true
            $0.appliedEnabled = true
            $0.appliedPreferences = $0.preferences
            $0.authorization = .authorized
            $0.phase = .enabled
        }
        let controller = CompanionNotificationController(
            settings: settings, registerForRemoteNotifications: {},
            authorizationStatus: { .authorized },
            environmentProvider: { .development })

        let disabled = await controller.disable(
            savedHostID: saved.id.uuidString, session: saved.herdrSession
        ) { request in
            XCTAssertEqual(request.operation, .unregisterRoute)
            return NotificationHelperResponse(
                ok: true, code: "unregistered", message: "removed",
                status: NotificationHelperStatus(
                    configured: true, registrationPresent: false, routePresent: false))
        }
        XCTAssertTrue(disabled)
        XCTAssertEqual(settings.record(savedHostID: saved.id.uuidString).phase, .disabled)

        XCTAssertEqual(
            hosts.update(
                saved, nickname: "New Mac", host: "new.example:2222",
                username: "new-user", session: "other",
                secret: .password("new-secret")),
            .updated)
        let updated = try XCTUnwrap(hosts.hosts.first)
        XCTAssertEqual(updated.id, saved.id)
        XCTAssertTrue(hosts.delete(updated))
        XCTAssertTrue(hosts.hosts.isEmpty)
    }

    func testConfigUsesDifferentAPNsEnvironmentsForDebugAndRelease() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(
            contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("Debug:\n          APS_ENVIRONMENT: development"))
        XCTAssertTrue(project.contains("Release:\n          APS_ENVIRONMENT: production"))
        let entitlements = try String(contentsOf: root.appendingPathComponent(
            "App/HerdrCompanion.entitlements"), encoding: .utf8)
        XCTAssertTrue(entitlements.contains("$(APS_ENVIRONMENT)"))
        let info = try String(contentsOf: root.appendingPathComponent(
            "App/Info.plist"), encoding: .utf8)
        XCTAssertTrue(info.contains("HerdrAPNSEnvironment"))
    }

    private func object(_ route: CompanionNotificationRoute) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(route))
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for notification state")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor NotificationRequestRecorder {
    private(set) var operations: [NotificationHelperOperation] = []

    func handle(_ request: NotificationHelperRequest) -> NotificationHelperResponse {
        operations.append(request.operation)
        return NotificationHelperResponse(
            ok: true, code: request.operation == .status ? "ready" : "registered",
            message: "ready",
            status: NotificationHelperStatus(
                configured: true, registrationPresent: true, routePresent: true,
                preferences: NotificationPreferences()))
    }
}

private enum NotificationFixtureError: Error { case offline }

private actor NotificationTestGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor GatedNotificationRequestRecorder {
    private let gate: NotificationTestGate
    private(set) var operations: [NotificationHelperOperation] = []

    init(gate: NotificationTestGate) { self.gate = gate }

    func handle(_ request: NotificationHelperRequest) async -> NotificationHelperResponse {
        operations.append(request.operation)
        if request.operation == .register { await gate.suspend() }
        return NotificationHelperResponse(
            ok: true, code: "ready", message: "ready",
            status: NotificationHelperStatus(
                configured: true, registrationPresent: true,
                routePresent: request.operation != .unregisterRoute,
                preferences: request.registration?.preferences ?? NotificationPreferences()))
    }
}

private actor ConvergingNotificationRequestRecorder {
    private(set) var operations: [NotificationHelperOperation] = []
    private var routePresent = true
    private var preferences = NotificationPreferences()
    private var mutedWorkspaceIDs: [String] = []

    func handle(_ request: NotificationHelperRequest) -> NotificationHelperResponse {
        operations.append(request.operation)
        switch request.operation {
        case .register:
            routePresent = true
            preferences = request.registration?.preferences ?? preferences
        case .setPreferences:
            preferences = request.preferences ?? preferences
        case .setWorkspaceMuted:
            if let workspaceID = request.workspaceID, request.muted == true,
               !mutedWorkspaceIDs.contains(workspaceID) {
                mutedWorkspaceIDs.append(workspaceID)
            } else if let workspaceID = request.workspaceID, request.muted == false {
                mutedWorkspaceIDs.removeAll { $0 == workspaceID }
            }
            mutedWorkspaceIDs.sort()
        case .unregisterRoute:
            routePresent = false
        case .status, .testNotification:
            break
        }
        return NotificationHelperResponse(
            ok: true, code: "ready", message: "ready",
            status: NotificationHelperStatus(
                configured: true, registrationPresent: true,
                routePresent: routePresent,
                preferences: routePresent ? preferences : nil,
                mutedWorkspaceIDs: routePresent ? mutedWorkspaceIDs : []))
    }
}

private actor NotificationAuthorizationFixture {
    private(set) var value: CompanionNotificationAuthorizationState

    init(_ value: CompanionNotificationAuthorizationState) { self.value = value }
    func set(_ value: CompanionNotificationAuthorizationState) { self.value = value }
}
