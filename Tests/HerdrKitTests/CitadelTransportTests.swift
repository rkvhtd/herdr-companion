// Modified from Herdrup https://github.com/jerryfane/herdrup commit 93c6578666e656c3206661389e81853bcc0b88da by Elysium Technologies.
import XCTest
import Foundation
import NIOCore
import Citadel
@testable import HerdrKit

final class CitadelTransportTests: XCTestCase {

    func testRemoteAttachmentAcceptsOnlyNormalizedImageExtensions() {
        XCTAssertEqual(RemoteAttachment.safeExtension("PNG"), "png")
        XCTAssertEqual(RemoteAttachment.safeExtension("jpeg"), "jpg")
        XCTAssertNil(RemoteAttachment.safeExtension("../../prompt"))
        XCTAssertNil(RemoteAttachment.safeExtension("gif"))
    }

    func testRemoteAttachmentSizeErrorIsActionable() {
        let error = RemoteAttachmentError.tooLarge(
            bytes: RemoteAttachment.maximumByteCount + 1,
            maximum: RemoteAttachment.maximumByteCount)
        XCTAssertTrue(error.localizedDescription.contains("12 MB"))
    }

    func testRemoteAttachmentOwnershipRequiresExactPrivateShape() {
        let home = "/Users/fixture"
        let directory = ".herdr-companion-attachments-0123456789abcdef0123456789abcdef"
        let file = "attachment-7553a209-41f8-493c-aeac-4edb2aad7efa.png"
        XCTAssertTrue(RemoteAttachment.isOwnedPath("\(home)/\(directory)/\(file)", home: home))
        XCTAssertFalse(RemoteAttachment.isOwnedPath("\(home)/\(directory)/../\(file)", home: home))
        XCTAssertFalse(RemoteAttachment.isOwnedPath("\(home)/\(directory)/note.txt", home: home))
        XCTAssertFalse(RemoteAttachment.isOwnedPath("/Users/other/\(directory)/\(file)", home: home))
        XCTAssertFalse(RemoteAttachment.isOwnedPath("\(home)\n/\(directory)/\(file)", home: "\(home)\n"))
    }

    func testCleanupTreatsOnlyExplicitNoSuchFileAsAbsence() {
        XCTAssertTrue(isExplicitSFTPAbsence(SFTPStatusCode.noSuchFile))
        XCTAssertFalse(isExplicitSFTPAbsence(SFTPStatusCode.connectionLost),
                       "a transport failure must remain retryable, not masquerade as absence")
        XCTAssertFalse(isExplicitSFTPAbsence(NSError(domain: "fixture", code: 1)))
    }

    // MARK: - connect budget (the endless-spinner fix)

    /// AXIS: the two wordings are genuinely different, and only the tailnet one
    /// names Tailscale.
    ///
    /// The generic branch must NOT mention Tailscale: on an ordinary host the
    /// cause is unknown, and guessing sends the user to fix something that is not
    /// broken. Asserting the absence is the half that keeps that honest.
    func testTimeoutMessageNamesTailscaleOnlyWhenTheHostIsOnATailnet() {
        let tailnet = TransportError.connectTimedOut(host: "box.ts.net", onTailnet: true).description
        XCTAssertTrue(tailnet.contains("Tailscale"), "the remedy must be named: \(tailnet)")
        XCTAssertTrue(tailnet.contains("box.ts.net"), "the host must be named: \(tailnet)")

        let generic = TransportError.connectTimedOut(host: "nas.local", onTailnet: false).description
        XCTAssertFalse(generic.contains("Tailscale"),
                       "an ordinary host must not be blamed on Tailscale: \(generic)")
        XCTAssertTrue(generic.contains("nas.local"), "the host must be named: \(generic)")
    }

