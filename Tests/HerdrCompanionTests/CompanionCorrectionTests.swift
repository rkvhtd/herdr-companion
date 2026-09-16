import XCTest
import UIKit
import SwiftTerm
import SwiftUI
import HerdrKit
@testable import HerdrCompanion

@MainActor
final class CompanionHostDestinationHolder: ObservableObject {
    @Published var destination: CompanionTerminalDestination?
}

struct CompanionHostBoundaryHarness: View {
    @ObservedObject var model: CompanionConnectionModel
    @ObservedObject var holder: CompanionHostDestinationHolder

    var body: some View {
        NavigationStack {
            if let destination = holder.destination {
                CompanionTerminalHost(model: model, destination: destination)
            } else {
                Color.clear
            }
        }
        .companionInsertionRecovery(model: model)
        .frame(width: 400, height: 760)
    }
}

@MainActor
final class CompanionScenePhaseHolder: ObservableObject {
    @Published var phase: ScenePhase = .active
}

struct CompanionSceneBoundaryHarness: View {
    @ObservedObject var model: CompanionConnectionModel
    @ObservedObject var holder: CompanionHostDestinationHolder
    @ObservedObject var scene: CompanionScenePhaseHolder

    var body: some View {
        CompanionHostBoundaryHarness(model: model, holder: holder)
            .environment(\.scenePhase, scene.phase)
    }
}

@MainActor
final class CompanionDynamicTypeHolder: ObservableObject {
    @Published var size: DynamicTypeSize = .large
}

struct CompanionRecoveryDynamicTypeHarness: View {
    @ObservedObject var model: CompanionConnectionModel
    @ObservedObject var typeSize: CompanionDynamicTypeHolder
    var width: CGFloat = 400
    var height: CGFloat = 760

    var body: some View {
        CompanionRootContent(model: model, displayHosts: [CompanionCorrectionTests.studioMac])
            .environment(\.dynamicTypeSize, typeSize.size)
            .frame(width: width, height: height)
    }
}

@MainActor
final class CompanionNavigationHolder: ObservableObject {
    @Published var navigation = CompanionSplitNavigationState()
}

struct CompanionSplitBoundaryHarness: View {
    @ObservedObject var model: CompanionConnectionModel
    @ObservedObject var holder: CompanionNavigationHolder

    var body: some View {
        CompanionSplitSessionView(model: model, navigation: $holder.navigation)
            .environment(\.horizontalSizeClass, .regular)
            .frame(width: 1024, height: 768)
    }
}

@MainActor
final class CompanionAdaptiveHolder: ObservableObject {
    @Published var sizeClass: UserInterfaceSizeClass = .regular
    @Published var size = CGSize(width: 1024, height: 768)
}

struct CompanionSessionShellHarness: View {
    @ObservedObject var model: CompanionConnectionModel
    @ObservedObject var adaptive: CompanionAdaptiveHolder

    var body: some View {
        CompanionRootContent(model: model, displayHosts: [CompanionCorrectionTests.studioMac])
            .environment(\.horizontalSizeClass, adaptive.sizeClass)
            .frame(width: adaptive.size.width, height: adaptive.size.height)
    }
}

struct CompanionMiddleSearchHarness: View {
    @ObservedObject var model: CompanionConnectionModel
    @ObservedObject var holder: CompanionNavigationHolder

    var body: some View {
        NavigationStack {
            CompanionOverviewDetailList(model: model, navigation: $holder.navigation)
        }
        .frame(width: 400, height: 760)
    }
}

@MainActor
final class CompanionCorrectionTests: XCTestCase {
    private var retainedWindow: UIWindow?

    override func tearDown() async throws {
        retainedWindow?.rootViewController?.dismiss(animated: false)
        retainedWindow?.isHidden = true
        retainedWindow = nil
        try await super.tearDown()
    }

    func testTerminalIdentityKeysSavedHostAndOfficialTargetNotLabel() {
        let host = UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        let agentA = CompanionTerminalIdentity.key(hostID: host, target: .agent(paneID: "pane-a"))
        let agentB = CompanionTerminalIdentity.key(hostID: host, target: .agent(paneID: "pane-b"))
        let shell = CompanionTerminalIdentity.key(hostID: host, target: .terminal(terminalID: "term-shell"))
        XCTAssertNotEqual(agentA, agentB)
        XCTAssertNotEqual(agentA, shell)
        XCTAssertNotEqual(
            agentA,
            CompanionTerminalIdentity.key(hostID: UUID(), target: .agent(paneID: "pane-a")))
    }

    func testPlainShellMatcherUsesTerminalIDNotPaneID() throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let pane = try XCTUnwrap(topology.panes.first { $0.paneID == "pane-shell" })
        XCTAssertNotEqual(pane.paneID, pane.terminalID)
        let destination = try XCTUnwrap(CompanionTerminalDestination(pane: pane))
        XCTAssertEqual(destination.target, .terminal(terminalID: "term-shell"))
        XCTAssertTrue(CompanionTerminalIdentity.matches(destination, pane: pane))

