import Foundation
import HerdrKit

/// App-layer session handle so tests and DEBUG fixtures can inject an inert
/// attachment without a second transport. Production wraps `OfficialAgentTerminalSession`.
protocol CompanionTerminalSessionHandle: AnyObject {
    var output: AsyncThrowingStream<Data, Error> { get }
    var readyForInput: Bool { get async }
    func start() async
    func send(_ data: Data)
    func sendAcknowledged(_ data: Data) async throws
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async
    func close() async
}

final class OfficialTerminalSessionHandle: CompanionTerminalSessionHandle {
    let session: OfficialAgentTerminalSession

    init(session: OfficialAgentTerminalSession) {
        self.session = session
    }

    var output: AsyncThrowingStream<Data, Error> { session.output }
    var readyForInput: Bool { get async { await session.readyForInput } }
    func start() async { await session.start() }
    func send(_ data: Data) { session.send(data) }
    func sendAcknowledged(_ data: Data) async throws { try await session.sendAcknowledged(data) }
    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        await session.resize(cols: cols, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
    func close() async { await session.close() }
}

typealias CompanionTerminalOpener = (
    OfficialTerminalAttachmentTarget, Int, Int, Int, Int
) async -> Result<any CompanionTerminalSessionHandle, Error>

enum CompanionTerminalOpeners {
    static func official(_ transport: CitadelTransport) -> CompanionTerminalOpener {
        { target, cols, rows, _, _ in
            let session = await transport.openTerminal(target: target, cols: cols, rows: rows)
            return .success(OfficialTerminalSessionHandle(session: session))
        }
    }
}

enum CompanionTerminalIdentity {
    static func key(hostID: UUID?, target: OfficialTerminalAttachmentTarget) -> String {
        let host = hostID?.uuidString ?? "none"
        switch target {
        case .agent(let paneID): return "\(host)|agent|\(paneID)"
        case .terminal(let terminalID): return "\(host)|terminal|\(terminalID)"
        }
    }

    static func matches(_ destination: CompanionTerminalDestination, pane: TopologyPaneInfo) -> Bool {
        guard destination.pane.paneID == pane.paneID else { return false }
        switch destination.target {
        case .agent(let paneID):
            return pane.isAgent && pane.paneID == paneID
        case .terminal(let terminalID):
            return !pane.isAgent && pane.terminalID == terminalID
        }
    }
}

enum CompanionDraftInsertResult: Equatable {
    case written
    case unavailable
    case rejected(String)
}

enum CompanionDraftValidation: Equatable {
    case accepted(String)
    case rejected(String)
}

enum CompanionDraftInsertion {
    /// Validates draft text against the actual paste mode. Does not alter the
    /// remote terminal. Returns the exact payload to wrap with `attachmentPasteData`.
    static func validatedText(_ text: String, bracketedPaste: Bool) -> CompanionDraftValidation {
        guard !text.isEmpty else {
            return .rejected("The draft is empty.")
        }
        if let reason = rejectionReason(in: text, bracketedPaste: bracketedPaste) {
            return .rejected(reason)
        }
        return .accepted(text)
    }

    private static func rejectionReason(in text: String, bracketedPaste: Bool) -> String? {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x7f || value == 0x1b {
                return "The draft contains control characters that cannot be inserted safely. It was not written."
            }
            if value < 0x20 {
                if bracketedPaste, value == 0x09 || value == 0x0a || value == 0x0d {
                    continue
                }
                if !bracketedPaste, value == 0x0a || value == 0x0d {
                    return "This terminal is not in bracketed-paste mode, so a multiline draft would submit a line. The text was kept and not written."
                }
                if !bracketedPaste, value == 0x09 {
                    return "This terminal is not in bracketed-paste mode, so a tab would be interpreted as a terminal key. The text was kept and not written."
                }
                return "The draft contains control characters that cannot be inserted safely. It was not written."
            }
        }
        return nil
    }
}



struct CompanionInsertionOwner: Equatable, Hashable {
    let savedHostID: UUID
    let hostLabel: String
    let host: String
    let username: String
    let session: String

    init(_ saved: SavedHost) {
        savedHostID = saved.id
        hostLabel = saved.label
        host = saved.host
        username = saved.username
        session = saved.herdrSession
    }

    func matches(_ saved: SavedHost) -> Bool {
        savedHostID == saved.id
            && host == saved.host
            && username == saved.username
            && session == saved.herdrSession
    }
}

enum CompanionInsertionPhase: Equatable {
    case uploading
    case uploadedUnsubmitted
    case submitting
    case cleanupInFlight(UUID)
    case resolved
}

