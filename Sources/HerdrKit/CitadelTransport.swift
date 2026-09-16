// Modified from Herdrup https://github.com/jerryfane/herdrup commit 93c6578666e656c3206661389e81853bcc0b88da by Elysium Technologies.
import Foundation
import Citadel
import Crypto
import NIOCore
@preconcurrency import NIOSSH

/// The pure-Swift transport: swift-nio-ssh + Citadel, replacing libssh2.
///
/// Where `SSHTransport` needed a bounded thread pool, a cancellation handle that
/// publishes the socket, and `DescriptorAudit` — all because libssh2 blocks and
/// owns raw fds — this needs none of it. Citadel is async/await-native:
/// cancellation is `channel.close()` on an event loop, and there are no fds to
/// audit. That deletion is the whole point of route B.
///
/// It reaches official Herdr's newline-delimited JSON socket with macOS `nc -U`
/// over one SSH exec channel per call. The request rides as base64 so untrusted
/// JSON never enters the remote shell grammar. Socket setup follows the official
/// XDG/default config-root and validated named-session rules.
///
/// One `SSHClient` is held and reused across calls (a fresh channel per call, no
/// per-request handshake — closing issue #25). Conforms to the two-method
/// `HerdrTransport` seam; `SessionRecovery`/`RecoveryExecutor` sit above it
/// unchanged.
/// Lets exactly one racer resume a continuation. Resuming a continuation twice is
/// undefined behaviour rather than a catchable error, so the guard has to be
/// atomic — a plain Bool read-then-write is a race in exactly the interleaving
/// this exists to prevent.
final class FirstPastThePost: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Owns the continuation and unstructured operation for one notification RPC race.
/// Cancellation can arrive before either is installed, so both installation methods
/// remember that state and immediately deliver/cancel late arrivals.
private final class NotificationRPCDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var work: Task<Value, Error>?
    private var cancelWorkOnAdoption = false

    var isClaimed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimed
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func adopt(_ work: Task<Value, Error>) {
        lock.lock()
        self.work = work
        let cancel = cancelWorkOnAdoption
        lock.unlock()
        if cancel { work.cancel() }
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }

    func cancelWork() {
        lock.lock()
        cancelWorkOnAdoption = true
        let work = work
        lock.unlock()
        work?.cancel()
    }

    func complete(_ result: Result<Value, Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}

