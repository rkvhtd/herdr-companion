import SwiftUI
import HerdrKit

struct CompanionTerminalDestination: Identifiable, Hashable {
    let pane: TopologyPaneInfo
    let target: OfficialTerminalAttachmentTarget
    let notice: String?

    var id: String { pane.paneID }
    var title: String {
        let candidates = [pane.label, pane.displayAgent, pane.terminalTitleStripped, pane.title]
        return candidates.compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.first ?? (pane.isAgent ? "Agent" : "Shell")
    }

    init?(pane: TopologyPaneInfo, notice: String? = nil) {
        guard !pane.paneID.isEmpty else { return nil }
        self.pane = pane
        self.notice = notice
        if pane.isAgent {
            target = .agent(paneID: pane.paneID)
        } else {
            guard !pane.terminalID.isEmpty else { return nil }
            target = .terminal(terminalID: pane.terminalID)
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pane.paneID == rhs.pane.paneID
            && lhs.target == rhs.target
            && lhs.notice == rhs.notice
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pane.paneID)
        hasher.combine(target)
        hasher.combine(notice)
    }
}

@main
struct HerdrCompanionApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if let launch = CompanionLaunchFixture.requested {
                CompanionLaunchFixture(mode: launch)
            } else if let fixture = CompanionNotificationVisualFixture.requested {
                CompanionNotificationVisualFixture(mode: fixture)
            } else {
                CompanionRootView()
            }
#else
            CompanionRootView()
#endif
        }
    }
}

@MainActor
final class CompanionConnectionModel: ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case connecting(String)
        case connected(String)
    }

    @Published private(set) var phase: Phase = .disconnected
    @Published private(set) var agents: [AgentInfo] = []
    @Published private(set) var topology: SessionTopology?
    @Published var message: String?
    @Published var topologyMessage: String?
    @Published private(set) var hostKeyRotation: HostKeyRotation?
    @Published private(set) var connectedSavedHost: SavedHost?
    @Published private(set) var notificationDestination: CompanionTerminalDestination?
    @Published private(set) var mutationInFlight: TopologyMutation?
    @Published private(set) var mutationOutcomeUnknown = false

    enum TopologyMutation: Equatable {
        case workspace
        case terminalTab(workspaceID: String)
        case split(paneID: String)
    }

    struct Connection {
        let transport: CitadelTransport?
        let client: HerdrClient
        let notificationCall: CompanionNotificationController.HelperCaller?
        let close: () async -> Void

        init(
            transport: CitadelTransport?,
            client: HerdrClient,
            notificationCall: CompanionNotificationController.HelperCaller? = nil,
            close: @escaping () async -> Void
        ) {
            self.transport = transport
            self.client = client
            self.notificationCall = notificationCall
            self.close = close
        }
    }

    typealias ConnectionFactory = (SSHCredentials) -> Connection
    typealias SavedCredentialsProvider = (SavedHost) -> SSHCredentials?
    typealias SavedHostDelete = (SavedHost) -> Bool
    typealias NotificationRoutingSecretProvider = (String) -> String?

    struct HostKeyRotation: Identifiable {
        let credentials: SSHCredentials
        let label: String
        let savedHost: SavedHost?
        let pinned: String
        let presented: String

        var id: String { "\(credentials.host):\(credentials.port):\(presented)" }
    }

    private(set) var transport: CitadelTransport?
    var terminalOpener: CompanionTerminalOpener?
    var fixtureShowKeys = false
    var fixtureShowDraft = false
    var fixtureShowAttachment = false
    var fixtureOpenPaneID: String?
    var fixtureWorkspaceID: String?
    var fixtureScope: CompanionOverviewScope?
#if DEBUG
    var testActivateTerminalScene = false
    var fixtureSizeClass: UserInterfaceSizeClass?
    var fixtureBeginUpload = false
    var fixtureBeginInsert = false
    var fixtureBeginCancel = false
    var fixtureDraftText: String?
    @Published var fixtureEditorCommand: CompanionDraftEditorCommand?
    var fixtureSessionMirror: CompanionFixtureSessionMirror?

    var fixtureGeneration: String { generation.uuidString }

    func issueFixtureEditorCommand(_ command: CompanionDraftEditorCommand) {
        fixtureEditorCommand = command
        insertionEpoch += 1
    }

    func deliverValidatedNotificationDestination(_ destination: CompanionTerminalDestination) {
        notificationDestination = destination
        insertionEpoch += 1
    }

    func fixtureDeliverNotification(paneID: String) {
        guard let pane = topology?.panes.first(where: { $0.paneID == paneID }),
              let destination = CompanionTerminalDestination(pane: pane) else { return }
        deliverValidatedNotificationDestination(destination)
    }

    func fixtureSetSizeClass(_ size: UserInterfaceSizeClass?) {
        fixtureSizeClass = size
        insertionEpoch += 1
    }

    func fixtureReceiptProbe() -> String {
        let lines = insertionReceipts.values
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { receipt -> String in
                let phase: String
                switch receipt.phase {
                case .uploading: phase = "uploading"
                case .uploadedUnsubmitted: phase = "uploaded"
                case .submitting: phase = "submitting"
                case .cleanupInFlight: phase = "cleanup"
                case .resolved: phase = "resolved"
                }
                let payload: String
                switch receipt.payload {
                case .pending: payload = "pending"
                case .draft: payload = "draft"
                case .uploaded: payload = "uploaded"
                case .incompleteCleanup: payload = "incomplete"
                }
                let status: String
                switch receipt.status {
                case .awaitingAcknowledgement: status = "awaiting"
                case .written: status = "written"
                case .confirmedNotWritten: status = "confirmed"
                case .acknowledgementUnknown: status = "unknown"
                }
                return "\(receipt.id.uuidString)|\(phase)|\(payload)|\(status)"
            }
        if lines.isEmpty { return "empty" }
        return lines.joined(separator: ";")
    }