struct CompanionInsertionReceipt: Identifiable, Equatable {
    let id: UUID
    let owner: CompanionInsertionOwner
    let target: OfficialTerminalAttachmentTarget
    let title: String
    var payload: CompanionInsertionPayload
    var status: CompanionInsertionStatus
    var phase: CompanionInsertionPhase = .resolved

    var needsUserRecovery: Bool {
        if case .cleanupInFlight = phase { return true }
        switch status {
        case .confirmedNotWritten, .acknowledgementUnknown:
            return phase == .resolved
        case .awaitingAcknowledgement, .written:
            return false
        }
    }

    var recoveryMessage: String? {
        if case .cleanupInFlight = phase {
            return "Discarding the private upload…"
        }
        switch status {
        case .confirmedNotWritten(let message), .acknowledgementUnknown(let message):
            return message
        case .awaitingAcknowledgement, .written:
            return nil
        }
    }

    var allowsCleanup: Bool {
        guard phase == .resolved else { return false }
        switch status {
        case .confirmedNotWritten:
            switch payload {
            case .uploaded, .incompleteCleanup: return true
            case .draft, .pending: return false
            }
        case .acknowledgementUnknown, .awaitingAcknowledgement, .written:
            return false
        }
    }

    var canForgetWithoutDeletion: Bool {
        guard phase == .resolved else { return false }
        switch status {
        case .acknowledgementUnknown:
            switch payload {
            case .uploaded, .incompleteCleanup: return true
            case .draft, .pending: return false
            }
        default:
            return false
        }
    }

    var isCleanupInFlight: Bool {
        if case .cleanupInFlight = phase { return true }
        return false
    }

    var isWriterOwned: Bool { phase == .submitting }
}

enum CompanionInsertionPayload: Equatable {
    case pending
    case draft(String)
    case uploaded(RemoteAttachment)
    case incompleteCleanup(RemoteAttachmentCleanup)
}

enum CompanionInsertionStatus: Equatable {
    case awaitingAcknowledgement
    case written
    case confirmedNotWritten(String)
    case acknowledgementUnknown(String)
}

enum CompanionDraftEditorCommand: Equatable {
    case setText(String)
    case insert
    case cancel
}

enum CompanionSubmissionFinish: Equatable {
    case written(UUID)
    case confirmedNotWritten(UUID)
    case acknowledgementUnknown(UUID)
    case awaiting(UUID)

    var operationID: UUID {
        switch self {
        case .written(let id), .confirmedNotWritten(let id),
             .acknowledgementUnknown(let id), .awaiting(let id):
            return id
        }
    }
}

/// Inert session for tests and DEBUG production-screen fixtures. Captures input
/// and never opens SSH.
enum CompanionFixtureSessionState: String {
    case pending
    case started
    case closed
}

final class CompanionInertTerminalSession: CompanionTerminalSessionHandle {
    let target: OfficialTerminalAttachmentTarget
    let identity = UUID()
    var onLifecycleChange: ((CompanionFixtureSessionState) -> Void)?
    private(set) var writes: [Data] = []
    private(set) var acknowledged: [Data] = []
    private(set) var closed = false
    private(set) var started = false
    var failAcknowledged = false
    var failAcknowledgedUnknown = false
    var acknowledgeDelayNanoseconds: UInt64 = 0
    var suspendAcknowledgement = false
    private(set) var acknowledgementInFlight = false
    var readyValue = true
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var acknowledgementGate: CheckedContinuation<Void, Never>?
    private var acknowledgementFinishQueued = false

    init(target: OfficialTerminalAttachmentTarget, outputText: String = "fixture>") {
        self.target = target
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        output = AsyncThrowingStream { captured = $0 }
        continuation = captured
        continuation.yield(Data(outputText.utf8))
    }

    var readyForInput: Bool { get async { readyValue } }

    func start() async {
        started = true
        let report = onLifecycleChange
        report?(.started)
    }

    func send(_ data: Data) { writes.append(data) }

    func sendAcknowledged(_ data: Data) async throws {
        if closed { throw OfficialTerminalInputError.closed }
        acknowledgementInFlight = true
        defer { acknowledgementInFlight = false }
        if suspendAcknowledgement {
            await withCheckedContinuation { continuation in
                if acknowledgementFinishQueued {
                    acknowledgementFinishQueued = false
                    continuation.resume()
                } else {
                    acknowledgementGate = continuation
                }
            }
        } else if acknowledgeDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: acknowledgeDelayNanoseconds)
        }
        if failAcknowledgedUnknown {
            throw OfficialTerminalError.transport("Terminal input failed: broken pipe")
        }
        if failAcknowledged { throw OfficialTerminalInputError.closed }
        acknowledged.append(data)
    }

    func finishAcknowledgement() {
        if let gate = acknowledgementGate {
            acknowledgementGate = nil
            gate.resume()
        } else {
            acknowledgementFinishQueued = true
        }
    }

    func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {}

    func close() async {
        guard !closed else { return }
        closed = true
        continuation.finish()
        let report = onLifecycleChange
        report?(.closed)
    }
}

