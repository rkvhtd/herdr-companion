#if os(macOS)
import XCTest
import Foundation
import Citadel
@testable import HerdrKit

final class OfficialCompanionIntegrationTests: XCTestCase {
    func testOfficialTopologyCreationAndPlainTerminalAttachment() async throws {
        let fixture = try IntegrationFixture.load()
        let key = try String(contentsOf: fixture.privateKeyURL, encoding: .utf8)
        let credentials = SSHCredentials(
            host: fixture.host,
            port: fixture.port,
            username: fixture.username,
            privateKeyPEM: key,
            remoteSocketPath: fixture.session.socketPath,
            herdrSession: fixture.session.name)
        let transport = CitadelTransport(
            credentials: credentials,
            hostKeyPolicy: PinningHostKeyPolicy(store: .init()),
            connectTimeoutNanoseconds: 5_000_000_000)
        let client = HerdrClient(transport: transport)
        var anchorWorkspaceID: String?
        var createdWorkspaceID: String?
        let cwd = fixture.root.appendingPathComponent("folder with ' quote").path

        do {
            try FileManager.default.createDirectory(
                atPath: cwd, withIntermediateDirectories: false)
            let initial = try await client.sessionTopology()
            for workspace in initial.workspaces {
                try await closeWorkspace(transport, workspaceID: workspace.workspaceID)
            }
            let empty = try await client.sessionTopology()
            XCTAssertTrue(empty.workspaces.isEmpty)
            XCTAssertTrue(empty.tabs.isEmpty)
            XCTAssertTrue(empty.panes.isEmpty)

            let canonicalCWD = cwd.hasPrefix("/tmp/") ? "/private" + cwd : cwd
            let anchor = try await client.createWorkspace(label: "anchor", cwd: cwd)
            anchorWorkspaceID = anchor.workspace.workspaceID
            let created = try await client.createWorkspace(
                label: "phone's workspace", cwd: cwd)
            createdWorkspaceID = created.workspace.workspaceID
            XCTAssertEqual(created.rootPane.effectiveCWD, canonicalCWD)
            XCTAssertFalse(created.rootPane.isAgent)
            XCTAssertFalse(created.workspace.focused)

            let tab = try await client.createTerminalTab(
                workspaceID: created.workspace.workspaceID,
                label: "tab with ' quote",
                cwd: cwd)
            XCTAssertEqual(tab.tab.workspaceID, created.workspace.workspaceID)
            XCTAssertEqual(tab.rootPane.effectiveCWD, canonicalCWD)
            XCTAssertFalse(tab.tab.focused)

            let split = try await client.splitPane(
                workspaceID: created.workspace.workspaceID,
                targetPaneID: tab.rootPane.paneID,
                cwd: cwd,
                direction: .down)
            XCTAssertEqual(split.workspaceID, created.workspace.workspaceID)
            XCTAssertEqual(split.tabID, tab.tab.tabID)
            XCTAssertEqual(split.effectiveCWD, canonicalCWD)
            XCTAssertFalse(split.focused)

            let returned = try await client.sessionTopology()
            XCTAssertEqual(returned.focusedWorkspaceID, anchor.workspace.workspaceID)
            XCTAssertEqual(Set(returned.workspaces.map(\.workspaceID)), [
                anchor.workspace.workspaceID, created.workspace.workspaceID,
            ])
            XCTAssertEqual(returned.tabs.count, 3)
            XCTAssertEqual(returned.panes.count, 4)
            XCTAssertTrue(returned.panes.allSatisfy { !$0.isAgent })
            XCTAssertTrue(returned.panes.contains {
                $0.paneID == split.paneID && $0.terminalID == split.terminalID
            })

            let capture = TerminalCapture()
            let terminal = await transport.openTerminal(
                target: .terminal(terminalID: split.terminalID), cols: 88, rows: 27)
            let output = consume(terminal, into: capture)
            await terminal.start()
            try await eventually("direct plain-terminal attachment") {
                await terminal.readyForInput
            }
            terminal.send(Data("printf 'HC_PLAIN_INPUT:%s\\n' 'works from phone'\r".utf8))
            try await eventually("plain-terminal input and output") {
                guard let text = try? await paneText(transport, paneID: split.paneID) else {
                    return false
                }
                return text.contains("HC_PLAIN_INPUT:works from phone")
            }

            terminal.send(Data([0x02, 0x71]))
            try await eventually("plain terminal detach") { await capture.finished }
            _ = await output.result
            let afterDetach = try await client.sessionTopology()
            XCTAssertTrue(afterDetach.panes.contains { $0.paneID == split.paneID })

            try await closeWorkspace(
                transport, workspaceID: created.workspace.workspaceID)
            createdWorkspaceID = nil
            try await closeWorkspace(
                transport, workspaceID: anchor.workspace.workspaceID)
            anchorWorkspaceID = nil
            let cleaned = try await client.sessionTopology()
            XCTAssertTrue(cleaned.workspaces.isEmpty)
            try FileManager.default.removeItem(atPath: cwd)
            await transport.close()
        } catch {
            if let createdWorkspaceID {
                try? await closeWorkspace(transport, workspaceID: createdWorkspaceID)
            }
            if let anchorWorkspaceID {
                try? await closeWorkspace(transport, workspaceID: anchorWorkspaceID)
            }
            try? FileManager.default.removeItem(atPath: cwd)
            await transport.close()
            throw error
        }
    }

