import XCTest
import HerdrKit
import Security
@testable import HerdrCompanion

@MainActor
final class CompanionConnectionModelTests: XCTestCase {
    func testSlowerFirstHostCannotReplaceNewerSelection() async {
        let slowGate = SuspensionGate()
        let slow = ResponsePlan(
            responses: [Self.topology(name: "slow", paneID: "pane-slow")],
            gatedCall: 1,
            gate: slowGate)
        let fast = ResponsePlan(
            responses: [Self.topology(name: "fast", paneID: "pane-fast")])
        let model = model(plans: ["slow.example": slow, "fast.example": fast])

        let first = Task {
            await model.connect(
                credentials: Self.credentials(host: "slow.example"), label: "Slow")
        }
        await slowGate.waitUntilEntered()

        await model.connect(
            credentials: Self.credentials(host: "fast.example"), label: "Fast")
        await slowGate.release()
        await first.value

        XCTAssertEqual(model.phase, .connected("Fast"))
        XCTAssertEqual(model.agents.map(\.paneID), ["pane-fast"])
        await model.disconnect()
    }

    func testStaleRefreshCannotPublishIntoReplacementHost() async {
        let refreshGate = SuspensionGate()
        let original = ResponsePlan(
            responses: [
                Self.topology(name: "original", paneID: "pane-original"),
                Self.topology(name: "stale", paneID: "pane-stale"),
            ],
            gatedCall: 2,
            gate: refreshGate)
        let replacement = ResponsePlan(
            responses: [Self.topology(name: "replacement", paneID: "pane-replacement")])
        let model = model(plans: [
            "original.example": original,
            "replacement.example": replacement,
        ])

        await model.connect(
            credentials: Self.credentials(host: "original.example"), label: "Original")
        let staleRefresh = Task { await model.refresh() }
        await refreshGate.waitUntilEntered()

        await model.connect(
            credentials: Self.credentials(host: "replacement.example"), label: "Replacement")
        await refreshGate.release()
        _ = await staleRefresh.value

        XCTAssertEqual(model.phase, .connected("Replacement"))
        XCTAssertEqual(model.agents.map(\.paneID), ["pane-replacement"])
        XCTAssertNil(model.message)
        await model.disconnect()
    }

    func testOlderRefreshCannotOverwriteNewerTopologyOnSameHost() async {
        let olderGate = SuspensionGate()
        let plan = ResponsePlan(
            responses: [
                Self.topology(name: "initial", paneID: "pane-initial"),
                Self.topology(name: "older", paneID: "pane-older"),
                Self.topology(name: "newer", paneID: "pane-newer"),
            ],
            gatedCall: 2,
            gate: olderGate)
        let model = model(plans: ["same.example": plan])
        await model.connect(
            credentials: Self.credentials(host: "same.example"), label: "Same")

        let olderRefresh = Task { await model.refresh() }
        await olderGate.waitUntilEntered()
        let newerPublished = await model.refresh()
        await olderGate.release()
        let olderPublished = await olderRefresh.value

        XCTAssertTrue(newerPublished)
        XCTAssertFalse(olderPublished)
        XCTAssertEqual(model.agents.map(\.paneID), ["pane-newer"])
        await model.disconnect()
    }

    func testFailedWorkspaceRefreshRetainsTopologyAndSurfacesConnectionError() async {
        let plan = ResponsePlan(planned: [
            .response(Self.topology(name: "visible", paneID: "pane-visible")),
            .failure(.connectionLost),
        ])
        let model = model(plans: ["refresh.example": plan])
        await model.connect(
            credentials: Self.credentials(host: "refresh.example"), label: "Refresh")

        let refreshed = await model.refresh()

        XCTAssertFalse(refreshed)
        XCTAssertEqual(model.topology?.panes.map(\.paneID), ["pane-visible"])
        XCTAssertNotNil(model.message)
        await model.disconnect()
    }

