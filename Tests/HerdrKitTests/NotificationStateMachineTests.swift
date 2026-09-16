import XCTest
@testable import HerdrKit

final class NotificationStateMachineTests: XCTestCase {
    private let now: UInt64 = 1_800_000_000

    func testInitialSnapshotSeedsWithoutFloodingOldBlockedPane() {
        var engine = NotificationTransitionEngine()
        XCTAssertTrue(engine.ingest(
            [observation(status: "blocked", sequence: 4)],
            reason: .initial, nowUnixSeconds: now).isEmpty)
        XCTAssertTrue(engine.ingest(
            [observation(status: "blocked", sequence: 4)],
            reason: .liveEvent, nowUnixSeconds: now + 1).isEmpty)
    }

    func testWorkingBlockedCoalescesAndLaterCycleNotifiesAgain() {
        var engine = NotificationTransitionEngine()
        _ = engine.ingest([observation(status: "working", sequence: 1)],
                          reason: .initial, nowUnixSeconds: now)

        let first = engine.ingest([observation(status: "blocked", sequence: 2)],
                                  reason: .liveEvent, nowUnixSeconds: now + 1)
        XCTAssertEqual(first.map(\.kind), [.needsAttention])
        XCTAssertTrue(engine.ingest([observation(status: "blocked", sequence: 2)],
                                    reason: .liveEvent, nowUnixSeconds: now + 2).isEmpty)
        _ = engine.ingest([observation(status: "working", sequence: 3)],
                          reason: .liveEvent, nowUnixSeconds: now + 3)
        let second = engine.ingest([observation(status: "blocked", sequence: 4)],
                                   reason: .liveEvent, nowUnixSeconds: now + 4)
        XCTAssertEqual(second.map(\.kind), [.needsAttention])
        XCTAssertNotEqual(first.first?.eventID, second.first?.eventID)
    }

    func testLaterCycleWithoutSequenceNotifiesAgain() {
        var engine = NotificationTransitionEngine()
        _ = engine.ingest([observation(status: "working", sequence: nil)],
                          reason: .initial, nowUnixSeconds: now)
        XCTAssertEqual(engine.ingest(
            [observation(status: "blocked", sequence: nil)],
            reason: .liveEvent, nowUnixSeconds: now + 1).map(\.kind), [.needsAttention])
        _ = engine.ingest([observation(status: "working", sequence: nil)],
                          reason: .liveEvent, nowUnixSeconds: now + 2)
        XCTAssertEqual(engine.ingest(
            [observation(status: "blocked", sequence: nil)],
            reason: .liveEvent, nowUnixSeconds: now + 3).map(\.kind), [.needsAttention])
    }

    func testOutOfOrderSequenceAndPaneMoveCannotCreateFalseTransition() {
        var engine = NotificationTransitionEngine()
        _ = engine.ingest([observation(status: "working", sequence: 5)],
                          reason: .initial, nowUnixSeconds: now)
        XCTAssertTrue(engine.ingest(
            [observation(status: "blocked", sequence: 4)],
            reason: .liveEvent, nowUnixSeconds: now + 1).isEmpty)

        let moved = NotificationAgentObservation(
            session: "default", workspaceID: "w1", paneID: "w1:p2",
            terminalID: "terminal-1", agentInstanceID: instanceA,
            status: "idle", stateChangeSequence: 6)
        XCTAssertTrue(engine.ingest(
            [moved], reason: .liveEvent, nowUnixSeconds: now + 2).isEmpty)
    }