public actor CitadelTransport: HerdrTransport {
    private let credentials: SSHCredentials
    private nonisolated let remoteSocketPath: String
    private let hostKeyValidator: SSHHostKeyValidator
    private var client: SSHClient?
    /// A connect in flight, so concurrent first-use awaits one attempt (see
    /// `connectedClient`) rather than each opening — and leaking — its own session.
    private var connectTask: Task<SSHClient, Error>?
    /// Bumped by `close()`. A connect that resolves after its starting generation is
    /// STALE: close() has already torn down and believes there is no live session, so
    /// the resolved client must be reaped, never installed. This closes the residual
    /// window where a handshake completing exactly as the user disconnects would
    /// otherwise re-install a live session behind close()'s back (leak).
    private var generation = 0
    /// Dedicated PTY clients opened for terminal attachments. They are separate
    /// from the command client so terminal backpressure cannot stall API calls.
    private var terminalSessions: [UUID: OfficialAgentTerminalSession] = [:]
    /// Dedicated SFTP uploads. Keeping them here lets `close()` cancel an image
    /// transfer without dropping it behind a transport generation change.
    private var attachmentUploads: [UUID: RemoteAttachmentUploadOperation] = [:]

    /// - Parameters:
    ///   - credentials: host/port/username, authentication, and the explicit
    ///     official session/socket target.
    ///   - hostKeyValidator: the raw Citadel validator, for callers that need
    ///     full control (e.g. `.acceptAnything()` in an isolated live test).
    ///     Prefer the `hostKeyPolicy` initializer, whose default pins.
    /// This transport's connect budget. Injectable so the timeout can be TESTED
    /// against a black-hole address in milliseconds instead of being asserted from
    /// reading the code — a 15s test is one nobody runs.
    let connectTimeoutNanoseconds: UInt64
    /// End-to-end budget for one helper RPC, including command execution and
    /// response framing. The RPC uses a dedicated SSH client so expiry can close
    /// the underlying channel without disrupting ordinary Herdr traffic.
    let notificationRPCTimeoutNanoseconds: UInt64

    public init(
        credentials: SSHCredentials,
        hostKeyValidator: SSHHostKeyValidator,
        connectTimeoutNanoseconds: UInt64 = CitadelTransport.defaultConnectTimeoutNanoseconds,
        notificationRPCTimeoutNanoseconds: UInt64 = CitadelTransport.defaultNotificationRPCTimeoutNanoseconds
    ) {
        self.credentials = credentials
        self.remoteSocketPath = credentials.remoteSocketPath
        self.hostKeyValidator = hostKeyValidator
        self.connectTimeoutNanoseconds = connectTimeoutNanoseconds
        self.notificationRPCTimeoutNanoseconds = notificationRPCTimeoutNanoseconds
    }

    /// Pins the host key on first contact and hard-stops on change (TOFU),
    /// wrapping the policy in the nio-ssh delegate internally so a caller needs
    /// no Citadel/nio-ssh types and cannot accidentally get a trust-everything
    /// validator.
    ///
    /// The default policy (`PinningHostKeyPolicy()`) is backed by the
    /// PROCESS-WIDE `PinStore.shared`, so two transports created this way enforce
    /// one pin set (a transport recreated mid-process still hard-stops a changed
    /// key). It does NOT persist across app launches — for cross-launch TOFU a
    /// shipping client passes its own `HostKeyPolicy` here that pins against
    /// persistent (e.g. Keychain) storage; `PinStore` is in-memory only.
    public init(
        credentials: SSHCredentials,
        hostKeyPolicy: HostKeyPolicy = PinningHostKeyPolicy(),
        connectTimeoutNanoseconds: UInt64 = CitadelTransport.defaultConnectTimeoutNanoseconds,
        notificationRPCTimeoutNanoseconds: UInt64 = CitadelTransport.defaultNotificationRPCTimeoutNanoseconds
    ) {
        self.connectTimeoutNanoseconds = connectTimeoutNanoseconds
        self.notificationRPCTimeoutNanoseconds = notificationRPCTimeoutNanoseconds
        self.credentials = credentials
        self.remoteSocketPath = credentials.remoteSocketPath
        self.hostKeyValidator = .custom(PinningHostKeyValidator(
            host: credentials.host, port: credentials.port, policy: hostKeyPolicy))
    }

    // MARK: - connection

    /// Returns the held client, connecting on first use or after a drop.
    ///
    /// Concurrent first-use joins ONE connect. `SSHClient.connect` is a
    /// suspension point, and actor reentrancy lets a second caller pass the
    /// `client == nil` check while the first is still connecting; without the
    /// shared `connectTask` both would open a session and all but the last would
    /// leak (a live SSH session never closed). Callers await the same in-flight
    /// task instead.
    private func connectedClient() async throws -> SSHClient {
        if let client, client.isConnected { return client }

        // Capture the generation BEFORE awaiting: if close() runs during the
        // handshake it bumps `generation`, marking whatever resolves as stale.
        let gen = generation
        let task: Task<SSHClient, Error>
        if let connectTask {
            task = connectTask                      // join the in-flight attempt
        } else {
            let created = Task<SSHClient, Error> { try await self.makeConnection() }
            connectTask = created
            task = created
        }
        do {
            let connected = try await task.value
            // Validate AFTER the suspension, under actor isolation. If close() ran
            // while we awaited, this session is orphaned — close() already believes
            // there is nothing to tear down, so reap it rather than installing a live
            // client behind close()'s back. BOTH the creator and any joined waiter
            // pass through this same check.
            guard gen == generation else {
                try? await connected.close()
                throw CancellationError()
            }
            client = connected
            if connectTask == task { connectTask = nil }
            return connected
        } catch {
            // Only clear the slot if it still holds OUR task — never clobber a newer
            // connect started after a close() bumped the generation.
            if connectTask == task { connectTask = nil }
            throw error
        }
    }

    func makeConnection() async throws -> SSHClient {
        let method: SSHAuthenticationMethod
        switch credentials.auth {
        case .privateKey(let pem, let passphrase):
            let privateKey = try Curve25519.Signing.PrivateKey(
                sshEd25519: Data(pem.utf8),
                decryptionKey: passphrase.map { Data($0.utf8) }
            )
            method = .ed25519(username: credentials.username, privateKey: privateKey)
        case .password(let password):
            method = .passwordBased(username: credentials.username, password: password)
        }
        // A client that resolves after a concurrent close() is reaped by the
        // generation check in connectedClient() (the only publisher of `self.client`),
        // so no cancellation handling is needed here.
        // RACE THE HANDSHAKE AGAINST A CLOCK. Without this an unroutable address —
        // a Tailscale host reached from a device that is not on the tailnet — hangs
        // at the TCP layer until the OS gives up (~75s on iOS). That is not
        // experienced as a failure; it is experienced as an endless spinner, with
        // nothing on screen to act on. A budget converts silence into an error the
        // UI can show.
        //
        // NOT a task group, and the reason is measured: a group awaits its children
        // at scope exit, and `SSHClient.connect` does not observe cancellation
        // promptly — so a group-based race returned only when the LOSING connect
        // finally gave up on its own (30s against a 0.3s budget, caught by
        // `testConnectFailsWithinTheBudgetAgainstABlackHoleAddress`). The winner
        // must be able to return while the loser unwinds unobserved.
        let host = credentials.host
        let port = Int(credentials.port)
        let validator = hostKeyValidator
        let budget = connectTimeoutNanoseconds
        let work = Task<SSHClient, Error> {
            try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: method,
                hostKeyValidator: validator,
                reconnect: .never
            )
        }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                // Exactly one of the two branches may resume the continuation;
                // resuming twice is undefined behaviour, not a recoverable error.
                let settled = FirstPastThePost()
                Task {
                    do {
                        let client = try await work.value
                        if settled.claim() {
                            continuation.resume(returning: client)
                        } else {
                            // The clock already won and the caller has its error.
                            // Close this rather than leaking a live session nobody
                            // holds a reference to.
                            try? await client.close()
                        }
                    } catch {
                        if settled.claim() { continuation.resume(throwing: error) }
                    }
                }
                Task {
                    try? await Task.sleep(nanoseconds: budget)
                    guard settled.claim() else { return }
                    work.cancel()
                    continuation.resume(throwing: TransportError.connectTimedOut(
                        host: host,
                        // credentials.host is already the bare host (the port is a
                        // separate field), so classify it directly rather than
                        // re-parsing a string that was never joined.
                        onTailnet: HostEndpoint(host: host, port: 22).isTailnetAddress
                    ))
                }
            }
        } catch SSHClientError.unsupportedPasswordAuthentication {
            // The server offers no password auth (e.g. `PasswordAuthentication no`).
            throw TransportError.passwordAuthUnsupported(host: credentials.host)
        } catch SSHClientError.allAuthenticationOptionsFailed {
            // Wrong password / rejected key. Host-key rejection is thrown by the
            // validator, not caught here, so it keeps its dedicated recovery path.
            throw TransportError.authenticationFailed(host: credentials.host)
        }
    }

    /// Conservative ceiling on the SSH exec command, below common argv limits.
    static let maxCommandBytes = 120_000
    /// A control/event JSON line cannot consume unbounded memory.
    static let maxResponseLineBytes = 1_048_576
    static let maxDiagnosticBytes = 8_192

    /// Default budget for a connect, handshake included.
    ///
    /// Well above a real handshake — even a slow cellular link completes in a
    /// second or two — and far below the OS's own ~75s give-up on an unroutable
    /// address. The gap between those two numbers is the whole point: 15s is long
    /// enough that no working connection is cut off, short enough that a broken
    /// one says so while the user is still looking at it.
    public static let defaultConnectTimeoutNanoseconds: UInt64 = 15 * 1_000_000_000
    public static let defaultNotificationRPCTimeoutNanoseconds: UInt64 = 20 * 1_000_000_000

    /// The request, base64-encoded. Kept separate from the command so the
    /// encoding contract can be tested without the shell wrapper around it.
    static func encodedRequest(for requestLine: String) -> String {
        Data(requestLine.utf8).base64EncodedString()
    }

    /// The official socket is newline-delimited. Keep framing outside the JSON
    /// encoder so callers and fixtures can continue to work with a bare JSON line.
    static func socketPayload(for requestLine: String) -> String {
        requestLine.hasSuffix("\n") ? requestLine : requestLine + "\n"
    }

    /// Fixed sentinels avoid matching localized shell diagnostics.
    static let herdrNotInstalledSentinel = "__HERDR_NOT_INSTALLED__"
    static let socketMissingSentinel = "__HERDR_SOCKET_MISSING__"
    static let notificationHelperMissingSentinel = "__HERDR_NOTIFICATION_HELPER_MISSING__"

    /// Resolves the official executable for PTY attach. Homebrew on Apple Silicon
    /// is explicitly covered even though a non-login SSH shell may omit it.
    static let herdrPathResolution =
        #"unset HERDR_SOCKET_PATH; HERDR=$(command -v herdr 2>/dev/null || true); for P in /opt/homebrew/bin/herdr /usr/local/bin/herdr "$HOME/.local/bin/herdr"; do [ -n "$HERDR" ] && break; [ -x "$P" ] && HERDR="$P"; done; [ -x "$HERDR" ] || { printf '__HERDR_NOT_INSTALLED__\n' >&2; exit 127; }; "#

    /// POSIX single-quote escaping. Used for every user-controlled shell argument.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Sends one base64-encoded JSON line to one explicit official socket.
    static func socketCommand(for requestLine: String, remoteSocketPath: String) throws -> String {
        let path = remoteSocketPath.isEmpty ? ".config/herdr/herdr.sock" : remoteSocketPath
        let command = #"SOCKET="$HOME"/"# + shellQuote(path)
            + #"; [ -S "$SOCKET" ] || { printf '__HERDR_SOCKET_MISSING__\n' >&2; exit 66; }; printf '%s\n' "#
            + shellQuote(encodedRequest(for: socketPayload(for: requestLine)))
            + #" | /usr/bin/base64 -D | /usr/bin/nc -U "$SOCKET""#
        let byteCount = command.utf8.count
        guard byteCount <= maxCommandBytes else {
            throw TransportError.requestTooLarge(bytes: byteCount, max: maxCommandBytes)
        }
        return command
    }

    /// Derives the selected official API socket exactly as official Herdr does,
    /// including XDG_CONFIG_HOME. An inherited socket override is irrelevant to
    /// an explicitly selected saved session and is cleared for clarity.
    static func resolvedSocketSetup(session: String) -> String {
        let location: String
        if session == OfficialHerdrSession.defaultName {
            location = #"SOCKET="$CONFIG_ROOT/herdr/herdr.sock"; "#
        } else {
            location = #"SOCKET="$CONFIG_ROOT/herdr/sessions/""#
                + shellQuote(session) + #""/herdr.sock"; "#
        }
        return #"unset HERDR_SOCKET_PATH; CONFIG_ROOT=${XDG_CONFIG_HOME:-"$HOME/.config"}; "#
            + location
            + #"[ -S "$SOCKET" ] || { printf '__HERDR_SOCKET_MISSING__\n' >&2; exit 66; }; "#
    }

    /// A held bidirectional exec for subscriptions. The caller writes one request
    /// and intentionally leaves stdin open until cancellation.
    static func heldSocketCommand(session: String) -> String {
        resolvedSocketSetup(session: session) + #"exec /usr/bin/nc -U "$SOCKET""#
    }

    /// Fixed, argument-free helper RPC entry point. The JSON request is written to
    /// stdin by `notificationHelperRPC`; it never enters this shell command or a
    /// process argument where tokens would be exposed by `ps` or shell logging.
    static var notificationHelperCommand: String {
        #"fail() { printf '__HERDR_NOTIFICATION_HELPER_MISSING__\n' >&2; exit 69; }; "#
            + #"ROOT="$HOME/Library/Application Support/Herdr Companion Notifications"; "#
            + #"BIN="$ROOT/bin"; HELPER="$BIN/herdr-notification-helper"; "#
            + #"for P in "$HOME" "$HOME/Library" "$HOME/Library/Application Support"; do "#
            + #"[ ! -L "$P" ] && [ -d "$P" ] && [ -O "$P" ] || fail; "#
            + #"M=$(/usr/bin/stat -f '%Lp' "$P") || fail; case "$M" in [0-7][0145][0145]) ;; *) fail ;; esac; done; "#
            + #"for P in "$ROOT" "$BIN"; do [ ! -L "$P" ] && [ -d "$P" ] && [ -O "$P" ] || fail; "#
            + #"M=$(/usr/bin/stat -f '%Lp' "$P") || fail; case "$M" in [0-7]00) ;; *) fail ;; esac; done; "#
            + #"[ ! -L "$HELPER" ] && [ -f "$HELPER" ] && [ -x "$HELPER" ] && [ -O "$HELPER" ] || fail; "#
            + #"M=$(/usr/bin/stat -f '%Lp' "$HELPER") || fail; case "$M" in [0-7][0145][0145]) ;; *) fail ;; esac; "#
            + #"exec "$HELPER" rpc"#
    }

    /// One-shot form for ordinary request/reply calls. EOF is correct here.
    static func officialRequestCommand(for requestLine: String, session: String) throws -> String {
        let payload = socketPayload(for: requestLine)
        let command = resolvedSocketSetup(session: session)
            + #"printf '%s' "# + shellQuote(encodedRequest(for: payload))
            + #" | /usr/bin/base64 -D | /usr/bin/nc -U "$SOCKET""#
        guard command.utf8.count <= maxCommandBytes else {
            throw TransportError.requestTooLarge(bytes: command.utf8.count, max: maxCommandBytes)
        }
        return command
    }

    /// Compatibility name retained for existing unit tests/callers. It builds the
    /// official default-session socket command.
    static func bridgeCommand(for requestLine: String) throws -> String {
        try officialRequestCommand(for: requestLine, session: "default")
    }

    static func classifySocketFailure(
        stderr: String, exitCode: Int, remoteSocketPath: String
    ) -> TransportError {
        let detail: String
        if stderr.contains(socketMissingSentinel) {
            detail = "the session is not running or the socket path is wrong"
        } else {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = trimmed.isEmpty ? "remote command exited \(exitCode)" : trimmed
        }
        return .remoteSocketFailed(path: remoteSocketPath, detail: detail)
    }

    // MARK: - HerdrTransport

    public func roundTrip(_ requestLine: String) async throws -> String {
        let client = try await connectedClient()
        let output = try await client.executeCommandStream(
            try Self.officialRequestCommand(
                for: requestLine, session: credentials.herdrSession))
        return try await Self.parseBridgeOutput(
            output, host: credentials.host, remoteSocketPath: credentials.remoteSocketPath)
    }

    /// Consumes the remote socket command output into its single reply line, or throws
    /// a classified `TransportError`. Extracted from `roundTrip` for ONE reason: to make
    /// the reachability of the exit-code classification testable. Citadel throws
    /// `CommandFailed` at EOF on ANY non-zero exit, so the `do/catch` MUST enclose the
    /// throwing loop or the raw "command failed, exit code N" escapes and the
    /// not-installed / incompatible guidance is never reached. `SSHClient` itself is not
    /// injectable, but a test can feed this a fake `AsyncThrowingStream` that finishes
    /// `throwing:` a `RemoteExitError`, binding that the catch is present AND scoped.
    static func parseBridgeOutput(
        _ output: AsyncThrowingStream<ExecCommandOutput, Error>, host: String,
        remoteSocketPath: String = ".config/herdr/herdr.sock"
    ) async throws -> String {
        // One request, one reply line. Accumulate RAW bytes and decode UTF-8 only at
        // newline boundaries: decoding each SSH channel-data chunk on its own
        // (String(buffer:)) turns a multi-byte scalar split across a chunk boundary into
        // U+FFFD, silently corrupting the reply.
        var lines = LineAccumulator()
        var stderr = ""
        do {
            for try await chunk in output {
                switch chunk {
                case .stdout(let buffer):
                    if let first = lines.append(buffer).first {
                        guard first.utf8.count <= maxResponseLineBytes else {
                            throw TransportError.responseTooLarge(
                                bytes: first.utf8.count, max: maxResponseLineBytes)
                        }
                        return first
                    }
                    guard lines.bufferedByteCount <= maxResponseLineBytes else {
                        throw TransportError.responseTooLarge(
                            bytes: lines.bufferedByteCount, max: maxResponseLineBytes)
                    }
                case .stderr(let buffer):
                    if stderr.utf8.count < maxDiagnosticBytes {
                        stderr += String(buffer: buffer)
                        if stderr.utf8.count > maxDiagnosticBytes {
                            stderr = String(stderr.prefix(maxDiagnosticBytes))
                        }
                    }
                }
            }
        } catch let failure as RemoteExitError {
            // A non-zero remote exit: Citadel throws `CommandFailed` at EOF instead of
            // ending the stream, so this catch is the ONLY place the exit status is
            // visible — without it the raw "command failed, exit code N" escapes and the
            // not-installed / incompatible guidance is never reached. A reply may still
            // have arrived first (returned above); reaching here means it did not.
            if lines.hasRemainder {
                guard lines.bufferedByteCount <= maxResponseLineBytes else {
                    throw TransportError.responseTooLarge(
                        bytes: lines.bufferedByteCount, max: maxResponseLineBytes)
                }
                return lines.flush()
            }
            throw classifySocketFailure(
                stderr: stderr, exitCode: failure.remoteExitCode,
                remoteSocketPath: remoteSocketPath)
        }
        // Channel closed on exit 0 without a newline-terminated reply.
        if lines.hasRemainder {
            guard lines.bufferedByteCount <= maxResponseLineBytes else {
                throw TransportError.responseTooLarge(
                    bytes: lines.bufferedByteCount, max: maxResponseLineBytes)
            }
            return lines.flush()   // a reply that lacked a trailing newline
        }
        // Empty stdout: surface the remote diagnostic rather than handing
        // the caller an empty string it can only fail to decode.
        if !stderr.isEmpty {
            throw classifySocketFailure(
                stderr: stderr, exitCode: 0, remoteSocketPath: remoteSocketPath)
        }
        throw TransportError.closedBeforeResponse
    }

    public nonisolated func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // A subscription gets its OWN connection, NOT the shared command
            // client. `nc -U` is bidirectional: its stdin must remain open after
            // the request or the API server correctly treats the peer as disconnected
            // and ends the subscription. Citadel's `withExec` owns both channel
            // directions without introducing PTY line processing.
            let connection = StreamConnection()
            let task = Task {
                var stderr = ""
                do {
                    guard #available(macOS 15.0, *) else {
                        throw TransportError.bridgeFailed(
                            stderr: "Persistent SSH exec support requires macOS 15 or later on this build host.")
                    }
                    let payload = Self.socketPayload(for: requestLine)
                    guard payload.utf8.count <= Self.maxCommandBytes else {
                        throw TransportError.requestTooLarge(
                            bytes: payload.utf8.count, max: Self.maxCommandBytes)
                    }
                    let client = try await self.makeConnection()
                    await connection.adopt(client)
                    if Task.isCancelled { await connection.close(); continuation.finish(); return }
                    let command = Self.heldSocketCommand(
                        session: self.credentials.herdrSession)
                    try await client.withExec(command) { inbound, outbound in
                        try await outbound.write(ByteBuffer(string: payload))

                        // Same byte-accurate decoding as roundTrip: decode UTF-8
                        // only at newline boundaries so a multi-byte scalar split
                        // across SSH chunks is never corrupted.
                        var lines = LineAccumulator()
                        for try await chunk in inbound {
                            if Task.isCancelled { throw CancellationError() }
                            switch chunk {
                            case .stdout(let bytes):
                                for line in lines.append(bytes) {
                                    guard line.utf8.count <= Self.maxResponseLineBytes else {
                                        throw TransportError.responseTooLarge(
                                            bytes: line.utf8.count,
                                            max: Self.maxResponseLineBytes)
                                    }
                                    continuation.yield(line)
                                }
                                guard lines.bufferedByteCount <= Self.maxResponseLineBytes else {
                                    throw TransportError.responseTooLarge(
                                        bytes: lines.bufferedByteCount,
                                        max: Self.maxResponseLineBytes)
                                }
                            case .stderr(let bytes):
                                if stderr.utf8.count < Self.maxDiagnosticBytes {
                                    stderr += String(buffer: bytes)
                                    if stderr.utf8.count > Self.maxDiagnosticBytes {
                                        stderr = String(stderr.prefix(Self.maxDiagnosticBytes))
                                    }
                                }
                            }
                        }
                        if lines.hasRemainder {
                            guard lines.bufferedByteCount <= Self.maxResponseLineBytes else {
                                throw TransportError.responseTooLarge(
                                    bytes: lines.bufferedByteCount,
                                    max: Self.maxResponseLineBytes)
                            }
                            continuation.yield(lines.flush())
                        }
                    }
                    await connection.close()
                    continuation.finish()
                } catch is CancellationError {
                    await connection.close()
                    continuation.finish()
                } catch let failure as RemoteExitError {
                    await connection.close()
                    continuation.finish(
                        throwing: Self.classifySocketFailure(
                            stderr: stderr, exitCode: failure.remoteExitCode,
                            remoteSocketPath: self.credentials.remoteSocketPath))
                } catch {
                    await connection.close()
                    continuation.finish(throwing: error)
                }
            }
            // Termination cancels the reader AND closes the dedicated client,
            // which reaps the SSH channel now rather than leaking it until the
            // process exits.
            continuation.onTermination = { _ in
                task.cancel()
                Task { await connection.close() }
            }
        }
    }

    /// Sends one narrowly-scoped notification request to the reviewed helper.
    /// The helper path and `rpc` mode are fixed; callers cannot execute a command.
    public func notificationHelperRPC(
        _ request: NotificationHelperRequest
    ) async throws -> NotificationHelperResponse {
        guard #available(macOS 15.0, *) else {
            throw NotificationHelperTransportError.transportFailed
        }
        let validated = try request.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var payload = try encoder.encode(validated)
        guard payload.count <= NotificationHelperProtocol.maximumRequestBytes else {
            throw NotificationHelperTransportError.requestTooLarge
        }
        payload.append(0x0a)
        let framedPayload = payload

        let connection = StreamConnection()
        do {
            let response = try await Self.withNotificationRPCDeadline(
                timeoutNanoseconds: notificationRPCTimeoutNanoseconds,
                operation: {
                    let client = try await self.makeConnection()
                    await connection.adopt(client)
                    if Task.isCancelled { throw CancellationError() }
                    return try await Self.executeNotificationHelperRPC(
                        client: client, payload: framedPayload)
                },
                onTimeout: { await connection.close() })
            // Do not make a successfully settled RPC newly cancellation-blocking on
            // client cleanup. The holder is idempotent and owns eventual close.
            Task { await connection.close() }
            return response
        } catch {
            // The cancellation/deadline branch already arranged the same close, while
            // ordinary operation errors still need it. Scheduling the idempotent holder
            // avoids waiting on cleanup after caller cancellation.
            Task { await connection.close() }
            throw error
        }
    }

    @available(macOS 15.0, *)
    private static func executeNotificationHelperRPC(
        client: SSHClient,
        payload: Data
    ) async throws -> NotificationHelperResponse {
        var stdout = LineAccumulator()
        var responseLine: String?
        var stderr = ""
        do {
            try await client.withExec(notificationHelperCommand) { inbound, outbound in
                try await outbound.write(ByteBuffer(data: payload))
                for try await chunk in inbound {
                    if Task.isCancelled { throw CancellationError() }
                    switch chunk {
                    case .stdout(let bytes):
                        let lines = stdout.append(bytes)
                        if responseLine == nil { responseLine = lines.first }
                        guard stdout.bufferedByteCount
                                <= NotificationHelperProtocol.maximumResponseBytes else {
                            throw NotificationHelperTransportError.responseTooLarge
                        }
                    case .stderr(let bytes):
                        if stderr.utf8.count < maxDiagnosticBytes {
                            stderr += String(buffer: bytes)
                        }
                    }
                }
            }
        } catch let error as NotificationHelperTransportError {
            throw error
        } catch {
            if stderr.contains(notificationHelperMissingSentinel) {
                throw NotificationHelperTransportError.helperMissing
            }
            // A helper deliberately exits non-zero for an RPC-level failure but
            // still writes its structured response. Decode that below.
            guard responseLine != nil || stdout.hasRemainder else {
                throw NotificationHelperTransportError.transportFailed
            }
        }
        let line: String
        if let responseLine {
            line = responseLine
        } else if stdout.hasRemainder {
            line = stdout.flush()
        } else {
            throw NotificationHelperTransportError.invalidResponse
        }
        guard line.utf8.count <= NotificationHelperProtocol.maximumResponseBytes,
              let data = line.data(using: .utf8) else {
            throw NotificationHelperTransportError.responseTooLarge
        }
        do {
            return try JSONDecoder().decode(NotificationHelperResponse.self, from: data)
        } catch {
            throw NotificationHelperTransportError.invalidResponse
        }
    }

    /// Races one RPC against a clock without a task group. Timeout and caller
    /// cancellation atomically claim settlement and cancel the unstructured work.
    /// Cancellation schedules underlying close and returns immediately; timeout
    /// retains the existing close-before-return contract. Late work adoption is
    /// canceled here and its late SSH client is reaped by `StreamConnection`.
    static func withNotificationRPCDeadline<T: Sendable>(
        timeoutNanoseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () async -> Void
    ) async throws -> T {
        let race = NotificationRPCDeadlineRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                guard !race.isClaimed else { return }

                let work = Task<T, Error> {
                    try Task.checkCancellation()
                    return try await operation()
                }
                race.adopt(work)
                Task {
                    do {
                        let value = try await work.value
                        guard race.claim() else { return }
                        race.complete(.success(value))
                    } catch {
                        guard race.claim() else { return }
                        race.complete(.failure(error))
                    }
                }
                Task {
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    } catch {
                        return
                    }
                    guard race.claim() else { return }
                    race.cancelWork()
                    await onTimeout()
                    race.complete(.failure(NotificationHelperTransportError.timedOut))
                }
            }
        } onCancel: {
            guard race.claim() else { return }
            race.cancelWork()
            Task { await onTimeout() }
            race.complete(.failure(CancellationError()))
        }
    }

    /// Opens a persistent input channel to the official socket, over which
    /// `PaneInputChannel` writes newline-delimited input frames to the daemon's
    /// `pane.input.stream`. Uses its OWN connection (like `stream`) so input
    /// backpressure never blocks the shared command socket or the pane.stream
    /// firehose. `openLine` is the JSON `pane.input.stream` open request the
    /// daemon's `--duplex` bridge reads first from stdin.
    public nonisolated func openInputChannel(_ openLine: String) -> PaneInputChannel {
        PaneInputChannel(
            makeConnection: { try await self.makeConnection() },
            command: #"exec /usr/bin/nc -U "$HOME"/"# + Self.shellQuote(remoteSocketPath),
            openLine: openLine
        )
    }

    /// Opens a streaming upload channel for one gram attachment: a dedicated SSH
    /// exec channel running `herdr api-bridge --duplex`, over which
    /// `GramUploadChannel` writes chunk frames to the daemon's
    /// `gram.upload.stream`. Its OWN connection, like `stream` and
    /// `openInputChannel`, so a multi-MB upload never blocks the shared command
    /// client or the `pane.stream` firehose. `openLine` is the JSON
    /// `gram.upload.stream` open request the `--duplex` bridge reads first.
    ///
    /// Deliberately NOT part of `HerdrTransport`: that protocol has two members,
    /// and a third would force an implementation into all 21 conformances (18 of
    /// them test doubles) for no gain. The downcast is what makes every double
    /// take the per-chunk fallback path automatically.
    public nonisolated func openUploadChannel(_ openLine: String) -> GramUploadChannel {
        GramUploadChannel(
            makeConnection: { try await self.makeConnection() },
            command: #"exec /usr/bin/nc -U "$HOME"/"# + Self.shellQuote(remoteSocketPath),
            openLine: openLine
        )
    }

    /// Opens a dedicated SSH PTY using the official attachment command for the
    /// typed target. `--takeover` is deliberately never present.
    public func openTerminal(
        target: OfficialTerminalAttachmentTarget, cols: Int = 80, rows: Int = 24
    ) -> OfficialAgentTerminalSession {
        let id = UUID()
        let session = OfficialAgentTerminalSession(
            id: id,
            target: target,
            herdrSession: credentials.herdrSession,
            initialCols: cols,
            initialRows: rows,
            makeConnection: { try await self.makeConnection() },
            onFinish: { await self.removeTerminal(id: id) }
        )
        terminalSessions[id] = session
        return session
    }

    /// Compatibility entry point for the shipped agent roster.
    public func openAgentTerminal(
        target: String, cols: Int = 80, rows: Int = 24
    ) -> OfficialAgentTerminalSession {
        openTerminal(target: .agent(paneID: target), cols: cols, rows: rows)
    }

    /// Uploads one normalized image to a private, uniquely-created directory in
    /// the SSH user's home. The returned absolute path is safe to paste into the
    /// terminal; this method never writes either clipboard and never submits input.
    public func uploadAttachment(
        data: Data, fileExtension: String
    ) async throws -> RemoteAttachment {
        guard data.count <= RemoteAttachment.maximumByteCount else {
            throw RemoteAttachmentError.tooLarge(
                bytes: data.count, maximum: RemoteAttachment.maximumByteCount)
        }
        guard let normalizedExtension = RemoteAttachment.safeExtension(fileExtension) else {
            throw RemoteAttachmentError.unsupportedFormat
        }

        let id = UUID()
        let operation = RemoteAttachmentUploadOperation(
            data: data,
            fileExtension: normalizedExtension,
            makeConnection: { try await self.makeConnection() })
        attachmentUploads[id] = operation
        defer { attachmentUploads[id] = nil }

        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            Task { await operation.cancel() }
        }
    }

    /// Removes a completed upload that the user cancelled before inserting it.
    /// Callers must never use this for an attachment that has crossed the
    /// terminal boundary: inserted images intentionally outlive the app view.
    public func removeUninsertedAttachment(_ attachment: RemoteAttachment) async throws {
        let client = try await makeConnection()
        do {
            let sftp = try await client.openSFTP()
            do {
                let home = try await sftp.getRealPath(atPath: ".")
                guard let cleanup = RemoteAttachmentCleanup(
                    completedAttachment: attachment, home: home) else {
                    throw RemoteAttachmentError.uploadedFileInvalid
                }
                try await removeRemoteAttachmentFiles(
                    cleanup, expectedCompletedAttachment: attachment, using: sftp)
                try? await sftp.close()
            } catch {
                try? await sftp.close()
                throw error
            }
            try? await client.close()
        } catch {
            try? await client.close()
            throw error
        }
    }

    /// Retries cleanup for an incomplete upload whose first disposal attempt
    /// lost its connection. The opaque handle is accepted only by the same
    /// host transport and revalidated against that account's canonical home.
    public func retryAttachmentCleanup(_ cleanup: RemoteAttachmentCleanup) async throws {
        try await runRemoteAttachmentCleanup(
            cleanup, expectedCompletedAttachment: nil,
            makeConnection: { try await self.makeConnection() })
    }

    private func removeTerminal(id: UUID) {
        terminalSessions[id] = nil
    }

    /// Closes the held SSH connection. Idempotent.
    public func close() async {
        // Invalidate any in-flight connect so a handshake that resolves after this
        // point is reaped by connectedClient() rather than installed post-close.
        generation &+= 1
        connectTask?.cancel()
        connectTask = nil
        // Snapshot and CLEAR the slot BEFORE awaiting teardown. Awaiting the old
        // client's close is a suspension point, and actor reentrancy lets a NEW
        // generation connect install a fresh client during it (a legitimate
        // reconnect). A trailing unconditional `client = nil` would then discard that
        // live session unclosed. Nil-before-await confines this teardown to the OLD
        // client and never clobbers a reconnect that lands mid-close.
        let old = client
        client = nil
        let terminals = Array(terminalSessions.values)
        terminalSessions.removeAll()
        let uploads = Array(attachmentUploads.values)
        attachmentUploads.removeAll()
        for upload in uploads { await upload.cancel() }
        for terminal in terminals { await terminal.close() }
        try? await old?.close()
    }
}