    func testOfficialSSHControlAndTerminalLifecycle() async throws {
        let fixture = try IntegrationFixture.load()
        let key = try String(contentsOf: fixture.privateKeyURL, encoding: .utf8)
        let credentials = SSHCredentials(
            host: fixture.host,
            port: fixture.port,
            username: fixture.username,
            privateKeyPEM: key,
            remoteSocketPath: fixture.session.socketPath,
            herdrSession: fixture.session.name)
        let transport = CitadelTransport(
            credentials: credentials,
            hostKeyPolicy: PinningHostKeyPolicy(store: .init()),
            connectTimeoutNanoseconds: 5_000_000_000)
        let client = HerdrClient(transport: transport)
        var workspaceID: String?
        var uploadedDirectory: URL?

        do {
            let initiallyListed: [AgentInfo]
            do { initiallyListed = try await client.agentList() }
            catch {
                throw IntegrationFailure.invalidResponse("initial agent.list failed: \(error)")
            }
            let initiallyListedPaneIDs = Set(initiallyListed.map(\.paneID))

            let label = "companion-integration-\(UUID().uuidString.prefix(8))"
            let created = try await api(
                transport,
                method: "workspace.create",
                params: ["cwd": "/private/tmp", "focus": false, "label": label, "env": [:]])
            let result = try dictionary(created["result"], "workspace.create result")
            let workspace = try dictionary(result["workspace"], "created workspace")
            let rootPane = try dictionary(result["root_pane"], "created root pane")
            workspaceID = try string(workspace["workspace_id"], "workspace_id")
            let paneID = try string(rootPane["pane_id"], "pane_id")

            let fixtureCommand = "stty -echo -isig; i=1; while [ $i -le 90 ]; do printf 'HISTORY-%03d\\n' \"$i\"; i=$((i+1)); done; printf 'FIXTURE_READY\\n'; while IFS= read -r line; do hex=$(printf '%s' \"$line\" | od -An -tx1 | tr -d '[:space:]'); printf 'INPUT_HEX:%s TEXT:%s SIZE:' \"$hex\" \"$line\"; stty size; done"
            _ = try await api(
                transport,
                method: "pane.send_input",
                params: ["pane_id": paneID, "text": fixtureCommand, "keys": ["enter"]])
            try await waitForPaneText(
                transport, paneID: paneID, needle: "FIXTURE_READY")

            _ = try await reportAgent(
                transport, paneID: paneID, state: "idle", sequence: 1)
            let listed = try await client.agentList()
            let agent = try XCTUnwrap(listed.first { $0.paneID == paneID })
            XCTAssertNotNil(agent.terminalID)
            XCTAssertNotEqual(agent.terminalID, paneID)

            // The held Citadel exec must remain open after its ack, receive a
            // later official event, and close only when the caller cancels it.
            let eventCapture = EventCapture()
            let eventTask = Task {
                do {
                    for try await line in client.subscribe([
                        Subscription(.paneAgentStatusChanged, paneID: paneID)
                    ]) {
                        await eventCapture.record(line)
                    }
                } catch {
                    await eventCapture.fail(error)
                }
                await eventCapture.finish()
            }
            try await eventually("subscription acknowledgement") {
                await eventCapture.hasAcknowledgement
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            let subscriptionEndedEarly = await eventCapture.finished
            XCTAssertFalse(subscriptionEndedEarly,
                           "the official subscription closed when its request was written")
            _ = try await reportAgent(
                transport, paneID: paneID, state: "working", sequence: 2)
            try await eventually("status event") {
                await eventCapture.hasEvent(paneID: paneID)
            }
            eventTask.cancel()
            try await eventually("subscription cancellation") {
                await eventCapture.finished
            }
            let subscriptionFailure = await eventCapture.failure
            XCTAssertNil(subscriptionFailure,
                         "canceling the held subscription surfaced a transport failure")

            let firstClient = SSHClientCapture()
            let firstCapture = TerminalCapture()
            let first = makeTerminal(
                transport: transport,
                target: paneID,
                session: fixture.session.name,
                cols: 101,
                rows: 37,
                clientCapture: firstClient)
            first.send(Data("EARLY-MUST-BE-DROPPED\r".utf8))
            let firstOutput = consume(first, into: firstCapture)
            await first.start()
            try await eventually("first official terminal frame") {
                let ready = await first.readyForInput
                let visible = await firstCapture.contains("FIXTURE_READY")
                return ready && visible
            }
            let earlyInputAppeared = await firstCapture.contains("EARLY-MUST-BE-DROPPED")
            XCTAssertFalse(earlyInputAppeared,
                           "pre-readiness input reached the remote PTY")

            // A second official attach must fail without takeover, and its
            // dedicated SSH client must still be reaped on the error path.
            let contenderClient = SSHClientCapture()
            let contenderCapture = TerminalCapture()
            let contender = makeTerminal(
                transport: transport,
                target: paneID,
                session: fixture.session.name,
                cols: 80,
                rows: 24,
                clientCapture: contenderClient)
            let contenderOutput = consume(contender, into: contenderCapture)
            await contender.start()
            try await eventually("controller contention result") {
                await contenderCapture.finished
            }
            let contenderFailure = await contenderCapture.failure
            guard case .controllerBusy? = contenderFailure else {
                let raw = await contenderCapture.allText
                throw IntegrationFailure.invalidResponse(
                    "competing attach failure was \(String(describing: contenderFailure)); output=\(raw)")
            }
            let capturedRejectedSSH = await contenderClient.client
            let rejectedSSH = try XCTUnwrap(capturedRejectedSSH)
            try await eventually("contender SSH cleanup") { !rejectedSSH.isConnected }
            _ = await contenderOutput.result

            let orderedOffset = await firstCapture.byteCount
            first.send(Data("first\r".utf8))
            first.send(Data("second\r".utf8))
            var orderedText = ""
            do {
                try await eventually("ordered input at initial geometry") {
                    guard let text = try? await paneText(transport, paneID: paneID) else {
                        return false
                    }
                    orderedText = text
                    return text.contains("TEXT:first SIZE:37 101")
                        && text.contains("TEXT:second SIZE:37 101")
                }
            } catch {
                let streamed = await firstCapture.text(since: orderedOffset)
                throw IntegrationFailure.invalidResponse(
                    "ordered pane output=\(orderedText); streamed=\(streamed)")
            }
            XCTAssertLessThan(
                try XCTUnwrap(orderedText.range(of: "TEXT:first")?.lowerBound),
                try XCTUnwrap(orderedText.range(of: "TEXT:second")?.lowerBound))
            let orderedStreamBytes = await firstCapture.byteCount
            XCTAssertGreaterThan(orderedStreamBytes, orderedOffset,
                                 "the held terminal stream did not deliver the ordered-input redraw")

            await first.resize(cols: 119, rows: 41, pixelWidth: 952, pixelHeight: 656)
            try await Task.sleep(nanoseconds: 300_000_000)
            first.send(Data("resized\r".utf8))
            try await eventually("subsequent terminal geometry") {
                guard let text = try? await paneText(transport, paneID: paneID) else {
                    return false
                }
                return text.contains("TEXT:resized SIZE:41 119")
            }

            let wheelUpOffset = await firstCapture.byteCount
            first.send(Data("\u{1b}[<64;1;1M".utf8))
            try await eventually("SGR wheel-up history redraw") {
                let text = await firstCapture.text(since: wheelUpOffset)
                return text.contains("HISTORY-") && text.utf8.count > 80
            }
            let wheelDownOffset = await firstCapture.byteCount
            first.send(Data("\u{1b}[<65;1;1M".utf8))
            try await eventually("SGR wheel-down redraw") {
                await firstCapture.byteCount > wheelDownOffset + 80
            }

            let pageUpOffset = await firstCapture.byteCount
            first.send(Data([0x1b, 0x5b, 0x35, 0x7e]))
            try await eventually("Page Up history redraw") {
                let text = await firstCapture.text(since: pageUpOffset)
                return text.contains("HISTORY-") && text.utf8.count > 80
            }
            let pageDownOffset = await firstCapture.byteCount
            first.send(Data([0x1b, 0x5b, 0x36, 0x7e]))
            try await eventually("Page Down history redraw") {
                await firstCapture.byteCount > pageDownOffset + 80
            }

            // The app's combined one-shot Option+Ctrl-C encoding must cross the
            // real PTY unchanged. The fixture disables ISIG and hex-encodes each
            // completed line so control bytes are observable without ANSI loss.
            first.send(Data([0x1b, 0x03, 0x0d]))
            try await eventually("combined Option+Ctrl key transport") {
                guard let text = try? await paneText(transport, paneID: paneID) else {
                    return false
                }
                return text.contains("INPUT_HEX:1b03")
            }

            // Upload known bytes over the pinned Citadel SFTP connection, then
            // prove the app-owned location, exact bytes, and private modes on the
            // loopback host before inserting the path into the terminal draft.
            let imageBytes = try XCTUnwrap(Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
            let attachment = try await transport.uploadAttachment(
                data: imageBytes, fileExtension: "png")
            let uploadedURL = URL(fileURLWithPath: attachment.path)
            uploadedDirectory = uploadedURL.deletingLastPathComponent()
            try assertPrivateFixtureUpload(
                file: uploadedURL, expectedBytes: imageBytes)

            let bracketedPaste = Data(
                ("\u{1b}[200~" + attachment.path + "\u{1b}[201~").utf8)
            let expectedPasteHex = bracketedPaste.map { String(format: "%02x", $0) }.joined()
            let payloadHex = Data(attachment.path.utf8)
                .map { String(format: "%02x", $0) }.joined()
            first.send(bracketedPaste)
            try await Task.sleep(nanoseconds: 250_000_000)
            let beforeSubmit = try await paneText(transport, paneID: paneID)
            XCTAssertFalse(beforeSubmit.contains("INPUT_HEX:\(expectedPasteHex)"),
                           "attachment paste submitted without an explicit Return")
            XCTAssertFalse(beforeSubmit.contains("INPUT_HEX:\(payloadHex)"))
            XCTAssertFalse(beforeSubmit.contains(attachment.path))
            first.send(Data([0x0d]))
            try await eventually("bracketed attachment paste transport") {
                guard let text = try? await paneText(transport, paneID: paneID) else {
                    return false
                }
                // Herdr 0.9.0 may deliver the complete terminal paste wrapper or
                // normalize it to its payload. Either result proves the uploaded
                // absolute path crossed this real attach only after explicit Return;
                // the focused encoder test separately requires one intact delegate
                // write with the bracket boundaries and no Return.
                return text.contains("INPUT_HEX:\(expectedPasteHex)")
                    || text.contains("INPUT_HEX:\(payloadHex)")
                    || text.contains(attachment.path)
            }

            try removeFixtureUploadDirectory(uploadedDirectory)
            uploadedDirectory = nil

            let discarded = try await transport.uploadAttachment(
                data: imageBytes, fileExtension: "png")
            let discardedURL = URL(fileURLWithPath: discarded.path)
            try assertPrivateFixtureUpload(file: discardedURL, expectedBytes: imageBytes)
            try await transport.removeUninsertedAttachment(discarded)
            XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.path))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: discardedURL.deletingLastPathComponent().path))

