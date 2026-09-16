import XCTest
import Foundation
import Citadel
import NIOCore
@testable import HerdrKit

final class OfficialCompanionTests: XCTestCase {
    private struct FixtureTransport: HerdrTransport {
        let response: String
        func roundTrip(_ requestLine: String) async throws -> String { response }
        func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testOfficialAgentListDecodesWithoutForkFields() async throws {
        let response = #"{"id":"test","result":{"type":"agent_list","agents":[{"terminal_id":"t-01","name":"reviewer","agent":"codex","title":"codex","terminal_title":"Codex","terminal_title_stripped":"Codex","display_agent":"Codex","agent_status":"working","workspace_id":"w1","tab_id":"t1","pane_id":"p1","focused":true,"interactive_ready":true,"state_change_seq":9,"cwd":"/tmp/project","foreground_cwd":"/tmp/project","revision":12}]}}"#
        let client = HerdrClient(transport: FixtureTransport(response: response))

        let agents = try await client.agentList()

        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].terminalID, "t-01")
        XCTAssertEqual(agents[0].displayName, "reviewer")
        XCTAssertEqual(agents[0].agent, "codex")
        XCTAssertEqual(agents[0].agentStatus, "working")
        XCTAssertNil(agents[0].composer, "official Herdr omits the fork-only composer field")
        XCTAssertNil(agents[0].sessionTransfer, "official Herdr omits fork transfer state")
    }

    func testOfficialSessionSnapshotDecodesWorkspaceTabsAndPlainPanes() async throws {
        let response = #"{"id":"test","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"focused_workspace_id":"w1","focused_tab_id":"w1:t1","focused_pane_id":"w1:p1","workspaces":[{"workspace_id":"w1","number":1,"label":"Mobile work","focused":true,"pane_count":2,"tab_count":1,"active_tab_id":"w1:t1","agent_status":"working"}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"shells","focused":true,"pane_count":2,"agent_status":"working"}],"panes":[{"pane_id":"w1:p1","terminal_id":"term plain","workspace_id":"w1","tab_id":"w1:t1","focused":true,"cwd":"/tmp/requested","foreground_cwd":"/tmp/actual folder","label":"plain shell","agent_status":"unknown","revision":3},{"pane_id":"w1:p2","terminal_id":"term-agent","workspace_id":"w1","tab_id":"w1:t1","focused":false,"cwd":"/tmp","agent":"codex","display_agent":"Codex","agent_status":"working","revision":4}],"layouts":[],"agents":[]}}}"#
        let topology = try await HerdrClient(
            transport: FixtureTransport(response: response)).sessionTopology()

        XCTAssertEqual(topology.version, "0.9.0")
        XCTAssertEqual(topology.protocolVersion, 22)
        XCTAssertEqual(topology.workspaces.first?.label, "Mobile work")
        XCTAssertEqual(topology.tabs.first?.workspaceID, "w1")
        XCTAssertEqual(topology.panes[0].terminalID, "term plain")
        XCTAssertEqual(topology.panes[0].effectiveCWD, "/tmp/actual folder")
        XCTAssertFalse(topology.panes[0].isAgent)
        XCTAssertTrue(topology.panes[1].isAgent)
    }

    func testCreationRequestsKeepDataExactAndNeverFocusDesktop() async throws {
        let plan = RequestResponsePlan(responses: [
            Self.workspaceCreatedResponse,
            Self.tabCreatedResponse,
            Self.paneCreatedResponse,
        ])
        let client = HerdrClient(transport: RecordingFixtureTransport(plan: plan))

        let workspace = try await client.createWorkspace(
            label: "phone's work", cwd: "/tmp/space and ' quote")
        let tab = try await client.createTerminalTab(
            workspaceID: workspace.workspace.workspaceID,
            label: "review's shell", cwd: "/tmp/tab folder")
        let pane = try await client.splitPane(
            workspaceID: workspace.workspace.workspaceID,
            targetPaneID: tab.rootPane.paneID,
            cwd: "/tmp/split folder",
            direction: .right)

        XCTAssertEqual(pane.terminalID, "term-split")
        let requests = await plan.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        let decoded = try requests.map { request -> [String: Any] in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        }
        XCTAssertEqual(decoded.map { $0["method"] as? String }, [
            "workspace.create", "tab.create", "pane.split",
        ])

        let workspaceParams = try XCTUnwrap(decoded[0]["params"] as? [String: Any])
        XCTAssertEqual(workspaceParams["focus"] as? Bool, false)
        XCTAssertEqual(workspaceParams["label"] as? String, "phone's work")
        XCTAssertEqual(workspaceParams["cwd"] as? String, "/tmp/space and ' quote")
        XCTAssertNil(workspaceParams["source_workspace_id"])

        let tabParams = try XCTUnwrap(decoded[1]["params"] as? [String: Any])
        XCTAssertEqual(tabParams["workspace_id"] as? String, "w-created")
        XCTAssertEqual(tabParams["focus"] as? Bool, false)
        XCTAssertEqual(tabParams["label"] as? String, "review's shell")

        let splitParams = try XCTUnwrap(decoded[2]["params"] as? [String: Any])
        XCTAssertEqual(splitParams["workspace_id"] as? String, "w-created")
        XCTAssertEqual(splitParams["target_pane_id"] as? String, "p-tab")
        XCTAssertEqual(splitParams["direction"] as? String, "right")
        XCTAssertEqual(splitParams["cwd"] as? String, "/tmp/split folder")
        XCTAssertEqual(splitParams["focus"] as? Bool, false)
    }

    func testOfficialEventEnvelopeIsClassified() {
        let line = #"{"event":"pane.agent_status_changed","data":{"pane_id":"p1","workspace_id":"w1","agent_status":"blocked"}}"#
        guard case .event(let kind, let paneID, _) = HerdrClient.classify(line) else {
            return XCTFail("official event envelope was not classified")
        }
        XCTAssertEqual(kind, "pane.agent_status_changed")
        XCTAssertEqual(paneID, "p1")
    }

    func testSessionTargetKeepsAPIAndCLISelectionExplicit() throws {
        let standard = try XCTUnwrap(OfficialHerdrSession(name: "default"))
        XCTAssertEqual(standard.socketPath, ".config/herdr/herdr.sock")
        let work = try XCTUnwrap(OfficialHerdrSession(name: "work-2"))
        XCTAssertEqual(work.socketPath, ".config/herdr/sessions/work-2/herdr.sock")
        XCTAssertNil(OfficialHerdrSession(name: "../other"))
        XCTAssertNil(OfficialHerdrSession(name: "has space"))
    }

    func testOfficialSocketCommandIsBoundedAndShellSafe() throws {
        let request = #"{"id":"1","method":"agent.list","params":{"text":"' $(touch /tmp/nope); `id`"}}"#
        let command = try CitadelTransport.socketCommand(
            for: request, remoteSocketPath: ".config/herdr/sessions/work/herdr.sock")

        XCTAssertTrue(command.contains("/usr/bin/nc -U"))
        XCTAssertTrue(command.contains("/usr/bin/base64 -D"))
        XCTAssertFalse(command.contains("api-bridge"))
        XCTAssertFalse(command.contains("touch /tmp/nope"), "raw JSON leaked into the shell command")
        XCTAssertEqual(CitadelTransport.shellQuote("a'b"), #"'a'"'"'b'"#)
        XCTAssertThrowsError(try CitadelTransport.socketCommand(
            for: String(repeating: "x", count: CitadelTransport.maxCommandBytes),
            remoteSocketPath: ".config/herdr/herdr.sock"))
        XCTAssertEqual(CitadelTransport.socketPayload(for: "{}"), "{}\n")
        XCTAssertEqual(CitadelTransport.socketPayload(for: "{}\n"), "{}\n")
    }

    func testPersistentSubscriptionUsesHeldOfficialSocket() {
        let command = CitadelTransport.heldSocketCommand(session: "work'; unsafe")

        XCTAssertTrue(command.hasSuffix(#"exec /usr/bin/nc -U "$SOCKET""#))
        XCTAssertTrue(command.contains(CitadelTransport.shellQuote("work'; unsafe")))
        XCTAssertTrue(command.contains("XDG_CONFIG_HOME"))
        XCTAssertTrue(command.contains(CitadelTransport.socketMissingSentinel))
        XCTAssertFalse(command.contains("remote-api-bridge"))
    }

    func testDefaultAndNamedSocketSetupUseXDGAndIgnoreInheritedOverride() {
        let standard = CitadelTransport.resolvedSocketSetup(session: "default")
        let named = CitadelTransport.resolvedSocketSetup(session: "work-2")

        for command in [standard, named] {
            XCTAssertTrue(command.hasPrefix("unset HERDR_SOCKET_PATH;"))
            XCTAssertTrue(command.contains(#"${XDG_CONFIG_HOME:-"$HOME/.config"}"#))
            XCTAssertTrue(command.contains(CitadelTransport.socketMissingSentinel))
        }
        XCTAssertTrue(standard.contains(#"SOCKET="$CONFIG_ROOT/herdr/herdr.sock""#))
        XCTAssertTrue(named.contains(#"SOCKET="$CONFIG_ROOT/herdr/sessions/""#))
        XCTAssertTrue(named.contains(CitadelTransport.shellQuote("work-2")))
        XCTAssertTrue(named.contains(#"/herdr.sock"#))
    }

    func testOfficialSocketResponseLineIsBounded() async {
        let stream = AsyncThrowingStream<ExecCommandOutput, Error> { continuation in
            continuation.yield(.stdout(ByteBuffer(
                string: String(repeating: "x", count: CitadelTransport.maxResponseLineBytes + 1))))
            continuation.finish()
        }

        do {
            _ = try await CitadelTransport.parseBridgeOutput(stream, host: "fixture")
            XCTFail("oversized unterminated response was accepted")
        } catch let error as TransportError {
            guard case .responseTooLarge(let bytes, let max) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertGreaterThan(bytes, max)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAttachCommandQuotesTargetAndNeverTakesOver() {
        let target = "pane'; echo unsafe"
        let command = OfficialAgentTerminalSession.attachCommand(
            target: target, session: "default")

        XCTAssertTrue(command.contains("/opt/homebrew/bin/herdr"))
        XCTAssertTrue(command.hasPrefix("unset HERDR_SOCKET_PATH;"))
        XCTAssertTrue(command.hasSuffix(
            "--session 'default' agent attach " + CitadelTransport.shellQuote(target)))
        XCTAssertFalse(command.contains("--takeover"))
    }

    func testPlainTerminalUsesDirectAttachWithReturnedIDAndNamedSession() {
        let terminalID = "term'; echo unsafe"
        let command = OfficialAgentTerminalSession.attachCommand(
            target: .terminal(terminalID: terminalID), session: "mobile-test")

        XCTAssertTrue(command.hasSuffix(
            "--session 'mobile-test' terminal attach "
                + CitadelTransport.shellQuote(terminalID)))
        XCTAssertFalse(command.contains(" agent attach "))
        XCTAssertFalse(command.contains("--takeover"))
    }

    func testOutOfOrderInputTicketsDrainInOriginalOrder() {
        var buffer = OrderedTerminalInputBuffer()
        buffer.insert(Data("second".utf8), ticket: 1)
        XCTAssertNil(buffer.takeNext(), "later input must wait for the missing earlier ticket")
        buffer.insert(Data("first".utf8), ticket: 0)
        XCTAssertEqual(buffer.takeNext(), Data("first".utf8))
        XCTAssertEqual(buffer.takeNext(), Data("second".utf8))
        XCTAssertNil(buffer.takeNext())
    }

    func testAcknowledgedPasteUsesOrderedWriterAndDoesNotSubmit() async throws {
        let writer = RecordingTerminalInputWriter()
        let session = testSession(writer: writer)
        let earlierKey = Data("x".utf8)
        let path = "/Users/fixture/.herdr-companion/image.png"
        let paste = Data("\u{1b}[200~\(path)\u{1b}[201~".utf8)

        session.send(earlierKey)
        try await session.sendAcknowledged(paste)

        let writes = await writer.writes
        XCTAssertEqual(writes, [earlierKey, paste])
        XCTAssertFalse(paste.contains(UInt8(ascii: "\r")),
                       "an acknowledged attachment paste must not press Return")
        await session.close()
    }

    func testAcknowledgedPasteReportsWriterFailure() async {
        let writer = RecordingTerminalInputWriter(failsWrites: true)
        let session = testSession(writer: writer)

        do {
            try await session.sendAcknowledged(Data("attachment".utf8))
            XCTFail("the failed TTY write was reported as acknowledged")
        } catch let error as OfficialTerminalError {
            guard case .transport(let message) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(message.contains("Terminal input failed"))
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testAcknowledgedPasteRejectsClosedSessionWithoutWriting() async {
        let writer = RecordingTerminalInputWriter()
        let session = testSession(writer: writer)
        await session.close()

        do {
            try await session.sendAcknowledged(Data("must not replay".utf8))
            XCTFail("a closed session accepted attachment input")
        } catch {
            XCTAssertEqual(error as? OfficialTerminalInputError, .closed)
        }
        let writes = await writer.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testWrittenPasteStaysAcknowledgedWhenSessionClosesDuringWriteCompletion() async throws {
        let writer = SuspendedSuccessfulTerminalInputWriter()
        let session = testSession(writer: writer)
        let paste = Data("written once".utf8)

        let sending = Task { try await session.sendAcknowledged(paste) }
        await writer.waitUntilWriteStarted()
        await session.close()
        await writer.finishWrite()

        try await sending.value
        let recorded = await writer.recordedWrite()
        XCTAssertEqual(recorded, paste)
    }

    func testTerminalDimensionsClampResizeSafetyFloor() {
        XCTAssertEqual(
            TerminalDimensions.clamped(cols: 0, rows: -2, pixelWidth: -1, pixelHeight: 800),
            TerminalDimensions(cols: 4, rows: 2, pixelWidth: 0, pixelHeight: 800))
    }

    func testCloseBeforeStartNeverConnectsAndFinishesOnce() async throws {
        let connections = LockedCounter()
        let finishes = LockedCounter()
        let session = OfficialAgentTerminalSession(
            id: UUID(), target: "t1", herdrSession: "default",
            initialCols: 80, initialRows: 24,
            makeConnection: {
                connections.increment()
                throw ProbeError.unexpectedConnect
            },
            onFinish: { finishes.increment() })

        await session.close()
        await session.close()
        await session.start()
        session.send(Data("must not replay".utf8))
        var chunks = 0
        for try await _ in session.output { chunks += 1 }

        XCTAssertEqual(chunks, 0)
        XCTAssertEqual(connections.value, 0)
        XCTAssertEqual(finishes.value, 1)
    }

    func testCloseDuringPendingConnectCancelsAndFinishesOnce() async throws {
        let connections = LockedCounter()
        let finishes = LockedCounter()
        let session = OfficialAgentTerminalSession(
            id: UUID(), target: "t1", herdrSession: "default",
            initialCols: 80, initialRows: 24,
            makeConnection: {
                connections.increment()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                throw ProbeError.unexpectedConnect
            },
            onFinish: { finishes.increment() })

        await session.start()
        while connections.value == 0 { await Task.yield() }
        session.send(Data("discard on close".utf8))
        await session.close()
        var chunks = 0
        for try await _ in session.output { chunks += 1 }

        XCTAssertEqual(chunks, 0)
        XCTAssertEqual(connections.value, 1)
        XCTAssertEqual(finishes.value, 1)
    }

    private func testSession(
        writer: any OfficialTerminalInputWriter
    ) -> OfficialAgentTerminalSession {
        OfficialAgentTerminalSession(
            id: UUID(), target: "t1", herdrSession: "default",
            initialCols: 80, initialRows: 24,
            makeConnection: { throw ProbeError.unexpectedConnect },
            onFinish: {}, initialWriter: writer, initiallyReady: true)
    }

    private static let paneJSON = #"{"pane_id":"p-root","terminal_id":"term-root","workspace_id":"w-created","tab_id":"t-root","focused":false,"cwd":"/tmp/space and ' quote","foreground_cwd":"/tmp/space and ' quote","label":null,"agent_status":"unknown","revision":0}"#
    private static let workspaceCreatedResponse = #"{"id":"test","result":{"type":"workspace_created","workspace":{"workspace_id":"w-created","number":2,"label":"phone's work","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"t-root","agent_status":"unknown"},"tab":{"tab_id":"t-root","workspace_id":"w-created","number":1,"label":"1","focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":\#(paneJSON)}}"#
    private static let tabCreatedResponse = #"{"id":"test","result":{"type":"tab_created","tab":{"tab_id":"t-created","workspace_id":"w-created","number":2,"label":"review's shell","focused":false,"pane_count":1,"agent_status":"unknown"},"root_pane":{"pane_id":"p-tab","terminal_id":"term-tab","workspace_id":"w-created","tab_id":"t-created","focused":false,"cwd":"/tmp/tab folder","foreground_cwd":"/tmp/tab folder","agent_status":"unknown","revision":0}}}"#
    private static let paneCreatedResponse = #"{"id":"test","result":{"type":"pane_info","pane":{"pane_id":"p-split","terminal_id":"term-split","workspace_id":"w-created","tab_id":"t-created","focused":false,"cwd":"/tmp/split folder","foreground_cwd":"/tmp/split folder","agent_status":"unknown","revision":0}}}"#
}

private struct RecordingFixtureTransport: HerdrTransport {
    let plan: RequestResponsePlan

    func roundTrip(_ requestLine: String) async throws -> String {
        await plan.next(requestLine)
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor RequestResponsePlan {
    private let responses: [String]
    private var requests: [String] = []

    init(responses: [String]) { self.responses = responses }

    func next(_ request: String) -> String {
        requests.append(request)
        return responses[min(requests.count - 1, responses.count - 1)]
    }

    func recordedRequests() -> [String] { requests }
}

private enum ProbeError: Error { case unexpectedConnect }

private actor RecordingTerminalInputWriter: OfficialTerminalInputWriter {
    private(set) var writes: [Data] = []
    private let failsWrites: Bool

    init(failsWrites: Bool = false) { self.failsWrites = failsWrites }

    func write(_ buffer: ByteBuffer) async throws {
        if failsWrites { throw ProbeError.unexpectedConnect }
        writes.append(Data(buffer.readableBytesView))
    }

    func changeSize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
}

private actor SuspendedSuccessfulTerminalInputWriter: OfficialTerminalInputWriter {
    private var recorded: Data?
    private var writeStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func write(_ buffer: ByteBuffer) async throws {
        recorded = Data(buffer.readableBytesView)
        writeStarted = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { finishContinuation = $0 }
    }

    func waitUntilWriteStarted() async {
        if writeStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finishWrite() { finishContinuation?.resume(); finishContinuation = nil }
    func recordedWrite() -> Data? { recorded }
    func changeSize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