#endif
    @Published private(set) var insertionReceipts: [UUID: CompanionInsertionReceipt] = [:]
    @Published var isPresentingRecovery = false
    @Published private(set) var insertionEpoch = 0
    private(set) var recoveryOwner: CompanionInsertionOwner?
    var attachmentCleanup: CompanionAttachmentCleaning?
    var attachmentUpload: CompanionAttachmentUploading?
    private(set) var forgottenInsertionIDs: Set<UUID> = []
    private var recoverUnsubmittedOnUpload: Set<UUID> = []
    private var retainedInsertControllers: [UUID: CompanionTerminalController] = [:]
    private var connection: Connection?
    private var eventsTask: Task<Void, Never>?
    private var generation = UUID()
    private var refreshRequest: UInt64 = 0
    private var pendingNotificationRoute: CompanionNotificationRoute?

    private let connectionFactory: ConnectionFactory
    private let hostKeyPolicy: CompanionHostKeyPolicy
    private let savedCredentialsProvider: SavedCredentialsProvider?
    private let notificationController: CompanionNotificationController
    private let savedHostDelete: SavedHostDelete
    private let notificationRoutingSecret: NotificationRoutingSecretProvider

    init(
        connectionFactory: ConnectionFactory? = nil,
        hostKeyPolicy: CompanionHostKeyPolicy = .shared,
        savedCredentialsProvider: SavedCredentialsProvider? = nil,
        notificationController: CompanionNotificationController? = nil,
        savedHostDelete: @escaping SavedHostDelete = { SavedHostsStore.shared.delete($0) },
        notificationRoutingSecret: NotificationRoutingSecretProvider? = nil
    ) {
        let notificationController = notificationController ?? .shared
        self.hostKeyPolicy = hostKeyPolicy
        self.savedCredentialsProvider = savedCredentialsProvider
        self.notificationController = notificationController
        self.savedHostDelete = savedHostDelete
        self.notificationRoutingSecret = notificationRoutingSecret ?? { savedHostID in
            notificationController.settings.record(savedHostID: savedHostID).routingSecret
        }
        self.connectionFactory = connectionFactory ?? { credentials in
            let transport = CitadelTransport(
                credentials: credentials,
                hostKeyPolicy: hostKeyPolicy)
            return Connection(
                transport: transport,
                client: HerdrClient(transport: transport),
                notificationCall: { try await transport.notificationHelperRPC($0) },
                close: { await transport.close() })
        }
    }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = phase { return true }
        return false
    }

    var recoverableReceipts: [CompanionInsertionReceipt] {
        insertionReceipts.values
            .filter(\.needsUserRecovery)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var awaitingReceipts: [CompanionInsertionReceipt] {
        insertionReceipts.values.filter(\.isWriterOwned)
    }

    var insertControllerForTests: CompanionTerminalController? {
        activeScreenController ?? retainedInsertControllers.values.first
    }

    func receipt(id: UUID) -> CompanionInsertionReceipt? { insertionReceipts[id] }

    private var activeScreenController: CompanionTerminalController?

    func attachInsertController(_ controller: CompanionTerminalController) {
        activeScreenController = controller
    }


    func wasForgotten(_ id: UUID) -> Bool { forgottenInsertionIDs.contains(id) }

    func preserveUnsentDraft(
        _ text: String,
        owner: CompanionInsertionOwner?,
        target: OfficialTerminalAttachmentTarget,
        title: String,
        id: UUID? = nil
    ) {
        let trimmed = text
        guard !trimmed.isEmpty, let owner else { return }
        let id = id ?? UUID()
        if forgottenInsertionIDs.contains(id) { return }
        if insertionReceipts[id] != nil { return }
        insertionReceipts[id] = CompanionInsertionReceipt(
            id: id, owner: owner, target: target, title: title,
            payload: .draft(trimmed),
            status: .confirmedNotWritten(
                "The terminal closed before this draft was written. The exact text was kept."))
        insertionEpoch += 1
    }

    func preserveUninsertedUpload(
        _ remote: RemoteAttachment,
        owner: CompanionInsertionOwner?,
        target: OfficialTerminalAttachmentTarget,
        title: String,
        id: UUID? = nil
    ) {
        guard let owner else { return }
        let id = id ?? UUID()
        if forgottenInsertionIDs.contains(id) { return }
        if let existing = insertionReceipts[id] {
            if case .acknowledgementUnknown = existing.status { return }
            if case .written = existing.status { return }
            return
        }
        insertionReceipts[id] = CompanionInsertionReceipt(
            id: id, owner: owner, target: target, title: title,
            payload: .uploaded(remote),
            status: .confirmedNotWritten(
                "The terminal closed before this image path was written. The private upload was not deleted."))
        insertionEpoch += 1
    }

    func preserveUnknownUpload(
        _ remote: RemoteAttachment,
        owner: CompanionInsertionOwner?,
        target: OfficialTerminalAttachmentTarget,
        title: String,
        id: UUID? = nil
    ) {
        guard let owner else { return }
        let id = id ?? UUID()
        if forgottenInsertionIDs.contains(id) { return }
        if let existing = insertionReceipts[id] {
            if case .acknowledgementUnknown = existing.status { return }
            if case .written = existing.status { return }
            return
        }
        insertionReceipts[id] = CompanionInsertionReceipt(
            id: id, owner: owner, target: target, title: title,
            payload: .uploaded(remote),
            status: .acknowledgementUnknown(
                "The write outcome is unknown. The private upload was not deleted."))
        insertionEpoch += 1
    }

    func preserveIncompleteCleanup(
        _ cleanup: RemoteAttachmentCleanup,
        owner: CompanionInsertionOwner?,
        target: OfficialTerminalAttachmentTarget,
        title: String,
        id: UUID? = nil
    ) {
        guard let owner else { return }
        let id = id ?? UUID()
        if forgottenInsertionIDs.contains(id) { return }
        if insertionReceipts[id] != nil { return }
        insertionReceipts[id] = CompanionInsertionReceipt(
            id: id, owner: owner, target: target, title: title,
            payload: .incompleteCleanup(cleanup),
            status: .confirmedNotWritten(
                "A private upload did not finish cleanup. Reconnect to this Mac to retry Discard."))
        insertionEpoch += 1
    }

    func beginAttachmentFlow(
        id: UUID,
        owner: CompanionInsertionOwner,
        target: OfficialTerminalAttachmentTarget,
        title: String
    ) {
        if forgottenInsertionIDs.contains(id) { return }
        if insertionReceipts[id] != nil { return }
        insertionReceipts[id] = CompanionInsertionReceipt(
            id: id, owner: owner, target: target, title: title,
            payload: .pending, status: .awaitingAcknowledgement, phase: .uploading)
        insertionEpoch += 1
    }

    func completeAttachmentUpload(id: UUID, remote: RemoteAttachment) {
        guard !forgottenInsertionIDs.contains(id), var receipt = insertionReceipts[id] else { return }
        if case .acknowledgementUnknown = receipt.status { return }
        if case .written = receipt.status { return }
        if receipt.phase == .submitting { return }
        if case .cleanupInFlight = receipt.phase { return }
        receipt.payload = .uploaded(remote)
        if receipt.phase == .uploading || receipt.phase == .resolved {
            receipt.phase = .uploadedUnsubmitted
        }
        if recoverUnsubmittedOnUpload.remove(id) != nil, receipt.phase == .uploadedUnsubmitted {
            receipt.status = .confirmedNotWritten(
                "The terminal closed before this image path was written. The private upload was not deleted.")
            receipt.phase = .resolved
        }
        insertionReceipts[id] = receipt
        insertionEpoch += 1
    }

    func failAttachmentUpload(
        id: UUID,
        cleanup: RemoteAttachmentCleanup?,
        message: String
    ) {
        guard !forgottenInsertionIDs.contains(id) else { return }
        guard var receipt = insertionReceipts[id] else { return }
        if case .acknowledgementUnknown = receipt.status { return }
        if case .written = receipt.status { return }
        if receipt.phase == .submitting { return }
        recoverUnsubmittedOnUpload.remove(id)
        if let cleanup {
            receipt.payload = .incompleteCleanup(cleanup)
            receipt.status = .confirmedNotWritten(message)
            receipt.phase = .resolved
            insertionReceipts[id] = receipt
        } else {
            insertionReceipts.removeValue(forKey: id)
        }
        insertionEpoch += 1
    }

    func markAttachmentForRecovery(id: UUID) {
        guard !forgottenInsertionIDs.contains(id), var receipt = insertionReceipts[id] else { return }
        if case .acknowledgementUnknown = receipt.status { return }
        if case .written = receipt.status { return }
        switch receipt.phase {
        case .submitting, .cleanupInFlight:
            insertionReceipts[id] = receipt
            return
        case .uploading:
            recoverUnsubmittedOnUpload.insert(id)
            insertionReceipts[id] = receipt
            return
        case .uploadedUnsubmitted:
            receipt.status = .confirmedNotWritten(
                "The terminal closed before this image path was written. The private upload was not deleted.")
            receipt.phase = .resolved
        case .resolved:
            if case .awaitingAcknowledgement = receipt.status {
                switch receipt.payload {
                case .uploaded:
                    receipt.status = .confirmedNotWritten(
                        "The terminal closed before this image path was written. The private upload was not deleted.")
                case .incompleteCleanup:
                    receipt.status = .confirmedNotWritten(
                        "A private upload did not finish cleanup. Reconnect to this Mac to retry Discard.")
                default:
                    break
                }
            }
        }
        insertionReceipts[id] = receipt
        insertionEpoch += 1
    }

    func discardAttachment(id: UUID) async -> String? {
        guard !forgottenInsertionIDs.contains(id), var receipt = insertionReceipts[id] else {
            return "This upload is no longer available."
        }
        if receipt.phase == .submitting {
            return "This item is still being written. Cleanup is not available until the write outcome is known."
        }
        if case .cleanupInFlight = receipt.phase {
            return "Cleanup is already in progress."
        }
        switch receipt.payload {
        case .pending, .draft:
            return "Nothing to discard yet."
        case .uploaded, .incompleteCleanup:
            break
        }
        let discardable: Bool = {
            if receipt.phase == .uploadedUnsubmitted, case .uploaded = receipt.payload { return true }
            return receipt.allowsCleanup
        }()
        guard discardable else {
            return "This item is not eligible for deletion because the write outcome is not a confirmed failure."
        }
        guard let current = connectedSavedHost, receipt.owner.matches(current) else {
            if receipt.phase == .uploadedUnsubmitted {
                receipt.status = .confirmedNotWritten(
                    "The terminal closed before this image path was written. The private upload was not deleted.")
                receipt.phase = .resolved
                insertionReceipts[id] = receipt
                insertionEpoch += 1
            }
            return "Reconnect to \(receipt.owner.hostLabel) (\(receipt.owner.host)) with the original account to discard this private upload."
        }
        let token = UUID()
        let owner = receipt.owner
        let payload = receipt.payload
        let performer = cleanupPerformer()
        receipt.phase = .cleanupInFlight(token)
        insertionReceipts[id] = receipt
        insertionEpoch += 1
        do {
            switch payload {
            case .uploaded(let remote):
                try await performer.removeUninsertedAttachment(remote)
            case .incompleteCleanup(let cleanup):
                try await performer.retryAttachmentCleanup(cleanup)
            case .pending, .draft:
                return "Nothing to discard yet."
            }
            guard !forgottenInsertionIDs.contains(id) else { return nil }
            guard let currentReceipt = insertionReceipts[id] else { return nil }
            guard currentReceipt.id == id else { return nil }
            guard currentReceipt.owner == owner else { return nil }
            guard case .cleanupInFlight(let currentToken) = currentReceipt.phase, currentToken == token else {
                return nil
            }
            consumeInsertion(id: id)
            return nil
        } catch {
            let failed = "Cleanup failed (\(error.localizedDescription)). The private file may still be on this Mac."
            guard !forgottenInsertionIDs.contains(id) else { return failed }
            guard var currentReceipt = insertionReceipts[id] else { return failed }
            guard currentReceipt.id == id else { return failed }
            guard currentReceipt.owner == owner else { return failed }
            guard case .cleanupInFlight(let currentToken) = currentReceipt.phase, currentToken == token else {
                return currentReceipt.recoveryMessage ?? failed
            }
            currentReceipt.phase = .resolved
            currentReceipt.status = .confirmedNotWritten(failed)
            insertionReceipts[id] = currentReceipt
            insertionEpoch += 1
            return failed
        }
    }

    func consumeInsertion(id: UUID) {
        insertionReceipts.removeValue(forKey: id)
        forgottenInsertionIDs.insert(id)
        if recoverableReceipts.isEmpty { isPresentingRecovery = false }
        insertionEpoch += 1
        releaseRetainedController(id: id)
    }

    private func releaseRetainedController(id: UUID) {
        let detached = retainedInsertControllers.removeValue(forKey: id)
        guard let detached, detached !== activeScreenController else { return }
        Task { await detached.close() }
    }

    func submitDraft(
        _ text: String,
        controller: CompanionTerminalController,
        owner: CompanionInsertionOwner?,
        target: OfficialTerminalAttachmentTarget,
        title: String,
        id: UUID? = nil
    ) async -> CompanionSubmissionFinish {
        let id = id ?? UUID()
        guard let owner else {
            return .confirmedNotWritten(id)
        }
        if forgottenInsertionIDs.contains(id) {
            return .confirmedNotWritten(id)
        }
        if let existing = insertionReceipts[id] {
            if existing.phase == .submitting {
                return .awaiting(id)
            }
            switch existing.status {
            case .acknowledgementUnknown:
                return .acknowledgementUnknown(id)
            case .confirmedNotWritten:
                return .confirmedNotWritten(id)
            case .written:
                return .written(id)
            case .awaitingAcknowledgement:
                return .awaiting(id)
            }
        }
        insertionReceipts[id] = CompanionInsertionReceipt(
            id: id, owner: owner, target: target, title: title,
            payload: .draft(text),
            status: .awaitingAcknowledgement, phase: .submitting)
        retainedInsertControllers[id] = controller
        insertionEpoch += 1
        return await finishSubmission(id: id) {
            try await controller.insertDraftText(text, identity: controller.targetIdentity)
        }
    }

    func submitUploadedPath(
        _ remote: RemoteAttachment,
        controller: CompanionTerminalController,
        owner: CompanionInsertionOwner?,
        target: OfficialTerminalAttachmentTarget,
        title: String,
        id: UUID? = nil
    ) async -> CompanionSubmissionFinish {
        let id = id ?? UUID()
        guard let owner else {
            return .confirmedNotWritten(id)
        }
        if forgottenInsertionIDs.contains(id) {
            return .confirmedNotWritten(id)
        }
        if var existing = insertionReceipts[id] {
            if existing.phase == .submitting {
                return .awaiting(id)
            }
            if case .cleanupInFlight = existing.phase {
                return .confirmedNotWritten(id)
            }
            switch existing.phase {
            case .uploading, .uploadedUnsubmitted:
                existing.payload = .uploaded(remote)
                existing.status = .awaitingAcknowledgement
                existing.phase = .submitting
                insertionReceipts[id] = existing
            case .resolved:
                switch existing.status {
                case .acknowledgementUnknown:
                    return .acknowledgementUnknown(id)
                case .confirmedNotWritten:
                    return .confirmedNotWritten(id)
                case .written:
                    return .written(id)
                case .awaitingAcknowledgement:
                    return .awaiting(id)
                }
            case .submitting, .cleanupInFlight:
                return .confirmedNotWritten(id)
            }
        } else {
            insertionReceipts[id] = CompanionInsertionReceipt(
                id: id, owner: owner, target: target, title: title,
                payload: .uploaded(remote),
                status: .awaitingAcknowledgement, phase: .submitting)
        }
        retainedInsertControllers[id] = controller
        insertionEpoch += 1
        return await finishSubmission(id: id) {
            let written = try await controller.insertAttachment(
                path: remote.path, identity: controller.targetIdentity)
            return written ? .written : .unavailable
        }
    }

    func submitDraftUsingActiveController(
        _ text: String, target: OfficialTerminalAttachmentTarget, title: String, id: UUID? = nil
    ) async -> CompanionSubmissionFinish {
        let controller = activeScreenController ?? retainedInsertControllers.values.first
        guard let controller, let owner = recoveryOwner else {
            return .confirmedNotWritten(id ?? UUID())
        }
        return await submitDraft(
            text, controller: controller, owner: owner, target: target, title: title, id: id)
    }

    private func finishSubmission(
        id: UUID,
        work: () async throws -> CompanionDraftInsertResult
    ) async -> CompanionSubmissionFinish {
        do {
            switch try await work() {
            case .written:
                resolveInsertion(id: id, status: .written)
                return .written(id)
            case .unavailable:
                resolveInsertion(
                    id: id,
                    status: .confirmedNotWritten(
                        "The terminal target was unavailable. The exact payload was kept and not written."))
                return .confirmedNotWritten(id)
            case .rejected(let reason):
                resolveInsertion(id: id, status: .confirmedNotWritten(reason))
                return .confirmedNotWritten(id)
            }
        } catch let error as OfficialTerminalInputError {
            resolveInsertion(
                id: id,
                status: .confirmedNotWritten(
                    "The attachment closed before the write was accepted. The payload was kept and not written."))
            _ = error
            return .confirmedNotWritten(id)
        } catch let error as OfficialTerminalError {
            resolveInsertion(
                id: id,
                status: .acknowledgementUnknown(
                    "The write outcome is unknown (\(error.localizedDescription)). The payload was kept. It was not treated as delivered and the private file was not deleted."))
            return .acknowledgementUnknown(id)
        } catch {
            resolveInsertion(
                id: id,
                status: .acknowledgementUnknown(
                    "The write outcome is unknown (\(error.localizedDescription)). The payload was kept. It was not treated as delivered and the private file was not deleted."))
            return .acknowledgementUnknown(id)
        }
    }

    func resolveInsertion(id: UUID, status: CompanionInsertionStatus) {
        guard var receipt = insertionReceipts[id] else { return }
        if case .written = receipt.status { return }
        if case .acknowledgementUnknown = receipt.status, case .confirmedNotWritten = status {
            return
        }
        if case .written = status {
            consumeInsertion(id: id)
            return
        }
        receipt.status = status
        receipt.phase = .resolved
        insertionReceipts[id] = receipt
        insertionEpoch += 1
        releaseRetainedController(id: id)
    }

    func dismissRecoveryPresentation() {
        isPresentingRecovery = false
    }

    func openRecoveryPresentation() {
        guard !recoverableReceipts.isEmpty || !awaitingReceipts.isEmpty else { return }
        isPresentingRecovery = true
    }

    func forgetReceipt(_ receipt: CompanionInsertionReceipt) {
        guard let current = insertionReceipts[receipt.id] else { return }
        switch current.phase {
        case .submitting, .cleanupInFlight, .uploading, .uploadedUnsubmitted:
            return
        case .resolved:
            consumeInsertion(id: current.id)
        }
    }

    func forgetReceiptIfPresent(id: UUID) {
        guard let receipt = insertionReceipts[id] else {
            forgottenInsertionIDs.insert(id)
            return
        }
        forgetReceipt(receipt)
    }

    func retryDiscard(_ receipt: CompanionInsertionReceipt) async -> String? {
        guard let currentReceipt = insertionReceipts[receipt.id] else {
            return "This item is no longer available."
        }
        guard currentReceipt.allowsCleanup else {
            return "This item is not eligible for deletion because the write outcome is not a confirmed failure."
        }
        guard let current = connectedSavedHost, currentReceipt.owner.matches(current) else {
            return "Reconnect to \(currentReceipt.owner.hostLabel) (\(currentReceipt.owner.host)) with the original account to discard this private upload."
        }
        return await discardAttachment(id: currentReceipt.id)
    }

    func cleanupPerformer() -> CompanionAttachmentCleaning {
        if let attachmentCleanup { return attachmentCleanup }
        if let transport { return CompanionTransportCleanup(transport: transport) }
        return CompanionUnavailableCleanup()
    }

    func uploadPerformer() -> CompanionAttachmentUploading {
        if let attachmentUpload { return attachmentUpload }
        if let transport { return CompanionTransportUpload(transport: transport) }
        return CompanionUnavailableUpload()
    }

    func connect(_ saved: SavedHost) async {
        cancelNotificationNavigation()
        guard let credentials = credentials(for: saved) else { return }
        await connect(credentials: credentials, label: saved.label, savedHost: saved)
    }

    func connect(
        credentials: SSHCredentials,
        label: String,
        savedHost: SavedHost? = nil,
        preservingNotificationRoute: Bool = false
    ) async {
        if !preservingNotificationRoute { cancelNotificationNavigation() }
        let token = UUID()
        generation = token
        refreshRequest = 0
        phase = .connecting(label)
        agents = []
        connectedSavedHost = nil
        topology = nil
        message = nil
        topologyMessage = nil
        mutationInFlight = nil
        mutationOutcomeUnknown = false
        hostKeyRotation = nil
        await tearDownConnection()
        guard generation == token else { return }

        let connection = connectionFactory(credentials)
        self.connection = connection
        transport = connection.transport
        do {
            let snapshot = try await connection.client.sessionTopology()
            guard generation == token else {
                await connection.close()
                return
            }
            publish(snapshot)
            connectedSavedHost = savedHost
            if let savedHost { recoveryOwner = CompanionInsertionOwner(savedHost) }
            phase = .connected(label)
            startEvents(client: connection.client, token: token)
            await reconcileNotifications(token: token, savedHost: savedHost)
        } catch {
            guard generation == token else { return }
            if case TransportError.hostKeyRejected(_, let presented) = error,
               let pinned = hostKeyPolicy.pinnedFingerprint(
                   host: credentials.host, port: credentials.port) {
                hostKeyRotation = HostKeyRotation(
                    credentials: credentials, label: label, savedHost: savedHost,
                    pinned: pinned, presented: presented)
                message = "The SSH host key changed. Review both fingerprints before reconnecting."
            } else {
                message = Self.safeMessage(for: error)
            }
            phase = .disconnected
            connectedSavedHost = nil
            self.connection = nil
            self.transport = nil
            await connection.close()
        }
    }

    func disconnect() async {
        generation = UUID()
        refreshRequest = 0
        phase = .disconnected
        agents = []
        topology = nil
        message = nil
        topologyMessage = nil
        mutationInFlight = nil
        mutationOutcomeUnknown = false
        hostKeyRotation = nil
        connectedSavedHost = nil
        cancelNotificationNavigation()
        await tearDownConnection()
    }

    /// Notification registrations outlive a saved route on the Mac. If that
    /// route is registered, remove it through the same pinned SSH policy before
    /// deleting local credentials. Failure leaves the host visible and truthfully pending.
    func deleteSavedHost(_ saved: SavedHost) async {
        let notifications = notificationController.settings.record(
            savedHostID: saved.id.uuidString)
        guard notifications.phase != .disabled
                || notifications.desiredEnabled
                || notifications.appliedEnabled else {
            if savedHostDelete(saved) {
                notificationController.settings.remove(savedHostID: saved.id.uuidString)
            }
            return
        }
        guard let credentials = credentials(for: saved) else { return }
        let temporary = connectionFactory(credentials)
        guard let notificationCall = temporary.notificationCall else {
            await temporary.close()
            message = "Notification removal is pending; the saved host was kept."
            return
        }
        let acknowledged = await notificationController.disable(
            savedHostID: saved.id.uuidString, session: saved.herdrSession,
            call: notificationCall)
        await temporary.close()
        guard acknowledged else {
            message = "Notification removal is pending; the saved host and credentials were kept."
            return
        }
        if savedHostDelete(saved) {
            notificationController.settings.remove(savedHostID: saved.id.uuidString)
        } else {
            message = "The notification route was removed, but the local credential could not be deleted."
        }
    }

    func dismissHostKeyRotation() {
        hostKeyRotation = nil
    }

    func cancelHostKeyRotation() {
        if pendingNotificationRoute != nil {
            pendingNotificationRoute = nil
            message = "The notification terminal was not opened because the changed host key was not trusted."
        }
        hostKeyRotation = nil
    }

    func trustChangedHostKeyAndReconnect(_ rotation: HostKeyRotation) async {
        guard hostKeyPolicy.replacePin(
            host: rotation.credentials.host,
            port: rotation.credentials.port,
            expected: rotation.pinned,
            presented: rotation.presented)
        else {
            hostKeyRotation = nil
            pendingNotificationRoute = nil
            message = "The saved host key changed again or could not be updated. Connect again to review it."
            return
        }
        hostKeyRotation = nil
        let shouldResumeNotification = pendingNotificationRoute != nil
        await connect(
            credentials: rotation.credentials,
            label: rotation.label,
            savedHost: rotation.savedHost,
            preservingNotificationRoute: shouldResumeNotification)
        if shouldResumeNotification, isConnected {
            finishPendingNotificationRoute()
        }
    }

    /// Opens only the exact terminal named by a validated push route. A route for
    /// another saved Mac reconnects through that saved record and its pinned SSH
    /// policy. Existing connections are refreshed before matching so an old local
    /// snapshot can never redirect a notification to a reused or nearby pane.
    func openNotificationRoute(
        _ route: CompanionNotificationRoute,
        savedHost: SavedHost?
    ) async {
        notificationDestination = nil
        guard let savedHost,
              savedHost.id.uuidString.caseInsensitiveCompare(route.savedHostID) == .orderedSame
        else {
            pendingNotificationRoute = nil
            message = "The saved Mac for this notification is no longer available."
            return
        }

        pendingNotificationRoute = route
        if connectedSavedHost?.id == savedHost.id, isConnected {
            guard await refresh(showError: false) else {
                guard pendingNotificationRoute == route else { return }
                pendingNotificationRoute = nil
                message = "The notification terminal could not be verified because the Mac did not return a fresh session snapshot."
                return
            }
        } else {
            guard let credentials = credentials(for: savedHost) else {
                pendingNotificationRoute = nil
                return
            }
            await connect(
                credentials: credentials,
                label: savedHost.label,
                savedHost: savedHost,
                preservingNotificationRoute: true)
            guard pendingNotificationRoute == route else { return }
            if hostKeyRotation != nil { return }
            guard isConnected else {
                pendingNotificationRoute = nil
                return
            }
        }
        guard pendingNotificationRoute == route else { return }
        finishPendingNotificationRoute()
    }

    func dismissNotificationDestination() {
        notificationDestination = nil
    }

    @discardableResult
    func refresh(showError: Bool = true) async -> Bool {
        let token = generation
        guard let connection, isConnected else { return false }
        refreshRequest &+= 1
        let request = refreshRequest
        do {
            let snapshot = try await connection.client.sessionTopology()
            guard generation == token, refreshRequest == request,
                  self.connection != nil, isConnected else { return false }
            publish(snapshot)
            message = nil
            return true
        } catch {
            guard generation == token, refreshRequest == request,
                  self.connection != nil, isConnected else { return false }
            if showError { message = Self.safeMessage(for: error) }
            return false
        }
    }

    func becameActive() async {
        let token = generation
        guard isConnected else { return }
        await refresh()
        guard generation == token, isConnected else { return }
        await reconcileNotifications(token: token, savedHost: connectedSavedHost)
    }

    func acknowledgeUnknownMutation() {
        mutationOutcomeUnknown = false
    }

    func createWorkspace(label: String, cwd: String?) async -> CompanionTerminalDestination? {
        await performMutation(.workspace, requestedCWD: cwd) { client in
            try await client.createWorkspace(label: label, cwd: cwd).rootPane
        }
    }

    func createTerminalTab(
        workspaceID: String, label: String?, cwd: String?
    ) async -> CompanionTerminalDestination? {
        await performMutation(.terminalTab(workspaceID: workspaceID), requestedCWD: cwd) { client in
            try await client.createTerminalTab(
                workspaceID: workspaceID, label: label, cwd: cwd).rootPane
        }
    }

    func splitPane(
        workspaceID: String,
        paneID: String,
        cwd: String?,
        direction: HerdrClient.SplitDirection
    ) async -> CompanionTerminalDestination? {
        await performMutation(.split(paneID: paneID), requestedCWD: cwd) { client in
            try await client.splitPane(
                workspaceID: workspaceID, targetPaneID: paneID,
                cwd: cwd, direction: direction)
        }
    }

    private func performMutation(
        _ mutation: TopologyMutation,
        requestedCWD: String?,
        operation: (HerdrClient) async throws -> TopologyPaneInfo
    ) async -> CompanionTerminalDestination? {
        guard mutationInFlight == nil, let connection, isConnected else { return nil }
        let token = generation
        mutationInFlight = mutation
        mutationOutcomeUnknown = false
        topologyMessage = nil
        do {
            let pane = try await operation(connection.client)
            guard generation == token, self.connection != nil, isConnected else { return nil }
            let refreshed = await refresh(showError: false)
            guard generation == token, self.connection != nil, isConnected else { return nil }
            let verifiedPane = topology?.panes.first { $0.paneID == pane.paneID }
            let refreshedPane = verifiedPane ?? pane
            let notice: String?
            if requestedCWD != nil, verifiedPane == nil, !refreshed {
                notice = "Created the terminal, but the companion could not refresh Herdr to verify its working folder."
            } else if requestedCWD != nil, verifiedPane == nil {
                notice = "Created the terminal, but it did not appear in the refreshed topology yet, so its working folder could not be verified."
            } else {
                notice = Self.cwdNotice(requested: requestedCWD, pane: refreshedPane)
            }
            topologyMessage = notice
            mutationInFlight = nil
            guard let destination = CompanionTerminalDestination(pane: refreshedPane, notice: notice) else {
                topologyMessage = "Herdr created a pane but did not return an attachable terminal identity. Refresh Workspaces to recover it."
                return nil
            }
            return destination
        } catch {
            guard generation == token, self.connection != nil, isConnected else { return nil }
            mutationInFlight = nil
            if let api = error as? APIError {
                mutationOutcomeUnknown = false
                topologyMessage = "Herdr did not create it: \(api.message)"
            } else {
                mutationOutcomeUnknown = true
                topologyMessage = "The connection ended before Herdr confirmed the result. It may have been created; review the refreshed list before trying again."
                await refresh(showError: false)
            }
            return nil
        }
    }

    private func tearDownConnection() async {
        eventsTask?.cancel()
        eventsTask = nil
        let old = connection
        transport = nil
        connection = nil
        await old?.close()
    }

    private func finishPendingNotificationRoute(now: Date = Date()) {
        guard let route = pendingNotificationRoute else { return }
        guard (try? route.validated(
            nowUnixSeconds: UInt64(now.timeIntervalSince1970))) != nil else {
            pendingNotificationRoute = nil
            message = "This notification is too old to open safely."
            return
        }
        guard let connectedSavedHost,
              connectedSavedHost.id.uuidString.caseInsensitiveCompare(route.savedHostID) == .orderedSame,
              let topology,
              topology.workspaces.contains(where: { $0.workspaceID == route.workspaceID }),
              let pane = topology.panes.first(where: {
                  $0.workspaceID == route.workspaceID
                      && $0.paneID == route.paneID
                      && $0.terminalID == route.terminalID
              }),
              pane.isAgent,
              let currentAgent = topology.agents.first(where: {
                  $0.workspaceID == route.workspaceID
                      && $0.paneID == route.paneID
                      && $0.terminalID == route.terminalID
                      && !$0.isArchived
              }),
              let agentSession = currentAgent.agentSession,
              let routingSecret = notificationRoutingSecret(route.savedHostID),
              NotificationAgentBinding.routeBinding(
                  for: agentSession, routingSecret: routingSecret)
                    == route.agentInstanceBinding,
              let destination = CompanionTerminalDestination(pane: pane)
        else {
            pendingNotificationRoute = nil
            message = "The exact terminal from this notification is no longer available."
            return
        }
        pendingNotificationRoute = nil
        message = nil
        notificationDestination = destination
    }

    private func cancelNotificationNavigation() {
        pendingNotificationRoute = nil
        notificationDestination = nil
    }

    private func reconcileNotifications(token: UUID, savedHost: SavedHost?) async {
        guard generation == token, isConnected,
              let savedHost,
              connectedSavedHost?.id == savedHost.id,
              notificationController.settings.contains(
                savedHostID: savedHost.id.uuidString),
              let call = connection?.notificationCall else { return }
        await notificationController.reconcile(
            savedHostID: savedHost.id.uuidString,
            session: savedHost.herdrSession,
            call: call,
            isConnectionCurrent: { [weak self] in
                guard let self else { return false }
                return self.generation == token
                    && self.isConnected
                    && self.connectedSavedHost?.id == savedHost.id
            })
    }

    private func credentials(for saved: SavedHost) -> SSHCredentials? {
        if let savedCredentialsProvider {
            guard let credentials = savedCredentialsProvider(saved) else {
                message = "The credentials for \(saved.label) are unavailable on this device."
                return nil
            }
            return credentials
        }
        guard let endpoint = HostEndpoint.parse(saved.host),
              let session = OfficialHerdrSession(name: saved.herdrSession) else {
            message = "This saved host has an invalid address or Herdr session. Edit it and try again."
            return nil
        }
        switch saved.auth {
        case .key:
            guard let key = SavedHostsStore.shared.key(for: saved) else {
                message = "The private key for \(saved.label) is missing from this device's Keychain."
                return nil
            }
            return SSHCredentials(
                host: endpoint.host, port: endpoint.port, username: saved.username,
                privateKeyPEM: key, remoteSocketPath: session.socketPath,
                herdrSession: session.name)
        case .password:
            guard let password = SavedHostsStore.shared.password(for: saved) else {
                message = "The password for \(saved.label) is missing from this device's Keychain."
                return nil
            }
            return SSHCredentials(
                host: endpoint.host, port: endpoint.port, username: saved.username,
                password: password, remoteSocketPath: session.socketPath,
                herdrSession: session.name)
        }
    }

    private func publish(_ snapshot: SessionTopology) {
        topology = snapshot
        agents = snapshot.agents
    }

    private static func cwdNotice(
        requested: String?, pane: TopologyPaneInfo
    ) -> String? {
        guard let requested else { return nil }
        guard let actual = pane.effectiveCWD else {
            return "Created the terminal, but Herdr did not report its working folder yet."
        }
        guard !equivalentMacPaths(requested, actual) else { return nil }
        return "Created the terminal, but Herdr reports \(actual) instead of the requested folder \(requested)."
    }

    private static func equivalentMacPaths(_ lhs: String, _ rhs: String) -> Bool {
        func canonicalTemporaryAlias(_ path: String) -> String {
            if path == "/tmp" { return "/private/tmp" }
            if path.hasPrefix("/tmp/") { return "/private" + path }
            return path
        }
        return canonicalTemporaryAlias(lhs) == canonicalTemporaryAlias(rhs)
    }

    private func startEvents(client: HerdrClient, token: UUID) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            await self?.runEvents(client: client, token: token)
        }
    }

    /// Event-driven refresh with capped reconnect backoff. There is no foreground
    /// timer or busy polling: a healthy socket wakes this loop only for Herdr events.
    private func runEvents(client: HerdrClient, token: UUID) async {
        var retrySeconds: UInt64 = 1
        while !Task.isCancelled, generation == token, isConnected {
            let paneIDs = Set(agents.map(\.paneID))
            var subscriptions: [Subscription] = [
                Subscription(.workspaceRenamed),
                Subscription(.workspaceMoved),
                Subscription(.workspaceReordered),
                Subscription(.workspaceClosed),
                Subscription(.tabRenamed),
                Subscription(.tabMoved),
                Subscription(.tabClosed),
                Subscription(.paneUpdated),
                Subscription(.paneFocused),
                Subscription(.paneClosed),
                Subscription(.paneExited),
                Subscription(.paneAgentDetected),
                Subscription(.layoutUpdated),
            ]
            subscriptions += paneIDs.map { Subscription(.paneAgentStatusChanged, paneID: $0) }
            var rosterChanged = false
            var receivedEvent = false
            do {
                for try await line in client.subscribe(subscriptions) {
                    guard !Task.isCancelled, generation == token else { return }
                    guard case .event = line else { continue }
                    receivedEvent = true
                    await refresh(showError: false)
                    guard !Task.isCancelled, generation == token else { return }
                    if Set(agents.map(\.paneID)) != paneIDs {
                        rosterChanged = true
                        break
                    }
                }
                guard !Task.isCancelled, generation == token else { return }
                if receivedEvent { retrySeconds = 1 }
                if rosterChanged { continue }
                message = "Live updates paused. Reconnecting…"
            } catch is CancellationError {
                return
            } catch {
                guard generation == token else { return }
                message = "Live updates paused. Reconnecting…"
            }

            do {
                try await Task.sleep(nanoseconds: retrySeconds * 1_000_000_000)
            } catch {
                return
            }
            guard generation == token else { return }
            retrySeconds = min(retrySeconds * 2, 15)
            await refresh(showError: false)
        }
    }

    private static func safeMessage(for error: Error) -> String {
        if let api = error as? APIError { return "Herdr: \(api.message)" }
        if let transport = error as? TransportError { return transport.description }
        return "Connection failed: \(error.localizedDescription)"
    }

