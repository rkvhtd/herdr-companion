import SwiftUI
import UIKit
import HerdrKit

#if DEBUG
/// Deterministic screenshot-only entry point. Uses the real production views with
/// synthetic, non-sensitive data. It does not open SSH, call APNs, or read saved hosts.
struct CompanionLaunchFixture: View {
    enum Mode: String {
        case connect
        case connectEmpty = "connect-empty"
        case overview
        case workspaces
        case workspace
        case form
        case terminal
        case empty
        case error
        case attachment
        case draft
        case largeText = "large-text"
        case notifications
        case notificationsDenied = "notifications-denied"
        case recovery
        case recoveryDisconnected = "recovery-disconnected"
        case recoveryLong = "recovery-long"
        case interactionRecovery = "interaction-recovery"
        case interactionCancel = "interaction-cancel"
        case interactionCancelCleanup = "interaction-cancel-cleanup"
        case interactionTerminal = "interaction-terminal"
        case interactionDiscardDraft = "interaction-discard-draft"
        case interactionRetryFail = "interaction-retry-fail"
        case interactionUnknownLeave = "interaction-unknown-leave"
        case interactionCollision = "interaction-collision"
    }

    static var requested: Mode? {
        guard let argument = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--companion-visual-fixture=")
        }) else { return nil }
        return Mode(rawValue: String(argument.dropFirst("--companion-visual-fixture=".count)))
    }

    let mode: Mode
    @StateObject private var model: CompanionConnectionModel

    init(mode: Mode) {
        self.mode = mode
        let store = CompanionInertSessionStore()
        let mirror = CompanionFixtureSessionMirror()
        let snapshotJSON = mode == .interactionCollision
            ? Self.collisionTopologyJSON() : Self.topologyJSON()
        let model = CompanionConnectionModel(
            connectionFactory: { _ in
                CompanionConnectionModel.Connection(
                    transport: nil,
                    client: HerdrClient(transport: FixtureSilentTransport(snapshot: snapshotJSON)),
                    close: {})
            },
            savedCredentialsProvider: { saved in
                SSHCredentials(
                    host: saved.host, port: 22, username: saved.username,
                    password: "fixture", remoteSocketPath: "/tmp/herdr.sock",
                    herdrSession: saved.herdrSession)
            })
        model.fixtureSessionMirror = mirror
        model.terminalOpener = { target, _, _, _, _ in
            let session = CompanionInertTerminalSession(target: target)
            let identity = session.identity
            session.onLifecycleChange = { event in
                mirror.note(identity, event)
            }
            mirror.registerPending(identity, target: session.target)
            await store.opened(session)
            return .success(session)
        }
        switch mode {
        case .connect, .connectEmpty, .notifications, .notificationsDenied, .recoveryDisconnected,
             .interactionRecovery, .interactionDiscardDraft, .interactionRetryFail, .interactionUnknownLeave:
            break
        case .interactionCollision:
            model.applyVisualFixture(
                label: "Example Mac",
                savedHost: Self.hosts[0],
                topology: Self.collisionTopology())
        case .empty:
            model.applyVisualFixture(
                label: "Example Mac",
                savedHost: Self.hosts[0],
                topology: Self.topology(agents: false, workspaces: false))
        case .error:
            model.applyVisualFixture(
                label: "Example Mac",
                savedHost: Self.hosts[0],
                topology: Self.topology(),
                message: "Live updates paused. Reconnecting…")
        default:
            model.applyVisualFixture(
                label: "Example Mac",
                savedHost: Self.hosts[0],
                topology: Self.topology())
        }
        switch mode {
        case .workspaces:
            model.fixtureScope = .workspaces
        case .workspace:
            model.fixtureWorkspaceID = "workspace-app"
        case .terminal:
            model.fixtureOpenPaneID = "pane-reviewer"
            model.fixtureShowKeys = true
        case .draft:
            model.fixtureOpenPaneID = "pane-reviewer"
            model.fixtureShowDraft = true
        case .attachment:
            model.fixtureOpenPaneID = "pane-reviewer"
            model.fixtureShowAttachment = true
        case .recovery:
            model.seedRecoveryFixture(host: Self.hosts[0], longDraft: false, present: true)
        case .recoveryLong:
            model.seedRecoveryFixture(host: Self.hosts[0], longDraft: true, present: true)
        case .recoveryDisconnected:
            model.attachmentCleanup = CompanionCleanupRecorder()
            model.seedRecoveryFixture(host: Self.hosts[0], longDraft: false, present: false)
        case .interactionRecovery:
            model.attachmentCleanup = CompanionCleanupRecorder()
            Self.seedKeptDraft(model)
            Self.seedKeptUpload(model)
        case .interactionDiscardDraft:
            Self.seedKeptDraft(model)
        case .interactionRetryFail:
            let recorder = CompanionCleanupRecorder()
            recorder.error = OfficialTerminalError.transport("cleanup-failed")
            model.attachmentCleanup = recorder
            Self.seedKeptUpload(model)
        case .interactionUnknownLeave:
            model.attachmentCleanup = CompanionCleanupRecorder()
            Self.seedUnknownUpload(model)
        case .interactionCancel:
            let uploader = CompanionUploadRecorder(result: .success(
                RemoteAttachment(
                    path: "/Users/fixture/.herdr-companion-attachments-0123456789abcdef0123456789abcdef/attachment-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.png",
                    byteCount: 4)))
            uploader.suspendUntilReleased = true
            model.attachmentUpload = uploader
            model.fixtureOpenPaneID = "pane-reviewer"
            model.fixtureShowAttachment = true
            model.fixtureBeginUpload = true
            model.testActivateTerminalScene = false
        case .interactionCancelCleanup:
            let uploader = CompanionUploadRecorder(result: .failure(
                RemoteAttachmentError.cleanupRequired(RemoteAttachmentCleanup.testingHandle(), "interrupted")))
            uploader.suspendUntilReleased = true
            uploader.cancellationError = RemoteAttachmentError.cleanupRequired(
                RemoteAttachmentCleanup.testingHandle(), "interrupted")
            model.attachmentCleanup = CompanionCleanupRecorder()
            model.attachmentUpload = uploader
            model.fixtureOpenPaneID = "pane-reviewer"
            model.fixtureShowAttachment = true
            model.fixtureBeginUpload = true
            model.testActivateTerminalScene = false
        case .interactionTerminal:
            model.fixtureOpenPaneID = "pane-reviewer"
            model.testActivateTerminalScene = false
        default:
            break
        }
        model.installFixtureConnection()
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        Group {
            switch mode {
            case .connect:
                NavigationStack {
                    CompanionConnectView(
                        model: model,
                        displayHosts: Self.hosts)
                }
            case .connectEmpty:
                NavigationStack { CompanionConnectView(model: model, displayHosts: []) }
            case .recoveryDisconnected:
                NavigationStack { CompanionConnectView(model: model, displayHosts: Self.hosts) }
            case .interactionRecovery, .interactionCancel, .interactionCancelCleanup, .interactionTerminal,
                 .interactionDiscardDraft, .interactionRetryFail, .interactionUnknownLeave,
                 .interactionCollision:
                CompanionRootContent(model: model, displayHosts: Self.hosts)
            case .form:
                NewWorkspaceForm(
                    model: model,
                    initialCWD: "/Users/fixture/companion",
                    onCreated: { _ in })
            case .notifications:
                CompanionNotificationVisualFixture(mode: .enabled)
            case .notificationsDenied:
                CompanionNotificationVisualFixture(mode: .permissionDenied)
            default:
                CompanionSessionShell(model: model)
            }
        }
        .tint(Palette.accent)
        .modifier(CompanionFixtureRecovery(mode: mode, model: model))
        .overlay(alignment: .bottom) {
            if Self.interactionModes.contains(mode) || mode == .workspace || mode == .workspaces {
                CompanionFixtureStatusOverlay(model: model)
            }
        }
        .overlay(alignment: .topTrailing) {
            if Self.interactionModes.contains(mode) {
                CompanionFixtureActionOverlay(model: model)
            }
        }
        .modifier(CompanionFixtureDynamicType(mode: mode))
    }

    fileprivate static let interactionModes: Set<Mode> = [
        .interactionRecovery, .interactionCancel, .interactionCancelCleanup, .interactionTerminal,
        .interactionDiscardDraft, .interactionRetryFail, .interactionUnknownLeave, .interactionCollision
    ]

    static let draftID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    static let uploadID = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    static let unknownID = UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!

    private static func seedKeptDraft(_ model: CompanionConnectionModel) {
        let owner = CompanionInsertionOwner(hosts[0])
        model.preserveUnsentDraft(
            "echo kept-draft", owner: owner, target: .agent(paneID: "pane-reviewer"),
            title: "Codex", id: draftID)
    }

    private static func seedKeptUpload(_ model: CompanionConnectionModel) {
        let owner = CompanionInsertionOwner(hosts[0])
        model.preserveUninsertedUpload(
            RemoteAttachment(
                path: "/Users/fixture/.herdr-companion-attachments-0123456789abcdef0123456789abcdef/attachment-11111111-1111-1111-1111-111111111111.png",
                byteCount: 4),
            owner: owner, target: .agent(paneID: "pane-reviewer"), title: "Codex", id: uploadID)
    }

    private static func seedUnknownUpload(_ model: CompanionConnectionModel) {
        let owner = CompanionInsertionOwner(hosts[0])
        model.preserveUnknownUpload(
            RemoteAttachment(
                path: "/Users/fixture/.herdr-companion-attachments-0123456789abcdef0123456789abcdef/attachment-11111111-1111-1111-1111-111111111111.png",
                byteCount: 4),
            owner: owner, target: .agent(paneID: "pane-reviewer"), title: "Codex", id: unknownID)
    }

    private static let hosts: [SavedHost] = [
        SavedHost(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            host: "mac.example.ts.net", username: "fixture",
            nickname: "Example Mac", authKind: .key, session: "default"),
        SavedHost(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            host: "mac.example.nord", username: "fixture",
            nickname: "Example VPN", authKind: .password, session: "default"),
    ]

    private static func topology(agents: Bool = true, workspaces: Bool = true) -> SessionTopology {
        try! JSONDecoder().decode(SessionTopology.self, from: Data(topologyJSON(agents: agents, workspaces: workspaces).utf8))
    }

    private static func collisionTopology() -> SessionTopology {
        try! JSONDecoder().decode(SessionTopology.self, from: Data(collisionTopologyJSON().utf8))
    }

    /// Wide-glyph titles that differ at character ten, distinct parent paths,
    /// shared workspace/leaf/status. Used only by the bounded collision fixture.
    static func collisionTopologyJSON() -> String {
        return #"{"version":"0.9.0","protocol":22,"focused_workspace_id":"workspace-app","focused_tab_id":"tab-app","focused_pane_id":"pane-wide-a","workspaces":[{"workspace_id":"workspace-app","number":1,"label":"Companion App","focused":true,"pane_count":6,"tab_count":1,"active_tab_id":"tab-app","agent_status":"blocked"}],"tabs":[{"tab_id":"tab-app","workspace_id":"workspace-app","number":1,"label":"review","focused":true,"pane_count":6,"agent_status":"blocked"}],"panes":[{"pane_id":"pane-wide-a","terminal_id":"term-wide-a","workspace_id":"workspace-app","tab_id":"tab-app","focused":true,"cwd":"/proj/a/src","foreground_cwd":"/proj/a/src","label":"WWWWWWWWWA terminal","agent":"codex","display_agent":"Codex","agent_status":"blocked","revision":1},{"pane_id":"pane-wide-b","terminal_id":"term-wide-b","workspace_id":"workspace-app","tab_id":"tab-app","focused":false,"cwd":"/proj/b/src","foreground_cwd":"/proj/b/src","label":"WWWWWWWWWB terminal","agent":"codex","display_agent":"Codex","agent_status":"blocked","revision":1},{"pane_id":"pane-long-parent-a","terminal_id":"term-long-parent-a","workspace_id":"workspace-app","tab_id":"tab-app","focused":false,"cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA/src","foreground_cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA/src","label":"long-parent","agent":"codex","display_agent":"Codex","agent_status":"blocked","revision":1},{"pane_id":"pane-long-parent-b","terminal_id":"term-long-parent-b","workspace_id":"workspace-app","tab_id":"tab-app","focused":false,"cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaB/src","foreground_cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaB/src","label":"long-parent","agent":"codex","display_agent":"Codex","agent_status":"blocked","revision":1},{"pane_id":"pane-long-leaf-a","terminal_id":"term-long-leaf-a","workspace_id":"workspace-app","tab_id":"tab-app","focused":false,"cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA","foreground_cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA","label":"long-leaf","agent":"codex","display_agent":"Codex","agent_status":"blocked","revision":1},{"pane_id":"pane-long-leaf-b","terminal_id":"term-long-leaf-b","workspace_id":"workspace-app","tab_id":"tab-app","focused":false,"cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaB","foreground_cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaB","label":"long-leaf","agent":"codex","display_agent":"Codex","agent_status":"blocked","revision":1}],"agents":[{"terminal_id":"term-wide-a","name":"WWWWWWWWWA terminal","agent":"codex","agent_status":"blocked","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-wide-a","cwd":"/proj/a/src","interactive_ready":true,"revision":1},{"terminal_id":"term-wide-b","name":"WWWWWWWWWB terminal","agent":"codex","agent_status":"blocked","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-wide-b","cwd":"/proj/b/src","interactive_ready":true,"revision":1},{"terminal_id":"term-long-parent-a","name":"long-parent","agent":"codex","agent_status":"blocked","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-long-parent-a","cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA/src","interactive_ready":true,"revision":1},{"terminal_id":"term-long-parent-b","name":"long-parent","agent":"codex","agent_status":"blocked","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-long-parent-b","cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaB/src","interactive_ready":true,"revision":1},{"terminal_id":"term-long-leaf-a","name":"long-leaf","agent":"codex","agent_status":"blocked","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-long-leaf-a","cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaA","interactive_ready":true,"revision":1},{"terminal_id":"term-long-leaf-b","name":"long-leaf","agent":"codex","agent_status":"blocked","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-long-leaf-b","cwd":"/proj/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaB","interactive_ready":true,"revision":1}],"layouts":[]}"#
    }

    static func topologyJSON(agents: Bool = true, workspaces: Bool = true) -> String {
        if !workspaces {
            return #"{"version":"0.9.0","protocol":22,"workspaces":[],"tabs":[],"panes":[],"agents":[],"layouts":[]}"#
        } else if !agents {
            return #"{"version":"0.9.0","protocol":22,"focused_workspace_id":"workspace-app","focused_tab_id":"tab-app","focused_pane_id":"pane-shell","workspaces":[{"workspace_id":"workspace-app","number":1,"label":"Companion App","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"tab-app","agent_status":"unknown"}],"tabs":[{"tab_id":"tab-app","workspace_id":"workspace-app","number":1,"label":"shells","focused":true,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"pane-shell","terminal_id":"term-shell","workspace_id":"workspace-app","tab_id":"tab-app","focused":true,"cwd":"/Users/fixture/companion","foreground_cwd":"/Users/fixture/companion","label":"zsh","agent_status":"unknown","revision":1}],"agents":[],"layouts":[]}"#
        }
        return #"{"version":"0.9.0","protocol":22,"focused_workspace_id":"workspace-app","focused_tab_id":"tab-app","focused_pane_id":"pane-reviewer","workspaces":[{"workspace_id":"workspace-app","number":1,"label":"Companion App","focused":true,"pane_count":4,"tab_count":2,"active_tab_id":"tab-app","agent_status":"blocked"},{"workspace_id":"workspace-docs","number":2,"label":"Docs","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"tab-docs","agent_status":"working"}],"tabs":[{"tab_id":"tab-app","workspace_id":"workspace-app","number":1,"label":"review","focused":true,"pane_count":3,"agent_status":"blocked"},{"tab_id":"tab-shell","workspace_id":"workspace-app","number":2,"label":"shell","focused":false,"pane_count":1,"agent_status":"unknown"},{"tab_id":"tab-docs","workspace_id":"workspace-docs","number":1,"label":"notes","focused":false,"pane_count":1,"agent_status":"working"}],"panes":[{"pane_id":"pane-reviewer","terminal_id":"term-reviewer","workspace_id":"workspace-app","tab_id":"tab-app","focused":true,"cwd":"/Users/fixture/companion","foreground_cwd":"/Users/fixture/companion","agent":"codex","display_agent":"Codex","agent_status":"blocked","revision":4},{"pane_id":"pane-calendar","terminal_id":"term-calendar","workspace_id":"workspace-app","tab_id":"tab-app","focused":false,"cwd":"/Users/fixture/companion","agent":"claude","display_agent":"Claude","agent_status":"working","revision":3},{"pane_id":"pane-mystery","terminal_id":"term-mystery","workspace_id":"workspace-app","tab_id":"tab-app","focused":false,"cwd":"/Users/fixture/companion","agent":"gemini","display_agent":"Gemini","agent_status":"unknown","revision":1},{"pane_id":"pane-shell","terminal_id":"term-shell","workspace_id":"workspace-app","tab_id":"tab-shell","focused":false,"cwd":"/Users/fixture/companion","label":"zsh","agent_status":"unknown","revision":1},{"pane_id":"pane-docs","terminal_id":"term-docs","workspace_id":"workspace-docs","tab_id":"tab-docs","focused":false,"cwd":"/Users/fixture/docs","agent":"codex","display_agent":"Codex","agent_status":"working","revision":2}],"agents":[{"terminal_id":"term-reviewer","name":"reviewer","agent":"codex","agent_status":"blocked","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-reviewer","cwd":"/Users/fixture/companion","interactive_ready":true,"revision":4},{"terminal_id":"term-calendar","name":"calendar-bot","agent":"claude","agent_status":"working","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-calendar","cwd":"/Users/fixture/companion","interactive_ready":true,"revision":3},{"terminal_id":"term-mystery","name":"mystery-bot","agent":"gemini","agent_status":"unknown","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-mystery","cwd":"/Users/fixture/companion","interactive_ready":true,"revision":1},{"terminal_id":"term-docs","name":"docs-pass","agent":"codex","agent_status":"working","workspace_id":"workspace-docs","tab_id":"tab-docs","pane_id":"pane-docs","cwd":"/Users/fixture/docs","interactive_ready":true,"revision":2},{"terminal_id":"term-idle","name":"idle-notes","agent":"codex","agent_status":"idle","workspace_id":"workspace-docs","tab_id":"tab-docs","pane_id":"pane-missing","cwd":"/Users/fixture/docs","interactive_ready":true,"revision":1}],"layouts":[]}"#
    }
}