    func testStructuralEventsAreGlobalAndRefreshRenamesAndNonFocusedCloses() async throws {
        let responses = ResponsePlan(responses: [
            Self.eventTopology(workspaceLabel: "Before", secondaryTab: true),
            Self.eventTopology(workspaceLabel: "Renamed", secondaryTab: true),
            Self.eventTopology(workspaceLabel: "Renamed", secondaryTab: false),
        ])
        let events = EventStreamPlan()
        let model = CompanionConnectionModel { _ in
            CompanionConnectionModel.Connection(
                transport: nil,
                client: HerdrClient(transport: EventingTransport(
                    responses: responses, events: events)),
                close: {})
        }

        await model.connect(
            credentials: Self.credentials(host: "events.example"), label: "Events")
        let request = await events.waitForRequest()
        let data = try XCTUnwrap(request.data(using: .utf8))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try XCTUnwrap(envelope["params"] as? [String: Any])
        let subscriptions = try XCTUnwrap(params["subscriptions"] as? [[String: Any]])
        let byType = Dictionary(
            uniqueKeysWithValues: subscriptions.compactMap { entry in
                (entry["type"] as? String).map { ($0, entry) }
            })
        let structuralTypes: Set<String> = [
            "workspace.renamed", "workspace.moved", "workspace.reordered",
            "workspace.closed", "tab.renamed", "tab.moved", "tab.closed",
        ]
        XCTAssertTrue(structuralTypes.isSubset(of: Set(byType.keys)))
        for type in structuralTypes {
            XCTAssertNil(byType[type]?["pane_id"], "\(type) must remain global")
        }
        XCTAssertEqual(byType["pane.agent_status_changed"]?["pane_id"] as? String, "pane-active")

        await events.emit(
            #"{"event":"workspace.renamed","data":{"type":"workspace_renamed","workspace_id":"workspace","label":"Renamed"}}"#)
        await responses.waitForCallCount(2)
        try await waitUntil { model.topology?.workspaces.first?.label == "Renamed" }

        await events.emit(
            #"{"event":"tab.closed","data":{"type":"tab_closed","workspace_id":"workspace","tab_id":"tab-secondary"}}"#)
        await responses.waitForCallCount(3)
        try await waitUntil { model.topology?.tabs.map(\.tabID) == ["tab-active"] }

        XCTAssertEqual(model.topology?.workspaces.first?.label, "Renamed")
        await model.disconnect()
    }

    func testCancelledConnectCannotPublishAndNextConnectSucceeds() async {
        let delayedGate = SuspensionGate()
        let delayed = ResponsePlan(
            responses: [Self.topology(name: "delayed", paneID: "pane-delayed")],
            gatedCall: 1,
            gate: delayedGate)
        let next = ResponsePlan(
            responses: [Self.topology(name: "next", paneID: "pane-next")])
        let model = model(plans: ["delayed.example": delayed, "next.example": next])

        let connecting = Task {
            await model.connect(
                credentials: Self.credentials(host: "delayed.example"), label: "Delayed")
        }
        await delayedGate.waitUntilEntered()
        await model.disconnect()
        await delayedGate.release()
        await connecting.value

        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertTrue(model.agents.isEmpty)

        await model.connect(
            credentials: Self.credentials(host: "next.example"), label: "Next")
        XCTAssertEqual(model.phase, .connected("Next"))
        XCTAssertEqual(model.agents.map(\.paneID), ["pane-next"])
        await model.disconnect()
    }

    func testOfficialRosterRowAttachesByPublicPaneID() async throws {
        let response = Self.agentList(name: "reviewer", paneID: "public-pane")
        let agent = try await HerdrClient(
            transport: PlannedTransport(plan: ResponsePlan(responses: [response])))
            .agentList().first

        XCTAssertEqual(agent?.terminalID, "terminal-observation-id")
        XCTAssertEqual(agent.flatMap(CompanionTerminalScreen.attachmentTarget), "public-pane")
        XCTAssertEqual(
            CompanionRemoteScrollEncoder.sgrWheel(.up, column: 4, row: 9),
            Array("\u{1b}[<64;4;9M".utf8))
        XCTAssertEqual(
            CompanionRemoteScrollEncoder.sgrWheel(.down, column: 4, row: 9),
            Array("\u{1b}[<65;4;9M".utf8))
    }

    func testPlainAndAgentTopologyChooseDistinctAttachmentTargets() async throws {
        let response = Self.topology(name: "reviewer", paneID: "agent-pane", includePlain: true)
        let topology = try await HerdrClient(
            transport: PlannedTransport(plan: ResponsePlan(responses: [response])))
            .sessionTopology()

        let plain = try XCTUnwrap(topology.panes.first { !$0.isAgent })
        let agent = try XCTUnwrap(topology.panes.first { $0.isAgent })
        XCTAssertEqual(
            CompanionTerminalDestination(pane: plain)?.target,
            .terminal(terminalID: "terminal-plain"))
        XCTAssertEqual(
            CompanionTerminalDestination(pane: agent)?.target,
            .agent(paneID: "agent-pane"))
    }

    func testRepeatedCreateTapStartsOnlyOneMutationAndChecksReturnedCWD() async throws {
        let gate = SuspensionGate()
        let plan = ResponsePlan(
            responses: [
                Self.topology(name: "original", paneID: "pane-original"),
                Self.workspaceCreated(paneID: "new-pane", terminalID: "new-terminal", cwd: "/requested"),
                Self.topology(
                    name: "original", paneID: "pane-original", includePlain: true,
                    plainPaneID: "new-pane", plainTerminalID: "new-terminal",
                    plainCWD: "/actual"),
            ],
            gatedCall: 2,
            gate: gate)
        let model = model(plans: ["create.example": plan])
        await model.connect(
            credentials: Self.credentials(host: "create.example"), label: "Create")

        let first = Task {
            await model.createWorkspace(label: "Phone", cwd: "/requested")
        }
        await gate.waitUntilEntered()
        let duplicate = await model.createWorkspace(label: "Duplicate", cwd: "/requested")
        XCTAssertNil(duplicate)
        await gate.release()
        let firstValue = await first.value
        let created = try XCTUnwrap(firstValue)

        XCTAssertEqual(created.target, .terminal(terminalID: "new-terminal"))
        XCTAssertTrue(created.notice?.contains("/actual") == true)
        XCTAssertTrue(model.topologyMessage?.contains("/requested") == true)
        let callCount = await plan.callCount()
        XCTAssertEqual(callCount, 3)
        await model.disconnect()
    }

    func testKnownCreateFailureIsRetryableAndDoesNotClaimPossibleSuccess() async {
        let plan = ResponsePlan(responses: [
            Self.topology(name: "original", paneID: "pane-original"),
            #"{"id":"test","error":{"code":"workspace_create_failed","message":"folder is inaccessible"}}"#,
        ])
        let model = model(plans: ["known.example": plan])
        await model.connect(
            credentials: Self.credentials(host: "known.example"), label: "Known")

        let created = await model.createWorkspace(label: "Phone", cwd: "/denied")

        XCTAssertNil(created)
        XCTAssertFalse(model.mutationOutcomeUnknown)
        XCTAssertEqual(model.topologyMessage, "Herdr did not create it: folder is inaccessible")
        let callCount = await plan.callCount()
        XCTAssertEqual(callCount, 2)
        await model.disconnect()
    }

    func testConfirmedCreateWithFailedRefreshDoesNotClaimCWDWasVerified() async throws {
        let plan = ResponsePlan(planned: [
            .response(Self.topology(name: "original", paneID: "pane-original")),
            .response(Self.workspaceCreated(
                paneID: "new-pane", terminalID: "new-terminal", cwd: "/requested")),
            .failure(.connectionLost),
        ])
        let model = model(plans: ["refresh-failure.example": plan])
        await model.connect(
            credentials: Self.credentials(host: "refresh-failure.example"),
            label: "Refresh failure")

        let result = await model.createWorkspace(label: "Phone", cwd: "/requested")
        let created = try XCTUnwrap(result)

        XCTAssertEqual(created.target, .terminal(terminalID: "new-terminal"))
        XCTAssertTrue(created.notice?.contains("could not refresh") == true)
        XCTAssertTrue(model.topologyMessage?.contains("could not refresh") == true)
        XCTAssertFalse(model.mutationOutcomeUnknown)
        let callCount = await plan.callCount()
        XCTAssertEqual(callCount, 3)
        await model.disconnect()
    }

    func testUnknownCreateOutcomeRefreshesOnceAndRequiresReview() async {
        let plan = ResponsePlan(planned: [
            .response(Self.topology(name: "original", paneID: "pane-original")),
            .failure(.connectionLost),
            .response(Self.topology(name: "original", paneID: "pane-original", includePlain: true)),
        ])
        let model = model(plans: ["unknown.example": plan])
        await model.connect(
            credentials: Self.credentials(host: "unknown.example"), label: "Unknown")

        let created = await model.createWorkspace(label: "Maybe", cwd: nil)

        XCTAssertNil(created)
        XCTAssertTrue(model.mutationOutcomeUnknown)
        XCTAssertTrue(model.topologyMessage?.contains("may have been created") == true)
        let callCount = await plan.callCount()
        XCTAssertEqual(callCount, 3, "recovery refetch must not retry the mutation")
        await model.disconnect()
    }

    func testTokenCallbackConvergesDuringNormalSavedHostConnect() async throws {
        let suite = "hc-companion-test-connect-notification-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = Self.savedHost(host: "notification-connect.example")
        let settings = CompanionNotificationSettingsStore(defaults: defaults)
        settings.update(savedHostID: saved.id.uuidString) {
            $0.desiredEnabled = true
            $0.appliedEnabled = true
            $0.appliedPreferences = $0.preferences
            $0.authorization = .authorized
            $0.routingSecret = Self.notificationRoutingSecret
            $0.phase = .enabled
        }
        let controller = CompanionNotificationController(
            settings: settings, registerForRemoteNotifications: {},
            authorizationStatus: { .authorized },
            environmentProvider: { .development })
        controller.didRegisterForRemoteNotifications(
            deviceToken: Data(repeating: 0xd1, count: 32))
        let notifications = ConnectionNotificationRecorder()
        let plan = ResponsePlan(responses: [
            Self.topology(name: "connect", paneID: "pane-connect"),
        ])
        let model = CompanionConnectionModel(
            connectionFactory: { _ in
                CompanionConnectionModel.Connection(
                    transport: nil,
                    client: HerdrClient(transport: PlannedTransport(plan: plan)),
                    notificationCall: { await notifications.handle($0) },
                    close: {})
            },
            savedCredentialsProvider: { Self.credentials(host: $0.host) },
            notificationController: controller)

        await model.connect(saved)

        let operations = await notifications.operations
        XCTAssertEqual(operations, [.status, .register])
        XCTAssertEqual(settings.record(savedHostID: saved.id.uuidString).phase, .enabled)
        await model.disconnect()
    }

    func testNewTokenDuringNormalConnectStatusRegistersOnlyNewestToken() async throws {
        let suite = "hc-companion-test-connect-token-interleave-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = Self.savedHost(host: "notification-status-gate.example")
        let settings = CompanionNotificationSettingsStore(defaults: defaults)
        settings.update(savedHostID: saved.id.uuidString) {
            $0.desiredEnabled = true
            $0.appliedEnabled = true
            $0.appliedPreferences = $0.preferences
            $0.authorization = .authorized
            $0.routingSecret = Self.notificationRoutingSecret
            $0.phase = .enabled
        }
        let controller = CompanionNotificationController(
            settings: settings, registerForRemoteNotifications: {},
            authorizationStatus: { .authorized },
            environmentProvider: { .development })
        controller.didRegisterForRemoteNotifications(
            deviceToken: Data(repeating: 0xe1, count: 32))
        let gate = SuspensionGate()
        let notifications = GatedConnectionNotificationRecorder(
            gatedOperation: .status, gate: gate)
        let plan = ResponsePlan(responses: [
            Self.topology(name: "status-gated", paneID: "pane-status-gated"),
        ])
        let model = CompanionConnectionModel(
            connectionFactory: { _ in
                CompanionConnectionModel.Connection(
                    transport: nil,
                    client: HerdrClient(transport: PlannedTransport(plan: plan)),
                    notificationCall: { await notifications.handle($0) },
                    close: {})
            },
            savedCredentialsProvider: { Self.credentials(host: $0.host) },
            notificationController: controller)

        let connecting = Task { await model.connect(saved) }
        await gate.waitUntilEntered()
        controller.didRegisterForRemoteNotifications(
            deviceToken: Data(repeating: 0xe2, count: 32))
        XCTAssertEqual(settings.record(savedHostID: saved.id.uuidString).phase, .pendingSync)
        await gate.release()
        await connecting.value

        let operations = await notifications.operations
        let registrationTokens = await notifications.registrationTokens
        XCTAssertEqual(operations, [.status, .register])
        XCTAssertEqual(
            registrationTokens,
            [String(repeating: "e2", count: 32)],
            "the status suspension must not leave the captured older token registered")
        XCTAssertEqual(settings.record(savedHostID: saved.id.uuidString).phase, .enabled)
        await model.disconnect()
    }

    func testTokenCallbackConvergesOnForegroundWithoutOpeningSettings() async throws {
        let suite = "hc-companion-test-foreground-notification-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = Self.savedHost(host: "notification-foreground.example")
        let settings = CompanionNotificationSettingsStore(defaults: defaults)
        let controller = CompanionNotificationController(
            settings: settings, registerForRemoteNotifications: {},
            authorizationStatus: { .authorized },
            environmentProvider: { .development })
        let notifications = ConnectionNotificationRecorder()
        let plan = ResponsePlan(responses: [
            Self.topology(name: "initial", paneID: "pane-initial"),
            Self.topology(name: "foreground", paneID: "pane-foreground"),
        ])
        let model = CompanionConnectionModel(
            connectionFactory: { _ in
                CompanionConnectionModel.Connection(
                    transport: nil,
                    client: HerdrClient(transport: PlannedTransport(plan: plan)),
                    notificationCall: { await notifications.handle($0) },
                    close: {})
            },
            savedCredentialsProvider: { Self.credentials(host: $0.host) },
            notificationController: controller)
        await model.connect(saved)

        settings.update(savedHostID: saved.id.uuidString) {
            $0.desiredEnabled = true
            $0.appliedEnabled = true
            $0.appliedPreferences = $0.preferences
            $0.authorization = .authorized
            $0.routingSecret = Self.notificationRoutingSecret
            $0.phase = .enabled
        }
        controller.didRegisterForRemoteNotifications(
            deviceToken: Data(repeating: 0xd2, count: 32))
        await model.becameActive()

        let operations = await notifications.operations
        XCTAssertEqual(operations, [.status, .register])
        XCTAssertEqual(model.agents.map(\.paneID), ["pane-foreground"])
        XCTAssertEqual(settings.record(savedHostID: saved.id.uuidString).phase, .enabled)
        await model.disconnect()
    }

    func testNewTokenDuringForegroundRegisterStaysArmedAndConvergesUnderRouteGate() async throws {
        let suite = "hc-companion-test-foreground-token-interleave-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = Self.savedHost(host: "notification-register-gate.example")
        let settings = CompanionNotificationSettingsStore(defaults: defaults)
        let controller = CompanionNotificationController(
            settings: settings, registerForRemoteNotifications: {},
            authorizationStatus: { .authorized },
            environmentProvider: { .development })
        let gate = SuspensionGate()
        let notifications = GatedConnectionNotificationRecorder(
            gatedOperation: .register, gate: gate)
        let plan = ResponsePlan(responses: [
            Self.topology(name: "initial", paneID: "pane-initial"),
            Self.topology(name: "foreground-a", paneID: "pane-foreground-a"),
            Self.topology(name: "foreground-b", paneID: "pane-foreground-b"),
        ])
        let model = CompanionConnectionModel(
            connectionFactory: { _ in
                CompanionConnectionModel.Connection(
                    transport: nil,
                    client: HerdrClient(transport: PlannedTransport(plan: plan)),
                    notificationCall: { await notifications.handle($0) },
                    close: {})
            },
            savedCredentialsProvider: { Self.credentials(host: $0.host) },
            notificationController: controller)
        await model.connect(saved)
        settings.update(savedHostID: saved.id.uuidString) {
            $0.desiredEnabled = true
            $0.appliedEnabled = true
            $0.appliedPreferences = $0.preferences
            $0.authorization = .authorized
            $0.routingSecret = Self.notificationRoutingSecret
            $0.phase = .enabled
        }
        controller.didRegisterForRemoteNotifications(
            deviceToken: Data(repeating: 0xf1, count: 32))

        let firstForeground = Task { await model.becameActive() }
        await gate.waitUntilEntered()
        controller.didRegisterForRemoteNotifications(
            deviceToken: Data(repeating: 0xf2, count: 32))
        XCTAssertEqual(settings.record(savedHostID: saved.id.uuidString).phase, .pendingSync)
        let laterForeground = Task { await model.becameActive() }
        await Task.yield()
        await gate.release()
        await firstForeground.value
        await laterForeground.value

        let operations = await notifications.operations
        let registrationTokens = await notifications.registrationTokens
        XCTAssertEqual(operations, [.status, .register, .register, .status])
        XCTAssertEqual(
            registrationTokens,
            [String(repeating: "f1", count: 32), String(repeating: "f2", count: 32)])
        XCTAssertEqual(settings.record(savedHostID: saved.id.uuidString).phase, .enabled)
        await model.disconnect()
    }

    func testDeleteSavedHostWaitsForRemoteUnregisterAndRemovesLocalRoute() async throws {
        let suite = "hc-companion-test-delete-notification-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = Self.savedHost(host: "notification-delete.example")
        let settings = CompanionNotificationSettingsStore(defaults: defaults)
        settings.update(savedHostID: saved.id.uuidString) {
            $0.desiredEnabled = true
            $0.appliedEnabled = true
            $0.appliedPreferences = $0.preferences
            $0.authorization = .authorized
            $0.routingSecret = Self.notificationRoutingSecret
            $0.phase = .enabled
        }
        let controller = CompanionNotificationController(
            settings: settings, registerForRemoteNotifications: {},
            authorizationStatus: { .authorized },
            environmentProvider: { .development })
        let notifications = ConnectionNotificationRecorder()
        let plan = ResponsePlan(responses: [
            Self.topology(name: "delete", paneID: "pane-delete"),
        ])
        var deletedHostID: UUID?
        let model = CompanionConnectionModel(
            connectionFactory: { _ in
                CompanionConnectionModel.Connection(
                    transport: nil,
                    client: HerdrClient(transport: PlannedTransport(plan: plan)),
                    notificationCall: { await notifications.handle($0) },
                    close: {})
            },
            savedCredentialsProvider: { Self.credentials(host: $0.host) },
            notificationController: controller,
            savedHostDelete: {
                deletedHostID = $0.id
                return true
            })

        await model.deleteSavedHost(saved)

        let operations = await notifications.operations
        XCTAssertEqual(operations, [.unregisterRoute])
        XCTAssertEqual(deletedHostID, saved.id)
        XCTAssertFalse(settings.contains(savedHostID: saved.id.uuidString))
    }

    func testNotificationRouteReconnectsSavedHostAndOpensExactAgentPane() async throws {
        let saved = Self.savedHost(host: "notified.example")
        let plan = ResponsePlan(responses: [
            Self.topology(name: "notified", paneID: "pane-notified"),
        ])
        let model = notificationModel(plans: ["notified.example": plan])
        let route = Self.notificationRoute(
            savedHostID: saved.id, paneID: "pane-notified",
            terminalID: "terminal-observation-id")

        await model.openNotificationRoute(route, savedHost: saved)

        XCTAssertEqual(model.phase, .connected("Notified Mac"))
        XCTAssertEqual(model.connectedSavedHost?.id, saved.id)
        XCTAssertEqual(
            model.notificationDestination?.target,
            .agent(paneID: "pane-notified"))
        let routeCalls = await plan.callCount()
        XCTAssertEqual(routeCalls, 1)
        await model.disconnect()
    }

    func testProductionPendingPayloadRoutesThroughSavedHostAndFreshSnapshot() async throws {
        let suite = "hc-companion-test-push-navigation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = CompanionNotificationController(
            settings: CompanionNotificationSettingsStore(defaults: defaults),
            registerForRemoteNotifications: {},
            environmentProvider: { .development })
        let saved = Self.savedHost(host: "payload.example")
        let plan = ResponsePlan(responses: [
            Self.topology(name: "payload", paneID: "pane-payload"),
        ])
        let model = notificationModel(plans: ["payload.example": plan])
        let route = Self.notificationRoute(
            savedHostID: saved.id,
            paneID: "pane-payload",
            terminalID: "terminal-observation-id")
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(route))

        controller.receiveNotification(
            userInfo: ["herdr": payload],
            now: Date(timeIntervalSince1970: TimeInterval(route.emittedAtUnixSeconds)))
        await CompanionNotificationNavigation.routePending(
            from: controller,
            savedHosts: [saved],
            model: model)

        XCTAssertNil(controller.pendingRoute)
        XCTAssertEqual(model.connectedSavedHost?.id, saved.id)
        XCTAssertEqual(
            model.notificationDestination?.target,
            .agent(paneID: "pane-payload"))
        await model.disconnect()
    }

