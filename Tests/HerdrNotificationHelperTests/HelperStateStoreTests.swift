import XCTest
import Foundation
import HerdrKit
@testable import HerdrNotificationHelperCore

final class HelperStateStoreTests: XCTestCase {
    private var root: URL!
    private var store: NotificationHelperStateStore!
    private let now: UInt64 = 1_800_000_000

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-companion-test-notifications-\(UUID().uuidString)")
        store = NotificationHelperStateStore(paths: NotificationHelperPaths(root: root))
        try store.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testRoutesToSameSessionMergeAndDeliverOncePerToken() throws {
        let device = UUID().uuidString
        let token = String(repeating: "ab", count: 32)
        let routeA = UUID().uuidString
        let routeB = UUID().uuidString
        try store.register(registration(device: device, token: token, route: routeA),
                           nowUnixSeconds: now)
        try store.register(registration(device: device, token: token, route: routeB),
                           nowUnixSeconds: now + 1)

        let state = try store.load()
        XCTAssertEqual(state.devices.count, 1)
        XCTAssertEqual(state.devices[0].sessions[0].routes.map(\.savedHostID).sorted(),
                       [routeA.lowercased(), routeB.lowercased()].sorted())
        XCTAssertEqual(state.devices[0].sessions[0].preferredRouteID, routeB.lowercased())
        XCTAssertEqual(try store.destinations(for: event()).count, 1)
    }

    func testDuplicateNetworkRoutesKeepIndependentSettingsAndBindingWhileDeliveringOnce() throws {
        let device = UUID().uuidString
        let token = String(repeating: "ac", count: 32)
        let routeA = UUID().uuidString
        let routeB = UUID().uuidString
        let secretA = String(repeating: "a", count: 64)
        let secretB = String(repeating: "b", count: 64)
        try store.register(registration(
            device: device, token: token, route: routeA, secret: secretA),
            nowUnixSeconds: now)
        try store.register(registration(
            device: device, token: token, route: routeB, secret: secretB),
            nowUnixSeconds: now + 1)

        try store.setPreferences(
            deviceID: device.lowercased(), savedHostID: routeA.lowercased(), session: "default",
            preferences: NotificationPreferences(needsAttention: false, finishedResponding: true))
        try store.setWorkspaceMuted(
            deviceID: device.lowercased(), savedHostID: routeA.lowercased(), session: "default",
            workspaceID: "w1", muted: true)
        let statusA = try store.status(
            deviceID: device.lowercased(), savedHostID: routeA.lowercased(),
            session: "default", configured: true)
        let statusB = try store.status(
            deviceID: device.lowercased(), savedHostID: routeB.lowercased(),
            session: "default", configured: true)
        XCTAssertEqual(statusA.preferences,
                       NotificationPreferences(needsAttention: false, finishedResponding: true))
        XCTAssertEqual(statusA.mutedWorkspaceIDs, ["w1"])
        XCTAssertEqual(statusB.preferences, NotificationPreferences())
        XCTAssertTrue(statusB.mutedWorkspaceIDs.isEmpty)

        try store.setPreferences(
            deviceID: device.lowercased(), savedHostID: routeB.lowercased(), session: "default",
            preferences: NotificationPreferences())
        let destinations = try store.destinations(for: event())
        XCTAssertEqual(destinations.count, 1)
        XCTAssertEqual(destinations[0].savedHostID, routeB.lowercased())
        XCTAssertEqual(destinations[0].agentInstanceBinding,
                       NotificationAgentBinding.routeBinding(
                        for: try XCTUnwrap(event().observation.agentSession),
                        routingSecret: secretB))
    }

    func testSeparateDevicesTokenRotationAndDuplicateTokenScoping() throws {
        let first = UUID().uuidString
        let second = UUID().uuidString
        let route = UUID().uuidString
        let secondRoute = UUID().uuidString
        let oldToken = String(repeating: "aa", count: 32)
        let newToken = String(repeating: "bb", count: 32)
        try store.register(registration(device: first, token: oldToken, route: route),
                           nowUnixSeconds: now)
        try store.register(registration(device: second, token: newToken, route: secondRoute),
                           nowUnixSeconds: now)
        XCTAssertEqual(try store.destinations(for: event()).count, 2)

        try store.register(registration(device: first, token: newToken, route: route),
                           nowUnixSeconds: now + 1)
        let state = try store.load()
        XCTAssertEqual(state.devices.count, 1, "one APNs token must not remain under two device ids")
        XCTAssertEqual(state.devices[0].deviceID, first.lowercased())
        XCTAssertEqual(Set(state.devices[0].sessions[0].routes.map(\.savedHostID)),
                       Set([route.lowercased(), secondRoute.lowercased()]))
    }

    func testPreferencesMuteAndUnregisterActuallyChangeDestinations() throws {
        let device = UUID().uuidString
        let route = UUID().uuidString
        try store.register(registration(device: device, token: String(repeating: "cd", count: 32),
                                        route: route), nowUnixSeconds: now)
        XCTAssertEqual(try store.destinations(for: event()).count, 1)
        try store.setWorkspaceMuted(
            deviceID: device.lowercased(), savedHostID: route.lowercased(), session: "default",
            workspaceID: "w1", muted: true)
        XCTAssertTrue(try store.destinations(for: event()).isEmpty)
        try store.setWorkspaceMuted(
            deviceID: device.lowercased(), savedHostID: route.lowercased(), session: "default",
            workspaceID: "w1", muted: false)
        try store.setPreferences(
            deviceID: device.lowercased(), savedHostID: route.lowercased(), session: "default",
            preferences: NotificationPreferences(needsAttention: false, finishedResponding: true))
        XCTAssertTrue(try store.destinations(for: event()).isEmpty)
        XCTAssertEqual(try store.destinations(for: event(kind: .finishedResponding)).count, 1)
        try store.unregisterRoute(
            deviceID: device.lowercased(), savedHostID: route.lowercased(), session: "default")
        XCTAssertTrue(try store.load().devices.isEmpty)
    }

    func testStateFilesArePrivateAndSymlinkedRootIsRejected() throws {
        try store.register(registration(
            device: UUID().uuidString, token: String(repeating: "ef", count: 32),
            route: UUID().uuidString), nowUnixSeconds: now)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.paths.state.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let target = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: target) }
        XCTAssertThrowsError(try NotificationHelperStateStore(
            paths: NotificationHelperPaths(root: link)).prepare())
    }

    private func registration(
        device: String,
        token: String,
        route: String,
        secret: String = String(repeating: "a", count: 64)
    ) -> NotificationDeviceRegistration {
        NotificationDeviceRegistration(
            deviceID: device, token: token, environment: .development,
            savedHostID: route, session: "default",
            routingSecret: secret)
    }

    private func event(
        kind: CompanionNotificationKind = .needsAttention
    ) -> CompanionNotificationEvent {
        let agentSession = AgentSessionInfo(
            source: "herdr:test", agent: "codex", kind: "id", value: "session-a")
        return CompanionNotificationEvent(
            kind: kind,
            observation: NotificationAgentObservation(
                session: "default", workspaceID: "w1", paneID: "w1:p1",
                terminalID: "terminal-1", agentInstanceID: String(repeating: "b", count: 64),
                status: kind == .needsAttention ? "blocked" : "idle",
                stateChangeSequence: 2, agentSession: agentSession))
    }
}
