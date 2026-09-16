import SwiftUI
import UIKit
import HerdrKit

enum CompanionOverviewScope: String, CaseIterable, Identifiable, Equatable {
    case attention
    case running
    case idle
    case workspaces
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attention: return "Attention"
        case .running: return "Running"
        case .idle: return "Inactive"
        case .workspaces: return "Workspaces"
        case .all: return "All"
        }
    }

    static var deskScopes: [CompanionOverviewScope] {
        [.attention, .running, .idle, .all]
    }

    var deskPlace: CompanionDeskPlace {
        self == .workspaces ? .workspaces : .desk
    }
}

struct CompanionOverviewSection: Equatable {
    let group: AgentGroup
    let rows: [AgentRow]
}

struct CompanionWorkspaceSummary: Equatable, Identifiable {
    let workspace: WorkspaceInfo
    let needsYou: Int
    let running: Int
    let unknown: Int

    var id: String { workspace.workspaceID }

    var title: String { CompanionWorkspaceTitle.display(workspace) }

    private static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    var subtitle: String {
        var bits: [String] = []
        if needsYou > 0 { bits.append("\(needsYou) need you") }
        if running > 0 { bits.append("\(running) running") }
        if unknown > 0 { bits.append("\(unknown) unknown") }
        bits.append(Self.count(workspace.tabCount, "tab"))
        bits.append(Self.count(workspace.paneCount, "terminal"))
        return bits.joined(separator: " · ")
    }
}

enum CompanionOverviewVacancy: Equatable {
    case connecting
    case loading
    case noAgents
    case noWorkspaces
    case quiet
    case noMatches
    case none
}

struct CompanionOverviewSnapshot: Equatable {
    let scope: CompanionOverviewScope
    let query: String
    let isConnected: Bool
    let isConnecting: Bool
    let topologyLoaded: Bool
    let list: AgentList
    let sections: [CompanionOverviewSection]
    let matchedRows: [AgentRow]
    let workspaces: [CompanionWorkspaceSummary]
    let vacancy: CompanionOverviewVacancy

    var attentionCount: Int { list.needsYouCount }
    var unknownCount: Int { list.rows.filter { $0.group == .unrecognised }.count }
    var runningCount: Int { list.rows.filter { $0.group == .working }.count }
    var inactiveCount: Int { list.rows.filter { $0.group == .idle || $0.group == .stopped }.count }
    var attentionFilterCount: Int { attentionCount + unknownCount }
    var showsWorkspaceList: Bool { scope == .workspaces }
    var deskPlace: CompanionDeskPlace { scope.deskPlace }

    init(
        agents: [AgentInfo],
        topology: SessionTopology?,
        scope: CompanionOverviewScope,
        query: String,
        isConnected: Bool,
        isConnecting: Bool
    ) {
        self.scope = scope
        self.query = query
        self.isConnected = isConnected
        self.isConnecting = isConnecting
        self.topologyLoaded = topology != nil
        let liveIDs = topology.map { Set($0.panes.map(\.paneID)) }
        let list = AgentList(agents: agents, livePaneIDs: liveIDs)
        self.list = list
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func agentMatches(_ row: AgentRow) -> Bool {
            guard !needle.isEmpty else { return true }
            let workspace = CompanionWorkspaceTitle.display(
                workspaceID: row.info.workspaceID ?? "", in: topology) ?? ""
            return [row.info.displayName, row.info.agent ?? "", row.info.agentStatus ?? "",
                    row.info.cwd ?? "", workspace]
                .contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        func scoped(_ row: AgentRow) -> Bool {
            switch scope {
            case .attention: return row.group == .needsYou || row.group == .unrecognised
            case .running: return row.group == .working
            case .idle: return row.group == .idle || row.group == .stopped
            case .workspaces, .all: return true
            }
        }
        let matched = list.rows.filter { scoped($0) && agentMatches($0) }
        self.matchedRows = matched
        self.sections = AgentGroup.allCases.compactMap { group in
            let rows = matched.filter { $0.group == group }
            return rows.isEmpty ? nil : CompanionOverviewSection(group: group, rows: rows)
        }
        let summaries = (topology?.workspaces ?? [])
            .sorted { $0.number < $1.number }
            .map { workspace -> CompanionWorkspaceSummary in
                let inWorkspace = list.rows.filter { $0.info.workspaceID == workspace.workspaceID }
                return CompanionWorkspaceSummary(
                    workspace: workspace,
                    needsYou: inWorkspace.filter { $0.group == .needsYou }.count,
                    running: inWorkspace.filter { $0.group == .working }.count,
                    unknown: inWorkspace.filter { $0.group == .unrecognised }.count)
            }
        if needle.isEmpty || scope != .workspaces && scope != .all {
            self.workspaces = scope == .workspaces || scope == .all ? summaries : []
        } else {
            self.workspaces = summaries.filter {
                $0.title.localizedCaseInsensitiveContains(needle) || $0.subtitle.localizedCaseInsensitiveContains(needle)
            }
        }
        if scope != .workspaces && scope != .all {
            // Keep workspace chips out of agent-only filters.
            // summaries already filtered above for those scopes as [].
        }
        if isConnecting && !isConnected {
            vacancy = .connecting
        } else if isConnected && topology == nil && agents.isEmpty {
            vacancy = .loading
        } else if scope == .workspaces {
            if topology == nil { vacancy = .loading }
            else if summaries.isEmpty { vacancy = .noWorkspaces }
            else if self.workspaces.isEmpty { vacancy = .noMatches }
            else { vacancy = .none }
        } else if matched.isEmpty && needle.isEmpty {
            if scope == .attention && (topology != nil || !list.rows.isEmpty) {
                vacancy = .quiet
            } else if scope == .all && topology != nil && list.rows.isEmpty {
                vacancy = .noAgents
            } else if topology == nil && list.rows.isEmpty {
                vacancy = .loading
            } else {
                vacancy = .noMatches
            }
        } else if matched.isEmpty {
            vacancy = .noMatches
        } else {
            vacancy = .none
        }
    }
}

enum CompanionCreationContext {
    static func workspaceFolder(from topology: SessionTopology?) -> String? {
        guard let topology else { return nil }
        if let paneID = topology.focusedPaneID,
           let cwd = topology.panes.first(where: { $0.paneID == paneID })?.effectiveCWD {
            return cwd
        }
        return topology.panes.compactMap(\.effectiveCWD).first
    }

    static func tabFolder(from topology: SessionTopology?, workspaceID: String) -> String? {
        let panes = topology?.panes.filter { $0.workspaceID == workspaceID } ?? []
        if let focused = panes.first(where: { $0.focused })?.effectiveCWD { return focused }
        return panes.compactMap(\.effectiveCWD).first
    }

    static func splitFolder(from pane: TopologyPaneInfo) -> String? {
        pane.effectiveCWD
    }

    static func agentPaneID(for agent: AgentInfo) -> String? {
        let paneID = agent.paneID.trimmingCharacters(in: .whitespacesAndNewlines)
        return paneID.isEmpty ? nil : paneID
    }
}

enum CompanionAgentTargeting {
    enum Resolution: Equatable {
        case live(CompanionTerminalDestination)
        case fallbackAgent(paneID: String)
        case stopped
        case unavailable
    }