    func testNotificationRouteRequiresFreshMatchingTerminalIdentity() async {
        let saved = Self.savedHost(host: "fresh.example")
        let plan = ResponsePlan(responses: [
            Self.topology(
                name: "initial", paneID: "pane-notified",
                agentTerminalID: "terminal-original"),
            Self.topology(
                name: "refreshed", paneID: "pane-notified",
                agentTerminalID: "terminal-replacement"),
        ])
        let model = notificationModel(plans: ["fresh.example": plan])
        await model.connect(
            credentials: Self.credentials(host: saved.host),
            label: saved.label,
            savedHost: saved)

        await model.openNotificationRoute(
            Self.notificationRoute(
                savedHostID: saved.id, paneID: "pane-notified",
                terminalID: "terminal-original"),
            savedHost: saved)

        XCTAssertNil(model.notificationDestination)
        XCTAssertTrue(model.message?.contains("exact terminal") == true)
        let routeCalls = await plan.callCount()
        XCTAssertEqual(routeCalls, 2, "an existing connection must be refreshed")
        await model.disconnect()
    }

    func testNotificationRouteDoesNotAttachToNeighborPane() async {
        let saved = Self.savedHost(host: "neighbor.example")
        let plan = ResponsePlan(responses: [
            Self.topology(
                name: "neighbor", paneID: "agent-pane", includePlain: true,
                plainPaneID: "plain-pane", plainTerminalID: "terminal-plain"),
        ])
        let model = notificationModel(plans: ["neighbor.example": plan])

        await model.openNotificationRoute(
            Self.notificationRoute(
                savedHostID: saved.id, paneID: "missing-pane",
                terminalID: "terminal-plain"),
            savedHost: saved)

        XCTAssertNil(model.notificationDestination)
        XCTAssertTrue(model.message?.contains("exact terminal") == true)
        await model.disconnect()
    }