public struct RemoteAttachment: Equatable, Sendable {
    public static let maximumByteCount = 12 * 1_024 * 1_024

    public let path: String
    public let byteCount: Int

    public init(path: String, byteCount: Int) {
        self.path = path
        self.byteCount = byteCount
    }

    static func safeExtension(_ value: String) -> String? {
        switch value.lowercased() {
        case "png": return "png"
        case "jpg", "jpeg": return "jpg"
        default: return nil
        }
    }

    static func isOwnedPath(_ path: String, home: String) -> Bool {
        guard RemoteAttachmentUploadOperation.isSafeAbsolutePath(home) else { return false }
        let root = (home == "/" ? "" : home) + "/"
        guard path.hasPrefix(root) else { return false }
        let relative = path.dropFirst(root.count)
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }

        let directory = components[0]
        let directoryPrefix = ".herdr-companion-attachments-"
        guard directory.hasPrefix(directoryPrefix) else { return false }
        let nonce = directory.dropFirst(directoryPrefix.count)
        guard nonce.count == 32,
              nonce.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }

        let filename = components[1]
        guard let dot = filename.lastIndex(of: "."),
              safeExtension(String(filename[filename.index(after: dot)...])) != nil else { return false }
        let stem = filename[..<dot]
        let filePrefix = "attachment-"
        guard stem.hasPrefix(filePrefix) else { return false }
        return UUID(uuidString: String(stem.dropFirst(filePrefix.count))) != nil
    }
}