    static func resolve(row: AgentRow, topology: SessionTopology?, canFallback: Bool) -> Resolution {
        if let topology {
            if let pane = topology.panes.first(where: { $0.paneID == row.info.paneID }),
               let destination = CompanionTerminalDestination(pane: pane) {
                return .live(destination)
            }
            return .stopped
        }
        if canFallback, let paneID = CompanionCreationContext.agentPaneID(for: row.info) {
            return .fallbackAgent(paneID: paneID)
        }
        return .unavailable
    }
}

struct CompanionSplitNavigationState: Equatable {
    var scope: CompanionOverviewScope = .attention
    var search: String = ""
    var selectedWorkspaceID: String?
    var openedTerminal: CompanionTerminalDestination?
    var focusedTerminal = false

    var deskPlace: CompanionDeskPlace { scope.deskPlace }

    mutating func selectWorkspace(_ id: String) {
        scope = .workspaces
        selectedWorkspaceID = id
        focusedTerminal = false
        if let opened = openedTerminal, opened.pane.workspaceID != id {
            openedTerminal = nil
        }
    }

    mutating func setDeskPlace(
        _ place: CompanionDeskPlace,
        agents: [AgentInfo],
        topology: SessionTopology?,
        isConnected: Bool,
        isConnecting: Bool
    ) {
        switch place {
        case .desk:
            if scope == .workspaces {
                setScope(
                    .attention, agents: agents, topology: topology,
                    isConnected: isConnected, isConnecting: isConnecting)
            }
        case .workspaces:
            setScope(
                .workspaces, agents: agents, topology: topology,
                isConnected: isConnected, isConnecting: isConnecting)
        }
    }

    mutating func selectAgent(destination: CompanionTerminalDestination?) {
        selectedWorkspaceID = nil
        openedTerminal = destination
        focusedTerminal = destination != nil
    }

    mutating func selectVisibleRow(
        _ destination: CompanionTerminalDestination,
        agents: [AgentInfo],
        topology: SessionTopology?,
        isConnected: Bool,
        isConnecting: Bool
    ) {
        selectAgent(destination: destination)
        if !includes(
            destination, agents: agents, topology: topology,
            isConnected: isConnected, isConnecting: isConnecting) {
            scope = .all
        }
    }

    mutating func revealTerminal(
        _ destination: CompanionTerminalDestination,
        keepingWorkspace: Bool
    ) {
        if !keepingWorkspace {
            selectedWorkspaceID = nil
        }
        openedTerminal = destination
        focusedTerminal = true
    }

    mutating func openValidatedDestination(
        _ destination: CompanionTerminalDestination,
        agents: [AgentInfo],
        topology: SessionTopology?,
        isConnected: Bool,
        isConnecting: Bool
    ) {
        search = ""
        selectedWorkspaceID = nil
        scope = .all
        openedTerminal = destination
        focusedTerminal = true
        reconcileOpenTarget(
            agents: agents, topology: topology,
            isConnected: isConnected, isConnecting: isConnecting)
    }

    mutating func setScope(
        _ scope: CompanionOverviewScope,
        agents: [AgentInfo],
        topology: SessionTopology?,
        isConnected: Bool,
        isConnecting: Bool
    ) {
        self.scope = scope
        if scope != .workspaces {
            selectedWorkspaceID = nil
        }
        reconcileOpenTarget(
            agents: agents, topology: topology,
            isConnected: isConnected, isConnecting: isConnecting)
    }

    mutating func setSearch(
        _ search: String,
        agents: [AgentInfo],
        topology: SessionTopology?,
        isConnected: Bool,
        isConnecting: Bool
    ) {
        self.search = search
        reconcileOpenTarget(
            agents: agents, topology: topology,
            isConnected: isConnected, isConnecting: isConnecting)
    }

    func includes(
        _ destination: CompanionTerminalDestination,
        agents: [AgentInfo],
        topology: SessionTopology?,
        isConnected: Bool,
        isConnecting: Bool
    ) -> Bool {
        if let workspaceID = selectedWorkspaceID {
            return destination.pane.workspaceID == workspaceID
        }
        if scope == .workspaces {
            return false
        }
        let snapshot = CompanionOverviewSnapshot(
            agents: agents, topology: topology, scope: scope, query: search,
            isConnected: isConnected, isConnecting: isConnecting)
        switch destination.target {
        case .agent:
            return snapshot.matchedRows.contains { $0.info.paneID == destination.pane.paneID }
        case .terminal:
            return false
        }
    }

    mutating func reconcileOpenTarget(
        agents: [AgentInfo],
        topology: SessionTopology?,
        isConnected: Bool,
        isConnecting: Bool
    ) {
        guard let destination = openedTerminal else { return }
        if !includes(
            destination, agents: agents, topology: topology,
            isConnected: isConnected, isConnecting: isConnecting) {
            openedTerminal = nil
        }
    }

    mutating func reconcile(
        topology: SessionTopology?,
        agents: [AgentInfo],
        isConnected: Bool,
        isConnecting: Bool
    ) {
        if let workspaceID = selectedWorkspaceID, let topology {
            if !topology.workspaces.contains(where: { $0.workspaceID == workspaceID }) {
                selectedWorkspaceID = nil
            }
        }
        if let destination = openedTerminal {
            if let topology {
                if let pane = topology.panes.first(where: { $0.paneID == destination.pane.paneID }),
                   CompanionTerminalIdentity.matches(destination, pane: pane) {
                    reconcileOpenTarget(
                        agents: agents, topology: topology,
                        isConnected: isConnected, isConnecting: isConnecting)
                    return
                }
                openedTerminal = nil
                return
            }
        }
    }

    func isSelectedWorkspace(_ id: String) -> Bool {
        selectedWorkspaceID == id
    }

    func isSelectedDestination(_ destination: CompanionTerminalDestination) -> Bool {
        openedTerminal?.pane.paneID == destination.pane.paneID
            && openedTerminal?.target == destination.target
    }
}

struct CompanionSessionShell: View {
    @ObservedObject var model: CompanionConnectionModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var navigation = CompanionSplitNavigationState()

    /// iPad keeps one split tree across regular/compact so a live terminal is not
    /// unmounted on resize. Phone compact stays the existing stack.
    private var usesPersistentSplit: Bool {
        UIDevice.current.userInterfaceIdiom == .pad || effectiveSizeClass == .regular
    }

    private var effectiveSizeClass: UserInterfaceSizeClass? {
#if DEBUG
        if let forced = model.fixtureSizeClass { return forced }
#endif
        return sizeClass
    }

    var body: some View {
        Group {
            if usesPersistentSplit, navigation.openedTerminal != nil {
                CompanionSplitSessionView(model: model, navigation: $navigation)
                    .id("companion-persistent-split")
            } else if usesPersistentSplit {
                NavigationStack {
                    CompanionOverviewView(model: model, navigation: $navigation)
                        .navigationDestination(item: Binding(
                            get: { navigation.selectedWorkspaceID },
                            set: { navigation.selectedWorkspaceID = $0 }
                        )) { workspaceID in
                            WorkspaceDetailView(
                                model: model,
                                workspaceID: workspaceID,
                                onReveal: { destination in
                                    navigation.revealTerminal(destination, keepingWorkspace: true)
                                })
                        }
                }
            } else {
                NavigationStack {
                    CompanionOverviewView(model: model)
                        .companionNotificationDestination(model: model)
                }
            }
        }
        .onAppear {
            applyFixtureLaunch()
            if usesPersistentSplit {
                consumeValidatedNotification()
            }
        }
        .onChange(of: model.notificationDestination) { _, _ in
            if usesPersistentSplit {
                consumeValidatedNotification()
            }
        }
        .modifier(CompanionOptionalSizeClass(forced: {
#if DEBUG
            // Persistent iPad split ignores compact overrides so the live
            // terminal is not unmounted; the fixture probe still records them.
            usesPersistentSplit && navigation.openedTerminal != nil ? nil : model.fixtureSizeClass
#else
            nil
#endif
        }()))
        .tint(Palette.accent)
    }