private struct CompanionFixtureRecovery: ViewModifier {
    let mode: CompanionLaunchFixture.Mode
    @ObservedObject var model: CompanionConnectionModel
    func body(content: Content) -> some View {
        if CompanionLaunchFixture.interactionModes.contains(mode) {
            content
        } else {
            content.companionInsertionRecovery(model: model)
        }
    }
}

private struct CompanionFixtureStatusOverlay: View {
    @ObservedObject var model: CompanionConnectionModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let _ = model.insertionEpoch
            VStack(alignment: .leading, spacing: 0) {
                probe("companion-fixture-connection", connectionValue)
                probe("companion-fixture-host", model.connectedSavedHost?.id.uuidString ?? "")
                probe("companion-fixture-generation", model.fixtureGeneration)
                probe("companion-fixture-receipts", model.fixtureReceiptProbe())
                probe(
                    "companion-fixture-upload",
                    (model.attachmentUpload as? CompanionUploadRecorder)?.probeSnapshot() ?? "none")
                probe(
                    "companion-fixture-cleanup",
                    (model.attachmentCleanup as? CompanionCleanupRecorder)?.probeSnapshot() ?? "none")
                probe(
                    "companion-fixture-sessions",
                    model.fixtureSessionMirror?.probeSnapshot() ?? "")
                probe(
                    "companion-fixture-session-target",
                    model.fixtureSessionMirror?.targetProbeSnapshot() ?? "")
                probe("companion-fixture-presenting", model.isPresentingRecovery ? "presented" : "dismissed")
                probe(
                    "companion-fixture-size-class",
                    model.fixtureSizeClass == .compact ? "compact"
                        : model.fixtureSizeClass == .regular ? "regular" : "system")
                probe(
                    "companion-fixture-notification",
                    model.notificationDestination?.pane.paneID ?? "none")
            }
            .frame(maxWidth: .infinity, maxHeight: 8, alignment: .bottom)
            .allowsHitTesting(false)
            .accessibilityElement(children: .contain)
        }
    }

    private var connectionValue: String {
        if model.isConnected { return "connected" }
        if model.isConnecting { return "connecting" }
        return "disconnected"
    }

    private func probe(_ id: String, _ value: String) -> some View {
        Text(value.isEmpty ? "empty" : value)
            .accessibilityIdentifier(id)
            .accessibilityValue(value)
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
    }
}