/// Exact app-owned paths retained when an incomplete upload could not be
/// authoritatively removed. Construction is internal to the upload code; the UI
/// can only carry the handle back to the transport for a deliberate retry.
public struct RemoteAttachmentCleanup: Equatable, Sendable {
    /// Opaque handle for app recovery tests. Production upload still constructs
    /// this only from the guarded cleanup path.
    public static func testingHandle() -> RemoteAttachmentCleanup {
        let home = "/Users/fixture"
        let attachment = RemoteAttachment(
            path: home + "/.herdr-companion-attachments-0123456789abcdef0123456789abcdef/attachment-11111111-1111-1111-1111-111111111111.png",
            byteCount: 4)
        return RemoteAttachmentCleanup(completedAttachment: attachment, home: home)!
    }

    fileprivate let home: String
    fileprivate let directory: String
    fileprivate let filePaths: [String]

    fileprivate init?(completedAttachment: RemoteAttachment, home: String) {
        guard RemoteAttachment.isOwnedPath(completedAttachment.path, home: home),
              let separator = completedAttachment.path.lastIndex(of: "/") else { return nil }
        self.home = home
        self.directory = String(completedAttachment.path[..<separator])
        self.filePaths = [completedAttachment.path]
    }

    fileprivate init?(home: String, directory: String, partial: String, final: String) {
        guard RemoteAttachmentUploadOperation.isSafeAbsolutePath(home),
              Self.isOwnedDirectory(directory, home: home),
              Self.isOwnedPartialPath(partial, directory: directory),
              RemoteAttachment.isOwnedPath(final, home: home),
              final.hasPrefix(directory + "/") else { return nil }
        self.home = home
        self.directory = directory
        self.filePaths = [partial, final]
    }