    private func applyFixtureLaunch() {
        if let scope = model.fixtureScope {
            navigation.setScope(
                scope, agents: model.agents, topology: model.topology,
                isConnected: model.isConnected, isConnecting: model.isConnecting)
        }
        if let workspaceID = model.fixtureWorkspaceID {
            navigation.selectWorkspace(workspaceID)
        }
        if let paneID = model.fixtureOpenPaneID,
           let pane = model.topology?.panes.first(where: { $0.paneID == paneID }),
           let destination = CompanionTerminalDestination(pane: pane) {
            navigation.revealTerminal(destination, keepingWorkspace: false)
        }
    }

    private func consumeValidatedNotification() {
        guard let destination = model.notificationDestination else { return }
        navigation.openValidatedDestination(
            destination, agents: model.agents, topology: model.topology,
            isConnected: model.isConnected, isConnecting: model.isConnecting)
        model.dismissNotificationDestination()
    }
}

private struct CompanionOptionalSizeClass: ViewModifier {
    var forced: UserInterfaceSizeClass?
    func body(content: Content) -> some View {
        if let forced {
            content.environment(\.horizontalSizeClass, forced)
        } else {
            content
        }
    }
}

private extension View {
    func companionNotificationDestination(model: CompanionConnectionModel) -> some View {
        navigationDestination(item: Binding(
            get: { model.notificationDestination },
            set: { if $0 == nil { model.dismissNotificationDestination() } }
        )) { destination in
            CompanionTerminalHost(model: model, destination: destination)
        }
    }
}

struct CompanionTerminalHost: View {
    @ObservedObject var model: CompanionConnectionModel
    let destination: CompanionTerminalDestination

    var body: some View {
        let opener = model.terminalOpener ?? model.transport.map { CompanionTerminalOpeners.official($0) }
        if let opener {
            CompanionTerminalScreen(
                transport: model.transport,
                opener: opener,
                title: destination.title,
                target: destination.target,
                notice: destination.notice,
                location: CompanionTerminalLocation(
                    mac: connectionTitle,
                    session: model.connectedSavedHost?.herdrSession ?? "session",
                    workspace: CompanionWorkspaceTitle.display(
                        workspaceID: destination.pane.workspaceID, in: model.topology),
                    terminal: destination.title),
                initiallyShowKeys: model.fixtureShowKeys,
                initiallyShowDraft: model.fixtureShowDraft,
                initiallyShowAttachment: model.fixtureShowAttachment,
                insertionModel: model,
                insertionOwner: model.recoveryOwner ?? model.connectedSavedHost.map(CompanionInsertionOwner.init))
            .id(CompanionTerminalIdentity.key(
                hostID: model.connectedSavedHost?.id, target: destination.target))
        } else {
            CompanionEmptyState(
                title: "Terminal unavailable",
                systemImage: "terminal",
                detail: "Reconnect to the saved Mac and open this terminal again.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .companionScreen()
        }
    }

    private var connectionTitle: String {
        if case .connected(let label) = model.phase { return label }
        return model.connectedSavedHost?.label ?? "Mac"
    }
}

struct CompanionSplitBrowserAction {
    var browsing: Bool
    var toggle: () -> Void
}

private struct CompanionSplitBrowserActionKey: EnvironmentKey {
    static let defaultValue: CompanionSplitBrowserAction? = nil
}

extension EnvironmentValues {
    var companionSplitBrowser: CompanionSplitBrowserAction? {
        get { self[CompanionSplitBrowserActionKey.self] }
        set { self[CompanionSplitBrowserActionKey.self] = newValue }
    }
}

private struct CompanionHideSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

private struct CompanionSplitColumnEnforcer: UIViewControllerRepresentable {
    var hideLists: Bool

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.hideLists = hideLists
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hideLists = hideLists
        controller.apply()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.stop()
    }

    final class Controller: UIViewController {
        var hideLists = false
        private weak var observedSplit: UISplitViewController?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        func stop() {
            observedSplit = nil
        }

        func apply() {
            guard let split = findOwningSplit() else { return }
            let ownerChanged = observedSplit.map { $0 !== split } ?? true
            observedSplit = split
            UIView.performWithoutAnimation {
                split.preferredSplitBehavior = .overlay
                split.presentsWithGesture = false
                split.displayModeButtonVisibility = .never
                let hidden = split.displayMode == .secondaryOnly
                if hideLists == hidden, !ownerChanged { return }
                if hideLists {
                    split.hide(.primary)
                    split.hide(.supplementary)
                    split.preferredDisplayMode = .secondaryOnly
                } else {
                    split.preferredDisplayMode = .oneOverSecondary
                    split.show(.primary)
                }
                split.view.layoutIfNeeded()
            }
        }

        private func findOwningSplit() -> UISplitViewController? {
            if let split = splitViewController { return split }
            var responder: UIResponder? = self
            while let current = responder {
                if let split = current as? UISplitViewController { return split }
                responder = current.next
            }
            let window = view.window
            var ancestor = view.superview
            while let current = ancestor {
                var next: UIResponder? = current.next
                while let candidate = next {
                    if let split = candidate as? UISplitViewController { return split }
                    next = candidate.next
                }
                ancestor = current.superview
            }
            return findSplit(in: window?.rootViewController)
        }

        private func findSplit(in root: UIViewController?) -> UISplitViewController? {
            guard let root else { return nil }
            if let split = root as? UISplitViewController { return split }
            if let split = root.splitViewController { return split }
            for child in root.children {
                if let split = findSplit(in: child) { return split }
            }
            return findSplit(in: root.presentedViewController)
        }
    }
}

struct CompanionSplitSessionView: View {
    @ObservedObject var model: CompanionConnectionModel
    @Binding var navigation: CompanionSplitNavigationState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var suppressVisibilityFeedback = 0