            // This is the same close operation the screen invokes on scene
            // background. It releases only the attachment; the agent remains.
            await first.close()
            try await eventually("background attachment cleanup") {
                guard let ssh = await firstClient.client else { return false }
                let outputFinished = await firstCapture.finished
                return !ssh.isConnected && outputFinished
            }
            _ = await firstOutput.result
            let afterBackground = try await client.agentList()
            XCTAssertTrue(afterBackground.contains { $0.paneID == paneID })

            // Sending through the closed object must never become input on the
            // fresh attachment. The next legitimate controller can attach.
            first.send(Data("STALE-MUST-NOT-REPLAY\r".utf8))
            let reconnectClient = SSHClientCapture()
            let reconnectCapture = TerminalCapture()
            let reconnect = makeTerminal(
                transport: transport,
                target: paneID,
                session: fixture.session.name,
                cols: 91,
                rows: 29,
                clientCapture: reconnectClient)
            let reconnectOutput = consume(reconnect, into: reconnectCapture)
            await reconnect.start()
            try await eventually("fresh attachment after background") {
                await reconnect.readyForInput
            }
            reconnect.send(Data("reconnected\r".utf8))
            var reconnectText = ""
            try await eventually("fresh input after reconnect") {
                guard let text = try? await paneText(transport, paneID: paneID) else {
                    return false
                }
                reconnectText = text
                return text.contains("TEXT:reconnected SIZE:29 91")
            }
            XCTAssertFalse(reconnectText.contains("STALE-MUST-NOT-REPLAY"))