    private static func isOwnedDirectory(_ path: String, home: String) -> Bool {
        let root = (home == "/" ? "" : home) + "/.herdr-companion-attachments-"
        guard path.hasPrefix(root) else { return false }
        let nonce = path.dropFirst(root.count)
        return nonce.count == 32 && nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isOwnedPartialPath(_ path: String, directory: String) -> Bool {
        let prefix = directory + "/.attachment-"
        guard path.hasPrefix(prefix), path.hasSuffix(".uploading") else { return false }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -".uploading".count)
        return UUID(uuidString: String(path[start..<end])) != nil
    }
}

public enum RemoteAttachmentError: Error, Equatable, Sendable, LocalizedError {
    case tooLarge(bytes: Int, maximum: Int)
    case unsupportedFormat
    case unsafeRemoteHome
    case privateDirectoryUnavailable
    case privateDirectoryPermissions
    case uploadedFileInvalid
    case cleanupRequired(RemoteAttachmentCleanup, String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(_, let maximum):
            return "The image is too large to upload. Choose one under \(maximum / 1_024 / 1_024) MB."
        case .unsupportedFormat:
            return "The selected image could not be converted to PNG or JPEG."
        case .unsafeRemoteHome:
            return "The Mac returned an unsafe home-directory path."
        case .privateDirectoryUnavailable:
            return "Herdr Companion could not create its private attachment directory on the Mac."
        case .privateDirectoryPermissions:
            return "The attachment directory on the Mac is not private (0700)."
        case .uploadedFileInvalid:
            return "The uploaded image could not be verified on the Mac."
        case .cleanupRequired(_, let reason):
            return "The upload stopped, but its private image could not be removed from the Mac (\(reason)). Reconnect to this Mac and retry Discard."
        }
    }
}

func isExplicitSFTPAbsence(_ error: Error) -> Bool {
    guard let status = error as? SFTPMessage.Status else { return false }
    return isExplicitSFTPAbsence(status.errorCode)
}

func isExplicitSFTPAbsence(_ statusCode: SFTPStatusCode) -> Bool {
    statusCode == .noSuchFile
}