    func testOldAgentAlertCannotOpenReplacementInSameWorkspacePaneAndTerminal() async {
        let saved = Self.savedHost(host: "replacement-agent.example")
        let plan = ResponsePlan(responses: [
            Self.topology(
                name: "replacement", paneID: "pane-notified",
                agentSessionValue: "agent-session-b"),
        ])
        let model = notificationModel(plans: ["replacement-agent.example": plan])

        await model.openNotificationRoute(
            Self.notificationRoute(
                savedHostID: saved.id, paneID: "pane-notified",
                terminalID: "terminal-observation-id"),
            savedHost: saved)

        XCTAssertNil(model.notificationDestination)
        XCTAssertTrue(model.message?.contains("exact terminal") == true)
        await model.disconnect()
    }

    func testOldAgentAlertCannotOpenLeftoverShellInSameWorkspacePaneAndTerminal() async {
        let saved = Self.savedHost(host: "replacement-shell.example")
        let plan = ResponsePlan(responses: [
            Self.shellTopology(paneID: "pane-notified", terminalID: "terminal-observation-id"),
        ])
        let model = notificationModel(plans: ["replacement-shell.example": plan])

        await model.openNotificationRoute(
            Self.notificationRoute(
                savedHostID: saved.id, paneID: "pane-notified",
                terminalID: "terminal-observation-id"),
            savedHost: saved)

        XCTAssertNil(model.notificationDestination)
        XCTAssertTrue(model.message?.contains("exact terminal") == true)
        await model.disconnect()
    }