enum CompanionInertTerminal {
    static func opener(
        store: CompanionInertSessionStore
    ) -> CompanionTerminalOpener {
        { target, _, _, _, _ in
            let session = CompanionInertTerminalSession(target: target)
            await store.opened(session)
            return .success(session)
        }
    }
}

actor CompanionInertSessionStore {
    private(set) var sessions: [CompanionInertTerminalSession] = []

    func opened(_ session: CompanionInertTerminalSession) {
        sessions.append(session)
    }

    func current() -> CompanionInertTerminalSession? { sessions.last }

    func closedTargets() -> [OfficialTerminalAttachmentTarget] {
        sessions.filter(\.closed).map(\.target)
    }
}


protocol CompanionAttachmentCleaning: AnyObject {
    func removeUninsertedAttachment(_ remote: RemoteAttachment) async throws
    func retryAttachmentCleanup(_ cleanup: RemoteAttachmentCleanup) async throws
}

final class CompanionTransportCleanup: CompanionAttachmentCleaning {
    let transport: CitadelTransport
    init(transport: CitadelTransport) { self.transport = transport }
    func removeUninsertedAttachment(_ remote: RemoteAttachment) async throws {
        try await transport.removeUninsertedAttachment(remote)
    }
    func retryAttachmentCleanup(_ cleanup: RemoteAttachmentCleanup) async throws {
        try await transport.retryAttachmentCleanup(cleanup)
    }
}

final class CompanionUnavailableCleanup: CompanionAttachmentCleaning {
    func removeUninsertedAttachment(_ remote: RemoteAttachment) async throws {
        throw OfficialTerminalError.transport("Reconnect to this Mac to discard the private upload.")
    }
    func retryAttachmentCleanup(_ cleanup: RemoteAttachmentCleanup) async throws {
        throw OfficialTerminalError.transport("Reconnect to this Mac to discard the private upload.")
    }
}

final class CompanionCleanupRecorder: CompanionAttachmentCleaning {
    private let lock = NSLock()
    private var storedRemoved: [RemoteAttachment] = []
    private var storedRetried: [RemoteAttachmentCleanup] = []
    private var storedError: Error?
    var delayNanoseconds: UInt64 = 0

    var error: Error? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storedError
        }
        set {
            lock.lock(); storedError = newValue; lock.unlock()
        }
    }

    var removed: [RemoteAttachment] {
        lock.lock(); defer { lock.unlock() }
        return storedRemoved
    }

    var retried: [RemoteAttachmentCleanup] {
        lock.lock(); defer { lock.unlock() }
        return storedRetried
    }

    func probeSnapshot() -> String {
        lock.lock()
        let removedCount = storedRemoved.count
        let retriedCount = storedRetried.count
        let hasError = storedError != nil
        lock.unlock()
        return "removed=\(removedCount),retried=\(retriedCount),error=\(hasError ? 1 : 0)"
    }

    func removeUninsertedAttachment(_ remote: RemoteAttachment) async throws {
        let delay = delayNanoseconds
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        lock.lock()
        let err = storedError
        lock.unlock()
        if let err { throw err }
        lock.lock()
        storedRemoved.append(remote)
        lock.unlock()
    }

    func retryAttachmentCleanup(_ cleanup: RemoteAttachmentCleanup) async throws {
        let delay = delayNanoseconds
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        lock.lock()
        let err = storedError
        lock.unlock()
        if let err { throw err }
        lock.lock()
        storedRetried.append(cleanup)
        lock.unlock()
    }
}

protocol CompanionAttachmentUploading: AnyObject {
    func uploadAttachment(data: Data, fileExtension: String) async throws -> RemoteAttachment
}

final class CompanionTransportUpload: CompanionAttachmentUploading {
    let transport: CitadelTransport
    init(transport: CitadelTransport) { self.transport = transport }
    func uploadAttachment(data: Data, fileExtension: String) async throws -> RemoteAttachment {
        try await transport.uploadAttachment(data: data, fileExtension: fileExtension)
    }
}

final class CompanionUnavailableUpload: CompanionAttachmentUploading {
    func uploadAttachment(data: Data, fileExtension: String) async throws -> RemoteAttachment {
        throw OfficialTerminalError.transport("Image upload is unavailable without a live connection.")
    }
}