private func runRemoteAttachmentCleanup(
    _ cleanup: RemoteAttachmentCleanup,
    expectedCompletedAttachment: RemoteAttachment?,
    makeConnection: @escaping @Sendable () async throws -> SSHClient
) async throws {
    let client = try await makeConnection()
    do {
        let sftp = try await client.openSFTP()
        do {
            try await removeRemoteAttachmentFiles(
                cleanup, expectedCompletedAttachment: expectedCompletedAttachment, using: sftp)
            try? await sftp.close()
        } catch {
            try? await sftp.close()
            throw error
        }
        try? await client.close()
    } catch {
        try? await client.close()
        throw error
    }
}

private func removeRemoteAttachmentFiles(
    _ cleanup: RemoteAttachmentCleanup,
    expectedCompletedAttachment: RemoteAttachment?,
    using sftp: SFTPClient
) async throws {
    guard try await sftp.getRealPath(atPath: ".") == cleanup.home else {
        throw RemoteAttachmentError.uploadedFileInvalid
    }

    let directoryAttributes: SFTPFileAttributes
    do {
        guard try await sftp.getRealPath(atPath: cleanup.directory) == cleanup.directory else {
            throw RemoteAttachmentError.uploadedFileInvalid
        }
        directoryAttributes = try await sftp.getAttributes(at: cleanup.directory)
    } catch where isExplicitSFTPAbsence(error) {
        return
    }
    guard let directoryMode = directoryAttributes.permissions,
          directoryMode & 0o170000 == 0o040000,
          directoryMode & 0o777 == 0o700 else {
        throw RemoteAttachmentError.uploadedFileInvalid
    }

    for path in cleanup.filePaths {
        do {
            guard try await sftp.getRealPath(atPath: path) == path else {
                throw RemoteAttachmentError.uploadedFileInvalid
            }
            let attributes = try await sftp.getAttributes(at: path)
            guard let fileMode = attributes.permissions,
                  fileMode & 0o170000 == 0o100000,
                  fileMode & 0o777 == 0o600 else {
                throw RemoteAttachmentError.uploadedFileInvalid
            }
            if let expectedCompletedAttachment, path == expectedCompletedAttachment.path,
               attributes.size != UInt64(expectedCompletedAttachment.byteCount) {
                throw RemoteAttachmentError.uploadedFileInvalid
            }
            try await sftp.remove(at: path)
        } catch where isExplicitSFTPAbsence(error) {
            continue
        }
    }
    do {
        try await sftp.rmdir(at: cleanup.directory)
    } catch where isExplicitSFTPAbsence(error) {
        return
    }
}

/// One upload owns one SSH/SFTP connection and one unpredictable directory.
/// Citadel 0.12.1 implements both attribute APIs with path-based STAT, so this
/// code does not treat them as lstat/fstat: it creates an unguessable path,
/// validates REALPATH before writing, and uses exclusive file creation.
private actor RemoteAttachmentUploadOperation {
    private let data: Data
    private let fileExtension: String
    private let makeConnection: @Sendable () async throws -> SSHClient

    private var client: SSHClient?
    private var sftp: SFTPClient?
    private var file: SFTPFile?
    private var homePath: String?
    private var directoryPath: String?
    private var partialPath: String?
    private var finalPath: String?
    private var cancelled = false
    private var committed = false

    init(
        data: Data,
        fileExtension: String,
        makeConnection: @escaping @Sendable () async throws -> SSHClient
    ) {
        self.data = data
        self.fileExtension = fileExtension
        self.makeConnection = makeConnection
    }

    func run() async throws -> RemoteAttachment {
        do {
            try checkCancellation()
            let client = try await makeConnection()
            self.client = client
            try checkCancellation()

            let sftp = try await client.openSFTP()
            self.sftp = sftp
            try checkCancellation()

            let home = try await sftp.getRealPath(atPath: ".")
            guard Self.isSafeAbsolutePath(home) else {
                throw RemoteAttachmentError.unsafeRemoteHome
            }
            homePath = home

            let nonce = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let directory = (home == "/" ? "" : home)
                + "/.herdr-companion-attachments-" + nonce
            directoryPath = directory
            let base = "attachment-" + UUID().uuidString.lowercased()
            let partial = directory + "/." + base + ".uploading"
            let final = directory + "/" + base + "." + fileExtension
            partialPath = partial
            finalPath = final
            var directoryAttributes = SFTPFileAttributes()
            directoryAttributes.permissions = 0o700
            try await sftp.createDirectory(
                atPath: directory, attributes: directoryAttributes)
            try checkCancellation()

            // Citadel propagates a non-OK STATUS. The canonical-path and mode
            // checks separately defend against a substituted or permissive path
            // before any file is opened. Both attribute calls are path STAT.
            guard try await sftp.getRealPath(atPath: directory) == directory else {
                throw RemoteAttachmentError.privateDirectoryUnavailable
            }
            try await sftp.setAttributes(at: directory, to: directoryAttributes)
            let directoryMode = try await sftp.getAttributes(at: directory).permissions
            guard let directoryMode,
                  directoryMode & 0o170000 == 0o040000,
                  directoryMode & 0o777 == 0o700 else {
                throw RemoteAttachmentError.privateDirectoryPermissions
            }

            var fileAttributes = SFTPFileAttributes()
            fileAttributes.permissions = 0o600
            let file = try await sftp.openFile(
                filePath: partial,
                flags: [.write, .create, .forceCreate],
                attributes: fileAttributes)
            self.file = file
            try checkCancellation()

            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            try await file.write(buffer)
            try checkCancellation()
            try await file.setAttributes(to: fileAttributes)
            try await file.close()
            self.file = nil
            try checkCancellation()

            try await sftp.rename(at: partial, to: final)
            try checkCancellation()

            guard try await sftp.getRealPath(atPath: final) == final else {
                throw RemoteAttachmentError.uploadedFileInvalid
            }
            let attributes = try await sftp.getAttributes(at: final)
            guard attributes.size == UInt64(data.count),
                  let fileMode = attributes.permissions,
                  fileMode & 0o170000 == 0o100000,
                  fileMode & 0o777 == 0o600 else {
                throw RemoteAttachmentError.uploadedFileInvalid
            }

            try checkCancellation()
            committed = true
            try await closeChannels()
            return RemoteAttachment(path: final, byteCount: data.count)
        } catch {
            try? await closeChannels()
            let cleanupFailure = await removeIncompleteUpload()
            if let cleanupFailure,
               let cleanup = cleanupHandle() {
                throw RemoteAttachmentError.cleanupRequired(
                    cleanup, cleanupFailure.localizedDescription)
            }
            if cancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    func cancel() async {
        guard !committed else { return }
        cancelled = true
        try? await closeChannels()
    }

    private func checkCancellation() throws {
        if cancelled || Task.isCancelled { throw CancellationError() }
    }

    private func cleanupHandle() -> RemoteAttachmentCleanup? {
        guard let homePath, let directoryPath, let partialPath, let finalPath else { return nil }
        return RemoteAttachmentCleanup(
            home: homePath, directory: directoryPath, partial: partialPath, final: finalPath)
    }

    private func removeIncompleteUpload() async -> Error? {
        guard !committed, let cleanup = cleanupHandle() else { return nil }
        let makeConnection = self.makeConnection
        do {
            // This child task is intentionally not cancelled with the upload:
            // cleanup gets one bounded fresh connection attempt, and a failure
            // is returned with the exact owned paths for explicit UI retry.
            try await Task {
                try await runRemoteAttachmentCleanup(
                    cleanup, expectedCompletedAttachment: nil,
                    makeConnection: makeConnection)
            }.value
            return nil
        } catch {
            return error
        }
    }

    private func closeChannels() async throws {
        if let file { try? await file.close() }
        file = nil
        if let sftp { try? await sftp.close() }
        self.sftp = nil
        if let client { try? await client.close() }
        self.client = nil
    }

    fileprivate static func isSafeAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            && !path.contains("/../")
            && !path.hasSuffix("/..")
    }
}

/// Failure modes specific to the app-owned official terminal attachment.
public enum OfficialTerminalError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case herdrNotInstalled
    case controllerBusy
    case attachFailed
    case transport(String)

    public var description: String {
        switch self {
        case .herdrNotInstalled:
            return "The official Herdr executable was not found on the Mac. Expected PATH, /opt/homebrew/bin/herdr, /usr/local/bin/herdr, or ~/.local/bin/herdr."
        case .controllerBusy:
            return "This terminal already has a controller. The companion did not take it over. Detach the other controller, then reconnect."
        case .attachFailed:
            return "Herdr could not attach to this agent. It may have exited or changed identity."
        case .transport(let message):
            return message
        }
    }

    public var errorDescription: String? { description }
}