            reconnect.send(Data([0x02, 0x71]))
            try await eventually("normal Ctrl-B q completion") {
                await reconnectCapture.finished
            }
            let capturedNormalSSH = await reconnectClient.client
            let normalSSH = try XCTUnwrap(capturedNormalSSH)
            try await eventually("normal-completion SSH cleanup") { !normalSSH.isConnected }
            _ = await reconnectOutput.result
            let afterNormalDetach = try await client.agentList()
            XCTAssertTrue(afterNormalDetach.contains { $0.paneID == paneID })

            try await closeWorkspace(transport, workspaceID: workspaceID)
            workspaceID = nil
            try await eventually("fixture workspace cleanup") {
                guard let remaining = try? await client.agentList() else { return false }
                let paneIDs = Set(remaining.map(\.paneID))
                return !paneIDs.contains(paneID) && initiallyListedPaneIDs.isSubset(of: paneIDs)
            }
            await transport.close()
        } catch {
            if let workspaceID { try? await closeWorkspace(transport, workspaceID: workspaceID) }
            try? removeFixtureUploadDirectory(uploadedDirectory)
            await transport.close()
            throw error
        }
    }

    func testCancelledSFTPUploadRemovesItsPartialAndPrivateDirectory() async throws {
        let fixture = try IntegrationFixture.load()
        let key = try String(contentsOf: fixture.privateKeyURL, encoding: .utf8)
        let credentials = SSHCredentials(
            host: fixture.host,
            port: fixture.port,
            username: fixture.username,
            privateKeyPEM: key,
            remoteSocketPath: fixture.session.socketPath,
            herdrSession: fixture.session.name)
        let transport = CitadelTransport(
            credentials: credentials,
            hostKeyPolicy: PinningHostKeyPolicy(store: .init()),
            connectTimeoutNanoseconds: 5_000_000_000)
        let before = try fixtureUploadDirectories()
        let task = Task {
            try await transport.uploadAttachment(
                data: Data(repeating: 0xa5, count: RemoteAttachment.maximumByteCount),
                fileExtension: "png")
        }

        let deadline = Date().addingTimeInterval(4)
        var created: Set<URL> = []
        while Date() < deadline {
            created = try fixtureUploadDirectories().subtracting(before)
            if !created.isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(created.isEmpty, "the live SFTP upload never created its private directory")
        task.cancel()
        do {
            let attachment = try await task.value
            try? removeFixtureUploadDirectory(
                URL(fileURLWithPath: attachment.path).deletingLastPathComponent())
            XCTFail("the 12 MB live upload committed after cancellation")
        } catch is CancellationError {
            // Expected: cancellation owns and cleans only this upload's paths.
        }
        await transport.close()

        try await eventually("cancelled SFTP cleanup") {
            (try? fixtureUploadDirectories()) == before
        }
    }

    private func makeTerminal(
        transport: CitadelTransport,
        target: String,
        session: String,
        cols: Int,
        rows: Int,
        clientCapture: SSHClientCapture
    ) -> OfficialAgentTerminalSession {
        OfficialAgentTerminalSession(
            id: UUID(),
            target: target,
            herdrSession: session,
            initialCols: cols,
            initialRows: rows,
            makeConnection: {
                let client = try await transport.makeConnection()
                await clientCapture.set(client)
                return client
            },
            onFinish: {})
    }

    private func consume(
        _ session: OfficialAgentTerminalSession,
        into capture: TerminalCapture
    ) -> Task<Void, Never> {
        Task {
            do {
                for try await data in session.output { await capture.append(data) }
            } catch let error as OfficialTerminalError {
                await capture.fail(error)
            } catch {
                await capture.fail(.transport(error.localizedDescription))
            }
            await capture.finish()
        }
    }

    @discardableResult
    private func reportAgent(
        _ transport: CitadelTransport,
        paneID: String,
        state: String,
        sequence: Int
    ) async throws -> [String: Any] {
        try await api(
            transport,
            method: "pane.report_agent",
            params: [
                "pane_id": paneID,
                "source": "herdr-companion-integration",
                "agent": "codex",
                "state": state,
                "seq": sequence,
            ])
    }

    private func closeWorkspace(
        _ transport: CitadelTransport,
        workspaceID: String?
    ) async throws {
        guard let workspaceID else { return }
        _ = try await api(
            transport,
            method: "workspace.close",
            params: ["workspace_id": workspaceID, "close_group": false])
    }

    private func api(
        _ transport: CitadelTransport,
        method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let request: [String: Any] = [
            "id": "integration:\(UUID().uuidString)",
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let responseLine: String
        do {
            responseLine = try await transport.roundTrip(String(decoding: data, as: UTF8.self))
        } catch {
            throw IntegrationFailure.invalidResponse("\(method) transport failed: \(error)")
        }
        let response = try dictionary(
            JSONSerialization.jsonObject(with: Data(responseLine.utf8)), "API response")
        if let error = response["error"] as? [String: Any] {
            throw IntegrationFailure.api(
                code: error["code"] as? String ?? "unknown",
                message: error["message"] as? String ?? responseLine)
        }
        return response
    }

    private func paneText(_ transport: CitadelTransport, paneID: String) async throws -> String {
        let response = try await api(
            transport,
            method: "pane.read",
            params: [
                "pane_id": paneID,
                "source": "recent_unwrapped",
                "lines": 120,
                "format": "text",
                "strip_ansi": true,
            ])
        let result = try dictionary(response["result"], "pane.read result")
        let read = try dictionary(result["read"], "pane.read payload")
        return try string(read["text"], "pane.read text")
    }

    private func dictionary(_ value: Any?, _ label: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw IntegrationFailure.invalidResponse("missing \(label)")
        }
        return value
    }

    private func string(_ value: Any?, _ label: String) throws -> String {
        guard let value = value as? String, !value.isEmpty else {
            throw IntegrationFailure.invalidResponse("missing \(label)")
        }
        return value
    }

    private func eventually(
        _ label: String,
        timeout: TimeInterval = 8,
        condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw IntegrationFailure.timedOut(label)
    }

    private func assertPrivateFixtureUpload(file: URL, expectedBytes: Data) throws {
        let directory = file.deletingLastPathComponent()
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        XCTAssertEqual(directory.deletingLastPathComponent(), home)
        XCTAssertTrue(directory.lastPathComponent.hasPrefix(".herdr-companion-attachments-"))
        XCTAssertEqual(file.pathExtension, "png")
        XCTAssertEqual(try Data(contentsOf: file), expectedBytes)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    private func fixtureUploadDirectories() throws -> Set<URL> {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        return Set(try FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil, options: [])
            .filter { $0.lastPathComponent.hasPrefix(".herdr-companion-attachments-") })
    }

    private func removeFixtureUploadDirectory(_ directory: URL?) throws {
        guard let directory else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        guard directory.deletingLastPathComponent() == home,
              directory.lastPathComponent.hasPrefix(".herdr-companion-attachments-") else {
            throw IntegrationFailure.invalidConfiguration(
                "refusing to remove a non-fixture attachment directory")
        }
        try FileManager.default.removeItem(at: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func waitForPaneText(
        _ transport: CitadelTransport,
        paneID: String,
        needle: String
    ) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let response = try await api(
                transport,
                method: "pane.read",
                params: [
                    "pane_id": paneID,
                    "source": "recent_unwrapped",
                    "lines": 120,
                    "format": "text",
                    "strip_ansi": true,
                ])
            if let result = response["result"] as? [String: Any],
               let read = result["read"] as? [String: Any],
               let text = read["text"] as? String,
               text.components(separatedBy: needle).count >= 3 {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw IntegrationFailure.timedOut("pane output \(needle)")
    }
}

private struct IntegrationFixture {
    let root: URL
    let privateKeyURL: URL
    let host: String
    let port: UInt16
    let username: String
    let session: OfficialHerdrSession

    static func load() throws -> IntegrationFixture {
        let env = ProcessInfo.processInfo.environment
        guard env["HERDR_COMPANION_INTEGRATION"] == "1" else {
            throw XCTSkip("set HERDR_COMPANION_INTEGRATION=1 with the isolated fixture parameters")
        }
        func required(_ name: String) throws -> String {
            guard let value = env[name], !value.isEmpty else {
                throw IntegrationFailure.invalidConfiguration("missing required \(name)")
            }
            return value
        }

        let root = URL(fileURLWithPath: try required("HERDR_COMPANION_FIXTURE_ROOT"))
            .resolvingSymlinksInPath()
        let fixtureParent = root.deletingLastPathComponent().path
        guard root.lastPathComponent.hasPrefix("herdr-companion-ssh-fixture."),
              fixtureParent == "/private/tmp" || fixtureParent == "/tmp" else {
            throw IntegrationFailure.invalidConfiguration("fixture root must be the isolated /private/tmp fixture")
        }
        let key = root.appendingPathComponent("client_ed25519").resolvingSymlinksInPath()
        guard key.deletingLastPathComponent() == root, key.lastPathComponent == "client_ed25519" else {
            throw IntegrationFailure.invalidConfiguration("only the fixture client_ed25519 key is allowed")
        }
        let host = try required("HERDR_COMPANION_FIXTURE_HOST")
        guard host == "127.0.0.1" else {
            throw IntegrationFailure.invalidConfiguration("integration host must be loopback")
        }
        guard let port = UInt16(try required("HERDR_COMPANION_FIXTURE_PORT")), port != 22 else {
            throw IntegrationFailure.invalidConfiguration("fixture port must be explicit and non-default")
        }
        let username = try required("HERDR_COMPANION_FIXTURE_USER")
        let sessionName = try required("HERDR_COMPANION_FIXTURE_SESSION")
        guard sessionName != OfficialHerdrSession.defaultName,
              sessionName.hasPrefix("hc-companion-test-"),
              let session = OfficialHerdrSession(name: sessionName) else {
            throw IntegrationFailure.invalidConfiguration("refusing a default or non-fixture session")
        }
        return IntegrationFixture(
            root: root,
            privateKeyURL: key,
            host: host,
            port: port,
            username: username,
            session: session)
    }
}

private enum IntegrationFailure: Error, CustomStringConvertible {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case api(code: String, message: String)
    case timedOut(String)

    var description: String {
        switch self {
        case .invalidConfiguration(let message): return message
        case .invalidResponse(let message): return message
        case .api(let code, let message): return "\(code): \(message)"
        case .timedOut(let operation): return "timed out waiting for \(operation)"
        }
    }
}

private actor EventCapture {
    private(set) var hasAcknowledgement = false
    private(set) var finished = false
    private(set) var failure: String?
    private var paneEvents: Set<String> = []

    func record(_ line: StreamLine) {
        switch line {
        case .subscriptionStarted: hasAcknowledgement = true
        case .event(_, let paneID, _):
            if let paneID { paneEvents.insert(paneID) }
        case .other: break
        }
    }

    func hasEvent(paneID: String) -> Bool { paneEvents.contains(paneID) }
    func fail(_ error: Error) { failure = error.localizedDescription }
    func finish() { finished = true }
}

private actor SSHClientCapture {
    private(set) var client: SSHClient?
    func set(_ client: SSHClient) { self.client = client }
}

private actor TerminalCapture {
    private var data = Data()
    private(set) var failure: OfficialTerminalError?
    private(set) var finished = false

    var byteCount: Int { data.count }
    var allText: String { String(decoding: data, as: UTF8.self) }

    func append(_ chunk: Data) { data.append(chunk) }
    func fail(_ error: OfficialTerminalError) { failure = error }
    func finish() { finished = true }

    func contains(_ needle: String) -> Bool {
        data.range(of: Data(needle.utf8)) != nil
    }

    func text(since offset: Int) -> String {
        guard offset < data.count else { return "" }
        return String(decoding: data[offset...], as: UTF8.self)
    }
}
#endif