    func testOnlyObservedLiveWorkingEndProducesFinishedResponding() {
        var engine = NotificationTransitionEngine()
        _ = engine.ingest([observation(status: "working", sequence: 1)],
                          reason: .initial, nowUnixSeconds: now)
        XCTAssertEqual(engine.ingest(
            [observation(status: "idle", sequence: 2)],
            reason: .liveEvent, nowUnixSeconds: now + 1).map(\.kind), [.finishedResponding])

        for prior in [nil, "unknown", "blocked", "done", "idle"] {
            var candidate = NotificationTransitionEngine()
            _ = candidate.ingest([observation(status: prior, sequence: 1)],
                                 reason: .initial, nowUnixSeconds: now)
            XCTAssertTrue(candidate.ingest(
                [observation(status: "idle", sequence: 2)],
                reason: .liveEvent, nowUnixSeconds: now + 1).isEmpty,
                "\(prior ?? "missing") must not masquerade as completion")
        }
    }

    func testReconnectSuppressesFinishedButCanSurfaceNewPositiveBlockedState() {
        var engine = NotificationTransitionEngine()
        _ = engine.ingest([observation(status: "working", sequence: 1)],
                          reason: .initial, nowUnixSeconds: now)
        XCTAssertTrue(engine.ingest(
            [observation(status: "done", sequence: 2)],
            reason: .reconnect, nowUnixSeconds: now + 10).isEmpty)

        _ = engine.ingest([observation(status: "working", sequence: 3)],
                          reason: .liveEvent, nowUnixSeconds: now + 11)
        XCTAssertEqual(engine.ingest(
            [observation(status: "blocked", sequence: 4)],
            reason: .reconnect, nowUnixSeconds: now + 20).map(\.kind), [.needsAttention])
    }

    func testPaneReuseOrMissingAgentCannotFinishOldTerminal() {
        var engine = NotificationTransitionEngine()
        _ = engine.ingest([observation(status: "working", sequence: 1, terminal: "terminal-old")],
                          reason: .initial, nowUnixSeconds: now)
        XCTAssertTrue(engine.ingest([], reason: .liveEvent, nowUnixSeconds: now + 1).isEmpty)
        XCTAssertTrue(engine.ingest(
            [observation(status: "idle", sequence: 2, terminal: "terminal-new")],
            reason: .liveEvent, nowUnixSeconds: now + 2).isEmpty)
    }

    func testSameTerminalReplacementSeedsIdleAndSequenceResetThenTracksNewCycle() {
        var engine = NotificationTransitionEngine()
        _ = engine.ingest(
            [observation(status: "working", sequence: 99, instance: instanceA)],
            snapshotSession: "default", reason: .initial, nowUnixSeconds: now)
        XCTAssertTrue(engine.ingest(
            [], snapshotSession: "default", reason: .liveEvent,
            nowUnixSeconds: now + 1).isEmpty)

        let replacementIdle = observation(
            status: "idle", sequence: 1, instance: instanceB)
        XCTAssertTrue(engine.ingest(
            [replacementIdle], snapshotSession: "default", reason: .liveEvent,
            nowUnixSeconds: now + 2).isEmpty,
            "replacement B must seed despite reusing A's workspace/pane/terminal and resetting sequence")
        XCTAssertEqual(engine.ingest(
            [observation(status: "blocked", sequence: 2, instance: instanceB)],
            snapshotSession: "default", reason: .liveEvent,
            nowUnixSeconds: now + 3).map(\.kind), [.needsAttention])
    }

    func testSameTerminalReplacementInitiallyBlockedSeedsWithoutFalseAttention() {
        var engine = NotificationTransitionEngine()
        _ = engine.ingest(
            [observation(status: "working", sequence: 8, instance: instanceA)],
            snapshotSession: "default", reason: .initial, nowUnixSeconds: now)
        _ = engine.ingest(
            [], snapshotSession: "default", reason: .liveEvent,
            nowUnixSeconds: now + 1)

        XCTAssertTrue(engine.ingest(
            [observation(status: "blocked", sequence: 1, instance: instanceB)],
            snapshotSession: "default", reason: .liveEvent,
            nowUnixSeconds: now + 2).isEmpty)
    }