    /// AXIS: the budget is REAL — a connect to an address that swallows packets
    /// fails within it instead of hanging.
    ///
    /// This is the actual regression. Before the budget there was no error at all:
    /// the OS sat on the socket for ~75s, which the user experienced as an endless
    /// spinner with nothing to act on.
    ///
    /// Gated on an INDEPENDENT probe (a raw socket, not the transport) that the
    /// address really does black-hole here — matching the LiveEnvironment
    /// convention. Where it fails fast instead, there is no hang to bound and the
    /// test would be asserting something the environment cannot produce.
    func testConnectFailsWithinTheBudgetAgainstABlackHoleAddress() async throws {
        let host = "100.64.0.1"   // CGNAT, and a tailnet address: exercises both halves
        try XCTSkipUnless(Self.blackHoles(host: host),
                          "\(host) does not black-hole in this environment; nothing to bound")

        let creds = SSHCredentials(
            host: host, port: 22, username: "nobody", password: "nobody", remoteSocketPath: "")
        let transport = CitadelTransport(
            credentials: creds,
            hostKeyPolicy: PinningHostKeyPolicy(),
            connectTimeoutNanoseconds: 300_000_000   // 0.3s, so the test is fast
        )

        let started = Date()
        do {
            _ = try await transport.roundTrip("{\"id\":\"x\",\"method\":\"server.ping\",\"params\":{}}")
            XCTFail("a black-hole address must not connect")
        } catch let error as TransportError {
            guard case .connectTimedOut(let h, let onTailnet) = error else {
                return XCTFail("expected connectTimedOut, got \(error)")
            }
            XCTAssertEqual(h, host)
            XCTAssertTrue(onTailnet, "100.64.0.1 is inside 100.64.0.0/10")
        }
        // The bound is the point: without the budget this is ~75 seconds.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "the connect budget did not bound the wait")
    }