private struct CompanionFixtureActionOverlay: View {
    @ObservedObject var model: CompanionConnectionModel

    var body: some View {
        VStack(spacing: 4) {
            fixtureButton("notify-calendar") {
                model.fixtureDeliverNotification(paneID: "pane-calendar")
            }
            .accessibilityIdentifier("companion-fixture-notify-calendar")
            fixtureButton("notify-reviewer") {
                model.fixtureDeliverNotification(paneID: "pane-reviewer")
            }
            .accessibilityIdentifier("companion-fixture-notify-reviewer")
            fixtureButton("force-compact") {
                model.fixtureSetSizeClass(.compact)
            }
            .accessibilityIdentifier("companion-fixture-force-compact")
            fixtureButton("force-regular") {
                model.fixtureSetSizeClass(.regular)
            }
            .accessibilityIdentifier("companion-fixture-force-regular")
        }
        .padding(.top, 56)
        .padding(.trailing, 4)
    }

    private func fixtureButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private struct CompanionFixtureDynamicType: ViewModifier {
    let mode: CompanionLaunchFixture.Mode
    func body(content: Content) -> some View {
        if mode == .largeText || mode == .recoveryLong {
            content.environment(\.dynamicTypeSize, .accessibility2)
        } else {
            content
        }
    }
}

final class FixtureSilentTransport: HerdrTransport {
    private var snapshot: String

