import XCTest
import Foundation
import CryptoKit
import HerdrKit
@testable import HerdrNotificationHelperCore

final class HelperServiceTests: XCTestCase {
    private var root: URL!
    private var store: NotificationHelperStateStore!
    private let now: UInt64 = 1_800_000_000

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-companion-test-helper-\(UUID().uuidString)")
        store = NotificationHelperStateStore(paths: NotificationHelperPaths(root: root))
        try store.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testRegistrationIsAcknowledgedButNotClaimedEnabledWhenUnconfigured() async throws {
        let service = NotificationHelperRPCService(store: store, now: { self.now })
        let registration = makeRegistration()
        let response = await service.handle(try JSONEncoder().encode(
            NotificationHelperRequest.register(registration)))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.code, "registered_unconfigured")
        XCTAssertEqual(response.status?.configured, false)
        XCTAssertEqual(response.status?.routePresent, true)
        XCTAssertEqual(try store.load().devices.count, 1)
    }

    func testMalformedAndOversizedRPCsAreRejectedWithoutMutation() async throws {
        let service = NotificationHelperRPCService(store: store)
        let malformed = await service.handle(Data("not-json".utf8))
        let oversized = await service.handle(Data(
            repeating: 0x61, count: NotificationHelperProtocol.maximumRequestBytes + 1))
        XCTAssertEqual(malformed.code, "invalid_json")
        XCTAssertEqual(oversized.code, "request_too_large")
        XCTAssertTrue(try store.load().devices.isEmpty)
    }

    func testConfiguredTestNotificationUsesSenderAndReportsAPNsAcceptance() async throws {
        try writeConfiguration()
        let sender = RecordingNotificationSender(result: .delivered)
        let service = NotificationHelperRPCService(
            store: store, senderFactory: { _ in sender }, now: { self.now })
        let registration = makeRegistration()
        _ = await service.handle(try JSONEncoder().encode(
            NotificationHelperRequest.register(registration)))
        let request = NotificationHelperRequest.routeOperation(
            .testNotification, deviceID: registration.deviceID,
            savedHostID: registration.savedHostID, session: registration.session)

        let response = await service.handle(try JSONEncoder().encode(request))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.code, "test_accepted")
        let sent = await sender.destinations
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].savedHostID, registration.savedHostID.lowercased())
    }

    func testPermanentTestRejectionRemovesToken() async throws {
        try writeConfiguration()
        let sender = RecordingNotificationSender(result: .permanentlyRejectedToken("Unregistered"))
        let service = NotificationHelperRPCService(
            store: store, senderFactory: { _ in sender }, now: { self.now })
        let registration = makeRegistration()
        _ = await service.handle(try JSONEncoder().encode(
            NotificationHelperRequest.register(registration)))
        let request = NotificationHelperRequest.routeOperation(
            .testNotification, deviceID: registration.deviceID,
            savedHostID: registration.savedHostID, session: registration.session)
        let response = await service.handle(try JSONEncoder().encode(request))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.code, "token_rejected")
        XCTAssertTrue(try store.load().devices.isEmpty)
    }

    func testWatcherUsesOfficialStatusSnapshotAndStopsOnCancellation() async throws {
        let registration = makeRegistration()
        try store.register(registration, nowUnixSeconds: now)
        let snapshots = SnapshotSequence([
            try agent(status: "working", sequence: 1),
            try agent(status: "blocked", sequence: 2),
        ])
        let client = FixtureEventClient(snapshots: snapshots)
        let sender = RecordingNotificationSender(result: .delivered)
        let watcher = HerdrNotificationSessionWatcher(
            session: "default", store: store, clientFactory: { client }, sender: sender,
            now: { self.now }, sleep: { _ in })
        let task = Task { await watcher.run() }

        for _ in 0..<100 where await sender.destinations.isEmpty {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        await task.value
        let sent = await sender.destinations
        XCTAssertEqual(sent.map(\.event.kind), [.needsAttention])
        XCTAssertEqual(sent.first?.event.observation.terminalID, "terminal-1")
    }

    func testWatcherBackoffIsBoundedWhenEventConnectionEnds() async throws {
        let registration = makeRegistration()
        try store.register(registration, nowUnixSeconds: now)
        let snapshots = SnapshotSequence([try agent(status: "working", sequence: 1)])
        let delay = BackoffRecorder()
        let watcher = HerdrNotificationSessionWatcher(
            session: "default", store: store,
            clientFactory: { FinishingEventClient(snapshots: snapshots) },
            sender: RecordingNotificationSender(result: .delivered),
            now: { self.now }, sleep: { value in
                await delay.record(value)
                throw CancellationError()
            })

        await watcher.run()
        let firstDelay = await delay.firstValue
        XCTAssertEqual(firstDelay, 1_000_000_000)
    }

    func testRealHelperExecutableStartsAndShutsDownCleanly() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-companion-test-helper-process-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let processStore = NotificationHelperStateStore(
            paths: NotificationHelperPaths.standard(home: home.path))
        try processStore.prepare()
        let keyURL = processStore.paths.root.appendingPathComponent("AuthKey.p8")
        try Data(P256.Signing.PrivateKey().pemRepresentation.utf8)
            .write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        let configuration = APNSConfiguration(
            teamID: "YOURTEAMID", keyID: "ABCDEFGHIJ",
            topic: "com.elysium.herdrcompanion", privateKeyPath: keyURL.path)
        try JSONEncoder().encode(configuration).write(
            to: processStore.paths.config, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: processStore.paths.config.path)

        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("herdr-notification-helper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process()
        process.executableURL = executable
        process.arguments = ["run"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let readiness = stderr.fileHandleForReading.availableData
        XCTAssertEqual(String(decoding: readiness, as: UTF8.self),
                       "Herdr notification helper started.\n")
        XCTAssertTrue(process.isRunning)
        process.terminate()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testRealHelperShortNewlineRPCRespondsAndExitsWhileStdinRemainsOpen() throws {
        let request = try JSONEncoder().encode(NotificationHelperRequest(operation: .status))
        let result = try runRealHelperRPC(input: request + Data([0x0a]), closeStdin: false)

        XCTAssertEqual(result.terminationStatus, 0)
        let response = try JSONDecoder().decode(NotificationHelperResponse.self, from: result.stdout)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.code, "unconfigured")
    }

    func testRealHelperAcceptsEOFAsOneBoundedFrame() throws {
        let request = try JSONEncoder().encode(NotificationHelperRequest(operation: .status))
        let result = try runRealHelperRPC(input: request, closeStdin: true)

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(try JSONDecoder().decode(
            NotificationHelperResponse.self, from: result.stdout).ok)
    }

    func testRealHelperRejectsMalformedAndOversizedFramesWithoutWaitingForEOF() throws {
        let malformed = try runRealHelperRPC(
            input: Data("not-json\n".utf8), closeStdin: false)
        XCTAssertEqual(malformed.terminationStatus, 1)
        XCTAssertEqual(try JSONDecoder().decode(
            NotificationHelperResponse.self, from: malformed.stdout).code, "invalid_json")

        let oversized = try runRealHelperRPC(
            input: Data(repeating: 0x61,
                        count: NotificationHelperProtocol.maximumRequestBytes + 1),
            closeStdin: false)
        XCTAssertEqual(oversized.terminationStatus, 1)
        XCTAssertEqual(try JSONDecoder().decode(
            NotificationHelperResponse.self, from: oversized.stdout).code, "invalid_input")
    }

    private func makeRegistration() -> NotificationDeviceRegistration {
        NotificationDeviceRegistration(
            deviceID: UUID().uuidString, token: String(repeating: "ab", count: 32),
            environment: .development, savedHostID: UUID().uuidString,
            session: "default", routingSecret: String(repeating: "a", count: 64))
    }

    private func runRealHelperRPC(
        input: Data,
        closeStdin: Bool,
        timeout: TimeInterval = 3
    ) throws -> RPCProcessResult {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-companion-test-helper-rpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: home) }

        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("herdr-notification-helper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process()
        process.executableURL = executable
        process.arguments = ["rpc"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = expectation(description: "real helper rpc exited")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        stdin.fileHandleForWriting.write(input)
        if closeStdin { try stdin.fileHandleForWriting.close() }

        let waitResult = XCTWaiter.wait(for: [exited], timeout: timeout)
        if waitResult != .completed, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        XCTAssertEqual(waitResult, .completed, "real helper RPC exceeded its bounded deadline")
        if !closeStdin { try? stdin.fileHandleForWriting.close() }
        return RPCProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile())
    }

    private func writeConfiguration() throws {
        let keyPath = root.appendingPathComponent("AuthKey.p8")
        try Data(P256.Signing.PrivateKey().pemRepresentation.utf8)
            .write(to: keyPath, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
        let configuration = APNSConfiguration(
            teamID: "YOURTEAMID", keyID: "ABCDEFGHIJ",
            topic: "com.elysium.herdrcompanion", privateKeyPath: keyPath.path)
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: store.paths.config, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: store.paths.config.path)
    }

    private func agent(status: String, sequence: UInt64) throws -> AgentInfo {
        let json = """
        {"terminal_id":"terminal-1","name":"worker","agent":"codex",\
        "agent_status":"\(status)","workspace_id":"w1","tab_id":"w1:t1",\
        "pane_id":"w1:p1","focused":false,"interactive_ready":true,\
        "agent_session":{"source":"herdr:codex","agent":"codex","kind":"id","value":"session-a"},\
        "state_change_seq":\(sequence),"revision":\(sequence)}
        """
        return try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
    }
}