#if DEBUG
    func applyVisualFixture(
        label: String,
        savedHost: SavedHost,
        topology: SessionTopology,
        message: String? = nil,
        topologyMessage: String? = nil
    ) {
        generation = UUID()
        phase = .connected(label)
        connectedSavedHost = savedHost
        publish(topology)
        recoveryOwner = CompanionInsertionOwner(savedHost)
        self.message = message
        self.topologyMessage = topologyMessage
        hostKeyRotation = nil
        mutationInFlight = nil
        mutationOutcomeUnknown = false
    }

    func installFixtureConnection() {
        guard connection == nil, let savedHost = connectedSavedHost,
              let credentials = savedCredentialsProvider?(savedHost) else { return }
        let made = connectionFactory(credentials)
        connection = made
        transport = made.transport
    }

    func seedRecoveryFixture(host: SavedHost, longDraft: Bool, present: Bool) {
        recoveryOwner = CompanionInsertionOwner(host)
        let owner = CompanionInsertionOwner(host)
        let draft = longDraft
            ? String(repeating: "kept draft line that must remain selectable and scrollable.\n", count: 24)
            : "echo kept-draft"
        preserveUnsentDraft(
            draft, owner: owner, target: .agent(paneID: "pane-reviewer"), title: "Codex")
        preserveUninsertedUpload(
            RemoteAttachment(
                path: "/Users/fixture/.herdr-companion-attachments-0123456789abcdef0123456789abcdef/attachment-11111111-1111-1111-1111-111111111111.png",
                byteCount: 4),
            owner: owner, target: .agent(paneID: "pane-reviewer"), title: "Codex")
        isPresentingRecovery = present
    }