/// Issues monotonically ordered input tickets synchronously. Calls into an actor
/// may be scheduled out of order; the ticket lets the actor wait for any earlier
/// call instead of sending a later key first.
final class TerminalInputTickets: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func issue() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let issued = value
        value &+= 1
        return issued
    }
}

/// Read from synchronous terminal delegates without hopping to the session actor.
/// A key is accepted only if readiness was true at the instant `send` was called;
/// becoming ready later never reclassifies or replays pre-ready input.
final class TerminalReadinessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    func markReady() {
        lock.lock()
        ready = true
        lock.unlock()
    }
}

struct OrderedTerminalInputBuffer {
    private(set) var next: UInt64 = 0
    private var pending: [UInt64: Data] = [:]

    mutating func insert(_ data: Data, ticket: UInt64) {
        pending[ticket] = data
    }

    mutating func takeNext() -> Data? {
        guard let data = pending.removeValue(forKey: next) else { return nil }
        next &+= 1
        return data
    }

    mutating func removeAll() {
        pending.removeAll()
    }
}

struct TerminalDimensions: Equatable {
    let cols: Int
    let rows: Int
    let pixelWidth: Int
    let pixelHeight: Int

    static func clamped(
        cols: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0
    ) -> TerminalDimensions {
        TerminalDimensions(
            cols: max(4, cols), rows: max(2, rows),
            pixelWidth: max(0, pixelWidth), pixelHeight: max(0, pixelHeight))
    }
}

public enum OfficialTerminalInputError: Error, Equatable, Sendable, LocalizedError {
    case notReady
    case closed

    public var errorDescription: String? {
        switch self {
        case .notReady: return "The terminal is not ready for input."
        case .closed: return "The terminal closed before the attachment path could be written."
        }
    }
}

/// The two public official CLI attachment namespaces are intentionally distinct:
/// agent attachment accepts a pane/name target, while a plain shell must attach
/// through its server-returned terminal id.
public enum OfficialTerminalAttachmentTarget: Equatable, Hashable, Sendable {
    case agent(paneID: String)
    case terminal(terminalID: String)
}

protocol OfficialTerminalInputWriter {
    func write(_ buffer: ByteBuffer) async throws
    func changeSize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws
}

extension TTYStdinWriter: OfficialTerminalInputWriter {}