    private var isBrowsing: Bool {
        navigation.openedTerminal == nil || !navigation.focusedTerminal
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            NavigationStack {
                CompanionOverviewView(model: model, navigation: $navigation)
                    .navigationDestination(item: Binding(
                        get: { navigation.selectedWorkspaceID },
                        set: { navigation.selectedWorkspaceID = $0 }
                    )) { workspaceID in
                        WorkspaceDetailView(
                            model: model,
                            workspaceID: workspaceID,
                            onReveal: { destination in
                                navigation.revealTerminal(destination, keepingWorkspace: true)
                            })
                    }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
            .environment(\.companionSplitBrowser, splitBrowserAction)
            .modifier(CompanionHideSidebarToggle())
        } detail: {
            NavigationStack {
                if let destination = navigation.openedTerminal {
                    CompanionTerminalHost(model: model, destination: destination)
                } else {
                    CompanionEmptyState(
                        title: "Select a terminal",
                        systemImage: "rectangle.split.3x1",
                        detail: "Pick an agent or a workspace pane. The selected Mac stays in the sidebar.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .companionScreen()
                }
            }
            .environment(\.companionSplitBrowser, splitBrowserAction)
            .modifier(CompanionHideSidebarToggle())
        }
        .navigationSplitViewStyle(.prominentDetail)
        // iPad split stays regular-width so compact size class cannot
        // collapse onto the sidebar and unmount the live terminal host.
        .environment(\.horizontalSizeClass, .regular)
        .modifier(CompanionHideSidebarToggle())
        .background {
            CompanionSplitColumnEnforcer(
                hideLists: navigation.openedTerminal != nil && navigation.focusedTerminal)
        }
        .onAppear {
            applyFixtureLaunch()
            consumeValidatedNotification()
            applyPreferredColumnVisibility()
        }
        .onChange(of: model.notificationDestination) { _, _ in
            consumeValidatedNotification()
        }
        .onChange(of: model.topology) { _, topology in
            navigation.reconcile(
                topology: topology, agents: model.agents,
                isConnected: model.isConnected, isConnecting: model.isConnecting)
        }
        .onChange(of: model.agents) { _, agents in
            navigation.reconcile(
                topology: model.topology, agents: agents,
                isConnected: model.isConnected, isConnecting: model.isConnecting)
        }
        .onChange(of: navigation.openedTerminal) { _, new in
            applyPreferredColumnVisibility()
        }
        .onChange(of: navigation.focusedTerminal) { _, _ in
            applyPreferredColumnVisibility()
        }
        .onChange(of: navigation.selectedWorkspaceID) { _, workspaceID in
            guard workspaceID != nil else { return }
            navigation.focusedTerminal = false
            applyPreferredColumnVisibility()
        }
        .onChange(of: columnVisibility) { _, visibility in
            if suppressVisibilityFeedback > 0 {
                suppressVisibilityFeedback -= 1
                return
            }
            guard navigation.openedTerminal != nil else { return }
            // Adopt native/system hide-lists as Focus. Do not unfocus from
            // .all: that is the initial value and a SwiftUI echo, and the
            // enforcer restores hidden lists while the terminal stays focused.
            if visibility == .detailOnly, !navigation.focusedTerminal {
                navigation.focusedTerminal = true
            }
        }
    }

    private var splitBrowserAction: CompanionSplitBrowserAction? {
        guard navigation.openedTerminal != nil else { return nil }
        return CompanionSplitBrowserAction(browsing: isBrowsing, toggle: toggleBrowser)
    }

    private func toggleBrowser() {
        guard navigation.openedTerminal != nil else { return }
        navigation.focusedTerminal.toggle()
        applyPreferredColumnVisibility()
    }

    private func applyPreferredColumnVisibility() {
        let focused = navigation.openedTerminal != nil && navigation.focusedTerminal
        let preferred: NavigationSplitViewVisibility = focused ? .detailOnly : .all
        if columnVisibility != preferred {
            suppressVisibilityFeedback += 1
            columnVisibility = preferred
        }
    }

    private func consumeValidatedNotification() {
        guard let destination = model.notificationDestination else { return }
        navigation.openValidatedDestination(
            destination, agents: model.agents, topology: model.topology,
            isConnected: model.isConnected, isConnecting: model.isConnecting)
        applyPreferredColumnVisibility()
        model.dismissNotificationDestination()
    }

    private func applyFixtureLaunch() {
        if navigation.openedTerminal != nil {
            applyPreferredColumnVisibility()
            return
        }
        if let scope = model.fixtureScope {
            navigation.setScope(
                scope, agents: model.agents, topology: model.topology,
                isConnected: model.isConnected, isConnecting: model.isConnecting)
        }
        if let workspaceID = model.fixtureWorkspaceID {
            navigation.selectWorkspace(workspaceID)
        }
        if let paneID = model.fixtureOpenPaneID,
           let pane = model.topology?.panes.first(where: { $0.paneID == paneID }),
           let destination = CompanionTerminalDestination(pane: pane) {
            navigation.openedTerminal = destination
            navigation.focusedTerminal = true
            applyPreferredColumnVisibility()
        }
    }
}

struct CompanionOverviewDetailList: View {
    @ObservedObject var model: CompanionConnectionModel
    @Binding var navigation: CompanionSplitNavigationState

    var body: some View {
        let snapshot = CompanionOverviewSnapshot(
            agents: model.agents, topology: model.topology, scope: navigation.scope,
            query: navigation.search, isConnected: model.isConnected, isConnecting: model.isConnecting)
        List {
            if snapshot.vacancy != .none && snapshot.sections.isEmpty {
                Section {
                    vacancy(snapshot)
                        .listRowBackground(Palette.ground)
                }
            }
            ForEach(snapshot.sections, id: \.group) { section in
                Section(section.group.sectionTitle) {
                    ForEach(section.rows) { row in
                        agentButton(row)
                    }
                }
            }
        }
        .companionScreen()
        .navigationTitle(navigation.scope.title)
        .searchable(text: Binding(
            get: { navigation.search },
            set: { navigation.setSearch(
                $0, agents: model.agents, topology: model.topology,
                isConnected: model.isConnected, isConnecting: model.isConnecting) }
        ), prompt: "Search agents")
        .accessibilityIdentifier("companion-middle-search")
    }

    @ViewBuilder
    private func vacancy(_ snapshot: CompanionOverviewSnapshot) -> some View {
        switch snapshot.vacancy {
        case .connecting:
            HStack(spacing: 10) { ProgressView(); Text("Connecting to this Mac") }
                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
        case .loading:
            HStack(spacing: 10) { ProgressView(); Text("Loading the session") }
                .font(Typography.app(14)).foregroundStyle(Palette.textDim)
        case .quiet:
            CompanionEmptyState(
                title: "Nothing needs attention",
                systemImage: "checkmark.circle",
                detail: "Running work stays under Running.")
        case .noAgents:
            CompanionEmptyState(
                title: "No agents in this session",
                systemImage: "terminal",
                detail: "Plain terminals still live in Workspaces.")
        case .noMatches:
            CompanionEmptyState(
                title: navigation.search.isEmpty ? "Nothing in this filter" : "No matches",
                systemImage: "magnifyingglass",
                detail: "Try All or Workspaces.")
        default:
            EmptyView()
        }
    }

    private var middleDiscriminators: [String: String] {
        let items = CompanionOverviewSnapshot(
            agents: model.agents, topology: model.topology, scope: navigation.scope,
            query: navigation.search, isConnected: model.isConnected, isConnecting: model.isConnecting
        ).sections.flatMap(\.rows).map {
            CompanionTargetContext(
                title: $0.info.displayName,
                workspace: CompanionWorkspaceTitle.display(
                    workspaceID: $0.info.workspaceID ?? "", in: model.topology),
                path: $0.info.cwd,
                paneID: $0.info.paneID)
        }
        return CompanionTargetContext.discriminators(for: items)
    }