#endif
}

@MainActor
enum CompanionNotificationNavigation {
    static func routePending(
        from notifications: CompanionNotificationController,
        savedHosts: [SavedHost],
        model: CompanionConnectionModel
    ) async {
        guard let route = notifications.consumePendingRoute() else { return }
        let savedHost = savedHosts.first {
            $0.id.uuidString.caseInsensitiveCompare(route.savedHostID) == .orderedSame
        }
        await model.openNotificationRoute(route, savedHost: savedHost)
    }
}

struct CompanionRootView: View {
    @StateObject private var model = CompanionConnectionModel()

    var body: some View {
        CompanionRootContent(model: model)
    }
}

struct CompanionRootContent: View {
    @ObservedObject var model: CompanionConnectionModel
    var displayHosts: [SavedHost]? = nil
    @ObservedObject private var notifications = CompanionNotificationController.shared
    @ObservedObject private var savedHosts = SavedHostsStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.isConnected {
                CompanionSessionShell(model: model)
            } else {
                NavigationStack {
                    CompanionConnectView(model: model, displayHosts: displayHosts)
                        .navigationDestination(item: Binding(
                            get: { model.notificationDestination },
                            set: { if $0 == nil { model.dismissNotificationDestination() } }
                        )) { destination in
                            CompanionTerminalHost(model: model, destination: destination)
                        }
                }
            }
        }
        .tint(Palette.accent)
        .companionInsertionRecovery(model: model)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.becameActive() } }
        }
        .task { await routePendingNotification() }
        .onChange(of: notifications.pendingRoute) { _, route in
            guard route != nil else { return }
            Task { await routePendingNotification() }
        }
    }

    private func routePendingNotification() async {
        await CompanionNotificationNavigation.routePending(
            from: notifications,
            savedHosts: displayHosts ?? savedHosts.hosts,
            model: model)
    }
}