        var navigation = CompanionSplitNavigationState()
        navigation.selectWorkspace("workspace-app")
        navigation.openedTerminal = destination
        navigation.reconcile(
            topology: topology, agents: topology.agents,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-shell")

        let empty = try CompanionOverviewTests.loadTopology(workspaces: false)
        navigation.reconcile(
            topology: empty, agents: [],
            isConnected: true, isConnecting: false)
        XCTAssertNil(navigation.openedTerminal)

        navigation.openedTerminal = destination
        navigation.reconcile(
            topology: nil, agents: topology.agents,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-shell")
    }

    func testProductionHostSwitchClosesAAndOpensB() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let destB = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-calendar" })))
        XCTAssertNotEqual(destA.target, destB.target)

        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))

        try await waitUntil {
            let sessions = await store.sessions
            return sessions.count == 1 && sessions.last?.started == true
        }
        let identityA = try XCTUnwrap(model.insertControllerForTests?.targetIdentity)
        let openedA = await store.current()
        let sessionA = try XCTUnwrap(openedA)
        XCTAssertEqual(sessionA.target, destA.target)

        holder.destination = destB
        try await waitUntil {
            let sessions = await store.sessions
            return sessions.count >= 2 && sessions[0].closed && sessions.last?.started == true
        }
        let sessions = await store.sessions
        XCTAssertTrue(sessions[0].closed)
        XCTAssertEqual(sessions[0].target, destA.target)
        XCTAssertEqual(sessions.last?.target, destB.target)
        XCTAssertFalse(sessions.last?.closed ?? true)

        let controllerB = try XCTUnwrap(model.insertControllerForTests)
        let stolen = try await controllerB.insertDraftText("from A", identity: identityA)
        XCTAssertEqual(stolen, .unavailable)
        XCTAssertTrue((sessions.last?.acknowledged ?? []).isEmpty)

        let written = try await controllerB.insertDraftText(
            "hello B", identity: controllerB.targetIdentity)
        XCTAssertEqual(written, .written)
        XCTAssertEqual(sessions.last?.acknowledged.count, 1)
        XCTAssertTrue(sessions[0].acknowledged.isEmpty)
    }

    func testDelayedDraftAckSurvivesScreenTeardownAndDoesNotWriteToReplacement() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let destB = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-calendar" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil { await store.sessions.last?.started == true }

        let openedA = await store.current()
        let sessionA = try XCTUnwrap(openedA)
        sessionA.suspendAcknowledgement = true
        let draft = "keep this exact draft"
        let submit = Task {
            await model.submitDraftUsingActiveController(
                draft, target: destA.target, title: destA.title)
        }
        try await waitUntil { sessionA.acknowledgementInFlight }
        holder.destination = destB
        try await waitUntil { sessionA.closed }
        XCTAssertTrue(sessionA.closed)
        XCTAssertTrue(sessionA.acknowledgementInFlight)
        sessionA.finishAcknowledgement()
        let finish = await submit.value
        XCTAssertTrue(
            model.wasForgotten(finish.operationID) || model.receipt(id: finish.operationID) == nil,
            "in-flight A write must resolve on A, not move to B")
        try await waitUntil {
            let sessions = await store.sessions
            return sessions.count >= 2
        }
        let later = await store.sessions
        XCTAssertTrue((later.last?.acknowledged ?? []).isEmpty)
        XCTAssertTrue(sessionA.closed)
    }

    func testUnknownUploadedPathIsNotDeletedOrDowngradedThroughCancelAndTeardown() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let recorder = CompanionCleanupRecorder()
        let uploader = CompanionUploadRecorder(result: .success(Self.validAttachment))
        let model = fixtureModel(topology: topology, store: store)
        model.attachmentCleanup = recorder
        model.attachmentUpload = uploader
        model.fixtureShowAttachment = true
        model.fixtureBeginUpload = true
        model.fixtureBeginInsert = true
        model.terminalOpener = { target, _, _, _, _ in
            let session = CompanionInertTerminalSession(target: target)
            session.failAcknowledgedUnknown = true
            await store.opened(session)
            return .success(session)
        }
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil {
            model.recoverableReceipts.contains {
                if case .acknowledgementUnknown = $0.status, case .uploaded = $0.payload { return true }
                return false
            }
        }
        let unknown = try XCTUnwrap(model.recoverableReceipts.first)
        XCTAssertFalse(unknown.allowsCleanup)
        XCTAssertTrue(unknown.canForgetWithoutDeletion)
        let refused = await model.retryDiscard(unknown)
        XCTAssertEqual(
            refused,
            "This item is not eligible for deletion because the write outcome is not a confirmed failure.")
        XCTAssertTrue(recorder.removed.isEmpty)
        holder.destination = nil
        try await waitUntil { model.recoverableReceipts.count == 1 }
        guard case .acknowledgementUnknown = model.recoverableReceipts.first?.status else {
            return XCTFail("teardown must not downgrade unknown")
        }
        XCTAssertTrue(recorder.removed.isEmpty)
        await model.disconnect()
        XCTAssertEqual(model.recoverableReceipts.count, 1)
        XCTAssertTrue(recorder.removed.isEmpty)
        XCTAssertEqual(uploader.started, 1)
    }

    func testSuccessfulUploadedPathIsNeverDeletedAndLateCallbackCannotResurrect() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let destB = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-calendar" })))
        let store = CompanionInertSessionStore()
        let recorder = CompanionCleanupRecorder()
        let uploader = CompanionUploadRecorder(result: .success(Self.validAttachment))
        let model = fixtureModel(topology: topology, store: store)
        model.attachmentCleanup = recorder
        model.attachmentUpload = uploader
        model.fixtureShowAttachment = true
        model.fixtureBeginUpload = true
        model.fixtureBeginInsert = true
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        var seenIDs = Set<UUID>()
        try await waitUntil {
            seenIDs.formUnion(model.insertionReceipts.keys)
            seenIDs.formUnion(model.forgottenInsertionIDs)
            return uploader.started == 1 && model.insertionReceipts.isEmpty && !seenIDs.isEmpty
        }
        let consumed = try XCTUnwrap(seenIDs.first)
        XCTAssertTrue(model.wasForgotten(consumed))
        XCTAssertTrue(model.recoverableReceipts.isEmpty)
        XCTAssertTrue(recorder.removed.isEmpty)
        model.resolveInsertion(id: consumed, status: .confirmedNotWritten("stale"))
        XCTAssertTrue(model.recoverableReceipts.isEmpty)
        XCTAssertTrue(model.wasForgotten(consumed))
        holder.destination = destB
        try await waitUntil { await store.sessions.count >= 2 }
        XCTAssertTrue(recorder.removed.isEmpty)
        XCTAssertTrue(model.recoverableReceipts.isEmpty)
    }

    func testUnbracketedMultilineDraftIsRejectedAndRetained() async throws {
        let (controller, view, session, identity) = try await connectedController(bracketed: false)
        let original = "echo first\necho second"
        let result = try await controller.insertDraftText(original, identity: identity)
        guard case .rejected(let reason) = result else {
            return XCTFail("expected rejection, got \(result)")
        }
        XCTAssertTrue(reason.contains("multiline"))
        XCTAssertTrue(session.acknowledged.isEmpty)
        XCTAssertFalse(view.getTerminal().bracketedPasteMode)
    }

    func testUnbracketedTabAndControlAreRejected() async throws {
        let (controller, _, session, identity) = try await connectedController(bracketed: false)
        let tab = try await controller.insertDraftText("hello\tworld", identity: identity)
        XCTAssertEqual(tab, .rejected("This terminal is not in bracketed-paste mode, so a tab would be interpreted as a terminal key. The text was kept and not written."))
        let esc = try await controller.insertDraftText("hello\u{1b}world", identity: identity)
        guard case .rejected = esc else { return XCTFail("esc should reject") }
        let cr = try await controller.insertDraftText("hello\r", identity: identity)
        guard case .rejected = cr else { return XCTFail("CR should reject") }
        XCTAssertTrue(session.acknowledged.isEmpty)
    }

    func testBracketedMultilineDraftWritesExactBytesWithoutReturnKey() async throws {
        let (controller, view, session, identity) = try await connectedController(bracketed: true)
        let original = "echo first\necho second"
        let result = try await controller.insertDraftText(original, identity: identity)
        XCTAssertEqual(result, .written)
        let payload = try XCTUnwrap(session.acknowledged.first)
        XCTAssertTrue(payload.starts(with: Data(EscapeSequences.bracketedPasteStart)))
        XCTAssertTrue(payload.elementsEqual(
            Data(EscapeSequences.bracketedPasteStart)
            + Data(original.utf8)
            + Data(EscapeSequences.bracketedPasteEnd)))
        XCTAssertTrue(view.getTerminal().bracketedPasteMode)
    }

    func testPlainTextWritesInBothPasteModes() async throws {
        let unbracketed = try await connectedController(bracketed: false)
        let unbracketedResult = try await unbracketed.controller.insertDraftText(
            "hello", identity: unbracketed.identity)
        XCTAssertEqual(unbracketedResult, .written)
        XCTAssertEqual(unbracketed.session.acknowledged.count, 1)

        let bracketed = try await connectedController(bracketed: true)
        let bracketedResult = try await bracketed.controller.insertDraftText(
            "hello", identity: bracketed.identity)
        XCTAssertEqual(bracketedResult, .written)
        XCTAssertEqual(bracketed.session.acknowledged.count, 1)
    }

    func testDraftWriteFailureAndDisconnectKeepTextUnwritten() async throws {
        let (controller, _, session, identity) = try await connectedController(bracketed: false)
        session.failAcknowledged = true
        do {
            _ = try await controller.insertDraftText("hello", identity: identity)
            XCTFail("expected closed error")
        } catch {
            XCTAssertEqual(error as? OfficialTerminalInputError, .closed)
        }
        XCTAssertTrue(session.acknowledged.isEmpty)

        await controller.close()
        let afterClose = try await controller.insertDraftText("hello", identity: identity)
        XCTAssertEqual(afterClose, .unavailable)
    }

    func testPendingUploadCleanupRequiredIsRetainedAfterScreenRemoval() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let recorder = CompanionCleanupRecorder()
        let uploader = CompanionUploadRecorder(result: .failure(
            RemoteAttachmentError.cleanupRequired(RemoteAttachmentCleanup.testingHandle(), "interrupted")))
        uploader.delayNanoseconds = 180_000_000
        let model = fixtureModel(topology: topology, store: store)
        model.attachmentCleanup = recorder
        model.attachmentUpload = uploader
        model.fixtureShowAttachment = true
        model.fixtureBeginUpload = true
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil { uploader.started == 1 }
        holder.destination = nil
        try await waitUntil {
            model.recoverableReceipts.contains {
                if case .incompleteCleanup = $0.payload { return true }
                return false
            }
        }
        XCTAssertTrue(recorder.removed.isEmpty)
        XCTAssertTrue(recorder.retried.isEmpty)
        await model.disconnect()
        XCTAssertEqual(model.recoverableReceipts.count, 1)
        guard case .incompleteCleanup = model.recoverableReceipts.first?.payload else {
            return XCTFail("late cleanupRequired must keep the opaque handle")
        }
    }

    func testPendingDiscardSuccessConsumesReceiptAfterDisconnect() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let recorder = CompanionCleanupRecorder()
        recorder.delayNanoseconds = 180_000_000
        let uploader = CompanionUploadRecorder(result: .success(Self.validAttachment))
        let model = fixtureModel(topology: topology, store: store)
        model.attachmentCleanup = recorder
        model.attachmentUpload = uploader
        model.fixtureShowAttachment = true
        model.fixtureBeginUpload = true
        model.fixtureBeginCancel = true
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil { uploader.started == 1 }
        try await waitUntil { model.insertionReceipts.values.contains(where: \.isCleanupInFlight) }
        holder.destination = nil
        await model.disconnect()
        try await waitUntil { recorder.removed.count == 1 && model.recoverableReceipts.isEmpty }
        XCTAssertEqual(recorder.removed.count, 1)
        XCTAssertTrue(model.recoverableReceipts.isEmpty)
    }


    func testPendingAcknowledgedWriteRemainsAwaitingAcrossDisposalThenWrites() async throws {
        try await assertScreenOwnedPendingWrite(
            unknown: false,
            afterResolution: { model, flowID, session, recorder in
                XCTAssertTrue(model.wasForgotten(flowID))
                XCTAssertNil(model.receipt(id: flowID))
                XCTAssertTrue(session.closed)
                XCTAssertEqual(session.acknowledged.count, 1)
                XCTAssertTrue(recorder.removed.isEmpty)
                XCTAssertTrue(model.recoverableReceipts.isEmpty)
            })
    }

    func testPendingAcknowledgedWriteRemainsAwaitingAcrossDisposalThenUnknown() async throws {
        try await assertScreenOwnedPendingWrite(
            unknown: true,
            afterResolution: { model, flowID, session, recorder in
                let unknown = try XCTUnwrap(model.receipt(id: flowID))
                guard case .acknowledgementUnknown = unknown.status else {
                    return XCTFail("expected unknown after in-flight writer result, got \(unknown.status)")
                }
                XCTAssertEqual(unknown.phase, .resolved)
                XCTAssertFalse(unknown.allowsCleanup)
                XCTAssertTrue(unknown.canForgetWithoutDeletion)
                XCTAssertTrue(session.closed)
                XCTAssertTrue(recorder.removed.isEmpty)
            })
    }

    func testLastDetachedTerminalClosesSessionAndBecomesReconnectable() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil { await store.sessions.last?.started == true }
        let _opened_session = await store.current()
        let session = try XCTUnwrap(_opened_session)
        let controller = try XCTUnwrap(model.insertControllerForTests)
        holder.destination = nil
        try await waitUntil { session.closed }
        try await waitUntil { controller.isReconnectable }
        XCTAssertTrue(session.closed)
        XCTAssertTrue(controller.isReconnectable)
        holder.destination = destA
        try await waitUntil { await store.sessions.count >= 2 }
        XCTAssertTrue(session.closed)
        let remounted = await store.current()
        XCTAssertTrue(try XCTUnwrap(remounted).started)
    }

    func testUploadRecorderCancelBeforeAndAfterGateInstallation() async throws {
        let before = CompanionUploadRecorder(result: .success(Self.validAttachment))
        before.suspendUntilReleased = true
        let early = Task {
            try await before.uploadAttachment(data: Data([0x89]), fileExtension: "png")
        }
        early.cancel()
        do {
            _ = try await early.value
            XCTFail("cancel-before-install must not succeed")
        } catch is CancellationError {
        } catch {
            XCTFail("cancel-before-install unexpected \(error)")
        }
        XCTAssertTrue(before.sawCancellation)
        XCTAssertEqual(before.terminalResult, "cancelled")
        XCTAssertEqual(before.started, 1)

        let after = CompanionUploadRecorder(result: .success(Self.validAttachment))
        after.suspendUntilReleased = true
        let running = Task {
            try await after.uploadAttachment(data: Data([0x89]), fileExtension: "png")
        }
        try await after.waitUntilGateWaiting(timeout: 1)
        running.cancel()
        do {
            _ = try await running.value
            XCTFail("cancel-after-install must not succeed")
        } catch is CancellationError {
        } catch {
            XCTFail("cancel-after-install unexpected \(error)")
        }
        XCTAssertTrue(after.sawCancellation)
        XCTAssertEqual(after.terminalResult, "cancelled")

        let released = CompanionUploadRecorder(result: .success(Self.validAttachment))
        released.suspendUntilReleased = true
        let ok = Task {
            try await released.uploadAttachment(data: Data([0x89]), fileExtension: "png")
        }
        try await released.waitUntilGateWaiting(timeout: 1)
        released.releaseGate()
        let remote = try await ok.value
        XCTAssertEqual(remote.byteCount, 4)
        XCTAssertFalse(released.sawCancellation)
        XCTAssertEqual(released.terminalResult, "success")
    }

    func testSessionMirrorClosedStaysTerminalAgainstStaleStart() {
        let mirror = CompanionFixtureSessionMirror()
        let id = UUID()
        mirror.registerPending(id)
        XCTAssertTrue(mirror.probeSnapshot().contains("|pending"))
        mirror.note(id, .started)
        XCTAssertTrue(mirror.probeSnapshot().contains("|started"))
        XCTAssertFalse(mirror.probeSnapshot().contains("|closed"))
        mirror.note(id, .closed)
        XCTAssertTrue(mirror.probeSnapshot().contains("|closed"))
        XCTAssertFalse(mirror.probeSnapshot().contains("|started"))
        mirror.note(id, .started)
        mirror.note(id, .pending)
        XCTAssertTrue(mirror.probeSnapshot().contains("|closed"))
        XCTAssertFalse(mirror.probeSnapshot().contains("|started"))
        XCTAssertFalse(mirror.probeSnapshot().contains("|pending"))
    }

    func testSessionMirrorTargetStaysBoundToIdentityAcrossLifecycle() {
        let mirror = CompanionFixtureSessionMirror()
        let first = UUID()
        let second = UUID()
        mirror.registerPending(first, target: .agent(paneID: "pane-long-parent-a"))
        mirror.registerPending(second, target: .agent(paneID: "pane-long-parent-b"))
        mirror.note(first, .started)
        XCTAssertEqual(
            mirror.targetProbeSnapshot(),
            "\(first.uuidString)|agent:pane-long-parent-a;\(second.uuidString)|agent:pane-long-parent-b")
        XCTAssertTrue(mirror.probeSnapshot().contains("\(first.uuidString)|started"))
        XCTAssertFalse(mirror.probeSnapshot().contains("\(second.uuidString)|started"))
        mirror.note(first, .closed)
        mirror.note(second, .started)
        let live = mirror.probeSnapshot().split(separator: ";").filter {
            $0.contains("|started") && !$0.contains("|closed")
        }
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(String(live[0]), "\(second.uuidString)|started")
        XCTAssertTrue(
            mirror.targetProbeSnapshot().contains("\(second.uuidString)|agent:pane-long-parent-b"))
        XCTAssertTrue(
            mirror.targetProbeSnapshot().contains("\(first.uuidString)|agent:pane-long-parent-a"))
        mirror.note(first, .started)
        mirror.registerPending(first, target: .agent(paneID: "pane-long-parent-b"))
        XCTAssertTrue(mirror.probeSnapshot().contains("\(first.uuidString)|closed"))
        XCTAssertTrue(
            mirror.targetProbeSnapshot().contains("\(first.uuidString)|agent:pane-long-parent-a"))
        XCTAssertFalse(
            mirror.targetProbeSnapshot().contains("\(first.uuidString)|agent:pane-long-parent-b"))
    }

    func testTeardownThenNoFileUploadFailureRemovesPendingReceipt() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let uploader = CompanionUploadRecorder(result: .failure(
            OfficialTerminalError.transport("upload-denied")))
        uploader.delayNanoseconds = 180_000_000
        let model = fixtureModel(topology: topology, store: store)
        model.attachmentUpload = uploader
        model.fixtureShowAttachment = true
        model.fixtureBeginUpload = true
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil(stage: "teardown-upload-started") { uploader.started == 1 }
        let flowID = try XCTUnwrap(model.insertionReceipts.values.first?.id)
        holder.destination = nil
        try await waitUntil(stage: "teardown-no-file-resolved") {
            model.receipt(id: flowID) == nil
        }
        XCTAssertTrue(model.recoverableReceipts.isEmpty)
        XCTAssertTrue(model.awaitingReceipts.isEmpty)
        XCTAssertFalse(model.wasForgotten(flowID))
    }

    func testSceneInactiveDoesNotSuppressPendingWriter() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let recorder = CompanionCleanupRecorder()
        let uploader = CompanionUploadRecorder(result: .success(Self.validAttachment))
        let model = fixtureModel(topology: topology, store: store)
        model.testActivateTerminalScene = false
        model.attachmentCleanup = recorder
        model.attachmentUpload = uploader
        model.fixtureShowAttachment = true
        model.fixtureBeginUpload = true
        model.fixtureBeginInsert = true
        model.terminalOpener = { target, _, _, _, _ in
            let session = CompanionInertTerminalSession(target: target)
            session.suspendAcknowledgement = true
            await store.opened(session)
            return .success(session)
        }
        let holder = CompanionHostDestinationHolder()
        let scene = CompanionScenePhaseHolder()
        holder.destination = destA
        _ = present(CompanionSceneBoundaryHarness(model: model, holder: holder, scene: scene))
        try await waitUntil(stage: "scene-writer-started") { await store.sessions.last?.started == true }
        let openedWriter = await store.current()
        let session = try XCTUnwrap(openedWriter)
        try await waitUntil(stage: "scene-writer-in-flight") {
            session.acknowledgementInFlight
                && model.insertionReceipts.values.contains { $0.phase == .submitting }
        }
        let flowID = try XCTUnwrap(model.insertionReceipts.values.first { $0.phase == .submitting }?.id)
        scene.phase = .inactive
        try await waitUntil(stage: "scene-writer-session-closed") { session.closed }
        XCTAssertEqual(model.receipt(id: flowID)?.phase, .submitting)
        XCTAssertFalse(try XCTUnwrap(model.receipt(id: flowID)).allowsCleanup)
        XCTAssertTrue(model.recoverableReceipts.isEmpty)
        scene.phase = .active
        session.finishAcknowledgement()
        try await waitUntil(stage: "scene-writer-settled") {
            model.receipt(id: flowID)?.phase != .submitting || model.receipt(id: flowID) == nil
        }
        XCTAssertTrue(session.closed)
        XCTAssertTrue(recorder.removed.isEmpty)
    }

    func testRecoveryEntryUsesAccessibilityActivateAndHonorsDynamicType() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let model = fixtureModel(topology: topology, store: CompanionInertSessionStore())
        let owner = try XCTUnwrap(model.recoveryOwner)
        model.preserveUninsertedUpload(
            Self.validAttachment, owner: owner, target: .agent(paneID: "pane-reviewer"), title: "Codex")
        let typeSize = CompanionDynamicTypeHolder()
        _ = present(CompanionRecoveryDynamicTypeHarness(model: model, typeSize: typeSize))
        try await waitUntil(stage: "entry-default-size") {
            self.controlExists(
                identifier: "companion-recovery-entry",
                label: "1 item kept from Example Mac. Review")
        }
        let defaultHeight = entryControlHeight()
        XCTAssertGreaterThanOrEqual(defaultHeight ?? 0, 44)
        XCTAssertLessThan(defaultHeight ?? 0, 120, "entry must size to its title, not leftover VStack height")
        try activateOnce(
            identifier: "companion-recovery-entry",
            label: "1 item kept from Example Mac. Review")
        try await waitUntil(stage: "entry-accessibility-activate-presented") {
            model.isPresentingRecovery && self.recoverySheetIsPresented()
        }
        try await activateControl(
            identifier: "companion-recovery-close", label: "Close",
            presentedOnly: true, stage: "close-control-ready")
        try await waitUntil(stage: "close-dismissed") {
            model.isPresentingRecovery == false && !self.recoverySheetIsPresented()
        }
        typeSize.size = .accessibility3
        try await waitUntil(stage: "entry-accessibility-size") {
            (self.entryControlHeight() ?? 0) >= (defaultHeight ?? 44)
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(entryControlHeight()), 44)
    }

    func testRecoveryEntryDynamicTypeOnIPadSize() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let model = fixtureModel(topology: topology, store: CompanionInertSessionStore())
        let owner = try XCTUnwrap(model.recoveryOwner)
        model.preserveUninsertedUpload(
            Self.validAttachment, owner: owner, target: .agent(paneID: "pane-reviewer"), title: "Codex")
        let typeSize = CompanionDynamicTypeHolder()
        typeSize.size = .accessibility2
        _ = present(
            CompanionRecoveryDynamicTypeHarness(
                model: model, typeSize: typeSize, width: 1024, height: 768),
            size: CGSize(width: 1024, height: 768))
        try await waitUntil(stage: "ipad-entry-control") {
            self.controlExists(
                identifier: "companion-recovery-entry",
                label: "1 item kept from Example Mac. Review")
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(entryControlHeight()), 44)
        XCTAssertLessThan(try XCTUnwrap(entryControlHeight()), 220)
        try activateOnce(
            identifier: "companion-recovery-entry",
            label: "1 item kept from Example Mac. Review")
        try await waitUntil(stage: "ipad-sheet-presented") {
            model.isPresentingRecovery && self.recoverySheetIsPresented()
        }
    }

    func testPendingWriteOnADoesNotSuppressBClose() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let destB = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-calendar" })))
        let store = CompanionInertSessionStore()
        let uploader = CompanionUploadRecorder(result: .success(Self.validAttachment))
        let model = fixtureModel(topology: topology, store: store)
        model.attachmentUpload = uploader
        model.fixtureShowAttachment = true
        model.fixtureBeginUpload = true
        model.fixtureBeginInsert = true
        model.terminalOpener = { target, _, _, _, _ in
            let session = CompanionInertTerminalSession(target: target)
            session.suspendAcknowledgement = true
            await store.opened(session)
            return .success(session)
        }
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil { await store.sessions.last?.started == true }
        let _opened_sessionA = await store.current()
        let sessionA = try XCTUnwrap(_opened_sessionA)
        try await waitUntil { sessionA.acknowledgementInFlight }
        holder.destination = destB
        try await waitUntil { sessionA.closed }
        try await waitUntil { await store.sessions.count >= 2 }
        let _opened_sessionB = await store.current()
        let sessionB = try XCTUnwrap(_opened_sessionB)
        try await waitUntil { sessionB.started }
        holder.destination = nil
        try await waitUntil { sessionB.closed }
        XCTAssertTrue(sessionA.closed)
        XCTAssertTrue(sessionB.closed)
        sessionA.finishAcknowledgement()
        try await waitUntil(stage: "a-writer-settled") {
            !sessionA.acknowledgementInFlight
        }
    }

    private func assertScreenOwnedPendingWrite(
        unknown: Bool,
        afterResolution: (CompanionConnectionModel, UUID, CompanionInertTerminalSession, CompanionCleanupRecorder) throws -> Void
    ) async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let recorder = CompanionCleanupRecorder()
        let uploader = CompanionUploadRecorder(result: .success(Self.validAttachment))
        let model = fixtureModel(topology: topology, store: store)
        model.attachmentCleanup = recorder
        model.attachmentUpload = uploader
        model.fixtureShowAttachment = true
        model.fixtureBeginUpload = true
        model.fixtureBeginInsert = true
        model.terminalOpener = { target, _, _, _, _ in
            let session = CompanionInertTerminalSession(target: target)
            session.suspendAcknowledgement = true
            session.failAcknowledgedUnknown = unknown
            await store.opened(session)
            return .success(session)
        }
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil { await store.sessions.last?.started == true }
        let _opened_session = await store.current()
        let session = try XCTUnwrap(_opened_session)
        try await waitUntil { uploader.started == 1 }
        try await waitUntil {
            model.insertionReceipts.values.contains { $0.phase == .submitting && $0.isWriterOwned }
                && session.acknowledgementInFlight
        }
        let flowID = try XCTUnwrap(model.insertionReceipts.values.first { $0.phase == .submitting }?.id)
        XCTAssertFalse(try XCTUnwrap(model.receipt(id: flowID)).allowsCleanup)
        XCTAssertFalse(try XCTUnwrap(model.receipt(id: flowID)).canForgetWithoutDeletion)
        holder.destination = nil
        try await waitUntil { session.closed }
        XCTAssertEqual(model.receipt(id: flowID)?.phase, .submitting)
        XCTAssertFalse(try XCTUnwrap(model.receipt(id: flowID)).allowsCleanup)
        XCTAssertTrue(model.recoverableReceipts.isEmpty)
        XCTAssertTrue(recorder.removed.isEmpty)
        let controller = try XCTUnwrap(model.insertControllerForTests)
        try await waitUntil { controller.isReconnectable }
        session.finishAcknowledgement()
        try await waitUntil { model.receipt(id: flowID)?.phase != .submitting || model.receipt(id: flowID) == nil }
        XCTAssertTrue(session.closed)
        try afterResolution(model, flowID, session, recorder)
    }

    func testDiscardOfDelayedAUploadRefusedWhileBIsCurrent() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let recorder = CompanionCleanupRecorder()
        let uploader = CompanionUploadRecorder(result: .success(Self.validAttachment))
        uploader.delayNanoseconds = 250_000_000
        let model = fixtureModel(topology: topology, store: store)
        model.attachmentCleanup = recorder
        model.attachmentUpload = uploader
        model.fixtureShowAttachment = true
        model.fixtureBeginUpload = true
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil { await store.sessions.last?.started == true }
        try await waitUntil { uploader.started == 1 && !model.insertionReceipts.isEmpty }
        let flowID = try XCTUnwrap(model.insertionReceipts.values.first?.id)
        let ownerA = try XCTUnwrap(model.receipt(id: flowID)?.owner.savedHostID)
        let pending = try XCTUnwrap(model.receipt(id: flowID))
        XCTAssertNotEqual(pending.phase, .uploadedUnsubmitted, "B must be current before A's upload callback returns")
        XCTAssertNotEqual(pending.phase, .resolved)
        let hostB = SavedHost(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            host: "other.example.ts.net", username: "fixture",
            nickname: "Other Mac", authKind: .key, session: "default")
        model.applyVisualFixture(label: "Other Mac", savedHost: hostB, topology: topology)
        XCTAssertEqual(try XCTUnwrap(model.connectedSavedHost).id, hostB.id)
        try await waitUntil {
            guard let receipt = model.receipt(id: flowID) else { return false }
            return receipt.owner.savedHostID == ownerA && receipt.phase != .uploading
        }
        let receipt = try XCTUnwrap(model.receipt(id: flowID))
        XCTAssertEqual(receipt.owner.savedHostID, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertNotEqual(try XCTUnwrap(model.connectedSavedHost).id, receipt.owner.savedHostID)
        let refused = await model.discardAttachment(id: receipt.id)
        XCTAssertTrue(refused?.contains("Reconnect") == true)
        XCTAssertTrue(recorder.removed.isEmpty)
        let kept = try XCTUnwrap(model.receipt(id: receipt.id))
        XCTAssertEqual(kept.owner.savedHostID, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertTrue(kept.allowsCleanup || kept.phase == .uploadedUnsubmitted)
        XCTAssertFalse(model.wasForgotten(receipt.id))
    }

    func testOverlappingDiscardAndStaleFailureDoNotResurrectForgottenReceipt() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let model = fixtureModel(topology: topology, store: CompanionInertSessionStore())
        let recorder = CompanionCleanupRecorder()
        recorder.delayNanoseconds = 200_000_000
        recorder.error = OfficialTerminalError.transport("cleanup-failed")
        model.attachmentCleanup = recorder
        let owner = try XCTUnwrap(model.recoveryOwner)
        model.preserveUninsertedUpload(
            Self.validAttachment, owner: owner, target: .agent(paneID: "pane-reviewer"), title: "Codex")
        let receipt = try XCTUnwrap(model.recoverableReceipts.first)
        let first = Task { await model.discardAttachment(id: receipt.id) }
        try await waitUntil { model.receipt(id: receipt.id)?.isCleanupInFlight == true }
        let overlapping = await model.discardAttachment(id: receipt.id)
        XCTAssertEqual(overlapping, "Cleanup is already in progress.")
        model.forgetReceipt(receipt)
        XCTAssertNotNil(model.receipt(id: receipt.id))
        XCTAssertTrue(try XCTUnwrap(model.receipt(id: receipt.id)).isCleanupInFlight)
        model.consumeInsertion(id: receipt.id)
        let failed = await first.value
        XCTAssertNotNil(failed)
        XCTAssertNil(model.receipt(id: receipt.id))
        XCTAssertTrue(model.wasForgotten(receipt.id))
        model.resolveInsertion(id: receipt.id, status: .confirmedNotWritten("stale"))
        XCTAssertNil(model.receipt(id: receipt.id))
        XCTAssertTrue(recorder.removed.isEmpty)
    }

    func testFailingCleanupModelKeepsItemWithoutSuccessfulRemoval() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let model = fixtureModel(topology: topology, store: CompanionInertSessionStore())
        let recorder = CompanionCleanupRecorder()
        recorder.delayNanoseconds = 180_000_000
        recorder.error = OfficialTerminalError.transport("cleanup-failed")
        model.attachmentCleanup = recorder
        let owner = try XCTUnwrap(model.recoveryOwner)
        model.preserveUninsertedUpload(
            Self.validAttachment, owner: owner, target: .agent(paneID: "pane-reviewer"), title: "Codex")
        _ = present(
            CompanionRootContent(model: model, displayHosts: [Self.studioMac])
                .frame(width: 400, height: 760))
        try await openRecoveryViaEntry(model)
        let id = try XCTUnwrap(model.recoverableReceipts.first?.id)
        let discard = Task { await model.discardAttachment(id: id) }
        try await waitUntil(stage: "cleanup-in-flight") { model.receipt(id: id)?.isCleanupInFlight == true }
        XCTAssertFalse(try XCTUnwrap(model.receipt(id: id)).allowsCleanup)
        model.forgetReceipt(try XCTUnwrap(model.receipt(id: id)))
        XCTAssertNotNil(model.receipt(id: id))
        let failed = await discard.value
        XCTAssertNotNil(failed)
        try await waitUntil(stage: "cleanup-failed-resolved") {
            model.receipt(id: id)?.phase == .resolved
        }
        XCTAssertEqual(model.receipt(id: id)?.id, id)
        XCTAssertTrue(try XCTUnwrap(model.receipt(id: id)).allowsCleanup)
        XCTAssertTrue(recorder.removed.isEmpty)
        XCTAssertEqual(retainedWindowCount(), 1)
    }

    func testMountedEditorMintsNewFlowAfterUnknownSubmitDiscardAndLaterTeardown() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        model.terminalOpener = { target, _, _, _, _ in
            let session = CompanionInertTerminalSession(target: target)
            session.failAcknowledgedUnknown = true
            await store.opened(session)
            return .success(session)
        }
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil { await store.sessions.last?.started == true }
        try await issueEditorCommand(.setText("first-unknown"), on: model)
        try await issueEditorCommand(.insert, on: model)
        try await waitUntil {
            model.recoverableReceipts.contains {
                if case .draft(let text) = $0.payload, text == "first-unknown" {
                    if case .acknowledgementUnknown = $0.status { return true }
                }
                return false
            }
        }
        let firstID = try XCTUnwrap(model.recoverableReceipts.first?.id)
        try await issueEditorCommand(.cancel, on: model)
        try await openRecoveryViaEntry(model)
        XCTAssertTrue(self.recoverySheetIsPresented())
        model.forgetReceipt(try XCTUnwrap(model.receipt(id: firstID)))
        try await waitUntil(stage: "draft-forgotten") { model.wasForgotten(firstID) }
        XCTAssertEqual(holder.destination?.target, destA.target)
        try await issueEditorCommand(.setText("second-composed"), on: model)
        try await issueEditorCommand(.insert, on: model)
        try await waitUntil {
            model.recoverableReceipts.contains {
                if case .draft(let text) = $0.payload, text == "second-composed" { return true }
                return false
            }
        }
        let secondID = try XCTUnwrap(
            model.recoverableReceipts.first { receipt in
                if case .draft(let text) = receipt.payload { return text == "second-composed" }
                return false
            }?.id)
        XCTAssertNotEqual(secondID, firstID)
        XCTAssertTrue(model.wasForgotten(firstID))
        holder.destination = nil
        try await waitUntil { model.receipt(id: secondID) != nil }
        XCTAssertNotNil(model.receipt(id: secondID))
        XCTAssertTrue(model.wasForgotten(firstID))
        if case .draft(let kept) = model.receipt(id: secondID)?.payload {
            XCTAssertEqual(kept, "second-composed")
        } else {
            XCTFail("second composed draft must survive later teardown")
        }
    }

    func testUnknownDraftForgetIsNotResurrectedOnTeardown() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        model.terminalOpener = { target, _, _, _, _ in
            let session = CompanionInertTerminalSession(target: target)
            session.failAcknowledgedUnknown = true
            await store.opened(session)
            return .success(session)
        }
        model.fixtureDraftText = "unknown-draft"
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil { await store.sessions.last?.started == true }
        try await waitUntil {
            model.recoverableReceipts.contains {
                if case .draft(let text) = $0.payload, text == "unknown-draft" {
                    if case .acknowledgementUnknown = $0.status { return true }
                }
                return false
            }
        }
        try await issueEditorCommand(.cancel, on: model)
        let flowID = try XCTUnwrap(model.recoverableReceipts.first?.id)
        XCTAssertEqual(model.recoverableReceipts.count, 1)
        try await openRecoveryViaEntry(model)
        XCTAssertEqual(retainedWindowCount(), 1)
        XCTAssertTrue(self.recoverySheetIsPresented())
        model.forgetReceipt(try XCTUnwrap(model.receipt(id: flowID)))
        try await waitUntil(stage: "draft-forgotten") { model.receipt(id: flowID) == nil && model.wasForgotten(flowID) }
        XCTAssertTrue(model.wasForgotten(flowID))
        XCTAssertEqual(holder.destination?.target, destA.target)
        holder.destination = nil
        try await waitUntil { model.recoverableReceipts.isEmpty }
        XCTAssertTrue(model.recoverableReceipts.isEmpty, "forgotten unknown draft must not resurrect as confirmed")
        XCTAssertTrue(model.wasForgotten(flowID))
    }

    func testSecondUnsentDraftSurvivesWhileFirstAwaits() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil { await store.sessions.last?.started == true }
        let openedA = await store.current()
        try XCTUnwrap(openedA).suspendAcknowledgement = true
        try XCTUnwrap(openedA).failAcknowledged = true
        try await issueEditorCommand(.setText("from-a"), on: model)
        try await issueEditorCommand(.insert, on: model)
        try await waitUntil {
            model.insertionReceipts.values.contains { receipt in
                if case .draft(let text) = receipt.payload, text == "from-a" {
                    return receipt.phase == .submitting
                }
                return false
            }
        }
        let firstID = try XCTUnwrap(
            model.insertionReceipts.values.first { receipt in
                if case .draft(let text) = receipt.payload { return text == "from-a" }
                return false
            }?.id)
        try await issueEditorCommand(.setText("from-b-unsent"), on: model)
        try await issueEditorCommand(.cancel, on: model)
        holder.destination = nil
        try await waitUntil {
            model.recoverableReceipts.contains {
                if case .draft(let text) = $0.payload { return text == "from-b-unsent" }
                return false
            }
        }
        try XCTUnwrap(openedA).finishAcknowledgement()
        try await waitUntil { model.receipt(id: firstID)?.phase == .resolved || model.receipt(id: firstID) == nil }
        let drafts = Set(model.recoverableReceipts.compactMap { receipt -> String? in
            if case .draft(let text) = receipt.payload { return text }
            return nil
        })
        XCTAssertTrue(drafts.contains("from-a"))
        XCTAssertTrue(drafts.contains("from-b-unsent"))
        XCTAssertNotNil(model.receipt(id: firstID))
        XCTAssertNotEqual(
            model.recoverableReceipts.first { receipt in
                if case .draft(let text) = receipt.payload { return text == "from-b-unsent" }
                return false
            }?.id,
            firstID)
    }

    func testDraftAndUploadAndIncompleteCleanupAllStayDistinct() throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let model = fixtureModel(topology: topology, store: CompanionInertSessionStore())
        let recorder = CompanionCleanupRecorder()
        model.attachmentCleanup = recorder
        let owner = try XCTUnwrap(model.recoveryOwner)
        let dest = OfficialTerminalAttachmentTarget.agent(paneID: "pane-reviewer")
        model.preserveUnsentDraft("draft-a", owner: owner, target: dest, title: "Codex", id: UUID())
        model.preserveUninsertedUpload(Self.validAttachment, owner: owner, target: dest, title: "Codex", id: UUID())
        model.preserveIncompleteCleanup(RemoteAttachmentCleanup.testingHandle(), owner: owner, target: dest, title: "Codex", id: UUID())
        XCTAssertEqual(model.recoverableReceipts.count, 3)
        XCTAssertEqual(Set(model.recoverableReceipts.map { payloadKind($0) }), ["draft", "uploaded", "incomplete"])
    }

    func testOriginalHostCleanupSucceedsAndChangedEndpointIsRefused() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let model = fixtureModel(topology: topology, store: CompanionInertSessionStore())
        let recorder = CompanionCleanupRecorder()
        model.attachmentCleanup = recorder
        let owner = try XCTUnwrap(model.recoveryOwner)
        model.preserveUninsertedUpload(
            Self.validAttachment, owner: owner, target: .agent(paneID: "pane-reviewer"), title: "Codex")
        let receipt = try XCTUnwrap(model.recoverableReceipts.first)
        let original = try XCTUnwrap(model.connectedSavedHost)
        let edited = SavedHost(
            id: original.id, host: "edited.example.ts.net", username: "fixture",
            nickname: "Example Mac", authKind: .key, session: "default")
        model.applyVisualFixture(label: "Example Mac", savedHost: edited, topology: topology)
        let refused = await model.retryDiscard(receipt)
        XCTAssertTrue(refused?.contains("Reconnect") == true)
        XCTAssertTrue(recorder.removed.isEmpty)
        XCTAssertEqual(model.recoverableReceipts.count, 1)
        model.applyVisualFixture(label: "Example Mac", savedHost: original, topology: topology)
        let ok = await model.retryDiscard(receipt)
        XCTAssertNil(ok)
        XCTAssertEqual(recorder.removed.count, 1)
        XCTAssertTrue(model.recoverableReceipts.isEmpty)
    }

    func testRecoveryCloseReopenUsesProductionControls() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let model = fixtureModel(topology: topology, store: CompanionInertSessionStore())
        let recorder = CompanionCleanupRecorder()
        model.attachmentCleanup = recorder
        let owner = try XCTUnwrap(model.recoveryOwner)
        model.preserveUnknownUpload(
            Self.validAttachment, owner: owner, target: .agent(paneID: "pane-reviewer"), title: "Codex")
        XCTAssertEqual(model.recoverableReceipts.count, 1)
        _ = present(
            CompanionRootContent(model: model, displayHosts: [Self.studioMac])
                .frame(width: 400, height: 760))
        try await openRecoveryViaEntry(model)
        XCTAssertEqual(retainedWindowCount(), 1)
        try await activateControl(
            identifier: "companion-recovery-close", label: "Close",
            presentedOnly: true, stage: "close-control-ready")
        try await waitUntil(stage: "close-dismissed") {
            model.isPresentingRecovery == false && !self.recoverySheetIsPresented()
        }
        XCTAssertEqual(model.recoverableReceipts.count, 1)
        try await openRecoveryViaEntry(model)
        XCTAssertTrue(self.recoverySheetIsPresented())
        XCTAssertEqual(retainedWindowCount(), 1)
    }

    func testAThenBKeepsBothReceipts() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let destB = try XCTUnwrap(CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-calendar" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        let holder = CompanionHostDestinationHolder()
        holder.destination = destA
        _ = present(CompanionHostBoundaryHarness(model: model, holder: holder))
        try await waitUntil { await store.sessions.last?.started == true }
        let idA = UUID()
        let idB = UUID()
        let openedA = await store.current()
        let sessionA = try XCTUnwrap(openedA)
        sessionA.acknowledgeDelayNanoseconds = 200_000_000
        sessionA.failAcknowledged = true
        let submitA = Task {
            await model.submitDraftUsingActiveController("from-a", target: destA.target, title: destA.title, id: idA)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        holder.destination = destB
        try await waitUntil { await store.sessions.count >= 2 }
        let openedB = await store.current()
        try XCTUnwrap(openedB).failAcknowledged = true
        _ = await model.submitDraftUsingActiveController("from-b", target: destB.target, title: destB.title, id: idB)
        await submitA.value
        let drafts = Set(model.recoverableReceipts.compactMap { receipt -> String? in
            if case .draft(let text) = receipt.payload { return text }
            return nil
        })
        XCTAssertTrue(drafts.contains("from-a"))
        XCTAssertTrue(drafts.contains("from-b"))
        XCTAssertNotNil(model.receipt(id: idA))
        XCTAssertNotNil(model.receipt(id: idB))
    }

    func testMiddleSearchBindingClearsHiddenAgent() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let model = fixtureModel(topology: topology, store: CompanionInertSessionStore())
        let holder = CompanionNavigationHolder()
        let reviewer = try XCTUnwrap(CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        holder.navigation.selectAgent(destination: reviewer)
        let host = present(CompanionMiddleSearchHarness(model: model, holder: holder))
        try await waitUntil { host.searchBar() != nil }
        let searchBar = try XCTUnwrap(host.searchBar(), "middle searchable must mount a search control")
        searchBar.text = "zzzz-no-match"
        searchBar.delegate?.searchBar?(searchBar, textDidChange: "zzzz-no-match")
        host.view.layoutIfNeeded()
        try await waitUntil { holder.navigation.openedTerminal == nil }
        XCTAssertNil(holder.navigation.openedTerminal)
    }

    func testLiveStatusPublicationClearsHiddenAttentionTarget() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let model = fixtureModel(topology: topology, store: CompanionInertSessionStore())
        let holder = CompanionNavigationHolder()
        let reviewer = try XCTUnwrap(CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        holder.navigation.selectAgent(destination: reviewer)
        XCTAssertEqual(holder.navigation.scope, .attention)
        XCTAssertEqual(holder.navigation.openedTerminal?.pane.paneID, "pane-reviewer")
        _ = present(CompanionSplitBoundaryHarness(model: model, holder: holder))
        let working = try CompanionOverviewTests.loadTopology(reviewerWorking: true)
        model.applyVisualFixture(
            label: "Example Mac",
            savedHost: SavedHost(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                host: "mac.example.ts.net", username: "fixture",
                nickname: "Example Mac", authKind: .key, session: "default"),
            topology: working)
        try await waitUntil { holder.navigation.openedTerminal == nil }
        XCTAssertNil(holder.navigation.openedTerminal)
    }

    func testReplacedShellAndTypeChangeClearDestination() throws {
        let topology = try CompanionOverviewTests.loadTopology()
        var navigation = CompanionSplitNavigationState()
        let shell = try XCTUnwrap(CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-shell" })))
        navigation.selectWorkspace("workspace-app")
        navigation.openedTerminal = shell
        let replaced = try CompanionOverviewTests.loadTopology(replacedShell: true)
        navigation.reconcile(topology: replaced, agents: replaced.agents, isConnected: true, isConnecting: false)
        XCTAssertNil(navigation.openedTerminal)
        navigation.selectWorkspace("workspace-app")
        navigation.openedTerminal = shell
        let typed = try CompanionOverviewTests.loadTopology(shellBecameAgent: true)
        navigation.reconcile(topology: typed, agents: typed.agents, isConnected: true, isConnecting: false)
        XCTAssertNil(navigation.openedTerminal)
    }

    func testDisconnectKeepsOriginalOwnerOnReceipt() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let destA = try XCTUnwrap(CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let model = fixtureModel(topology: topology, store: CompanionInertSessionStore())
        let ownerID = try XCTUnwrap(model.recoveryOwner?.savedHostID)
        model.preserveUninsertedUpload(Self.validAttachment, owner: model.recoveryOwner, target: destA.target, title: destA.title)
        _ = present(
            CompanionRootContent(model: model, displayHosts: [Self.studioMac])
                .frame(width: 400, height: 760))
        await model.disconnect()
        let receipt = try XCTUnwrap(model.recoverableReceipts.first)
        XCTAssertEqual(receipt.owner.savedHostID, ownerID)
        XCTAssertEqual(receipt.owner.host, "mac.example.ts.net")
        XCTAssertFalse(model.isConnected)
        try await openRecoveryViaEntry(model)
        XCTAssertTrue(model.isPresentingRecovery)
        try await activateControl(
            identifier: "companion-recovery-close", label: "Close",
            presentedOnly: true, stage: "close-control-ready")
        try await waitUntil(stage: "close-dismissed") {
            model.isPresentingRecovery == false && !self.recoverySheetIsPresented()
        }
        XCTAssertEqual(model.recoverableReceipts.count, 1)
    }

    func testSplitSelectionIdentifiesWorkspaceAndClearsExcludedAgent() throws {
        let topology = try CompanionOverviewTests.loadTopology()
        var navigation = CompanionSplitNavigationState()
        navigation.selectWorkspace("workspace-app")
        XCTAssertEqual(navigation.scope, .workspaces)
        XCTAssertTrue(navigation.isSelectedWorkspace("workspace-app"))
        XCTAssertFalse(navigation.isSelectedWorkspace("workspace-docs"))

        let docs = try XCTUnwrap(topology.panes.first { $0.paneID == "pane-docs" })
        let destination = try XCTUnwrap(CompanionTerminalDestination(pane: docs))
        navigation.selectAgent(destination: destination)
        XCTAssertNil(navigation.selectedWorkspaceID)
        XCTAssertTrue(navigation.isSelectedDestination(destination))

        navigation.setScope(
            .running, agents: topology.agents, topology: topology,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-docs")

        let reviewer = try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })
        let needsYou = try XCTUnwrap(CompanionTerminalDestination(pane: reviewer))
        navigation.selectAgent(destination: needsYou)
        navigation.setScope(
            .running, agents: topology.agents, topology: topology,
            isConnected: true, isConnecting: false)
        XCTAssertNil(navigation.openedTerminal)

        navigation.selectWorkspace("workspace-app")
        let shell = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-shell" })))
        navigation.openedTerminal = shell
        navigation.reconcile(
            topology: topology, agents: topology.agents,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-shell")

        navigation.setSearch(
            "zzzz", agents: topology.agents, topology: topology,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-shell",
                       "workspace-pane shells stay while that workspace is the active context")

        navigation.setScope(
            .attention, agents: topology.agents, topology: topology,
            isConnected: true, isConnecting: false)
        XCTAssertNil(navigation.openedTerminal)
        XCTAssertNil(navigation.selectedWorkspaceID)
    }

    func testSplitBrowseKeepsTheSameInertSession() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let reviewer = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let mystery = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-mystery" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        let holder = CompanionNavigationHolder()
        holder.navigation.selectAgent(destination: reviewer)
        _ = present(
            CompanionSplitBoundaryHarness(model: model, holder: holder),
            size: CGSize(width: 1024, height: 768))
        try await waitUntil {
            let sessions = await store.sessions
            return sessions.count == 1 && sessions.last?.started == true && sessions.last?.closed == false
        }
        let opened = await store.current()
        let first = try XCTUnwrap(opened)
        XCTAssertEqual(first.target, reviewer.target)
        try await waitUntil(stage: "split-keeps-session-while-presented") {
            let sessions = await store.sessions
            return sessions.count == 1 && sessions[0] === first && first.started && !first.closed
        }
        holder.navigation.selectAgent(destination: mystery)
        try await waitUntil(stage: "split-switch-opens-new-session") {
            let sessions = await store.sessions
            return sessions.count >= 2 && first.closed && sessions.last?.started == true
                && sessions.last?.target == mystery.target
        }
    }

    func testSessionShellCompactResizeKeepsTheSameInertSessionOnIPad() async throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != .pad,
            "stable split across compact width is iPad-scoped")
        let topology = try CompanionOverviewTests.loadTopology()
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        model.fixtureOpenPaneID = "pane-reviewer"
        let adaptive = CompanionAdaptiveHolder()
        _ = present(
            CompanionSessionShellHarness(model: model, adaptive: adaptive),
            size: adaptive.size)
        try await waitUntil(stage: "adaptive-session-started") {
            let sessions = await store.sessions
            return sessions.count == 1 && sessions.last?.started == true && sessions.last?.closed == false
        }
        let openedAdaptive = await store.current()
        let first = try XCTUnwrap(openedAdaptive)
        // Size-class override only: a UIWindow frame rewrite in this harness remounts
        // the hosting controller. XCUI compact coverage uses the same DEBUG override
        // and is disclosed separately from a real window resize.
        adaptive.sizeClass = .compact
        try await waitUntil(stage: "adaptive-compact-keeps-session") {
            let sessions = await store.sessions
            return sessions.count == 1 && sessions[0] === first && first.started && !first.closed
        }
        XCTAssertEqual(first.target, .agent(paneID: "pane-reviewer"))
    }

    func testValidatedNotificationReplacesSelectionThroughSplitOwnership() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let reviewer = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let calendar = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-calendar" })))
        let mystery = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-mystery" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        let holder = CompanionNavigationHolder()
        _ = present(
            CompanionSplitBoundaryHarness(model: model, holder: holder),
            size: CGSize(width: 1024, height: 768))
        model.deliverValidatedNotificationDestination(reviewer)
        try await waitUntil(stage: "notify-cold-opens-reviewer") {
            let sessions = await store.sessions
            return holder.navigation.openedTerminal?.target == reviewer.target
                && sessions.count == 1 && sessions.last?.target == reviewer.target
                && sessions.last?.started == true
        }
        XCTAssertNil(model.notificationDestination)
        let openedNotify = await store.current()
        let first = try XCTUnwrap(openedNotify)
        model.deliverValidatedNotificationDestination(calendar)
        try await waitUntil(stage: "notify-over-a-opens-b") {
            let sessions = await store.sessions
            return holder.navigation.openedTerminal?.target == calendar.target
                && first.closed
                && sessions.last?.target == calendar.target
                && sessions.last?.started == true
                && sessions.last?.closed == false
        }
        XCTAssertNil(model.notificationDestination)
        holder.navigation.selectAgent(destination: mystery)
        try await waitUntil(stage: "manual-c-replaces-notification-b") {
            let sessions = await store.sessions
            let live = sessions.filter { $0.started && !$0.closed }
            return live.count == 1 && live[0].target == mystery.target
                && holder.navigation.openedTerminal?.target == mystery.target
        }
        XCTAssertNil(model.notificationDestination)
    }

    func testSplitOutOfFilterNotificationKeepsOneLiveSessionAfterReconcile() async throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom != .pad,
            "split out-of-filter notification is iPad-scoped")
        let topology = try CompanionOverviewTests.loadTopology()
        let calendar = try XCTUnwrap(
            CompanionTerminalDestination(
                pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-calendar" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        let holder = CompanionNavigationHolder()
        XCTAssertEqual(holder.navigation.scope, .attention)
        _ = present(
            CompanionSplitBoundaryHarness(model: model, holder: holder),
            size: CGSize(width: 1024, height: 768))
        XCTAssertEqual(holder.navigation.scope, .attention)
        model.deliverValidatedNotificationDestination(calendar)
        try await waitUntil(stage: "notify-out-of-filter-opens-calendar") {
            let sessions = await store.sessions
            return holder.navigation.openedTerminal?.target == calendar.target
                && holder.navigation.scope == .all
                && holder.navigation.search.isEmpty
                && holder.navigation.focusedTerminal
                && sessions.count == 1
                && sessions.last?.target == calendar.target
                && sessions.last?.started == true
                && sessions.last?.closed == false
        }
        let openedCalendar = await store.current()
        let first = try XCTUnwrap(openedCalendar)
        XCTAssertEqual(first.target, calendar.target)
        model.applyVisualFixture(
            label: "Example Mac",
            savedHost: Self.studioMac,
            topology: topology)
        try await waitUntil(stage: "notify-out-of-filter-survives-reconcile") {
            let live = (await store.sessions).filter { $0.started && !$0.closed }
            return live.count == 1
                && live[0] === first
                && holder.navigation.openedTerminal?.target == calendar.target
                && holder.navigation.focusedTerminal
        }
        XCTAssertNil(model.notificationDestination)
    }

    func testSplitSameTargetNotificationRefocusesWithoutReplacingSession() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let reviewer = try XCTUnwrap(
            CompanionTerminalDestination(
                pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        let holder = CompanionNavigationHolder()
        holder.navigation.selectAgent(destination: reviewer)
        _ = present(
            CompanionSplitBoundaryHarness(model: model, holder: holder),
            size: CGSize(width: 1024, height: 768))
        try await waitUntil(stage: "same-target-session-open") {
            let sessions = await store.sessions
            return sessions.count == 1 && sessions.last?.started == true && sessions.last?.closed == false
                && holder.navigation.openedTerminal?.target == reviewer.target
        }
        let openedReviewer = await store.current()
        let first = try XCTUnwrap(openedReviewer)
        holder.navigation.focusedTerminal = false
        try await waitUntil(stage: "same-target-browsing") {
            holder.navigation.focusedTerminal == false
                && holder.navigation.openedTerminal?.target == reviewer.target
        }
        model.deliverValidatedNotificationDestination(reviewer)
        try await waitUntil(stage: "same-target-notification-refocuses") {
            holder.navigation.focusedTerminal
                && holder.navigation.openedTerminal?.target == reviewer.target
                && holder.navigation.scope == .all
        }
        let live = (await store.sessions).filter { $0.started && !$0.closed }
        XCTAssertEqual(live.count, 1)
        XCTAssertTrue(live[0] === first)
        XCTAssertFalse(first.closed)
        XCTAssertNil(model.notificationDestination)
    }

    func testSessionShellCompactNotificationColdKeepsExactPaneAndOneSession() async throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "compact notification owner is phone-scoped")
        let topology = try CompanionOverviewTests.loadTopology()
        let reviewer = try XCTUnwrap(
            CompanionTerminalDestination(
                pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        let adaptive = CompanionAdaptiveHolder()
        adaptive.sizeClass = .compact
        adaptive.size = CGSize(width: 390, height: 844)
        _ = present(
            CompanionSessionShellHarness(model: model, adaptive: adaptive),
            size: adaptive.size)
        XCTAssertNil(model.notificationDestination)
        model.deliverValidatedNotificationDestination(reviewer)
        try await waitUntil(stage: "compact-cold-opens-reviewer") {
            let sessions = await store.sessions
            let live = sessions.filter { $0.started && !$0.closed }
            return live.count == 1
                && live[0].target == reviewer.target
                && model.notificationDestination?.pane.paneID == reviewer.pane.paneID
        }
        let opened = await store.current()
        let first = try XCTUnwrap(opened)
        model.applyVisualFixture(label: "Example Mac", savedHost: Self.studioMac, topology: topology)
        try await waitUntil(stage: "compact-cold-survives-publication") {
            let live = (await store.sessions).filter { $0.started && !$0.closed }
            return live.count == 1
                && live[0] === first
                && model.notificationDestination?.pane.paneID == reviewer.pane.paneID
        }
        XCTAssertEqual(model.notificationDestination?.target, reviewer.target)
    }

    func testSessionShellCompactInAppNotificationReplacesPaneThenDismissesAfterSuccess() async throws {
        try XCTSkipIf(
            UIDevice.current.userInterfaceIdiom == .pad,
            "compact notification owner is phone-scoped")
        let topology = try CompanionOverviewTests.loadTopology()
        let reviewer = try XCTUnwrap(
            CompanionTerminalDestination(
                pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        let calendar = try XCTUnwrap(
            CompanionTerminalDestination(
                pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-calendar" })))
        let store = CompanionInertSessionStore()
        let model = fixtureModel(topology: topology, store: store)
        let adaptive = CompanionAdaptiveHolder()
        adaptive.sizeClass = .compact
        adaptive.size = CGSize(width: 390, height: 844)
        _ = present(
            CompanionSessionShellHarness(model: model, adaptive: adaptive),
            size: adaptive.size)
        model.deliverValidatedNotificationDestination(reviewer)
        try await waitUntil(stage: "compact-in-app-reviewer") {
            let live = (await store.sessions).filter { $0.started && !$0.closed }
            return live.count == 1
                && live[0].target == reviewer.target
                && model.notificationDestination?.pane.paneID == reviewer.pane.paneID
        }
        let openedReviewer = await store.current()
        let first = try XCTUnwrap(openedReviewer)
        model.deliverValidatedNotificationDestination(calendar)
        try await waitUntil(stage: "compact-in-app-calendar-replaces") {
            let live = (await store.sessions).filter { $0.started && !$0.closed }
            return live.count == 1
                && live[0].target == calendar.target
                && first.closed
                && model.notificationDestination?.pane.paneID == calendar.pane.paneID
        }
        let openedCalendar = await store.current()
        let second = try XCTUnwrap(openedCalendar)
        model.dismissNotificationDestination()
        try await waitUntil(stage: "compact-dismiss-after-success") {
            model.notificationDestination == nil && second.closed
        }
        let live = (await store.sessions).filter { $0.started && !$0.closed }
        XCTAssertEqual(live.count, 0)
    }

    func testNewTabFormShowsWorkspaceAndFocusesCreatedPane() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let store = CompanionInertSessionStore()
        let model = mutationModel(topology: topology, store: store)
        let holder = CompanionNavigationHolder()
        holder.navigation.selectWorkspace("workspace-app")
        let shown = CompanionDestinationContext(
            location: CompanionTerminalLocation(
                mac: "Example Mac", session: "default",
                workspace: CompanionWorkspaceTitle.display(
                    workspaceID: "workspace-app", in: topology)),
            prefix: "Adds a tab in this workspace")
        _ = present(
            VStack {
                shown
                NewTerminalTabForm(
                    model: model, workspaceID: "workspace-app",
                    initialCWD: "/Users/fixture/companion"
                ) { destination in
                    holder.navigation.revealTerminal(destination, keepingWorkspace: true)
                }
            },
            size: CGSize(width: 390, height: 844))
        XCTAssertEqual(
            CompanionWorkspaceTitle.display(workspaceID: "workspace-app", in: topology),
            "Companion App")
        let created = await model.createTerminalTab(
            workspaceID: "workspace-app", label: nil, cwd: "/Users/fixture/companion")
        let destination = try XCTUnwrap(created)
        holder.navigation.revealTerminal(destination, keepingWorkspace: true)
        XCTAssertEqual(destination.pane.paneID, "pane-tab-created")
        XCTAssertEqual(destination.target, .terminal(terminalID: "term-tab-created"))
        XCTAssertTrue(holder.navigation.focusedTerminal)
        XCTAssertTrue(holder.navigation.isSelectedWorkspace("workspace-app"))
    }

    func testSplitFormShowsPaneAndFocusesCreatedPane() async throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let pane = try XCTUnwrap(topology.panes.first { $0.paneID == "pane-shell" })
        let store = CompanionInertSessionStore()
        let model = mutationModel(topology: topology, store: store)
        let holder = CompanionNavigationHolder()
        holder.navigation.selectWorkspace("workspace-app")
        let title = CompanionTerminalDestination(pane: pane)?.title ?? "Terminal"
        let shown = CompanionDestinationContext(
            location: CompanionTerminalLocation(
                mac: "Example Mac", session: "default",
                workspace: CompanionWorkspaceTitle.display(
                    workspaceID: pane.workspaceID, in: topology),
                terminal: title),
            prefix: "Splits this pane",
            detail: [pane.effectiveCWD, pane.paneID].compactMap { $0 }.joined(separator: " · "))
        _ = present(
            VStack {
                shown
                SplitPaneForm(model: model, pane: pane) { destination in
                    holder.navigation.revealTerminal(destination, keepingWorkspace: true)
                }
            },
            size: CGSize(width: 390, height: 844))
        XCTAssertEqual(title, "zsh")
        XCTAssertEqual(pane.paneID, "pane-shell")
        let created = await model.splitPane(
            workspaceID: pane.workspaceID, paneID: pane.paneID,
            cwd: pane.effectiveCWD, direction: .right)
        let destination = try XCTUnwrap(created)
        holder.navigation.revealTerminal(destination, keepingWorkspace: true)
        XCTAssertEqual(destination.pane.paneID, "pane-split-created")
        XCTAssertEqual(destination.target, .terminal(terminalID: "term-split-created"))
        XCTAssertTrue(holder.navigation.focusedTerminal)
        XCTAssertTrue(holder.navigation.isSelectedWorkspace("workspace-app"))
    }

    func testOutOfFilterNotificationSurvivesReconcileAndRefocuses() throws {
        let topology = try CompanionOverviewTests.loadTopology()
        var navigation = CompanionSplitNavigationState()
        let calendar = try XCTUnwrap(
            CompanionTerminalDestination(
                pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-calendar" })))
        navigation.scope = .attention
        navigation.search = "zzzz"
        navigation.openValidatedDestination(
            calendar, agents: topology.agents, topology: topology,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.scope, .all)
        XCTAssertEqual(navigation.search, "")
        XCTAssertTrue(navigation.focusedTerminal)
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-calendar")
        navigation.reconcile(
            topology: topology, agents: topology.agents,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-calendar")
        XCTAssertTrue(navigation.focusedTerminal)
    }

    func testSameTargetNotificationRefocusesWhileBrowsing() throws {
        let topology = try CompanionOverviewTests.loadTopology()
        var navigation = CompanionSplitNavigationState()
        let reviewer = try XCTUnwrap(
            CompanionTerminalDestination(
                pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })))
        navigation.selectAgent(destination: reviewer)
        navigation.focusedTerminal = false
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-reviewer")
        navigation.openValidatedDestination(
            reviewer, agents: topology.agents, topology: topology,
            isConnected: true, isConnecting: false)
        XCTAssertTrue(navigation.focusedTerminal)
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-reviewer")
        XCTAssertEqual(navigation.scope, .all)
    }

    func testMissingPaneIsStoppedAndNotALiveTarget() throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let snapshot = CompanionOverviewSnapshot(
            agents: topology.agents, topology: topology, scope: .idle,
            query: "", isConnected: true, isConnecting: false)
        let stopped = try XCTUnwrap(snapshot.matchedRows.first { $0.info.displayName == "idle-notes" })
        XCTAssertEqual(stopped.group, .stopped)
        XCTAssertFalse(stopped.isLive)
        XCTAssertEqual(
            CompanionAgentTargeting.resolve(row: stopped, topology: topology, canFallback: true),
            .stopped)
        XCTAssertEqual(
            CompanionAgentTargeting.resolve(row: stopped, topology: nil, canFallback: true),
            .fallbackAgent(paneID: "pane-missing"))
    }

    func testUnknownAgentIsAttentionWithItsOwnGroup() throws {
        let topology = try CompanionOverviewTests.loadTopology()
        let snapshot = CompanionOverviewSnapshot(
            agents: topology.agents, topology: topology, scope: .attention,
            query: "", isConnected: true, isConnecting: false)
        XCTAssertEqual(snapshot.attentionCount, 1)
        XCTAssertEqual(snapshot.unknownCount, 1)
        XCTAssertEqual(snapshot.attentionFilterCount, 2)
        XCTAssertEqual(Set(snapshot.matchedRows.map(\.info.displayName)), ["reviewer", "mystery-bot"])
        XCTAssertEqual(snapshot.sections.map(\.group), [.needsYou, .unrecognised])
        XCTAssertEqual(CompanionOverviewScope.attention.title, "Attention")
        XCTAssertEqual(CompanionOverviewScope.idle.title, "Inactive")
    }

    func testStatusAndChipTokensMeetContrast() {
        let pairs: [(UInt32, UInt32)] = [
            (Palette.Token.waitingLight, Palette.Token.cardLight),
            (Palette.Token.textFaintLight, Palette.Token.cardLight),
            (Palette.Token.textFaintDark, Palette.Token.cardDark),
            (Palette.Token.accentOnLight, Palette.Token.accentLight),
            (Palette.Token.accentOnDark, Palette.Token.accentDark),
            (Palette.Token.workingLight, Palette.Token.cardLight),
            (Palette.Token.doneLight, Palette.Token.cardLight),
            (Palette.Token.diedDark, Palette.Token.cardDark),
        ]
        for (foreground, background) in pairs {
            XCTAssertGreaterThanOrEqual(
                PaletteContrast.ratio(foreground, background), 4.5,
                String(format: "#%06X on #%06X", foreground, background))
        }
    }

    static let validAttachment = RemoteAttachment(
        path: "/Users/fixture/.herdr-companion-attachments-0123456789abcdef0123456789abcdef/attachment-11111111-1111-1111-1111-111111111111.png",
        byteCount: 4)

    static let studioMac = SavedHost(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        host: "mac.example.ts.net", username: "fixture",
        nickname: "Example Mac", authKind: .key, session: "default")

    private func payloadKind(_ receipt: CompanionInsertionReceipt) -> String {
        switch receipt.payload {
        case .pending: return "pending"
        case .draft: return "draft"
        case .uploaded: return "uploaded"
        case .incompleteCleanup: return "incomplete"
        }
    }

    private func fixtureModel(
        topology: SessionTopology, store: CompanionInertSessionStore
    ) -> CompanionConnectionModel {
        let model = CompanionConnectionModel(
            connectionFactory: { _ in
                CompanionConnectionModel.Connection(
                    transport: nil,
                    client: HerdrClient(transport: CorrectionSilentTransport()),
                    close: {})
            },
            savedCredentialsProvider: { saved in
                SSHCredentials(
                    host: saved.host, port: 22, username: saved.username,
                    password: "fixture", remoteSocketPath: "/tmp/herdr.sock",
                    herdrSession: saved.herdrSession)
            })
        model.terminalOpener = CompanionInertTerminal.opener(store: store)
        model.testActivateTerminalScene = true
        model.applyVisualFixture(
            label: "Example Mac",
            savedHost: SavedHost(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                host: "mac.example.ts.net", username: "fixture",
                nickname: "Example Mac", authKind: .key, session: "default"),
            topology: topology)
        return model
    }

    private func mutationModel(
        topology: SessionTopology, store: CompanionInertSessionStore
    ) -> CompanionConnectionModel {
        let transport = FixtureSilentTransport(snapshot: CompanionLaunchFixture.topologyJSON())
        let model = CompanionConnectionModel(
            connectionFactory: { _ in
                CompanionConnectionModel.Connection(
                    transport: nil,
                    client: HerdrClient(transport: transport),
                    close: {})
            },
            savedCredentialsProvider: { saved in
                SSHCredentials(
                    host: saved.host, port: 22, username: saved.username,
                    password: "fixture", remoteSocketPath: "/tmp/herdr.sock",
                    herdrSession: saved.herdrSession)
            })
        model.terminalOpener = CompanionInertTerminal.opener(store: store)
        model.testActivateTerminalScene = true
        model.applyVisualFixture(label: "Example Mac", savedHost: Self.studioMac, topology: topology)
        model.installFixtureConnection()
        return model
    }

    private struct MissingProductionControl: Error {}

    private func retainedWindowCount() -> Int {
        retainedWindow == nil ? 0 : 1
    }

    private func presentedController() -> UIViewController? {
        guard var current = retainedWindow?.rootViewController else { return nil }
        while let presented = current.presentedViewController {
            current = presented
        }
        return current === retainedWindow?.rootViewController ? nil : current
    }

    private func interactionHosts() -> [UIViewController] {
        var hosts: [UIViewController] = []
        if let presented = presentedController() { hosts.append(presented) }
        if let root = retainedWindow?.rootViewController { hosts.append(root) }
        return hosts
    }

    private func presentedViewContains(_ needle: String) -> Bool {
        guard let presented = presentedController() else { return false }
        var visited = Set<ObjectIdentifier>()
        return Self.walkAccessibility(presented.view, visited: &visited) { object in
            Self.objectIdentifier(object) == needle
                || Self.objectIdentifier(object).contains(needle)
                || Self.objectLabel(object) == needle
        }
    }

    private func treeTextContains(_ needle: String) -> Bool {
        for host in interactionHosts() {
            host.view.layoutIfNeeded()
            for view in Self.allViews(host.view) {
                let bits = [
                    (view as? UILabel)?.text,
                    view.accessibilityIdentifier,
                    view.accessibilityLabel,
                    (view as? UIButton)?.currentTitle
                ]
                if bits.contains(where: { ($0 ?? "").contains(needle) }) { return true }
            }
        }
        return false
    }

    private func treeContains(_ needle: String) -> Bool {
        for host in interactionHosts() {
            host.view.layoutIfNeeded()
            var visited = Set<ObjectIdentifier>()
            if Self.walkAccessibility(host.view, visited: &visited, body: { object in
                let id = Self.objectIdentifier(object)
                let label = Self.objectLabel(object)
                return id == needle || id.contains(needle)
                    || label == needle || label.contains(needle)
            }) {
                return true
            }
        }
        return false
    }

    private func recoverySheetIsPresented() -> Bool {
        guard let presented = presentedController() else { return false }
        presented.view.layoutIfNeeded()
        var visited = Set<ObjectIdentifier>()
        return Self.walkAccessibility(presented.view, visited: &visited) { object in
            Self.objectIdentifier(object) == "companion-recovery-sheet"
        }
    }

    private func controlExists(identifier: String, label: String, presentedOnly: Bool = false) -> Bool {
        resolveActionObject(identifier: identifier, label: label, presentedOnly: presentedOnly) != nil
    }

    private static func objectIdentifier(_ object: NSObject) -> String {
        if let view = object as? UIView, let id = view.accessibilityIdentifier, !id.isEmpty {
            return id
        }
        if let id = object.value(forKey: "accessibilityIdentifier") as? String, !id.isEmpty {
            return id
        }
        return ""
    }

    private static func objectLabel(_ object: NSObject) -> String {
        if let view = object as? UIView, let label = view.accessibilityLabel, !label.isEmpty {
            return label
        }
        if let text = (object as? UILabel)?.text, !text.isEmpty { return text }
        if let label = object.value(forKey: "accessibilityLabel") as? String, !label.isEmpty {
            return label
        }
        return ""
    }

    private static func matchesControl(
        _ object: NSObject, identifier: String, label: String
    ) -> Bool {
        let id = objectIdentifier(object)
        let acc = objectLabel(object)
        if !identifier.isEmpty, id == identifier { return true }
        if !label.isEmpty, acc == label { return true }
        if let button = object as? UIButton, button.currentTitle == label { return true }
        return false
    }

    @discardableResult
    private static func walkAccessibility(
        _ object: NSObject,
        visited: inout Set<ObjectIdentifier>,
        body: (NSObject) -> Bool
    ) -> Bool {
        let token = ObjectIdentifier(object)
        if visited.contains(token) { return false }
        visited.insert(token)
        if body(object) { return true }
        if object.responds(to: NSSelectorFromString("accessibilityElements")),
           let elements = object.value(forKey: "accessibilityElements") as? [Any] {
            for element in elements {
                if let node = element as? NSObject,
                   walkAccessibility(node, visited: &visited, body: body) {
                    return true
                }
            }
        }
        if let view = object as? UIView {
            for sub in view.subviews {
                if walkAccessibility(sub, visited: &visited, body: body) { return true }
            }
        }
        return false
    }

    private func resolveActionObject(
        identifier: String, label: String, presentedOnly: Bool = false
    ) -> NSObject? {
        let hosts: [UIViewController]
        if presentedOnly {
            guard let presented = presentedController() else { return nil }
            hosts = [presented]
        } else {
            hosts = interactionHosts()
        }
        var preferred: NSObject?
        var fallback: NSObject?
        var visited = Set<ObjectIdentifier>()
        for host in hosts {
            host.view.layoutIfNeeded()
            _ = Self.walkAccessibility(host.view, visited: &visited) { object in
                guard Self.matchesControl(object, identifier: identifier, label: label) else {
                    return false
                }
                if object.isAccessibilityElement {
                    preferred = object
                    return true
                }
                if fallback == nil { fallback = object }
                return false
            }
            if let preferred { return preferred }
        }
        return fallback
    }

    private func activateOnce(
        identifier: String, label: String, presentedOnly: Bool = false
    ) throws {
        guard let object = resolveActionObject(
            identifier: identifier, label: label, presentedOnly: presentedOnly
        ) else {
            dumpIdentifierTree(stage: "missing-\(identifier)")
            XCTFail("missing production control \(identifier) (\(label)); model was not mutated")
            throw MissingProductionControl()
        }
        // One accessibility activation API, once. A false return is not retried
        // with the same selector. This is accessibilityActivate, not VoiceOver.
        if let view = object as? UIView {
            _ = view.accessibilityActivate()
            return
        }
        let selector = NSSelectorFromString("accessibilityActivate")
        if object.responds(to: selector) {
            _ = object.perform(selector)
            return
        }
        dumpIdentifierTree(stage: "unactivatable-\(identifier)")
        XCTFail("missing production control \(identifier) (\(label)); model was not mutated")
        throw MissingProductionControl()
    }

    private func dumpIdentifierTree(stage: String) {
        var lines: [String] = ["stage=\(stage)"]
        lines.append("windowScene=\(retainedWindow?.windowScene != nil)")
        lines.append("connectedScenes=\(UIApplication.shared.connectedScenes.count)")
        if let presented = presentedController() {
            lines.append("presented=\(type(of: presented))")
        } else {
            lines.append("presented=nil")
        }
        for host in interactionHosts() {
            host.view.layoutIfNeeded()
            lines.append("host=\(type(of: host)) views=\(Self.allViews(host.view).count)")
            for view in Self.allViews(host.view) {
                let id = view.accessibilityIdentifier ?? ""
                let acc = view.accessibilityLabel ?? ""
                let title = (view as? UIButton)?.currentTitle ?? ""
                let text = (view as? UILabel)?.text ?? ""
                if !id.isEmpty || !title.isEmpty || !text.isEmpty || view is UIButton || view is UIControl {
                    lines.append("view \(type(of: view)) id=\(id) acc=\(acc) title=\(title) text=\(text) frame=\(view.frame)")
                }
            }
            var visited = Set<ObjectIdentifier>()
            _ = Self.walkAccessibility(host.view, visited: &visited) { object in
                let id = Self.objectIdentifier(object)
                let acc = Self.objectLabel(object)
                if !id.isEmpty || !acc.isEmpty {
                    lines.append("ax \(type(of: object)) id=\(id) acc=\(acc) ax=\(object.isAccessibilityElement)")
                }
                return false
            }
        }
        let blob = lines.joined(separator: "\n")
        print(blob)
        let fileStage = stage.replacingOccurrences(of: "/", with: "-")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdr-companion-unit-evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? blob.write(
            to: directory.appendingPathComponent("c7-\(fileStage).txt"),
            atomically: true,
            encoding: .utf8)
    }

    private func openRecoveryViaEntry(_ model: CompanionConnectionModel) async throws {
        XCTAssertFalse(model.isPresentingRecovery)
        XCTAssertFalse(recoverySheetIsPresented())
        XCTAssertFalse(model.recoverableReceipts.isEmpty, "production entry requires a kept item")
        try await waitUntil(stage: "recovery-entry-control") {
            self.controlExists(
                identifier: "companion-recovery-entry",
                label: "1 item kept from Example Mac. Review")
        }
        try activateOnce(
            identifier: "companion-recovery-entry",
            label: "1 item kept from Example Mac. Review")
        try await waitUntil(stage: "recovery-sheet-presented") {
            model.isPresentingRecovery && self.recoverySheetIsPresented()
        }
        XCTAssertEqual(retainedWindowCount(), 1)
    }

    private func activateControl(
        identifier: String, label: String, presentedOnly: Bool = false, stage: String? = nil
    ) async throws {
        let waitStage = stage ?? "control-\(identifier)"
        try await waitUntil(stage: waitStage) {
            self.controlExists(identifier: identifier, label: label, presentedOnly: presentedOnly)
        }
        try activateOnce(identifier: identifier, label: label, presentedOnly: presentedOnly)
    }

    private func issueEditorCommand(
        _ command: CompanionDraftEditorCommand,
        on model: CompanionConnectionModel
    ) async throws {
        model.issueFixtureEditorCommand(command)
        try await waitUntil(stage: "editor-command-consumed") { model.fixtureEditorCommand == nil }
    }

    private static func allViews(_ root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { allViews($0) }
    }

    private func present<V: View>(
        _ view: V, size: CGSize = CGSize(width: 400, height: 844)
    ) -> UIHostingController<V> {
        if let existing = retainedWindow {
            XCTFail("must retain one production root/window")
            existing.makeKeyAndVisible()
            if let host = existing.rootViewController as? UIHostingController<V> {
                return host
            }
        }
        let host = UIHostingController(rootView: view)
        host.additionalSafeAreaInsets = UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
        } else {
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
        }
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        retainedWindow = window
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host
    }

    private func waitUntil(
        stage: String = "production terminal boundary",
        timeout: TimeInterval = 6,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            retainedWindow?.makeKeyAndVisible()
            retainedWindow?.rootViewController?.view.layoutIfNeeded()
            presentedController()?.view.layoutIfNeeded()
            if await condition() { return }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        dumpIdentifierTree(stage: stage)
        XCTFail("timed out waiting for \(stage)")
        throw MissingProductionControl()
    }

    private func entryControlHeight() -> CGFloat? {
        guard let root = retainedWindow?.rootViewController?.view else { return nil }
        var best: CGFloat = 0
        for view in Self.allViews(root) {
            if view.accessibilityIdentifier == "companion-recovery-entry" {
                best = max(best, max(view.bounds.height, view.frame.height))
            }
            if let label = view as? UILabel,
               label.text?.localizedCaseInsensitiveContains("kept") == true {
                var current: UIView? = label
                while let node = current {
                    best = max(best, max(node.bounds.height, node.frame.height))
                    current = node.superview
                    if node.accessibilityIdentifier == "companion-recovery-entry" { break }
                }
            }
        }
        return best > 0 ? best : nil
    }

    private func terminalView() -> CompanionInteractiveTerminalView {
        CompanionInteractiveTerminalView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600),
            font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
    }

    private func connectedController(
        bracketed: Bool
    ) async throws -> (
        controller: CompanionTerminalController,
        view: CompanionInteractiveTerminalView,
        session: CompanionInertTerminalSession,
        identity: UUID
    ) {
        let view = terminalView()
        if bracketed { view.feed(text: "\u{1b}[?2004h") }
        let session = CompanionInertTerminalSession(target: .agent(paneID: "pane-a"))
        let controller = CompanionTerminalController()
        let identity = controller.targetIdentity
        controller.adopt(view: view, identity: identity)
        XCTAssertTrue(controller.adopt(session, identity: identity))
        controller.receivedOutput(identity: identity)
        return (controller, view, session, identity)
    }
}

private extension UIView {
    func activateAccessibilityIdentifier(_ identifier: String) -> Bool {
        if accessibilityIdentifier == identifier {
            if accessibilityActivate() { return true }
            if let control = self as? UIControl {
                control.sendActions(for: .touchUpInside)
                return true
            }
        }
        if let elements = accessibilityElements {
            for element in elements {
                if let view = element as? UIView, view.activateAccessibilityIdentifier(identifier) {
                    return true
                }
                if let object = element as? NSObject,
                   (object.value(forKey: "accessibilityIdentifier") as? String) == identifier {
                    if object.responds(to: NSSelectorFromString("accessibilityActivate")) {
                        _ = object.perform(NSSelectorFromString("accessibilityActivate"))
                        return true
                    }
                }
            }
        }
        for subview in subviews where subview.activateAccessibilityIdentifier(identifier) {
            return true
        }
        return false
    }

    func accessibilityTreeContains(_ needle: String) -> Bool {
        if accessibilityLabel?.contains(needle) == true
            || accessibilityIdentifier?.contains(needle) == true
            || accessibilityValue?.contains(needle) == true {
            return true
        }
        if let label = self as? UILabel, label.text?.contains(needle) == true {
            return true
        }
        if let elements = accessibilityElements {
            for element in elements {
                if let view = element as? UIView, view.accessibilityTreeContains(needle) {
                    return true
                }
                if let object = element as? NSObject {
                    let values = [
                        object.value(forKey: "accessibilityLabel") as? String,
                        object.value(forKey: "accessibilityIdentifier") as? String,
                        object.value(forKey: "accessibilityValue") as? String
                    ]
                    if values.contains(where: { $0?.contains(needle) == true }) { return true }
                }
            }
        }
        return subviews.contains { $0.accessibilityTreeContains(needle) }
    }
}

private extension UIView {
    func searchBarInHierarchy() -> UISearchBar? {
        if let bar = self as? UISearchBar { return bar }
        for subview in subviews {
            if let bar = subview.searchBarInHierarchy() { return bar }
        }
        return nil
    }
}

private extension UIViewController {
    func tapIdentifier(_ identifier: String) -> Bool {
        if view.activateAccessibilityIdentifier(identifier) { return true }
        if let presented = presentedViewController, presented.tapIdentifier(identifier) {
            return true
        }
        return children.contains { $0.tapIdentifier(identifier) }
    }

    func searchBar() -> UISearchBar? {
        if let bar = navigationItem.searchController?.searchBar { return bar }
        if let bar = view.searchBarInHierarchy() { return bar }
        for child in children {
            if let bar = child.searchBar() { return bar }
        }
        if let presented = presentedViewController, let bar = presented.searchBar() { return bar }
        if let nav = self as? UINavigationController {
            return nav.visibleViewController?.searchBar()
        }
        return nil
    }
}

private struct CorrectionSilentTransport: HerdrTransport {
    func roundTrip(_ requestLine: String) async throws -> String {
        #"{"id":"fixture","result":{"type":"session_snapshot","snapshot":{"version":"0.9.0","protocol":22,"workspaces":[],"tabs":[],"panes":[],"agents":[]}}}"#
    }
    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

extension CompanionOverviewTests {
    static func loadTopology(
        agents: Bool = true, workspaces: Bool = true,
        reviewerWorking: Bool = false, replacedShell: Bool = false, shellBecameAgent: Bool = false
    ) throws -> SessionTopology {
        try CompanionOverviewTests.topology(
            agents: agents, workspaces: workspaces,
            reviewerWorking: reviewerWorking, replacedShell: replacedShell, shellBecameAgent: shellBecameAgent)
    }
}