    func testManualHostSelectionCancelsInFlightNotificationNavigation() async {
        let gate = SuspensionGate()
        let notified = Self.savedHost(host: "notified.example")
        let notifiedPlan = ResponsePlan(
            responses: [Self.topology(name: "notified", paneID: "pane-notified")],
            gatedCall: 1,
            gate: gate)
        let manualPlan = ResponsePlan(responses: [
            Self.topology(name: "manual", paneID: "pane-manual"),
        ])
        let model = notificationModel(plans: [
            "notified.example": notifiedPlan,
            "manual.example": manualPlan,
        ])
        let opening = Task {
            await model.openNotificationRoute(
                Self.notificationRoute(
                    savedHostID: notified.id, paneID: "pane-notified",
                    terminalID: "terminal-observation-id"),
                savedHost: notified)
        }
        await gate.waitUntilEntered()

        await model.connect(
            credentials: Self.credentials(host: "manual.example"),
            label: "Manual")
        await gate.release()
        await opening.value

        XCTAssertEqual(model.phase, .connected("Manual"))
        XCTAssertEqual(model.agents.map(\.paneID), ["pane-manual"])
        XCTAssertNil(model.notificationDestination)
        await model.disconnect()
    }

    func testLateCreateFromOldHostCannotNavigateOrReplaceNewTopology() async {
        let gate = SuspensionGate()
        let original = ResponsePlan(
            responses: [
                Self.topology(name: "original", paneID: "pane-original"),
                Self.workspaceCreated(paneID: "stale-pane", terminalID: "stale-terminal", cwd: "/tmp"),
            ], gatedCall: 2, gate: gate)
        let replacement = ResponsePlan(
            responses: [Self.topology(name: "replacement", paneID: "pane-replacement")])
        let model = model(plans: [
            "original.example": original,
            "replacement.example": replacement,
        ])
        await model.connect(
            credentials: Self.credentials(host: "original.example"), label: "Original")
        let creating = Task {
            await model.createWorkspace(label: "Stale", cwd: "/tmp")
        }
        await gate.waitUntilEntered()

        await model.connect(
            credentials: Self.credentials(host: "replacement.example"), label: "Replacement")
        await gate.release()
        let staleDestination = await creating.value

        XCTAssertNil(staleDestination)
        XCTAssertEqual(model.phase, .connected("Replacement"))
        XCTAssertEqual(model.agents.map(\.paneID), ["pane-replacement"])
        XCTAssertNil(model.mutationInFlight)
        await model.disconnect()
    }