struct CompanionConnectView: View {
    @ObservedObject var model: CompanionConnectionModel
    @ObservedObject var savedHosts: SavedHostsStore
    var displayHosts: [SavedHost]? = nil
    @State private var editor: HostEditorTarget?
    @State private var showingCredits = false

    init(
        model: CompanionConnectionModel,
        savedHosts: SavedHostsStore = .shared,
        displayHosts: [SavedHost]? = nil
    ) {
        self.model = model
        self.savedHosts = savedHosts
        self.displayHosts = displayHosts
    }

    private var hosts: [SavedHost] { displayHosts ?? savedHosts.hosts }

    var body: some View {
        List {
            if let message = model.message {
                Section {
                    CompanionBanner(text: message, kind: .error)
                        .listRowBackground(Palette.ground)
                }
            }

            Section {
                if hosts.isEmpty {
                    CompanionEmptyState(
                        title: "No saved Macs",
                        systemImage: "laptopcomputer",
                        detail: "Add a Meshnet or Tailscale address. Save each route separately if you use both.")
                    .listRowBackground(Palette.ground)
                }
                ForEach(hosts) { host in
                    Button { Task { await model.connect(host) } } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.label)
                                    .font(Typography.app(16, .semibold))
                                    .foregroundStyle(Palette.text)
                                    .lineLimit(1)
                                Text("\(host.username)@\(host.host) · \(host.herdrSession)")
                                    .font(Typography.machine(12))
                                    .foregroundStyle(Palette.textDim)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if case .connecting(let label) = model.phase, label == host.label {
                                ProgressView()
                            } else {
                                Text("Connect")
                                    .font(Typography.app(13, .semibold))
                                    .foregroundStyle(Palette.accent)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("companion-connect-host")
                    .accessibilityLabel(host.label)
                    .disabled(model.isConnecting)
                    .listRowBackground(Palette.ground)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            guard !model.isConnecting else { return }
                            Task { await model.deleteSavedHost(host) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(model.isConnecting)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            guard !model.isConnecting else { return }
                            editor = .edit(host)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .disabled(model.isConnecting)
                        .tint(Palette.accent)
                    }
                    .contextMenu {
                        Button("Edit") {
                            guard !model.isConnecting else { return }
                            editor = .edit(host)
                        }
                        .disabled(model.isConnecting)
                    }
                }
            }

            Section {
                Button("Credits and licenses") { showingCredits = true }
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.textDim)
                    .listRowBackground(Palette.ground)
            }
        }
        .listStyle(.plain)
        .companionScreen()
        .navigationTitle("Saved Macs")
        .companionScreen()
        .navigationTitle("Herdr Companion")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if model.isConnecting {
                    Button("Cancel") { Task { await model.disconnect() } }
                        .font(Typography.app(14, .semibold))
                } else {
                    CompanionMark(size: 24)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { editor = .add } label: {
                    Label("Add Mac", systemImage: "plus")
                }
                .disabled(model.isConnecting)
                .accessibilityLabel("Add Mac")
            }
        }
        .sheet(item: $editor) { target in
            HostEditor(target: target, store: savedHosts) { credentials in
                if let justSaved = savedHosts.hosts.first {
                    Task { await model.connect(justSaved) }
                } else {
                    Task { await model.connect(credentials: credentials, label: credentials.host) }
                }
            }
        }
        .sheet(isPresented: $showingCredits) {
            NavigationStack {
                List {
                    Text("Herdr Companion is licensed under Apache-2.0. It is derived from the Herdrup client and includes a vendored SwiftTerm distribution. Retain the repository and third-party license notices when redistributing it.")
                        .font(Typography.app(14))
                        .foregroundStyle(Palette.textDim)
                }
                .companionScreen()
                .navigationTitle("Credits")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showingCredits = false }
                    }
                }
            }
        }
        .alert(
            "SSH host key changed",
            isPresented: Binding(
                get: { model.hostKeyRotation != nil },
                set: { if !$0 { model.dismissHostKeyRotation() } }),
            presenting: model.hostKeyRotation
        ) { rotation in
            Button("Trust New Key & Reconnect", role: .destructive) {
                Task { await model.trustChangedHostKeyAndReconnect(rotation) }
            }
            Button("Cancel", role: .cancel) { model.cancelHostKeyRotation() }
        } message: { rotation in
            Text("\(rotation.credentials.host):\(rotation.credentials.port)\n\nPinned\n\(rotation.pinned)\n\nPresented\n\(rotation.presented)")
        }
    }
}