private struct RPCProcessResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

private actor RecordingNotificationSender: CompanionNotificationSending {
    private(set) var destinations: [NotificationDestination] = []
    private let result: APNSDeliveryResult

    init(result: APNSDeliveryResult) { self.result = result }

    func send(
        _ destination: NotificationDestination,
        nowUnixSeconds: UInt64
    ) async -> APNSDeliveryResult {
        destinations.append(destination)
        return result
    }
}

private actor SnapshotSequence {
    private var values: [AgentInfo]
    init(_ values: [AgentInfo]) { self.values = values }
    func next() -> [AgentInfo] {
        guard values.count > 1 else { return values }
        return [values.removeFirst()]
    }
}

private struct FixtureEventClient: NotificationEventClient {
    let snapshots: SnapshotSequence

    func agentList() async throws -> [AgentInfo] { await snapshots.next() }

    nonisolated func subscribe(
        _ subscriptions: [Subscription]
    ) -> AsyncThrowingStream<StreamLine, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.event(
                kind: "pane.agent_status_changed", paneID: "w1:p1",
                raw: #"{"event":"pane.agent_status_changed"}"#))
            let task = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct FinishingEventClient: NotificationEventClient {
    let snapshots: SnapshotSequence

    func agentList() async throws -> [AgentInfo] { await snapshots.next() }

    nonisolated func subscribe(
        _ subscriptions: [Subscription]
    ) -> AsyncThrowingStream<StreamLine, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor BackoffRecorder {
    private(set) var firstValue: UInt64?
    func record(_ value: UInt64) { if firstValue == nil { firstValue = value } }
}