    init(snapshot: String) {
        self.snapshot = snapshot
    }

    func roundTrip(_ requestLine: String) async throws -> String {
        if requestLine.contains("\"method\":\"tab.create\"") {
            return tabCreated(from: requestLine)
        }
        if requestLine.contains("\"method\":\"pane.split\"") {
            return paneSplit(from: requestLine)
        }
        return #"{"id":"fixture","result":{"type":"session_snapshot","snapshot":\#(snapshot)}}"#
    }

    func stream(_ requestLine: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    private func tabCreated(from request: String) -> String {
        let workspaceID = jsonString("workspace_id", in: request) ?? "workspace-app"
        let cwd = jsonString("cwd", in: request) ?? "/Users/fixture/companion"
        let tab = #"{"tab_id":"tab-created","workspace_id":"\#(workspaceID)","number":9,"label":"created","focused":false,"pane_count":1,"agent_status":"unknown"}"#
        let pane = paneJSON(
            paneID: "pane-tab-created", terminalID: "term-tab-created",
            workspaceID: workspaceID, tabID: "tab-created", cwd: cwd)
        inject(tab, arrayKey: "tabs", before: "],\"panes\":")
        inject(pane, arrayKey: "panes", before: "],\"agents\":")
        return #"{"id":"fixture","result":{"type":"tab_created","tab":\#(tab),"root_pane":\#(pane)}}"#
    }

    private func paneSplit(from request: String) -> String {
        let workspaceID = jsonString("workspace_id", in: request) ?? "workspace-app"
        let target = jsonString("target_pane_id", in: request)
        let cwd = jsonString("cwd", in: request) ?? "/Users/fixture/companion"
        let tabID = tabID(for: target) ?? "tab-app"
        let pane = paneJSON(
            paneID: "pane-split-created", terminalID: "term-split-created",
            workspaceID: workspaceID, tabID: tabID, cwd: cwd)
        inject(pane, arrayKey: "panes", before: "],\"agents\":")
        return #"{"id":"fixture","result":{"type":"pane_info","pane":\#(pane)}}"#
    }

    private func paneJSON(
        paneID: String, terminalID: String, workspaceID: String, tabID: String, cwd: String
    ) -> String {
        #"{"pane_id":"\#(paneID)","terminal_id":"\#(terminalID)","workspace_id":"\#(workspaceID)","tab_id":"\#(tabID)","focused":false,"cwd":"\#(cwd)","foreground_cwd":"\#(cwd)","label":"zsh","agent_status":"unknown","revision":0}"#
    }

    private func inject(_ object: String, arrayKey: String, before token: String) {
        let empty = "\"\(arrayKey)\":[]"
        if snapshot.contains(empty) {
            snapshot = snapshot.replacingOccurrences(of: empty, with: "\"\(arrayKey)\":[\(object)]")
            return
        }
        if let range = snapshot.range(of: token) {
            snapshot.replaceSubrange(range, with: ",\(object)\(token)")
        }
    }

    private func tabID(for paneID: String?) -> String? {
        guard let paneID else { return nil }
        let marker = "\"pane_id\":\"" + paneID + "\""
        guard let range = snapshot.range(of: marker) else { return nil }
        let lower = snapshot.index(range.lowerBound, offsetBy: -220, limitedBy: snapshot.startIndex) ?? snapshot.startIndex
        let upper = snapshot.index(range.upperBound, offsetBy: 80, limitedBy: snapshot.endIndex) ?? snapshot.endIndex
        return jsonString("tab_id", in: String(snapshot[lower..<upper]))
    }

    private func jsonString(_ key: String, in request: String) -> String? {
        let needle = "\"\(key)\":\""
        guard let start = request.range(of: needle) else { return nil }
        let rest = request[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
#endif