    func testAgentSessionPathIsDecodedButNeverPersistedRaw() throws {
        let privatePath = "/Users/fixture/.codex/sessions/private-transcript.jsonl"
        let json = """
        {"terminal_id":"terminal-1","name":"worker","agent":"codex",\
        "agent_status":"working","agent_session":{"source":"herdr:codex",\
        "agent":"codex","kind":"path","value":"\(privatePath)"},\
        "workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p1",\
        "focused":false,"state_change_seq":1,"revision":1}
        """
        let agent = try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
        XCTAssertEqual(agent.agentSession?.kind, "path")
        XCTAssertEqual(agent.agentSession?.value, privatePath)
        let observation = try XCTUnwrap(NotificationAgentObservation(
            session: "default", agent: agent,
            installationID: "99207c06-f66e-4c1a-aa57-64eafbb74781"))
        let persisted = String(decoding: try JSONEncoder().encode(observation), as: UTF8.self)
        XCTAssertFalse(persisted.contains(privatePath))
        XCTAssertFalse(persisted.contains("agent_session"))
        XCTAssertTrue(persisted.contains(observation.agentInstanceID))
    }

    func testRouteValidationRejectsStaleAndMalformedPayloads() throws {
        let route = CompanionNotificationRoute(
            kind: .needsAttention, savedHostID: UUID().uuidString,
            workspaceID: "w1", paneID: "w1:p2", terminalID: "terminal-1",
            agentInstanceBinding: instanceA,
            stateChangeSequence: 9, emittedAtUnixSeconds: now)
        XCTAssertNoThrow(try route.validated(nowUnixSeconds: now + 30))
        XCTAssertThrowsError(try route.validated(nowUnixSeconds: now + 901))
        let malformed = CompanionNotificationRoute(
            kind: .needsAttention, savedHostID: UUID().uuidString,
            workspaceID: "w1\nunsafe", paneID: "p", terminalID: "t",
            agentInstanceBinding: instanceA,
            stateChangeSequence: nil, emittedAtUnixSeconds: now)
        XCTAssertThrowsError(try malformed.validated(nowUnixSeconds: now))
    }

    func testRegistrationAndOperationValidationRejectUntrustedFields() throws {
        let registration = NotificationDeviceRegistration(
            deviceID: UUID().uuidString,
            token: String(repeating: "ab", count: 32), environment: .development,
            savedHostID: UUID().uuidString, session: "default",
            routingSecret: routingSecret)
        XCTAssertNoThrow(try registration.validated())
        XCTAssertThrowsError(try NotificationDeviceRegistration(
            deviceID: UUID().uuidString, token: "$(unsafe)", environment: .development,
            savedHostID: UUID().uuidString, session: "../default",
            routingSecret: routingSecret).validated())
        XCTAssertThrowsError(try NotificationHelperRequest(
            operation: .unregisterRoute, registration: registration,
            deviceID: registration.deviceID, savedHostID: registration.savedHostID,
            session: registration.session).validated())
    }

    func testFixedHelperCommandNeverContainsRequestDataOrGeneralShellEntryPoint() {
        let command = CitadelTransport.notificationHelperCommand
        XCTAssertTrue(command.hasSuffix(#"exec "$HELPER" rpc"#))
        XCTAssertTrue(command.contains("Herdr Companion Notifications"))
        XCTAssertTrue(command.contains(CitadelTransport.notificationHelperMissingSentinel))
        XCTAssertFalse(command.contains("$1"))
        XCTAssertFalse(command.contains("sh -c"))
        XCTAssertFalse(command.contains(String(repeating: "ab", count: 32)))
    }

    private func observation(
        status: String?, sequence: UInt64?, terminal: String = "terminal-1",
        instance: String? = nil
    ) -> NotificationAgentObservation {
        NotificationAgentObservation(
            session: "default", workspaceID: "w1", paneID: "w1:p1",
            terminalID: terminal, agentInstanceID: instance ?? instanceA,
            status: status, stateChangeSequence: sequence)
    }

    private var instanceA: String { String(repeating: "a", count: 64) }
    private var instanceB: String { String(repeating: "b", count: 64) }
    private var routingSecret: String { String(repeating: "b", count: 64) }
}