/// One dedicated SSH PTY running an official agent or direct-terminal attach.
///
/// The channel owns neither the agent nor the Herdr server. Closing it only ends
/// this app's attachment. Input is at-most-once and is never retained for a new
/// attachment after a drop.
public actor OfficialAgentTerminalSession {
    public nonisolated let output: AsyncThrowingStream<Data, Error>

    private let id: UUID
    private let target: OfficialTerminalAttachmentTarget
    private let herdrSession: String
    private let makeConnection: @Sendable () async throws -> SSHClient
    private let onFinish: @Sendable () async -> Void
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private nonisolated let tickets = TerminalInputTickets()
    private nonisolated let readinessGate = TerminalReadinessGate()

    private var client: SSHClient?
    private var writer: (any OfficialTerminalInputWriter)?
    private var task: Task<Void, Never>?
    private var inputBuffer = OrderedTerminalInputBuffer()
    private var inputAcknowledgements: [UInt64: CheckedContinuation<Void, Error>] = [:]
    private var inputWriteInFlight: UInt64?
    private var drainingInput = false
    private var closed = false
    private var didFinish = false
    private var startupProbe = Data()
    private var readinessProbe = Data()
    private var latestDimensions: TerminalDimensions

    /// Official frame rendering starts with this synchronized-output prefix.
    /// Shell echo/banner/setup bytes do not constitute attachment readiness.
    static let officialFramePrefix = Data("\u{1b}[?2026h\u{1b}[?25l\u{1b}]8;;\u{1b}\\".utf8)

    init(
        id: UUID,
        target: OfficialTerminalAttachmentTarget,
        herdrSession: String,
        initialCols: Int,
        initialRows: Int,
        makeConnection: @escaping @Sendable () async throws -> SSHClient,
        onFinish: @escaping @Sendable () async -> Void,
        initialWriter: (any OfficialTerminalInputWriter)? = nil,
        initiallyReady: Bool = false
    ) {
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        output = AsyncThrowingStream { captured = $0 }
        continuation = captured
        self.id = id
        self.target = target
        self.herdrSession = herdrSession
        self.latestDimensions = TerminalDimensions.clamped(
            cols: initialCols, rows: initialRows)
        self.makeConnection = makeConnection
        self.onFinish = onFinish
        self.writer = initialWriter
        if initiallyReady { readinessGate.markReady() }
    }

    /// Compatibility initializer retained for existing agent-only callers/tests.
    init(
        id: UUID,
        target: String,
        herdrSession: String,
        initialCols: Int,
        initialRows: Int,
        makeConnection: @escaping @Sendable () async throws -> SSHClient,
        onFinish: @escaping @Sendable () async -> Void,
        initialWriter: (any OfficialTerminalInputWriter)? = nil,
        initiallyReady: Bool = false
    ) {
        self.init(
            id: id,
            target: .agent(paneID: target),
            herdrSession: herdrSession,
            initialCols: initialCols,
            initialRows: initialRows,
            makeConnection: makeConnection,
            onFinish: onFinish,
            initialWriter: initialWriter,
            initiallyReady: initiallyReady)
    }

    /// Starts once. Keeping construction and start separate lets the UI subscribe
    /// to `output` before the first byte can arrive.
    public func start() {
        guard task == nil, !closed else { return }
        task = Task { await self.run() }
    }

    /// Synchronous enqueue for SwiftTerm's delegate. The ticket preserves the
    /// exact delegate call order even if the Tasks reach this actor out of order.
    public nonisolated func send(_ data: Data) {
        guard !data.isEmpty else { return }
        let ticket = tickets.issue()
        let acceptedAtSend = readinessGate.isReady
        Task { await self.accept(data, ticket: ticket, acceptedAtSend: acceptedAtSend) }
    }

    /// Enqueues one input transaction through the same ticketed queue as the
    /// synchronous terminal delegate and returns only after that session's TTY
    /// writer accepted the bytes. It never waits for the remote program to
    /// interpret them and never carries input into a later session.
    public nonisolated func sendAcknowledged(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let ticket = tickets.issue()
        let acceptedAtSend = readinessGate.isReady
        try await withCheckedThrowingContinuation { continuation in
            Task {
                await self.accept(
                    data, ticket: ticket, acceptedAtSend: acceptedAtSend,
                    acknowledgement: continuation)
            }
        }
    }

    public var readyForInput: Bool { readinessGate.isReady }

    public func resize(cols: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) async {
        let dimensions = TerminalDimensions.clamped(
            cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        guard !closed else { return }
        latestDimensions = dimensions
        guard let writer else { return }
        do {
            try await writer.changeSize(
                cols: dimensions.cols, rows: dimensions.rows,
                pixelWidth: dimensions.pixelWidth, pixelHeight: dimensions.pixelHeight)
        } catch {
            await fail(.transport("Terminal resize failed: \(error.localizedDescription)"))
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        rejectPendingInput(with: OfficialTerminalInputError.closed, excluding: inputWriteInFlight)
        inputBuffer.removeAll()
        writer = nil
        task?.cancel()
        task = nil
        continuation.finish()
        let held = client
        client = nil
        try? await held?.close()
        await notifyFinished()
    }

    private func run() async {
        guard #available(macOS 15.0, *) else {
            await fail(.transport("Interactive SSH PTY support requires macOS 15 or later on this build host."))
            return
        }
        do {
            let connected = try await makeConnection()
            if closed {
                try? await connected.close()
                return
            }
            client = connected
            let target = self.target
            let herdrSession = self.herdrSession
            let continuation = self.continuation
            let dimensions = latestDimensions
            let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm-256color",
                terminalCharacterWidth: dimensions.cols,
                terminalRowHeight: dimensions.rows,
                terminalPixelWidth: dimensions.pixelWidth,
                terminalPixelHeight: dimensions.pixelHeight,
                terminalModes: SSHTerminalModes([:]))

            try await connected.withPTY(request) { inbound, outbound in
                // A PTY starts a shell. Send one securely-quoted exec line before
                // publishing the writer, so user input can never land in that shell.
                let command = Self.attachCommand(target: target, session: herdrSession)
                try await outbound.write(ByteBuffer(string: command + "\n"))
                try await self.install(outbound)

                for try await event in inbound {
                    if Task.isCancelled { throw CancellationError() }
                    let buffer: ByteBuffer
                    switch event {
                    case .stdout(let bytes), .stderr(let bytes): buffer = bytes
                    }
                    let data = Data(buffer.readableBytesView)
                    if !data.isEmpty {
                        self.recordStartupProbe(data)
                        continuation.yield(data)
                        if self.recordReadiness(data) { await self.drainInput() }
                    }
                }
            }
            await finishNormally()
        } catch is CancellationError {
            if !closed { await close() }
        } catch {
            let mapped = mapAttachFailure(error)
            await fail(mapped)
        }
    }

    static func attachCommand(
        target: OfficialTerminalAttachmentTarget, session: String
    ) -> String {
        let command: String
        let identifier: String
        switch target {
        case .agent(let paneID):
            command = " agent attach "
            identifier = paneID
        case .terminal(let terminalID):
            command = " terminal attach "
            identifier = terminalID
        }
        return CitadelTransport.herdrPathResolution
            + #"exec "$HERDR" --session "# + CitadelTransport.shellQuote(session)
            + command + CitadelTransport.shellQuote(identifier)
    }

    static func attachCommand(target: String, session: String) -> String {
        attachCommand(target: .agent(paneID: target), session: session)
    }

    private func install(_ writer: TTYStdinWriter) async throws {
        guard !closed else { throw CancellationError() }
        self.writer = writer
        let dimensions = latestDimensions
        try await writer.changeSize(
            cols: dimensions.cols, rows: dimensions.rows,
            pixelWidth: dimensions.pixelWidth, pixelHeight: dimensions.pixelHeight)
        await drainInput()
    }

    /// Normal CLI completion (including the user's Ctrl-B, q detach) must reap
    /// the dedicated SSH client just like explicit close and error completion.
    private func finishNormally() async {
        guard !closed else { return }
        closed = true
        rejectPendingInput(with: OfficialTerminalInputError.closed, excluding: inputWriteInFlight)
        inputBuffer.removeAll()
        writer = nil
        task = nil
        continuation.finish()
        let held = client
        client = nil
        try? await held?.close()
        await notifyFinished()
    }

    private func accept(
        _ data: Data,
        ticket: UInt64,
        acceptedAtSend: Bool,
        acknowledgement: CheckedContinuation<Void, Error>? = nil
    ) async {
        guard !closed else {
            acknowledgement?.resume(throwing: OfficialTerminalInputError.closed)
            return
        }
        inputBuffer.insert(acceptedAtSend ? data : Data(), ticket: ticket)
        if let acknowledgement {
            if acceptedAtSend {
                inputAcknowledgements[ticket] = acknowledgement
            } else {
                acknowledgement.resume(throwing: OfficialTerminalInputError.notReady)
            }
        }
        guard readinessGate.isReady else { return }
        await drainInput()
    }

    private func drainInput() async {
        guard !drainingInput, readinessGate.isReady, let writer, !closed else { return }
        drainingInput = true
        defer { drainingInput = false }
        do {
            while !closed, let data = inputBuffer.takeNext() {
                let ticket = inputBuffer.next &- 1
                inputWriteInFlight = ticket
                if !data.isEmpty { try await writer.write(ByteBuffer(bytes: data)) }
                inputWriteInFlight = nil
                inputAcknowledgements.removeValue(forKey: ticket)?.resume()
            }
        } catch {
            let mapped = OfficialTerminalError.transport(
                "Terminal input failed: \(error.localizedDescription)")
            if let ticket = inputWriteInFlight {
                inputWriteInFlight = nil
                inputAcknowledgements.removeValue(forKey: ticket)?.resume(throwing: mapped)
            }
            rejectPendingInput(with: mapped)
            if !closed { await fail(mapped) }
        }
    }

    private func recordStartupProbe(_ data: Data) {
        guard startupProbe.count < 8_192 else { return }
        startupProbe.append(data.prefix(8_192 - startupProbe.count))
    }

    private func recordReadiness(_ data: Data) -> Bool {
        guard !readinessGate.isReady else { return false }
        readinessProbe.append(data)
        if readinessProbe.range(of: Self.officialFramePrefix) != nil {
            readinessGate.markReady()
            readinessProbe.removeAll()
            return true
        }
        let overlap = max(0, Self.officialFramePrefix.count - 1)
        if readinessProbe.count > overlap {
            readinessProbe.removeFirst(readinessProbe.count - overlap)
        }
        return false
    }

    private func mapAttachFailure(_ error: Error) -> OfficialTerminalError {
        let text = String(decoding: startupProbe, as: UTF8.self)
        if text.contains("already has an attached client") || text.contains("retry with --takeover") {
            return .controllerBusy
        }
        let printedMissingSentinel = text
            .components(separatedBy: .newlines)
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                == CitadelTransport.herdrNotInstalledSentinel }
        if printedMissingSentinel { return .herdrNotInstalled }
        if error is SSHClient.CommandFailed { return .attachFailed }
        if let transport = error as? TransportError { return .transport(transport.description) }
        return .transport("Terminal connection failed: \(error.localizedDescription)")
    }

    private func fail(_ error: OfficialTerminalError) async {
        guard !closed else { return }
        closed = true
        rejectPendingInput(with: error, excluding: inputWriteInFlight)
        inputBuffer.removeAll()
        writer = nil
        continuation.finish(throwing: error)
        let held = client
        client = nil
        try? await held?.close()
        await notifyFinished()
    }

    private func rejectPendingInput(with error: Error, excluding excludedTicket: UInt64? = nil) {
        let rejected = inputAcknowledgements.filter { $0.key != excludedTicket }
        for ticket in rejected.keys { inputAcknowledgements.removeValue(forKey: ticket) }
        for continuation in rejected.values { continuation.resume(throwing: error) }
    }

    private func notifyFinished() async {
        guard !didFinish else { return }
        didFinish = true
        await onFinish()
    }
}

/// Accumulates raw stdout bytes and yields complete newline-delimited lines,
/// decoding UTF-8 only at line boundaries.
///
/// Decoding each SSH channel-data chunk independently (`String(buffer:)`) would
/// corrupt any multi-byte UTF-8 scalar split across a chunk boundary: the
/// incomplete tail becomes U+FFFD and its bytes are consumed, so concatenating
/// the decoded chunks can never reconstitute the character. A `\n` byte (0x0A)
/// can never fall inside a multi-byte UTF-8 sequence, so decoding only at
/// newlines keeps every line intact.
struct LineAccumulator {
    private var bytes: [UInt8] = []

    /// Appends a chunk and returns the lines it completed (newline stripped).
    mutating func append(_ buffer: ByteBuffer) -> [String] {
        bytes.append(contentsOf: buffer.readableBytesView)
        var lines: [String] = []
        while let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: bytes[..<newline], as: UTF8.self))
            bytes.removeSubrange(...newline)
        }
        return lines
    }

    /// Bytes remain after the last newline (an unterminated final line).
    var hasRemainder: Bool { !bytes.isEmpty }
    var bufferedByteCount: Int { bytes.count }

    /// Decodes and clears whatever is left after the last newline.
    mutating func flush() -> String {
        defer { bytes.removeAll() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Owns a subscription's dedicated SSH client so termination can close it —
/// which reaps the exec channel that Citadel's `executeCommandStream` would
/// otherwise leave open. Idempotent; a `close` that races the connect (`adopt`
/// after `close`) still closes the late client.
actor StreamConnection {
    private var client: SSHClient?
    private var closed = false

    func adopt(_ client: SSHClient) async {
        if closed {
            try? await client.close()
        } else {
            self.client = client
        }
    }

    func close() async {
        closed = true
        let held = client
        client = nil
        try? await held?.close()
    }
}

/// A remote command's non-zero exit, abstracted so `parseBridgeOutput`'s classification
/// path is unit-testable. A test cannot construct Citadel's `SSHClient.CommandFailed`
/// (its memberwise initialiser is internal to that module), so `parseBridgeOutput`
/// catches THIS protocol instead of the concrete type; the test injects its own
/// conforming error through a fake stream. Citadel's error conforms below.
protocol RemoteExitError: Error {
    var remoteExitCode: Int { get }
}

extension SSHClient.CommandFailed: RemoteExitError {
    var remoteExitCode: Int { exitCode }
}