    @ViewBuilder
    private func agentButton(_ row: AgentRow) -> some View {
        let content = AgentRosterRow(
            row: row,
            workspaceName: CompanionWorkspaceTitle.display(
                workspaceID: row.info.workspaceID ?? "", in: model.topology),
            discriminator: middleDiscriminators[row.info.paneID])
        switch CompanionAgentTargeting.resolve(
            row: row, topology: model.topology,
            canFallback: model.transport != nil || model.terminalOpener != nil) {
        case .live(let destination):
            let selected = navigation.isSelectedDestination(destination)
            Button {
                navigation.selectVisibleRow(
                    destination, agents: model.agents, topology: model.topology,
                    isConnected: model.isConnected, isConnecting: model.isConnecting)
            } label: {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("companion-agent-\(row.info.paneID)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .listRowBackground(selected ? Palette.surfaceRaised : Palette.ground)
        case .fallbackAgent, .stopped, .unavailable:
            content
                .foregroundStyle(Palette.textFaint)
                .listRowBackground(Palette.ground)
        }
    }
}

struct CompanionOverviewView: View {
    @ObservedObject var model: CompanionConnectionModel
    var navigation: Binding<CompanionSplitNavigationState>? = nil
    @Environment(\.companionSplitBrowser) private var splitBrowser
    @State private var localSearch = ""
    @State private var localScope: CompanionOverviewScope = .attention
    @State private var showingNewWorkspace = false
    @State private var compactOpenedTerminal: CompanionTerminalDestination?
    @State private var compactWorkspaceID: String?

    private var splitMode: Bool { navigation != nil }

    private var search: Binding<String> {
        if let navigation {
            return Binding(
                get: { navigation.wrappedValue.search },
                set: { newValue in
                    var nav = navigation.wrappedValue
                    nav.setSearch(
                        newValue, agents: model.agents, topology: model.topology,
                        isConnected: model.isConnected, isConnecting: model.isConnecting)
                    navigation.wrappedValue = nav
                })
        }
        return $localSearch
    }

    private var scope: Binding<CompanionOverviewScope> {
        if let navigation {
            return Binding(
                get: { navigation.wrappedValue.scope },
                set: { newValue in
                    var nav = navigation.wrappedValue
                    nav.setScope(
                        newValue, agents: model.agents, topology: model.topology,
                        isConnected: model.isConnected, isConnecting: model.isConnecting)
                    navigation.wrappedValue = nav
                })
        }
        return $localScope
    }

    var body: some View {
        let snapshot = CompanionOverviewSnapshot(
            agents: model.agents,
            topology: model.topology,
            scope: scope.wrappedValue,
            query: search.wrappedValue,
            isConnected: model.isConnected,
            isConnecting: model.isConnecting)
        List {
            Section {
                CompanionConnectionHeader(
                    mac: connectionTitle,
                    session: model.connectedSavedHost?.herdrSession ?? "session",
                    status: connectionStatus,
                    isLive: model.isConnected,
                    switchAction: { Task { await model.disconnect() } })
                .listRowBackground(Palette.ground)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 2, trailing: 16))
                .listRowSeparator(.hidden)
            }
            if let message = model.message {
                Section { CompanionBanner(text: message, kind: .info).listRowBackground(Palette.ground) }
            }
            if let message = model.topologyMessage {
                Section { CompanionBanner(text: message, kind: .warning).listRowBackground(Palette.ground) }
            }
            Section {
                CompanionDeskSwitcher(
                    selected: snapshot.deskPlace,
                    action: { place in applyDeskPlace(place) })
                .listRowBackground(Palette.ground)
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                .listRowSeparator(.hidden)
                if snapshot.deskPlace == .desk {
                    CompanionFilterBar(
                        scopes: CompanionOverviewScope.deskScopes,
                        selected: scope.wrappedValue,
                        count: { count(for: $0, snapshot: snapshot) },
                        action: { item in applyScope(item) })
                    .listRowBackground(Palette.ground)
                    .accessibilityIdentifier("overview-filters")
                }
            }
            .listRowBackground(Palette.ground)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 4, trailing: 8))
            switch snapshot.vacancy {
            case .connecting:
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Connecting to this Mac")
                    }
                    .font(Typography.app(14))
                    .foregroundStyle(Palette.textDim)
                    .listRowBackground(Palette.ground)
                }
            case .loading:
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading the session")
                    }
                    .font(Typography.app(14))
                    .foregroundStyle(Palette.textDim)
                    .listRowBackground(Palette.ground)
                }
            case .noAgents:
                empty("No agents in this session", "terminal",
                      "Plain terminals still live in Workspaces.")
            case .noWorkspaces:
                empty("No workspaces", "rectangle.3.group",
                      "Create a workspace to open a plain interactive terminal.",
                      identifier: "workspaces-empty-state")
            case .quiet:
                if runningPeek(snapshot).isEmpty {
                    empty("Nothing needs attention", "checkmark.circle",
                          "Open Running for live work, or Workspaces for every terminal.")
                }
            case .noMatches:
                empty(search.wrappedValue.isEmpty ? "Nothing in this filter" : "No matches",
                      "magnifyingglass",
                      search.wrappedValue.isEmpty
                        ? "Try All, or open Workspaces."
                        : "Try a name, status, workspace or folder.")
            case .none:
                EmptyView()
            }
            if snapshot.deskPlace == .workspaces, !snapshot.workspaces.isEmpty {
                Section {
                    ForEach(snapshot.workspaces) { summary in
                        workspaceRow(summary)
                    }
                } header: {
                    Text("Projects")
                }
            }
            if snapshot.deskPlace == .desk, !snapshot.sections.isEmpty {
                ForEach(snapshot.sections, id: \.group) { section in
                    Section(section.group.sectionTitle) {
                        ForEach(section.rows) { row in
                            agentRow(row)
                        }
                    }
                }
            }
            if snapshot.deskPlace == .desk, scope.wrappedValue == .attention {
                let running = runningPeek(snapshot)
                if !running.isEmpty {
                    Section("Running") {
                        ForEach(running) { row in
                            agentRow(row)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .companionScreen()
        .navigationTitle(snapshot.deskPlace.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: search,
            prompt: snapshot.deskPlace == .workspaces ? "Search workspaces" : "Search the desk")
        .refreshable { await model.refresh() }
        .toolbar { toolbar }
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceForm(
                model: model,
                initialCWD: CompanionCreationContext.workspaceFolder(from: model.topology)
            ) { destination in
                showingNewWorkspace = false
                open(destination)
            }
            .interactiveDismissDisabled(
                model.mutationInFlight != nil || model.mutationOutcomeUnknown)
        }
        .navigationDestination(item: $compactOpenedTerminal) { destination in
            CompanionTerminalHost(model: model, destination: destination)
        }
        .navigationDestination(item: $compactWorkspaceID) { workspaceID in
            WorkspaceDetailView(model: model, workspaceID: workspaceID)
        }
        .onAppear { applyFixtureLaunch() }
        .onChange(of: model.topology) { _, topology in
            if var nav = navigation?.wrappedValue {
                nav.reconcile(
                    topology: topology, agents: model.agents,
                    isConnected: model.isConnected, isConnecting: model.isConnecting)
                navigation?.wrappedValue = nav
            }
        }
        .onChange(of: model.agents) { _, agents in
            if var nav = navigation?.wrappedValue {
                nav.reconcile(
                    topology: model.topology, agents: agents,
                    isConnected: model.isConnected, isConnecting: model.isConnecting)
                navigation?.wrappedValue = nav
            }
        }
    }

    private func applyFixtureLaunch() {
        if let fixtureScope = model.fixtureScope, navigation == nil {
            localScope = fixtureScope
        }
        if compactWorkspaceID == nil, let workspaceID = model.fixtureWorkspaceID, navigation == nil {
            compactWorkspaceID = workspaceID
        }
        if navigation == nil, compactOpenedTerminal == nil,
           let paneID = model.fixtureOpenPaneID,
           let pane = model.topology?.panes.first(where: { $0.paneID == paneID }),
           let destination = CompanionTerminalDestination(pane: pane) {
            compactOpenedTerminal = destination
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let splitBrowser, splitBrowser.browsing {
            ToolbarItem(placement: .topBarLeading) {
                CompanionSplitBrowserControl(browsing: true, action: splitBrowser.toggle)
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let host = model.connectedSavedHost {
                Menu {
                    if let transport = model.transport {
                        NavigationLink {
                            CompanionNotificationSettingsView(
                                savedHostID: host.id.uuidString,
                                session: host.herdrSession,
                                workspaces: notificationWorkspaces,
                                call: { try await transport.notificationHelperRPC($0) })
                        } label: {
                            Label("Notifications", systemImage: "bell")
                        }
                    } else {
                        Label("Notifications unavailable until connected", systemImage: "bell.slash")
                    }
                    Button("New Workspace") {
                        model.acknowledgeUnknownMutation()
                        model.topologyMessage = nil
                        showingNewWorkspace = true
                    }
                    .disabled(model.mutationInFlight != nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Session actions")
            }
            Button {
                model.acknowledgeUnknownMutation()
                model.topologyMessage = nil
                showingNewWorkspace = true
            } label: {
                Label("New Workspace", systemImage: "plus")
            }
            .disabled(model.mutationInFlight != nil)
            .accessibilityIdentifier("new-workspace-button")
        }
    }

    private var notificationWorkspaces: [CompanionNotificationWorkspace] {
        model.topology?.workspaces.map {
            CompanionNotificationWorkspace(
                id: $0.workspaceID,
                label: $0.label.isEmpty ? "Workspace \($0.number)" : $0.label)
        }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending } ?? []
    }

    private var connectionTitle: String {
        if case .connected(let label) = model.phase { return label }
        if case .connecting(let label) = model.phase { return label }
        return model.connectedSavedHost?.label ?? "Session"
    }

    private var connectionStatus: String {
        if model.isConnected { return "Connected" }
        if model.isConnecting { return "Connecting" }
        return "Disconnected"
    }

    private func applyDeskPlace(_ place: CompanionDeskPlace) {
        if var nav = navigation?.wrappedValue {
            nav.setDeskPlace(
                place, agents: model.agents, topology: model.topology,
                isConnected: model.isConnected, isConnecting: model.isConnecting)
            navigation?.wrappedValue = nav
        } else {
            switch place {
            case .desk:
                if localScope == .workspaces { localScope = .attention }
            case .workspaces:
                localScope = .workspaces
            }
        }
    }

    private func applyScope(_ item: CompanionOverviewScope) {
        if var nav = navigation?.wrappedValue {
            nav.setScope(
                item, agents: model.agents, topology: model.topology,
                isConnected: model.isConnected, isConnecting: model.isConnecting)
            navigation?.wrappedValue = nav
        } else {
            localScope = item
        }
    }

    private func runningPeek(_ snapshot: CompanionOverviewSnapshot) -> [AgentRow] {
        CompanionOverviewSnapshot(
            agents: model.agents, topology: model.topology, scope: .running,
            query: search.wrappedValue, isConnected: model.isConnected,
            isConnecting: model.isConnecting).matchedRows
    }

    private func count(for scope: CompanionOverviewScope, snapshot: CompanionOverviewSnapshot) -> Int? {
        switch scope {
        case .attention:
            return snapshot.attentionFilterCount == 0 ? nil : snapshot.attentionFilterCount
        case .running: return snapshot.runningCount == 0 ? nil : snapshot.runningCount
        case .idle: return snapshot.inactiveCount == 0 ? nil : snapshot.inactiveCount
        case .workspaces:
            let count = model.topology?.workspaces.count ?? 0
            return count == 0 ? nil : count
        case .all:
            let count = snapshot.list.rows.count
            return count == 0 ? nil : count
        }
    }

    @ViewBuilder
    private func empty(_ title: String, _ image: String, _ detail: String, identifier: String? = nil) -> some View {
        Section {
            CompanionEmptyState(title: title, systemImage: image, detail: detail)
                .listRowBackground(Palette.ground)
                .accessibilityIdentifier(identifier ?? "overview-empty")
        }
    }

    @ViewBuilder
    private func workspaceRow(_ summary: CompanionWorkspaceSummary) -> some View {
        if let navigation {
            let selected = navigation.wrappedValue.isSelectedWorkspace(summary.workspace.workspaceID)
            Button {
                var nav = navigation.wrappedValue
                nav.selectWorkspace(summary.workspace.workspaceID)
                navigation.wrappedValue = nav
            } label: {
                WorkspaceRow(summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .listRowBackground(selected ? Palette.surfaceRaised : Palette.ground)
            .accessibilityIdentifier("workspaces-entry")
        } else {
            NavigationLink {
                WorkspaceDetailView(model: model, workspaceID: summary.workspace.workspaceID)
            } label: {
                WorkspaceRow(summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .listRowBackground(Palette.ground)
            .accessibilityIdentifier("workspaces-entry")
        }
    }

    @ViewBuilder
    private func agentRow(_ row: AgentRow) -> some View {
        let content = AgentRosterRow(
            row: row,
            workspaceName: CompanionWorkspaceTitle.display(
                workspaceID: row.info.workspaceID ?? "", in: model.topology),
            discriminator: deskDiscriminators(
                CompanionOverviewSnapshot(
                    agents: model.agents, topology: model.topology,
                    scope: scope.wrappedValue, query: search.wrappedValue,
                    isConnected: model.isConnected, isConnecting: model.isConnecting)
            )[row.info.paneID])
        let canFallback = model.transport != nil || model.terminalOpener != nil
        switch CompanionAgentTargeting.resolve(row: row, topology: model.topology, canFallback: canFallback) {
        case .live(let destination):
            let selected = navigation?.wrappedValue.isSelectedDestination(destination) == true
            HStack(spacing: 0) {
                Button { open(destination) } label: {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("companion-agent-\(row.info.paneID)")
                .accessibilityAddTraits(selected ? .isSelected : [])
                Menu {
                    Text(row.info.displayName)
                    if let workspace = CompanionWorkspaceTitle.display(
                        workspaceID: row.info.workspaceID ?? "", in: model.topology)
                    { Text(workspace) }
                    if let cwd = row.info.cwd, !cwd.isEmpty { Text(cwd) }
                    if !row.info.paneID.isEmpty { Text(row.info.paneID) }
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Palette.textFaint)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Full path and identity")
            }
            .listRowBackground(selected ? Palette.surfaceRaised : Palette.ground)

        case .fallbackAgent(let paneID):
            let owner = model.recoveryOwner
                ?? model.connectedSavedHost.map(CompanionInsertionOwner.init)
            if let transport = model.transport {
                NavigationLink {
                    CompanionTerminalScreen(
                        transport: transport,
                        title: row.info.displayName,
                        target: .agent(paneID: paneID),
                        insertionModel: model,
                        insertionOwner: owner)
                } label: { content }
                .listRowBackground(Palette.ground)
            } else if let opener = model.terminalOpener {
                NavigationLink {
                    CompanionTerminalScreen(
                        transport: nil,
                        opener: opener,
                        title: row.info.displayName,
                        target: .agent(paneID: paneID),
                        insertionModel: model,
                        insertionOwner: owner)
                } label: { content }
                .listRowBackground(Palette.ground)
            } else {
                content.foregroundStyle(Palette.textFaint).listRowBackground(Palette.ground)
            }
        case .stopped, .unavailable:
            content
                .foregroundStyle(Palette.textFaint)
                .listRowBackground(Palette.ground)
        }
    }

    private func open(_ destination: CompanionTerminalDestination) {
        if var nav = navigation?.wrappedValue {
            nav.selectVisibleRow(
                destination, agents: model.agents, topology: model.topology,
                isConnected: model.isConnected, isConnecting: model.isConnecting)
            navigation?.wrappedValue = nav
        } else {
            compactOpenedTerminal = destination
        }
    }

    private func deskDiscriminators(_ snapshot: CompanionOverviewSnapshot) -> [String: String] {
        var rows = snapshot.sections.flatMap(\.rows)
        if snapshot.deskPlace == .desk, snapshot.scope == .attention {
            rows += runningPeek(snapshot)
        }
        let items = rows.map {
            CompanionTargetContext(
                title: $0.info.displayName,
                workspace: CompanionWorkspaceTitle.display(
                    workspaceID: $0.info.workspaceID ?? "", in: model.topology),
                path: $0.info.cwd,
                paneID: $0.info.paneID)
        }
        return CompanionTargetContext.discriminators(for: items)
    }
}


private struct CompanionVisiblePathMeta: View {
    var lead: String? = nil
    var path: String? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    inline
                    stacked
                }
            }
        }
        .font(Typography.app(12))
        .foregroundStyle(Palette.textDim)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var inline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let lead, !lead.isEmpty { Text(lead) }
            if let path, !path.isEmpty {
                if let lead, !lead.isEmpty { Text("·") }
                Text(path).font(Typography.machine(12))
            }
        }
        .lineLimit(1)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let lead, !lead.isEmpty {
                Text(lead)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            if let path, !path.isEmpty {
                Text(path)
                    .font(Typography.machine(12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AgentRosterRow: View {
    let row: AgentRow
    var workspaceName: String? = nil
    var discriminator: String? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var agent: AgentInfo { row.info }

    var body: some View {
        let title = Text(agent.displayName)
            .font(Typography.app(16, .semibold))
            .foregroundStyle(Palette.text)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
        let meta = CompanionVisiblePathMeta(
            lead: workspaceName,
            path: discriminator ?? CompanionPathLabel.folder(agent.cwd))
        let status = CompanionStatusBadge(group: row.group, compact: true)
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    title
                    status
                    meta
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        meta
                    }
                    Spacer(minLength: 8)
                    status
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Text(agent.displayName)
            if let workspaceName, !workspaceName.isEmpty { Text(workspaceName) }
            if let cwd = agent.cwd, !cwd.isEmpty { Text(cwd) }
            if !agent.paneID.isEmpty { Text(agent.paneID) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityDetail)
        .accessibilityHint("Long press for the full path")
    }

    private var accessibilityDetail: String {
        var parts: [String] = [agent.displayName]
        if let workspaceName, !workspaceName.isEmpty { parts.append(workspaceName) }
        if let cwd = agent.cwd, !cwd.isEmpty { parts.append(cwd) }
        if !agent.paneID.isEmpty { parts.append(agent.paneID) }
        return parts.joined(separator: ", ")
    }
}

struct WorkspaceBrowserView: View {
    @ObservedObject var model: CompanionConnectionModel
    @State private var showingNewWorkspace = false
    @State private var openedTerminal: CompanionTerminalDestination?

    var body: some View {
        let workspaces = model.topology?.workspaces.sorted { $0.number < $1.number } ?? []
        List {
            if let message = model.message {
                CompanionBanner(text: message, kind: .info).listRowBackground(Palette.ground)
            }
            if let message = model.topologyMessage {
                CompanionBanner(text: message, kind: .warning).listRowBackground(Palette.ground)
            }
            if model.topology == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading workspaces")
                }
                .font(Typography.app(14))
                .listRowBackground(Palette.ground)
            } else if workspaces.isEmpty {
                CompanionEmptyState(
                    title: "No workspaces",
                    systemImage: "rectangle.3.group",
                    detail: "Create a workspace to open a plain interactive terminal.")
                .listRowBackground(Palette.ground)
                .accessibilityIdentifier("workspaces-empty-state")
            } else {
                ForEach(workspaces) { workspace in
                    NavigationLink {
                        WorkspaceDetailView(model: model, workspaceID: workspace.workspaceID)
                    } label: {
                        WorkspaceRow(workspace: workspace)
                    }
                    .listRowBackground(Palette.ground)
                }
            }
        }
        .companionScreen()
        .navigationTitle("Workspaces")
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.acknowledgeUnknownMutation()
                    model.topologyMessage = nil
                    showingNewWorkspace = true
                } label: {
                    Label("New Workspace", systemImage: "plus")
                }
                .disabled(model.mutationInFlight != nil)
                .accessibilityIdentifier("new-workspace-button")
            }
        }
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceForm(
                model: model,
                initialCWD: CompanionCreationContext.workspaceFolder(from: model.topology)
            ) { destination in
                showingNewWorkspace = false
                openedTerminal = destination
            }
            .interactiveDismissDisabled(
                model.mutationInFlight != nil || model.mutationOutcomeUnknown)
        }
        .navigationDestination(item: $openedTerminal) { destination in
            CompanionTerminalHost(model: model, destination: destination)
        }
    }
}

struct WorkspaceRow: View {
    let workspace: WorkspaceInfo
    var needsYou: Int = 0
    var running: Int = 0
    var unknown: Int = 0
    var summary: String? = nil

    init(workspace: WorkspaceInfo, summary: String? = nil) {
        self.workspace = workspace
        self.summary = summary
    }

    init(_ summary: CompanionWorkspaceSummary) {
        self.workspace = summary.workspace
        self.needsYou = summary.needsYou
        self.running = summary.running
        self.unknown = summary.unknown
        self.summary = summary.subtitle
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let title = Text(CompanionWorkspaceTitle.display(workspace))
            .font(Typography.app(16, .semibold))
            .foregroundStyle(Palette.text)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
        let counts = Text(compactCounts)
            .font(Typography.app(12))
            .foregroundStyle(Palette.textDim)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
        let marks = HStack(spacing: 10) {
            if needsYou > 0 {
                CompanionCountMark(value: needsYou, label: "you", color: Palette.waiting)
            }
            if running > 0 {
                CompanionCountMark(value: running, label: "run", color: Palette.working)
            }
            if unknown > 0 {
                CompanionCountMark(value: unknown, label: "?", color: Palette.waiting)
            }
        }
        .accessibilityElement(children: .combine)
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    title
                    counts
                    marks
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        counts
                    }
                    Spacer(minLength: 8)
                    marks
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Text(CompanionWorkspaceTitle.display(workspace))
            Text(compactCounts)
            Text(workspace.workspaceID)
        }
        .accessibilityElement(children: .combine)
    }

    private var compactCounts: String {
        let tabs = workspace.tabCount == 1 ? "1 tab" : "\(workspace.tabCount) tabs"
        let terms = workspace.paneCount == 1 ? "1 terminal" : "\(workspace.paneCount) terminals"
        return "\(tabs) · \(terms)"
    }
}

struct WorkspaceDetailView: View {
    private enum Sheet: Identifiable {
        case tab
        case split(TopologyPaneInfo)

        var id: String {
            switch self {
            case .tab: "tab"
            case .split(let pane): "split:\(pane.paneID)"
            }
        }
    }

    @ObservedObject var model: CompanionConnectionModel
    let workspaceID: String
    var onReveal: ((CompanionTerminalDestination) -> Void)? = nil
    @Environment(\.companionSplitBrowser) private var splitBrowser
    @State private var sheet: Sheet?
    @State private var localOpenedTerminal: CompanionTerminalDestination?

    private var workspace: WorkspaceInfo? {
        model.topology?.workspaces.first { $0.workspaceID == workspaceID }
    }

    private var tabs: [TabInfo] {
        (model.topology?.tabs ?? [])
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.number < $1.number }
    }

    private func panes(in tabID: String) -> [TopologyPaneInfo] {
        (model.topology?.panes ?? [])
            .filter { $0.workspaceID == workspaceID && $0.tabID == tabID }
    }

    var body: some View {
        List {
            if let workspace {
                Section {
                    Text("\(workspace.tabCount) tabs · \(workspace.paneCount) terminals")
                        .font(Typography.app(13))
                        .foregroundStyle(Palette.textDim)
                        .listRowBackground(Palette.ground)
                        .listRowSeparator(.hidden)
                }
            }
            if let message = model.message {
                CompanionBanner(text: message, kind: .info).listRowBackground(Palette.ground)
            }
            if let message = model.topologyMessage {
                CompanionBanner(text: message, kind: .warning).listRowBackground(Palette.ground)
            }
            if workspace == nil {
                CompanionEmptyState(
                    title: "Workspace unavailable",
                    systemImage: "rectangle.3.group.slash",
                    detail: "Refresh to check whether it still exists.")
                .listRowBackground(Palette.ground)
            } else if tabs.isEmpty {
                CompanionEmptyState(
                    title: "No terminal tabs",
                    systemImage: "macwindow.badge.plus",
                    detail: "Create a terminal tab to start a plain shell.")
                .listRowBackground(Palette.ground)
            } else {
                ForEach(tabs) { tab in
                    Section {
                        if panes(in: tab.tabID).isEmpty {
                            Text("No terminal panes")
                                .font(Typography.app(13))
                                .foregroundStyle(Palette.textFaint)
                        }
                        ForEach(panes(in: tab.tabID)) { pane in
                            if let destination = CompanionTerminalDestination(pane: pane) {
                                HStack(spacing: 8) {
                                    paneLink(destination, pane: pane)
                                    Menu {
                                        Button {
                                            model.acknowledgeUnknownMutation()
                                            model.topologyMessage = nil
                                            sheet = .split(pane)
                                        } label: {
                                            Label("Split Pane", systemImage: "rectangle.split.2x1")
                                        }
                                        Text(destination.title)
                                        if let cwd = pane.effectiveCWD, !cwd.isEmpty {
                                            Text(cwd)
                                        }
                                        Text(pane.paneID)
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                            .frame(minWidth: 44, minHeight: 44)
                                    }
                                    .accessibilityLabel("Actions for \(destination.title)")
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text(CompanionWorkspaceTitle.tab(tab))
                            Spacer()
                            Text(tab.paneCount == 1 ? "1 pane" : "\(tab.paneCount) panes")
                                .font(Typography.app(12))
                                .foregroundStyle(Palette.textFaint)
                        }
                    }
                }
            }
        }
        .companionScreen()
        .navigationTitle(workspace.map(CompanionWorkspaceTitle.display) ?? "Workspace")
        .refreshable { await model.refresh() }
        .toolbar {
            if let splitBrowser, splitBrowser.browsing {
                ToolbarItem(placement: .topBarLeading) {
                    CompanionSplitBrowserControl(browsing: true, action: splitBrowser.toggle)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.acknowledgeUnknownMutation()
                    model.topologyMessage = nil
                    sheet = .tab
                } label: {
                    Label("New Terminal Tab", systemImage: "plus")
                }
                .disabled(workspace == nil || model.mutationInFlight != nil)
                .accessibilityIdentifier("new-terminal-tab-button")
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .tab:
                NewTerminalTabForm(
                    model: model, workspaceID: workspaceID,
                    initialCWD: CompanionCreationContext.tabFolder(
                        from: model.topology, workspaceID: workspaceID)
                ) { destination in
                    sheet = nil
                    open(destination)
                }
                .interactiveDismissDisabled(
                    model.mutationInFlight != nil || model.mutationOutcomeUnknown)
            case .split(let pane):
                SplitPaneForm(model: model, pane: pane) { destination in
                    sheet = nil
                    open(destination)
                }
                .interactiveDismissDisabled(
                    model.mutationInFlight != nil || model.mutationOutcomeUnknown)
            }
        }
        .navigationDestination(item: $localOpenedTerminal) { destination in
            CompanionTerminalHost(model: model, destination: destination)
        }
    }

    @ViewBuilder
    private func paneLink(_ destination: CompanionTerminalDestination, pane: TopologyPaneInfo) -> some View {
        if let onReveal {
            Button { onReveal(destination) } label: {
                WorkspacePaneRow(
                    pane: pane, agents: model.agents,
                    discriminator: paneDiscriminators[pane.paneID])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("companion-pane-\(pane.paneID)")
            .listRowBackground(Palette.ground)
        } else {
            NavigationLink {
                CompanionTerminalHost(model: model, destination: destination)
            } label: {
                WorkspacePaneRow(
                    pane: pane, agents: model.agents,
                    discriminator: paneDiscriminators[pane.paneID])
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("companion-pane-\(pane.paneID)")
        }
    }

    private func open(_ destination: CompanionTerminalDestination) {
        if let onReveal {
            onReveal(destination)
        } else {
            localOpenedTerminal = destination
        }
    }

    private var paneDiscriminators: [String: String] {
        let panes = (model.topology?.panes ?? []).filter { $0.workspaceID == workspaceID }
        let items = panes.map {
            CompanionTargetContext(
                title: CompanionTerminalDestination(pane: $0)?.title ?? "Terminal",
                workspace: workspace.map(CompanionWorkspaceTitle.display),
                path: $0.effectiveCWD,
                paneID: $0.paneID)
        }
        return CompanionTargetContext.discriminators(for: items)
    }
}

struct WorkspacePaneRow: View {
    let pane: TopologyPaneInfo

    private var title: String {
        CompanionTerminalDestination(pane: pane)?.title ?? "Terminal"
    }

    var agents: [AgentInfo] = []
    var discriminator: String? = nil

    private var group: AgentGroup {
        if let agent = agents.first(where: { $0.paneID == pane.paneID }) {
            return AgentRow(info: agent, isLive: true).group
        }
        return .idle
    }

    @ViewBuilder
    private var statusMark: some View {
        if pane.isAgent {
            CompanionStatusBadge(group: group, compact: true)
        } else {
            Text("Shell")
                .font(Typography.app(12, .semibold))
                .foregroundStyle(Palette.textFaint)
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let name = Text(title)
            .font(Typography.app(16, .semibold))
            .foregroundStyle(Palette.text)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
        let meta = CompanionVisiblePathMeta(
            lead: pane.isAgent ? "Agent" : "Shell",
            path: discriminator ?? CompanionPathLabel.folder(pane.effectiveCWD))
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    name
                    statusMark
                    meta
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        name
                        meta
                    }
                    Spacer(minLength: 8)
                    statusMark
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Text(title)
            if let cwd = pane.effectiveCWD, !cwd.isEmpty { Text(cwd) }
            Text(pane.paneID)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue([title, pane.effectiveCWD, pane.paneID].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Long press for the full path")
    }
}