    func testHostKeyRotationIsExplicitAndCanonicalByEndpoint() {
        let service = "com.elysium.herdrcompanion.tests.\(UUID().uuidString)"
        let policy = CompanionHostKeyPolicy(service: service)
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }

        XCTAssertEqual(policy.evaluate(
            host: "MAC.EXAMPLE.", port: 22, presented: "old-dns"), .trust)
        // Recreating the policy models deleting/re-adding a saved host: the
        // independently stored endpoint pin must remain durable and recoverable.
        let readdedPolicy = CompanionHostKeyPolicy(service: service)
        XCTAssertEqual(readdedPolicy.evaluate(
            host: "mac.example", port: 22, presented: "new-dns"), .reject)
        XCTAssertFalse(readdedPolicy.replacePin(
            host: "mac.example", port: 22,
            expected: "not-the-current-pin", presented: "new-dns"))
        XCTAssertTrue(readdedPolicy.replacePin(
            host: "mac.example", port: 22,
            expected: "old-dns", presented: "new-dns"))
        XCTAssertEqual(readdedPolicy.evaluate(
            host: "MAC.EXAMPLE.", port: 22, presented: "new-dns"), .trust)
        XCTAssertEqual(readdedPolicy.evaluate(
            host: "mac.example", port: 2200, presented: "other-port"), .trust)