struct NewWorkspaceForm: View {
    @ObservedObject var model: CompanionConnectionModel
    let onCreated: (CompanionTerminalDestination) -> Void
    @State private var name = ""
    @State private var folder: String
    @Environment(\.dismiss) private var dismiss

    init(
        model: CompanionConnectionModel,
        initialCWD: String?,
        onCreated: @escaping (CompanionTerminalDestination) -> Void
    ) {
        self.model = model
        self.onCreated = onCreated
        _folder = State(initialValue: initialCWD ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("new-workspace-name")
                    TextField("Starting folder", text: $folder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Typography.machine(15))
                        .accessibilityIdentifier("new-workspace-folder")
                } footer: {
                    Text(folder.isEmpty
                         ? "Enter the folder this workspace should start in. Mac focus does not change."
                         : "Starts in this folder. Mac focus does not change.")
                }
                MutationStatusSection(model: model)
            }
            .companionScreen()
            .navigationTitle("New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.mutationOutcomeUnknown ? "Review Workspaces" : "Cancel") {
                        model.acknowledgeUnknownMutation()
                        dismiss()
                    }
                    .disabled(model.mutationInFlight != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .font(Typography.app(14, .semibold))
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || folder.isEmpty
                                  || model.mutationInFlight != nil
                                  || model.mutationOutcomeUnknown)
                        .accessibilityIdentifier("create-workspace-submit")
                }
            }
        }
    }

    private func create() {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let destination = await model.createWorkspace(label: label, cwd: folder) {
                onCreated(destination)
            }
        }
    }
}