    /// Independent of the transport: does a raw TCP connect to this address hang?
    private static func blackHoles(host: String) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(22).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // Connected, or refused/unreachable outright -> not a black hole.
        // Timed out (EINPROGRESS/EAGAIN/ETIMEDOUT) -> packets are being swallowed.
        return rc != 0 && (errno == ETIMEDOUT || errno == EINPROGRESS || errno == EAGAIN)
    }

    // MARK: - LineAccumulator (byte-accurate line decoding)

    /// AXIS: a multi-byte UTF-8 scalar split across two stdout chunks is
    /// reconstructed intact. Decoding each chunk independently with
    /// `String(buffer:)` replaced the split scalar with U+FFFD — the HIGH bug
    /// the review caught. SSH splits large stdout at arbitrary byte boundaries,
    /// so this is the real wire condition, not a contrived one.
    func testLineAccumulatorReconstructsMultibyteScalarSplitAcrossChunks() {
        let rocket = Array("🚀".utf8)   // F0 9F 9A 80
        XCTAssertEqual(rocket.count, 4, "precondition: the scalar is 4 bytes")
        var acc = LineAccumulator()

        // Chunk boundary falls INSIDE the scalar: first two bytes, then the rest.
        XCTAssertTrue(acc.append(ByteBuffer(bytes: rocket[0..<2])).isEmpty,
                      "no newline yet, so no completed line")
        let completed = acc.append(ByteBuffer(bytes: Array(rocket[2..<4]) + [UInt8(ascii: "\n")]))
        XCTAssertEqual(completed, ["🚀"],
                       "the scalar split across chunks was corrupted, not reconstructed")
    }

    /// Splits on every newline and holds the unterminated tail as a remainder.
    func testLineAccumulatorSplitsLinesAndKeepsRemainder() {
        var acc = LineAccumulator()
        let lines = acc.append(ByteBuffer(string: "alpha\nbeta\ngamma"))
        XCTAssertEqual(lines, ["alpha", "beta"], "did not split on both newlines")
        XCTAssertTrue(acc.hasRemainder, "the tail after the last newline was dropped")
        XCTAssertEqual(acc.flush(), "gamma", "the remainder was not the unterminated tail")
        XCTAssertFalse(acc.hasRemainder, "flush did not clear the remainder")
    }


    /// AXIS: the base64 argument the transport builds is exactly what the
    /// server-side official bridge receives after `/usr/bin/base64 -D`.
    ///
    /// This is the contract BETWEEN the two repos — the transport encodes, the
    /// bridge's `decode_request_arg` decodes. If they disagree on the encoding,
    /// every request silently breaks, so it is pinned here where it is cheap to
    /// check rather than discovered against a live server.
    func testEncodedRequestBase64RoundTrips() throws {
        let request = #"{"id":"7","method":"agent.list","params":{}}"#
        let encoded = CitadelTransport.encodedRequest(for: request)

        let decoded = try XCTUnwrap(Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) },
                                    "the argument is not valid base64")
        XCTAssertEqual(decoded, request,
                       "the base64 argument does not decode to the original request")
    }

    /// A request containing shell metacharacters must survive verbatim — the
    /// whole reason for base64 rather than shell-quoting. A prompt with quotes,
    /// backticks, `$(…)`, and newlines is exactly what would break a naive shell
    /// command containing raw JSON.
    func testEncodedRequestSurvivesShellMetacharacters() throws {
        let nasty = #"{"id":"1","method":"agent.prompt","params":{"text":"run `id`; echo $(whoami) \"quoted\" & | ; newline\nhere"}}"#
        let encoded = CitadelTransport.encodedRequest(for: nasty)

        // No shell metacharacter leaks into the base64 blob.
        XCTAssertFalse(encoded.contains(where: { "`$();|&\"\n".contains($0) }),
                       "a shell metacharacter survived into the base64 argument")
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) })
        XCTAssertEqual(decoded, nasty, "the request was altered in transit")
    }

    /// The official socket follows XDG_CONFIG_HOME and the default session layout;
    /// it is not coupled to a source-only or fork-only Herdr subcommand.
    func testBridgeCommandResolvesOfficialSocket() throws {
        let command = try CitadelTransport.bridgeCommand(for: #"{"id":"1","method":"agent.list"}"#)

        XCTAssertTrue(command.contains(#"${XDG_CONFIG_HOME:-"$HOME/.config"}"#))
        XCTAssertTrue(command.contains(#"SOCKET="$CONFIG_ROOT/herdr/herdr.sock""#))
        XCTAssertTrue(command.contains(#"/usr/bin/nc -U "$SOCKET""#))
        XCTAssertTrue(command.contains("unset HERDR_SOCKET_PATH"),
                      "an inherited socket override should not retarget an explicit session")
        XCTAssertFalse(command.contains("api-bridge"))
    }

    /// The full exec command line is single-line — an SSH exec command line
    /// cannot contain a raw newline, and base64 standard encoding without line
    /// wrapping is what guarantees the argument stays on one line. (Foundation's
    /// base64 does not wrap by default; this pins that assumption.)
    func testBridgeCommandIsASingleLine() throws {
        let request = String(repeating: #"{"k":"vvvvvvvvvv"},"#, count: 50)
        let command = try CitadelTransport.bridgeCommand(for: request)
        XCTAssertFalse(command.contains("\n"), "the exec command line contains a newline")
    }

    /// AXIS: a request too large for the argv transport is refused with a clear
    /// error, not allowed to fail opaquely at execve (E2BIG) on the host.
    func testOversizedRequestIsRefused() {
        // Just over the ceiling once base64-expanded.
        let huge = String(repeating: "x", count: CitadelTransport.maxCommandBytes)
        XCTAssertThrowsError(try CitadelTransport.bridgeCommand(for: huge)) { error in
            guard case TransportError.requestTooLarge(let bytes, let max) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertGreaterThan(bytes, max, "refused a request that was within the limit")
        }
        // A normal request is well under and does not throw.
        XCTAssertNoThrow(try CitadelTransport.bridgeCommand(for: #"{"id":"1","method":"agent.list"}"#))
    }

    // MARK: - official socket detection

    func testBridgeCommandGuardsOfficialSocketWithSentinel() throws {
        let command = try CitadelTransport.bridgeCommand(for: #"{"id":"1","method":"agent.list"}"#)

        XCTAssertTrue(command.contains(#"[ -S "$SOCKET" ]"#))
        XCTAssertTrue(command.contains(CitadelTransport.socketMissingSentinel))
        let guardIndex = try XCTUnwrap(command.range(of: #"[ -S "$SOCKET" ]"#)?.lowerBound)
        let ncIndex = try XCTUnwrap(command.range(of: #"/usr/bin/nc -U "$SOCKET""#)?.lowerBound)
        XCTAssertLessThan(guardIndex, ncIndex)
    }

    func testNotificationRPCDeadlineClosesStalledExecutionAndReturnsPromptly() async {
        let probe = NotificationRPCDeadlineProbe()
        let started = Date()
        do {
            _ = try await CitadelTransport.withNotificationRPCDeadline(
                timeoutNanoseconds: 30_000_000,
                operation: { await probe.waitUntilClosed() },
                onTimeout: { await probe.closeUnderlyingExecution() })
            XCTFail("a stalled helper RPC must time out")
        } catch let error as NotificationHelperTransportError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("unexpected deadline error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let closeCount = await probe.closeCount
        XCTAssertEqual(closeCount, 1,
                       "the deadline must close the underlying exec, not only cancel a task")
    }

    func testNotificationRPCDeadlineCancellationBeforeAdoptionReturnsPromptlyAndClosesLateResourceOnce() async {
        let gate = NotificationRPCPhaseGate()
        let resource = NotificationRPCResourceProbe()
        let task = Task<Int, Error> {
            try await CitadelTransport.withNotificationRPCDeadline(
                timeoutNanoseconds: 5_000_000_000,
                operation: {
                    await gate.suspend()
                    await resource.adoptResource()
                    return 1
                },
                onTimeout: { await resource.closeUnderlyingExecution() })
        }
        await gate.waitUntilEntered()

        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("caller cancellation must win before late adoption")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        await resource.waitUntilClosed()
        await gate.release()
        await resource.waitUntilResourceClosed()
        let counts = await resource.counts
        XCTAssertEqual(counts.closeInvocations, 1)
        XCTAssertEqual(counts.resourceCloses, 1)
        XCTAssertEqual(counts.adoptions, 1)
    }

    func testNotificationRPCDeadlineCancellationDuringHeldExecutionReturnsPromptlyAndClosesOnce() async {
        let gate = NotificationRPCPhaseGate()
        let resource = NotificationRPCResourceProbe()
        let task = Task<Int, Error> {
            try await CitadelTransport.withNotificationRPCDeadline(
                timeoutNanoseconds: 5_000_000_000,
                operation: {
                    await resource.adoptResource()
                    await gate.suspend()
                    return 2
                },
                onTimeout: { await resource.closeUnderlyingExecution() })
        }
        await gate.waitUntilEntered()

        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("caller cancellation must settle a held execution")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        await resource.waitUntilClosed()
        await resource.waitUntilResourceClosed()
        await gate.release()
        let counts = await resource.counts
        XCTAssertEqual(counts.closeInvocations, 1)
        XCTAssertEqual(counts.resourceCloses, 1)
        XCTAssertEqual(counts.adoptions, 1)
    }

    func testNotificationRPCDeadlineCancellationRacingSuccessSettlesAndCleansExactlyOnce() async {
        let gate = NotificationRPCPhaseGate()
        let resource = NotificationRPCResourceProbe()
        let task = Task<Int, Error> {
            try await CitadelTransport.withNotificationRPCDeadline(
                timeoutNanoseconds: 5_000_000_000,
                operation: {
                    await resource.adoptResource()
                    await gate.suspend()
                    return 3
                },
                onTimeout: { await resource.closeUnderlyingExecution() })
        }
        await gate.waitUntilEntered()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { task.cancel() }
            group.addTask { await gate.release() }
        }

        do {
            let value = try await task.value
            XCTAssertEqual(value, 3)
            await resource.closeUnderlyingExecution()
        } catch is CancellationError {
            await resource.waitUntilClosed()
        } catch {
            XCTFail("success/cancellation race returned unexpected error: \(error)")
        }
        await resource.waitUntilResourceClosed()
        let counts = await resource.counts
        XCTAssertEqual(counts.closeInvocations, 1)
        XCTAssertEqual(counts.resourceCloses, 1)
    }

    func testNotificationRPCDeadlineCancellationRacingDeadlineSettlesAndCleansExactlyOnce() async {
        let gate = NotificationRPCPhaseGate()
        let resource = NotificationRPCResourceProbe()
        let task = Task<Int, Error> {
            try await CitadelTransport.withNotificationRPCDeadline(
                timeoutNanoseconds: 30_000_000,
                operation: {
                    await gate.suspend()
                    await resource.adoptResource()
                    return 4
                },
                onTimeout: { await resource.closeUnderlyingExecution() })
        }
        await gate.waitUntilEntered()
        let canceller = Task {
            try? await Task.sleep(nanoseconds: 30_000_000)
            task.cancel()
        }

        do {
            _ = try await task.value
            XCTFail("a suspended operation must not beat cancellation/deadline")
        } catch is CancellationError {
            // Either cancellation...
        } catch let error as NotificationHelperTransportError {
            XCTAssertEqual(error, .timedOut) // ...or the deadline may win the race.
        } catch {
            XCTFail("unexpected cancellation/deadline race error: \(error)")
        }
        _ = await canceller.value
        await resource.waitUntilClosed()
        await gate.release()
        await resource.waitUntilResourceClosed()
        let counts = await resource.counts
        XCTAssertEqual(counts.closeInvocations, 1)
        XCTAssertEqual(counts.resourceCloses, 1)
    }

    func testFixedNotificationCommandRejectsUnsafePathShapesBeforeExecution() throws {
        let valid = try runNotificationHelperCommand()
        XCTAssertEqual(valid.status, 0)
        XCTAssertEqual(String(decoding: valid.stdout, as: UTF8.self), "fixture-rpc\n")

        for mutate in [
            { (fixture: HelperCommandFixture) throws in
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
            },
            { (fixture: HelperCommandFixture) throws in
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o775], ofItemAtPath: fixture.bin.path)
            },
            { (fixture: HelperCommandFixture) throws in
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o722], ofItemAtPath: fixture.helper.path)
            },
            { (fixture: HelperCommandFixture) throws in
                try FileManager.default.removeItem(at: fixture.helper)
                try FileManager.default.createDirectory(
                    at: fixture.helper, withIntermediateDirectories: false)
            },
            { (fixture: HelperCommandFixture) throws in
                let target = fixture.home.appendingPathComponent("replacement-helper")
                try Data("#!/bin/sh\nprintf 'replacement ran\\n'\n".utf8).write(to: target)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: target.path)
                try FileManager.default.removeItem(at: fixture.helper)
                try FileManager.default.createSymbolicLink(
                    at: fixture.helper, withDestinationURL: target)
            },
            { (fixture: HelperCommandFixture) throws in
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o777],
                    ofItemAtPath: fixture.root.deletingLastPathComponent().path)
            },
        ] {
            let rejected = try runNotificationHelperCommand(mutate: mutate)
            XCTAssertEqual(rejected.status, 69)
            XCTAssertTrue(String(decoding: rejected.stderr, as: UTF8.self)
                .contains(CitadelTransport.notificationHelperMissingSentinel))
            XCTAssertFalse(String(decoding: rejected.stdout, as: UTF8.self)
                .contains("fixture-rpc"))
        }

        let command = CitadelTransport.notificationHelperCommand
        XCTAssertTrue(command.contains(#"[ -O "$P" ]"#),
                      "every directory loop must enforce current-user ownership")
        XCTAssertTrue(command.contains(#"[ -O "$HELPER" ]"#),
                      "the executable must enforce current-user ownership")
    }

    // MARK: - parseBridgeOutput reachability (the do/catch WIRING, not the pure classifier)

    /// A fake non-zero exit the test can inject — `SSHClient.CommandFailed`'s init is
    /// internal to Citadel, so `parseBridgeOutput` catches the `RemoteExitError` protocol
    /// (which `CommandFailed` conforms to) and this stands in for it here.
    private struct FakeExit: RemoteExitError { let remoteExitCode: Int }

    /// Builds the exec output stream a test wants: some stdout/stderr, then either a
    /// clean finish or a `throwing:` finish (what Citadel does on non-zero exit).
    private func bridgeStream(
        stdout: [String] = [], stderr: [String] = [], finishThrowing: Error? = nil
    ) -> AsyncThrowingStream<ExecCommandOutput, Error> {
        AsyncThrowingStream { continuation in
            for s in stdout { continuation.yield(.stdout(ByteBuffer(string: s))) }
            for s in stderr { continuation.yield(.stderr(ByteBuffer(string: s))) }
            if let finishThrowing { continuation.finish(throwing: finishThrowing) }
            else { continuation.finish() }
        }
    }

    /// A non-zero `nc` exit must become the official socket diagnostic rather
    /// than leaking Citadel's raw command failure.
    func testParseBridgeOutputNonzeroExitReportsSocketFailure() async {
        let stream = bridgeStream(
            stderr: ["nc: connectx failed\n"],
            finishThrowing: FakeExit(remoteExitCode: 2))
        do {
            _ = try await CitadelTransport.parseBridgeOutput(stream, host: "box.example")
            XCTFail("expected a throw")
        } catch let error as TransportError {
            guard case .remoteSocketFailed(_, let detail) = error else {
                return XCTFail("expected .remoteSocketFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("connectx failed"))
        } catch {
            XCTFail("raw \(error) escaped — the do/catch is gone or mis-scoped")
        }
    }

    /// The socket sentinel follows the same throwing-stream wiring.
    func testParseBridgeOutputSentinelReportsMissingSocket() async {
        let stream = bridgeStream(
            stderr: ["\(CitadelTransport.socketMissingSentinel)\n"],
            finishThrowing: FakeExit(remoteExitCode: 66))
        do {
            _ = try await CitadelTransport.parseBridgeOutput(stream, host: "box.example")
            XCTFail("expected a throw")
        } catch let error as TransportError {
            guard case .remoteSocketFailed(_, let detail) = error else {
                return XCTFail("expected .remoteSocketFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("session is not running"))
        } catch {
            XCTFail("raw \(error) escaped — the do/catch is gone or mis-scoped")
        }
    }

    /// A reply that arrived before a non-zero exit is RETURNED, not overridden by the
    /// exit classification — guards the `lines.first` early-return / `hasRemainder` order.
    func testParseBridgeOutputReturnsReplyBeforeNonZeroExit() async throws {
        let stream = bridgeStream(
            stdout: ["{\"ok\":true}\n"],
            finishThrowing: FakeExit(remoteExitCode: 1))
        let reply = try await CitadelTransport.parseBridgeOutput(stream, host: "box.example")
        XCTAssertEqual(reply, "{\"ok\":true}")
    }

    /// A clean exit-0 close with no reply surfaces `.closedBeforeResponse`, not a hang.
    func testParseBridgeOutputCleanCloseWithoutReply() async {
        let stream = bridgeStream()
        do {
            _ = try await CitadelTransport.parseBridgeOutput(stream, host: "box.example")
            XCTFail("expected a throw")
        } catch let error as TransportError {
            guard case .closedBeforeResponse = error else {
                return XCTFail("expected .closedBeforeResponse, got \(error)")
            }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private func runNotificationHelperCommand(
        mutate: ((HelperCommandFixture) throws -> Void)? = nil
    ) throws -> HelperCommandResult {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("hc-companion-test-helper-command-\(UUID().uuidString)")
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let support = library.appendingPathComponent("Application Support", isDirectory: true)
        let root = support.appendingPathComponent(
            "Herdr Companion Notifications", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let helper = bin.appendingPathComponent("herdr-notification-helper")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for directory in [home, library, support] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path)
        }
        for directory in [root, bin] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        try Data("#!/bin/sh\nprintf 'fixture-rpc\\n'\n".utf8).write(to: helper)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let fixture = HelperCommandFixture(home: home, root: root, bin: bin, helper: helper)
        try mutate?(fixture)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CitadelTransport.notificationHelperCommand]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return HelperCommandResult(
            status: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile())
    }
}

private actor NotificationRPCDeadlineProbe {
    private var closed = false
    private var waiter: CheckedContinuation<Int, Never>?
    private(set) var closeCount = 0

    func waitUntilClosed() async -> Int {
        if closed { return 0 }
        return await withCheckedContinuation { waiter = $0 }
    }

    func closeUnderlyingExecution() {
        closeCount += 1
        closed = true
        waiter?.resume(returning: 0)
        waiter = nil
    }
}

private actor NotificationRPCPhaseGate {
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

private actor NotificationRPCResourceProbe {
    private var closed = false
    private var holdingResource = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var resourceCloseWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeInvocations = 0
    private var resourceCloses = 0
    private var adoptions = 0

    var counts: (closeInvocations: Int, resourceCloses: Int, adoptions: Int) {
        (closeInvocations, resourceCloses, adoptions)
    }

    func adoptResource() {
        adoptions += 1
        if closed {
            resourceCloses += 1
            resumeResourceCloseWaiters()
        } else {
            holdingResource = true
        }
    }

    func closeUnderlyingExecution() {
        closeInvocations += 1
        guard !closed else { return }
        closed = true
        if holdingResource {
            holdingResource = false
            resourceCloses += 1
            resumeResourceCloseWaiters()
        }
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilClosed() async {
        if closed { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    func waitUntilResourceClosed() async {
        if resourceCloses > 0 { return }
        await withCheckedContinuation { resourceCloseWaiters.append($0) }
    }

    private func resumeResourceCloseWaiters() {
        let waiters = resourceCloseWaiters
        resourceCloseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private struct HelperCommandFixture {
    let home: URL
    let root: URL
    let bin: URL
    let helper: URL
}

private struct HelperCommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}