        XCTAssertEqual(policy.evaluate(
            host: "2001:0db8:0:0:0:0:0:1", port: 2200, presented: "old-v6"), .trust)
        XCTAssertEqual(policy.evaluate(
            host: "[2001:db8::1]", port: 2200, presented: "new-v6"), .reject)
        XCTAssertTrue(policy.replacePin(
            host: "[2001:db8::1]", port: 2200,
            expected: "old-v6", presented: "new-v6"))
        XCTAssertEqual(policy.evaluate(
            host: "2001:db8::1", port: 2200, presented: "new-v6"), .trust)
    }

    func testCapturedHostKeyRotationSurvivesDismissalAndRejectsAStalePin() async throws {
        let service = "com.elysium.herdrcompanion.tests.\(UUID().uuidString)"
        let policy = CompanionHostKeyPolicy(service: service)
        defer {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
            ] as CFDictionary)
        }
        let credentials = Self.credentials(host: "rotated.example")
        XCTAssertEqual(policy.evaluate(
            host: credentials.host, port: credentials.port, presented: "old"), .trust)

        let plan = HostKeyResponsePlan(
            presented: "new",
            response: Self.topology(name: "rotated", paneID: "pane-rotated"))
        let model = CompanionConnectionModel(connectionFactory: { credentials in
            let transport = HostKeyPlannedTransport(
                credentials: credentials, policy: policy, plan: plan)
            return CompanionConnectionModel.Connection(
                transport: nil,
                client: HerdrClient(transport: transport),
                close: {})
        }, hostKeyPolicy: policy)

        await model.connect(credentials: credentials, label: "Rotated")
        let captured = try XCTUnwrap(model.hostKeyRotation)
        model.dismissHostKeyRotation()
        XCTAssertNil(model.hostKeyRotation)

        await model.trustChangedHostKeyAndReconnect(captured)
        XCTAssertEqual(model.phase, .connected("Rotated"))
        XCTAssertEqual(model.agents.map(\.paneID), ["pane-rotated"])
        XCTAssertEqual(policy.pinnedFingerprint(
            host: credentials.host, port: credentials.port), "new")

        await plan.setPresented("newer")
        await model.connect(credentials: credentials, label: "Rotated again")
        let stale = try XCTUnwrap(model.hostKeyRotation)
        XCTAssertTrue(policy.replacePin(
            host: credentials.host, port: credentials.port,
            expected: "new", presented: "competing"))
        model.dismissHostKeyRotation()
        let attemptsBeforeConfirmation = await plan.calls

        await model.trustChangedHostKeyAndReconnect(stale)

        let attemptsAfterConfirmation = await plan.calls
        XCTAssertEqual(attemptsAfterConfirmation, attemptsBeforeConfirmation,
                       "a stale confirmation must not start a reconnect")
        XCTAssertEqual(model.phase, .disconnected)
        XCTAssertNil(model.hostKeyRotation)
        XCTAssertEqual(policy.pinnedFingerprint(
            host: credentials.host, port: credentials.port), "competing")
        XCTAssertTrue(model.message?.contains("changed again") == true)
    }

    private func model(plans: [String: ResponsePlan]) -> CompanionConnectionModel {
        CompanionConnectionModel { credentials in
            let transport = PlannedTransport(plan: plans[credentials.host]!)
            return CompanionConnectionModel.Connection(
                transport: nil,
                client: HerdrClient(transport: transport),
                close: {})
        }
    }

    private func notificationModel(plans: [String: ResponsePlan]) -> CompanionConnectionModel {
        CompanionConnectionModel(
            connectionFactory: { credentials in
                let transport = PlannedTransport(plan: plans[credentials.host]!)
                return CompanionConnectionModel.Connection(
                    transport: nil,
                    client: HerdrClient(transport: transport),
                    close: {})
            },
            savedCredentialsProvider: { Self.credentials(host: $0.host) },
            notificationRoutingSecret: { _ in Self.notificationRoutingSecret })
    }

    private static func credentials(host: String) -> SSHCredentials {
        SSHCredentials(
            host: host,
            username: "fixture",
            password: "fixture",
            remoteSocketPath: ".config/herdr/sessions/fixture/herdr.sock",
            herdrSession: "fixture")
    }

    private static func savedHost(host: String) -> SavedHost {
        SavedHost(
            id: UUID(), host: host, username: "fixture",
            nickname: "Notified Mac", authKind: .password, session: "fixture")
    }

    private static func notificationRoute(
        savedHostID: UUID,
        paneID: String,
        terminalID: String
    ) -> CompanionNotificationRoute {
        let binding = NotificationAgentBinding.routeBinding(
            for: Self.agentSession(), routingSecret: Self.notificationRoutingSecret)!
        return CompanionNotificationRoute(
            kind: .needsAttention,
            savedHostID: savedHostID.uuidString,
            workspaceID: "workspace",
            paneID: paneID,
            terminalID: terminalID,
            agentInstanceBinding: binding,
            stateChangeSequence: 4,
            emittedAtUnixSeconds: UInt64(Date().timeIntervalSince1970))
    }

    private static let notificationRoutingSecret = String(repeating: "a", count: 64)

    private static func agentSession(value: String = "agent-session-a") -> AgentSessionInfo {
        AgentSessionInfo(
            source: "herdr:codex", agent: "codex", kind: "id", value: value)
    }

    private static func agentList(
        name: String,
        paneID: String,
        terminalID: String = "terminal-observation-id",
        agentSessionValue: String = "agent-session-a"
    ) -> String {
        """
        {"id":"test","result":{"type":"agent_list","agents":[{"terminal_id":"\(terminalID)","name":"\(name)","agent":"codex","title":"codex","terminal_title":"Codex","terminal_title_stripped":"Codex","display_agent":"Codex","agent_status":"working","agent_session":{"source":"herdr:codex","agent":"codex","kind":"id","value":"\(agentSessionValue)"},"workspace_id":"workspace","tab_id":"tab","pane_id":"\(paneID)","focused":true,"interactive_ready":true,"state_change_seq":1,"cwd":"/tmp","foreground_cwd":"/tmp","revision":1}]}}
        """
    }

    private static func topology(
        name: String,
        paneID: String,
        includePlain: Bool = false,
        agentTerminalID: String = "terminal-observation-id",
        plainPaneID: String = "plain-pane",
        plainTerminalID: String = "terminal-plain",
        plainCWD: String = "/tmp/plain folder",
        agentSessionValue: String = "agent-session-a"
    ) -> String {
        let agentPane = """
        {"pane_id":"\(paneID)","terminal_id":"\(agentTerminalID)","workspace_id":"workspace","tab_id":"tab","focused":true,"cwd":"/tmp","foreground_cwd":"/tmp","agent":"codex","display_agent":"Codex","agent_status":"working","revision":1}
        """
        let plainPane = """
        ,{"pane_id":"\(plainPaneID)","terminal_id":"\(plainTerminalID)","workspace_id":"workspace","tab_id":"tab","focused":false,"cwd":"\(plainCWD)","foreground_cwd":"\(plainCWD)","label":"Plain shell","agent_status":"unknown","revision":1}
        """
        let agent = agentList(
            name: name, paneID: paneID, terminalID: agentTerminalID,
            agentSessionValue: agentSessionValue)
            .replacingOccurrences(of: #"{"id":"test","result":{"type":"agent_list","agents":"#, with: "")
            .dropLast(2)
        return """
        {"id":"test","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"workspace","focused_tab_id":"tab","focused_pane_id":"\(paneID)","workspaces":[{"workspace_id":"workspace","number":1,"label":"Workspace","focused":true,"pane_count":\(includePlain ? 2 : 1),"tab_count":1,"active_tab_id":"tab","agent_status":"working"}],"tabs":[{"tab_id":"tab","workspace_id":"workspace","number":1,"label":"Main","focused":true,"pane_count":\(includePlain ? 2 : 1),"agent_status":"working"}],"panes":[\(agentPane)\(includePlain ? plainPane : "")],"layouts":[],"agents":\(agent)}}}
        """
    }

    private static func shellTopology(paneID: String, terminalID: String) -> String {
        """
        {"id":"test","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"workspace","focused_tab_id":"tab","focused_pane_id":"\(paneID)","workspaces":[{"workspace_id":"workspace","number":1,"label":"Workspace","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"tab","agent_status":"unknown"}],"tabs":[{"tab_id":"tab","workspace_id":"workspace","number":1,"label":"Main","focused":true,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"\(paneID)","terminal_id":"\(terminalID)","workspace_id":"workspace","tab_id":"tab","focused":true,"cwd":"/tmp","foreground_cwd":"/tmp","label":"Shell","agent_status":"unknown","revision":1}],"layouts":[],"agents":[]}}}
        """
    }

    private static func workspaceCreated(
        paneID: String, terminalID: String, cwd: String
    ) -> String {
        """
        {"id":"test","result":{"type":"workspace_created","workspace":{"workspace_id":"new-workspace","number":2,"label":"Phone","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"new-tab","agent_status":"unknown"},"tab":{"tab_id":"new-tab","workspace_id":"new-workspace","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"pane_id":"\(paneID)","terminal_id":"\(terminalID)","workspace_id":"new-workspace","tab_id":"new-tab","focused":false,"cwd":"\(cwd)","foreground_cwd":"\(cwd)","agent_status":"unknown","revision":0}}}
        """
    }

    private static func eventTopology(workspaceLabel: String, secondaryTab: Bool) -> String {
        let secondTab = secondaryTab
            ? #",{"tab_id":"tab-secondary","workspace_id":"workspace","number":2,"label":"Secondary","focused":false,"pane_count":1,"agent_status":"unknown"}"#
            : ""
        let secondPane = secondaryTab
            ? #",{"pane_id":"pane-secondary","terminal_id":"terminal-secondary","workspace_id":"workspace","tab_id":"tab-secondary","focused":false,"cwd":"/tmp","foreground_cwd":"/tmp","agent_status":"unknown","revision":1}"#
            : ""
        return """
        {"id":"test","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"workspace","focused_tab_id":"tab-active","focused_pane_id":"pane-active","workspaces":[{"workspace_id":"workspace","number":1,"label":"\(workspaceLabel)","focused":true,"pane_count":\(secondaryTab ? 2 : 1),"tab_count":\(secondaryTab ? 2 : 1),"active_tab_id":"tab-active","agent_status":"working"}],"tabs":[{"tab_id":"tab-active","workspace_id":"workspace","number":1,"label":"Active","focused":true,"pane_count":1,"agent_status":"working"}\(secondTab)],"panes":[{"pane_id":"pane-active","terminal_id":"terminal-active","workspace_id":"workspace","tab_id":"tab-active","focused":true,"cwd":"/tmp","foreground_cwd":"/tmp","agent":"codex","display_agent":"Codex","agent_status":"working","revision":1}\(secondPane)],"layouts":[],"agents":[{"terminal_id":"terminal-active","name":"worker","agent":"codex","title":"codex","terminal_title":"Codex","terminal_title_stripped":"Codex","display_agent":"Codex","agent_status":"working","workspace_id":"workspace","tab_id":"tab-active","pane_id":"pane-active","focused":true,"interactive_ready":true,"state_change_seq":1,"cwd":"/tmp","foreground_cwd":"/tmp","revision":1}]}}}
        """
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for connection-model state")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor ConnectionNotificationRecorder {
    private(set) var operations: [NotificationHelperOperation] = []

    func handle(_ request: NotificationHelperRequest) -> NotificationHelperResponse {
        operations.append(request.operation)
        let present = request.operation != .unregisterRoute
        return NotificationHelperResponse(
            ok: true, code: "ready", message: "ready",
            status: NotificationHelperStatus(
                configured: true, registrationPresent: present,
                routePresent: present,
                preferences: present
                    ? request.registration?.preferences ?? NotificationPreferences()
                    : nil))
    }
}

private actor GatedConnectionNotificationRecorder {
    private let gatedOperation: NotificationHelperOperation
    private let gate: SuspensionGate
    private var didGate = false
    private(set) var operations: [NotificationHelperOperation] = []
    private(set) var registrationTokens: [String] = []

    init(gatedOperation: NotificationHelperOperation, gate: SuspensionGate) {
        self.gatedOperation = gatedOperation
        self.gate = gate
    }

    func handle(_ request: NotificationHelperRequest) async -> NotificationHelperResponse {
        operations.append(request.operation)
        if let token = request.registration?.token { registrationTokens.append(token) }
        if request.operation == gatedOperation, !didGate {
            didGate = true
            await gate.suspend()
        }
        let present = request.operation != .unregisterRoute
        return NotificationHelperResponse(
            ok: true, code: "ready", message: "ready",
            status: NotificationHelperStatus(
                configured: true, registrationPresent: present,
                routePresent: present,
                preferences: present
                    ? request.registration?.preferences ?? NotificationPreferences()
                    : nil))
    }
}

private struct PlannedTransport: HerdrTransport {
    let plan: ResponsePlan

    func roundTrip(_ requestLine: String) async throws -> String {
        try await plan.next(requestLine)
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { _ in }
    }
}

private struct EventingTransport: HerdrTransport {
    let responses: ResponsePlan
    let events: EventStreamPlan

    func roundTrip(_ requestLine: String) async throws -> String {
        try await responses.next(requestLine)
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task { await events.open(request: requestLine, continuation: continuation) }
        }
    }
}