struct NewTerminalTabForm: View {
    @ObservedObject var model: CompanionConnectionModel
    let workspaceID: String
    let onCreated: (CompanionTerminalDestination) -> Void
    @State private var label = ""
    @State private var folder: String
    @Environment(\.dismiss) private var dismiss

    init(
        model: CompanionConnectionModel,
        workspaceID: String,
        initialCWD: String?,
        onCreated: @escaping (CompanionTerminalDestination) -> Void
    ) {
        self.model = model
        self.workspaceID = workspaceID
        self.onCreated = onCreated
        _folder = State(initialValue: initialCWD ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CompanionDestinationContext(
                        location: CompanionTerminalLocation(
                            mac: macTitle,
                            session: model.connectedSavedHost?.herdrSession ?? "session",
                            workspace: CompanionWorkspaceTitle.display(
                                workspaceID: workspaceID, in: model.topology)),
                        prefix: "Adds a tab in this workspace")
                }
                Section {
                    TextField("Label (optional)", text: $label)
                    TextField("Starting folder", text: $folder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Typography.machine(15))
                } footer: {
                    Text(folder.isEmpty
                         ? "Adds a tab in this workspace. Empty folder uses the workspace default."
                         : "Adds a tab in this workspace. Mac focus does not change.")
                }
                MutationStatusSection(model: model)
            }
            .companionScreen()
            .navigationTitle("New Terminal Tab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.mutationOutcomeUnknown ? "Review Workspace" : "Cancel") {
                        model.acknowledgeUnknownMutation()
                        dismiss()
                    }
                    .disabled(model.mutationInFlight != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .font(Typography.app(14, .semibold))
                        .disabled(model.mutationInFlight != nil || model.mutationOutcomeUnknown)
                        .accessibilityIdentifier("create-terminal-tab-submit")
                }
            }
        }
    }

    private var macTitle: String {
        if case .connected(let label) = model.phase { return label }
        return model.connectedSavedHost?.label ?? "Mac"
    }

    private func create() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if let destination = await model.createTerminalTab(
                workspaceID: workspaceID,
                label: trimmedLabel.isEmpty ? nil : trimmedLabel,
                cwd: folder.isEmpty ? nil : folder) {
                onCreated(destination)
            }
        }
    }
}