final class CompanionUploadRecorder: CompanionAttachmentUploading {
    var delayNanoseconds: UInt64 = 0
    var result: Result<RemoteAttachment, Error>
    var suspendUntilReleased = false
    var cancellationError: Error?
    private let lock = NSLock()
    private var gate: Gate = .idle
    private var _started = 0
    private var _sawCancellation = false
    private var _terminal = "idle"

    private enum Gate {
        case idle
        case waiting(CheckedContinuation<Void, Never>)
        case released
    }

    init(result: Result<RemoteAttachment, Error>) { self.result = result }

    var started: Int {
        lock.lock(); defer { lock.unlock() }
        return _started
    }

    var sawCancellation: Bool {
        lock.lock(); defer { lock.unlock() }
        return _sawCancellation
    }

    var terminalResult: String {
        lock.lock(); defer { lock.unlock() }
        return _terminal
    }

    func probeSnapshot() -> String {
        lock.lock()
        let started = _started
        let cancelled = _sawCancellation
        let terminal = _terminal
        lock.unlock()
        return "started=\(started),cancelled=\(cancelled ? 1 : 0),terminal=\(terminal)"
    }

    func waitUntilGateWaiting(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let waiting: Bool
            if case .waiting = gate { waiting = true } else { waiting = false }
            lock.unlock()
            if waiting { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw OfficialTerminalError.transport("upload gate did not enter waiting")
    }

    func uploadAttachment(data: Data, fileExtension: String) async throws -> RemoteAttachment {
        lock.lock()
        _started += 1
        _terminal = "uploading"
        lock.unlock()
        if suspendUntilReleased {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let toResume: CheckedContinuation<Void, Never>?
                    lock.lock()
                    switch gate {
                    case .idle:
                        gate = .waiting(continuation)
                        toResume = nil
                    case .released:
                        gate = .idle
                        toResume = continuation
                    case .waiting:
                        toResume = continuation
                    }
                    lock.unlock()
                    toResume?.resume()
                }
            } onCancel: { [self] in
                lock.lock()
                _sawCancellation = true
                lock.unlock()
                releaseGate()
            }
        } else if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if Task.isCancelled {
            lock.lock()
            _sawCancellation = true
            if cancellationError != nil {
                if let remoteError = cancellationError as? RemoteAttachmentError,
                   case .cleanupRequired = remoteError {
                    _terminal = "cleanupRequired"
                } else {
                    _terminal = "failed"
                }
            } else {
                _terminal = "cancelled"
            }
            let error = cancellationError
            lock.unlock()
            if let error { throw error }
            throw CancellationError()
        }
        let value = try result.get()
        lock.lock()
        _terminal = "success"
        lock.unlock()
        return value
    }

    func releaseGate() {
        let toResume: CheckedContinuation<Void, Never>?
        lock.lock()
        switch gate {
        case .waiting(let continuation):
            gate = .idle
            toResume = continuation
        case .idle:
            gate = .released
            toResume = nil
        case .released:
            toResume = nil
        }
        lock.unlock()
        toResume?.resume()
    }
}

#if DEBUG
final class CompanionFixtureSessionMirror {
    private let lock = NSLock()
    private var order: [UUID] = []
    private var records: [UUID: CompanionFixtureSessionState] = [:]
    private var targets: [UUID: OfficialTerminalAttachmentTarget] = [:]

    func registerPending(_ identity: UUID, target: OfficialTerminalAttachmentTarget? = nil) {
        lock.lock()
        if records[identity] != .closed {
            if records[identity] == nil {
                order.append(identity)
            }
            records[identity] = .pending
            if let target, targets[identity] == nil {
                targets[identity] = target
            }
        }
        lock.unlock()
    }

    func note(_ identity: UUID, _ event: CompanionFixtureSessionState) {
        lock.lock()
        if records[identity] == .closed {
            lock.unlock()
            return
        }
        if records[identity] == nil {
            order.append(identity)
        }
        if event == .closed {
            records[identity] = .closed
        } else {
            records[identity] = event
        }
        lock.unlock()
    }

    func probeSnapshot() -> String {
        lock.lock()
        let snapshot = order.map { id in
            let state = records[id] ?? .pending
            return "\(id.uuidString)|\(state.rawValue)"
        }
        .joined(separator: ";")
        lock.unlock()
        return snapshot
    }

    func targetProbeSnapshot() -> String {
        lock.lock()
        let snapshot = order.compactMap { id -> String? in
            guard let target = targets[id] else { return nil }
            return "\(id.uuidString)|\(Self.token(target))"
        }
        .joined(separator: ";")
        lock.unlock()
        return snapshot
    }

    private static func token(_ target: OfficialTerminalAttachmentTarget) -> String {
        switch target {
        case .agent(let paneID): return "agent:\(paneID)"
        case .terminal(let terminalID): return "terminal:\(terminalID)"
        }
    }
}
#endif