private actor EventStreamPlan {
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var request: String?
    private var requestWaiters: [CheckedContinuation<String, Never>] = []

    func open(
        request: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        self.request = request
        self.continuation = continuation
        let waiting = requestWaiters
        requestWaiters.removeAll()
        waiting.forEach { $0.resume(returning: request) }
    }

    func waitForRequest() async -> String {
        if let request { return request }
        return await withCheckedContinuation { requestWaiters.append($0) }
    }

    func emit(_ line: String) {
        continuation?.yield(line)
    }
}

private struct HostKeyPlannedTransport: HerdrTransport {
    let credentials: SSHCredentials
    let policy: CompanionHostKeyPolicy
    let plan: HostKeyResponsePlan

    func roundTrip(_ requestLine: String) async throws -> String {
        let attempt = await plan.next()
        guard policy.evaluate(
            host: credentials.host,
            port: credentials.port,
            presented: attempt.presented) == .trust
        else {
            throw TransportError.hostKeyRejected(
                host: credentials.host, fingerprint: attempt.presented)
        }
        return attempt.response
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { _ in }
    }
}

private actor HostKeyResponsePlan {
    private var presented: String
    private let response: String
    private(set) var calls = 0

    init(presented: String, response: String) {
        self.presented = presented
        self.response = response
    }

    func setPresented(_ presented: String) { self.presented = presented }

    func next() -> (presented: String, response: String) {
        calls += 1
        return (presented, response)
    }
}

private actor ResponsePlan {
    enum Planned: Sendable {
        case response(String)
        case failure(ResponsePlanError)
    }

    private let responses: [Planned]
    private let gatedCall: Int?
    private let gate: SuspensionGate?
    private var calls = 0
    private var requests: [String] = []
    private var callWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(responses: [String], gatedCall: Int? = nil, gate: SuspensionGate? = nil) {
        self.responses = responses.map(Planned.response)
        self.gatedCall = gatedCall
        self.gate = gate
    }

    init(planned: [Planned], gatedCall: Int? = nil, gate: SuspensionGate? = nil) {
        self.responses = planned
        self.gatedCall = gatedCall
        self.gate = gate
    }

    func next(_ request: String) async throws -> String {
        calls += 1
        requests.append(request)
        let call = calls
        let reached = callWaiters.filter { call >= $0.count }
        callWaiters.removeAll { call >= $0.count }
        reached.forEach { $0.continuation.resume() }
        if call == gatedCall { await gate?.suspend() }
        switch responses[min(call - 1, responses.count - 1)] {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }

    func callCount() -> Int { calls }
    func recordedRequests() -> [String] { requests }

    func waitForCallCount(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }
}

private enum ResponsePlanError: Error, Sendable { case connectionLost }

private actor SuspensionGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        let waiting = entryWaiters
        entryWaiters.removeAll()
        waiting.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        let waiting = releaseWaiters
        releaseWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}