struct SplitPaneForm: View {
    @ObservedObject var model: CompanionConnectionModel
    let pane: TopologyPaneInfo
    let onCreated: (CompanionTerminalDestination) -> Void
    @State private var folder: String
    @State private var direction: HerdrClient.SplitDirection = .right
    @Environment(\.dismiss) private var dismiss

    init(
        model: CompanionConnectionModel,
        pane: TopologyPaneInfo,
        onCreated: @escaping (CompanionTerminalDestination) -> Void
    ) {
        self.model = model
        self.pane = pane
        self.onCreated = onCreated
        _folder = State(initialValue: pane.effectiveCWD ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CompanionDestinationContext(
                        location: CompanionTerminalLocation(
                            mac: macTitle,
                            session: model.connectedSavedHost?.herdrSession ?? "session",
                            workspace: CompanionWorkspaceTitle.display(
                                workspaceID: pane.workspaceID, in: model.topology),
                            terminal: paneTitle),
                        prefix: "Splits this pane",
                        detail: paneDetail)
                }
                Section {
                    Picker("Direction", selection: $direction) {
                        Text("Right").tag(HerdrClient.SplitDirection.right)
                        Text("Down").tag(HerdrClient.SplitDirection.down)
                    }
                    .pickerStyle(.segmented)
                    TextField("Starting folder", text: $folder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Typography.machine(15))
                } header: {
                    Text("Split")
                } footer: {
                    Text("Splits this pane. Mac focus stays put.")
                }
                MutationStatusSection(model: model)
            }
            .companionScreen()
            .navigationTitle("Split Pane")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.mutationOutcomeUnknown ? "Review Workspace" : "Cancel") {
                        model.acknowledgeUnknownMutation()
                        dismiss()
                    }
                    .disabled(model.mutationInFlight != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Split") { split() }
                        .font(Typography.app(14, .semibold))
                        .disabled(model.mutationInFlight != nil || model.mutationOutcomeUnknown)
                        .accessibilityIdentifier("split-pane-submit")
                }
            }
        }
    }

    private var macTitle: String {
        if case .connected(let label) = model.phase { return label }
        return model.connectedSavedHost?.label ?? "Mac"
    }

    private var paneTitle: String {
        CompanionTerminalDestination(pane: pane)?.title ?? "Terminal"
    }

    private var paneDetail: String {
        [pane.effectiveCWD, pane.paneID].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func split() {
        Task {
            if let destination = await model.splitPane(
                workspaceID: pane.workspaceID,
                paneID: pane.paneID,
                cwd: folder.isEmpty ? nil : folder,
                direction: direction) {
                onCreated(destination)
            }
        }
    }
}

struct MutationStatusSection: View {
    @ObservedObject var model: CompanionConnectionModel

    var body: some View {
        if model.mutationInFlight != nil {
            Section {
                HStack(spacing: 10) {
                    ProgressView().tint(Palette.accent)
                    Text("Creating in Herdr…")
                }
                .font(Typography.app(14, .semibold))
            }
        } else if let message = model.topologyMessage {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.app(13))
                    .foregroundStyle(Palette.waiting)
            }
        }
    }
}
