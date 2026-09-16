import XCTest
import UIKit
import SwiftUI
import HerdrKit
@testable import HerdrCompanion

final class CompanionOverviewTests: XCTestCase {
    func testAttentionFilterSurfacesBlockedAndUnknownSeparatelyFromRunning() throws {
        let topology = try Self.topology()
        let snapshot = CompanionOverviewSnapshot(
            agents: topology.agents, topology: topology, scope: .attention,
            query: "", isConnected: true, isConnecting: false)

        XCTAssertEqual(snapshot.vacancy, .none)
        XCTAssertEqual(snapshot.matchedRows.map(\.info.displayName), ["reviewer", "mystery-bot"])
        XCTAssertEqual(snapshot.sections.map(\.group), [.needsYou, .unrecognised])
        XCTAssertEqual(snapshot.attentionCount, 1)
        XCTAssertEqual(snapshot.unknownCount, 1)
        XCTAssertEqual(snapshot.attentionFilterCount, 2)
        XCTAssertEqual(snapshot.runningCount, 2)

        let running = CompanionOverviewSnapshot(
            agents: topology.agents, topology: topology, scope: .running,
            query: "", isConnected: true, isConnecting: false)
        XCTAssertEqual(Set(running.matchedRows.map(\.info.displayName)), ["calendar-bot", "docs-pass"])
        XCTAssertTrue(running.workspaces.isEmpty)
    }

    func testSearchMatchesWorkspaceLabelAndDoesNotInventCounts() throws {
        let topology = try Self.topology()
        let snapshot = CompanionOverviewSnapshot(
            agents: topology.agents, topology: topology, scope: .all,
            query: "Docs", isConnected: true, isConnecting: false)
        XCTAssertEqual(snapshot.workspaces.map(\.title), ["Docs"])
        XCTAssertEqual(snapshot.workspaces.first?.running, 1)
        XCTAssertEqual(snapshot.workspaces.first?.needsYou, 0)
        XCTAssertTrue(snapshot.matchedRows.contains { $0.info.displayName == "docs-pass" })
    }

    func testVacancyDistinguishesLoadingQuietEmptyAndNoMatches() throws {
        let topology = try Self.topology()
        XCTAssertEqual(
            CompanionOverviewSnapshot(
                agents: [], topology: nil, scope: .all,
                query: "", isConnected: false, isConnecting: true).vacancy,
            .connecting)
        XCTAssertEqual(
            CompanionOverviewSnapshot(
                agents: [], topology: nil, scope: .all,
                query: "", isConnected: true, isConnecting: false).vacancy,
            .loading)
        XCTAssertEqual(
            CompanionOverviewSnapshot(
                agents: [], topology: try Self.topology(workspaces: false),
                scope: .workspaces, query: "", isConnected: true, isConnecting: false).vacancy,
            .noWorkspaces)
        XCTAssertEqual(
            CompanionOverviewSnapshot(
                agents: [], topology: try Self.topology(agents: false),
                scope: .all, query: "", isConnected: true, isConnecting: false).vacancy,
            .noAgents)
        let attention = CompanionOverviewSnapshot(
            agents: topology.agents, topology: topology, scope: .attention,
            query: "", isConnected: true, isConnecting: false)
        XCTAssertEqual(attention.vacancy, .none)
        XCTAssertFalse(attention.matchedRows.isEmpty)
        let idleOnly = CompanionOverviewSnapshot(
            agents: topology.agents.filter { $0.agentStatus == "idle" },
            topology: topology, scope: .attention,
            query: "", isConnected: true, isConnecting: false)
        XCTAssertEqual(idleOnly.vacancy, .quiet)
        XCTAssertEqual(
            CompanionOverviewSnapshot(
                agents: topology.agents, topology: topology, scope: .all,
                query: "zzzz", isConnected: true, isConnecting: false).vacancy,
            .noMatches)
    }

    func testCreationContextUsesVisibleTopologyNotMacFocus() throws {
        let topology = try Self.topology()
        XCTAssertEqual(
            CompanionCreationContext.workspaceFolder(from: topology),
            "/Users/fixture/companion")
        XCTAssertEqual(
            CompanionCreationContext.tabFolder(from: topology, workspaceID: "workspace-docs"),
            "/Users/fixture/docs")
        let pane = try XCTUnwrap(topology.panes.first { $0.paneID == "pane-docs" })
        XCTAssertEqual(CompanionCreationContext.splitFolder(from: pane), "/Users/fixture/docs")
        XCTAssertNil(CompanionCreationContext.workspaceFolder(from: nil))
    }

    func testAgentAndPaneTargetsStayOnOfficialIdentities() throws {
        let topology = try Self.topology()
        let reviewer = try XCTUnwrap(topology.agents.first { $0.displayName == "reviewer" })
        XCTAssertEqual(CompanionCreationContext.agentPaneID(for: reviewer), "pane-reviewer")
        let shell = try XCTUnwrap(topology.panes.first { $0.paneID == "pane-shell" })
        XCTAssertFalse(shell.isAgent)
        let destination = try XCTUnwrap(CompanionTerminalDestination(pane: shell))
        XCTAssertEqual(destination.target, .terminal(terminalID: "term-shell"))
        let agentPane = try XCTUnwrap(topology.panes.first { $0.paneID == "pane-reviewer" })
        XCTAssertEqual(
            CompanionTerminalDestination(pane: agentPane)?.target,
            .agent(paneID: "pane-reviewer"))
    }

    func testDeskScopesStaySeparateFromWorkspacesDestination() throws {
        let topology = try Self.topology()
        XCTAssertEqual(
            CompanionOverviewScope.deskScopes,
            [.attention, .running, .idle, .all])
        XCTAssertEqual(CompanionOverviewScope.attention.deskPlace, .desk)
        XCTAssertEqual(CompanionOverviewScope.workspaces.deskPlace, .workspaces)
        XCTAssertFalse(
            CompanionOverviewSnapshot(
                agents: topology.agents, topology: topology, scope: .all,
                query: "", isConnected: true, isConnecting: false).showsWorkspaceList)
        XCTAssertTrue(
            CompanionOverviewSnapshot(
                agents: topology.agents, topology: topology, scope: .workspaces,
                query: "", isConnected: true, isConnecting: false).showsWorkspaceList)

        var navigation = CompanionSplitNavigationState()
        navigation.setDeskPlace(
            .workspaces, agents: topology.agents, topology: topology,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.scope, .workspaces)
        navigation.selectWorkspace("workspace-app")
        XCTAssertTrue(navigation.isSelectedWorkspace("workspace-app"))
        navigation.setDeskPlace(
            .desk, agents: topology.agents, topology: topology,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.scope, .attention)
        XCTAssertNil(navigation.selectedWorkspaceID)
    }

    func testMachineSemiboldUsesBundledPostScriptName() {
        XCTAssertEqual(UIFont(name: "IBMPlexMono-SmBld", size: 9)?.fontName, "IBMPlexMono-SmBld")
        XCTAssertNil(UIFont(name: "IBMPlexMono-SemiBold", size: 9))
    }

    func testAppTypographyUsesSemanticStylesNotFixedSizes() {
        XCTAssertEqual(Typography.textStyle(for: 11), .caption2)
        XCTAssertEqual(Typography.textStyle(for: 12), .caption)
        XCTAssertEqual(Typography.textStyle(for: 13), .footnote)
        XCTAssertEqual(Typography.textStyle(for: 16), .body)
        XCTAssertEqual(Typography.textStyle(for: 18), .title3)
    }

    func testAllSearchVacancyIgnoresHiddenWorkspaceMatches() throws {
        let topology = try Self.topology()
        let emptyName = CompanionOverviewSnapshot(
            agents: topology.agents, topology: topology, scope: .all,
            query: "zzzz-no-agent", isConnected: true, isConnecting: false)
        XCTAssertTrue(emptyName.matchedRows.isEmpty)
        XCTAssertEqual(emptyName.vacancy, .noMatches)
        XCTAssertFalse(emptyName.showsWorkspaceList)

        let workspaceOnly = CompanionOverviewSnapshot(
            agents: topology.agents.filter { $0.workspaceID != "workspace-docs" },
            topology: topology, scope: .all,
            query: "Docs", isConnected: true, isConnecting: false)
        XCTAssertTrue(workspaceOnly.matchedRows.isEmpty, "no Docs agents remain")
        XCTAssertFalse(workspaceOnly.workspaces.isEmpty)
        XCTAssertEqual(workspaceOnly.vacancy, .noMatches)

        let workspacePlace = CompanionOverviewSnapshot(
            agents: topology.agents, topology: topology, scope: .workspaces,
            query: "Docs", isConnected: true, isConnecting: false)
        XCTAssertEqual(workspacePlace.vacancy, .none)
        XCTAssertEqual(workspacePlace.workspaces.map(\.title), ["Docs"])
    }

    func testRunningPeekSelectionSurvivesPublication() throws {
        let topology = try Self.topology()
        let calendar = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-calendar" })))
        var navigation = CompanionSplitNavigationState()
        XCTAssertEqual(navigation.scope, .attention)
        navigation.selectVisibleRow(
            calendar, agents: topology.agents, topology: topology,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.scope, .all)
        XCTAssertTrue(navigation.focusedTerminal)
        navigation.reconcile(
            topology: topology, agents: topology.agents,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-calendar")

        let docs = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-docs" })))
        navigation.scope = .attention
        navigation.selectVisibleRow(
            docs, agents: topology.agents, topology: topology,
            isConnected: true, isConnecting: false)
        navigation.reconcile(
            topology: topology, agents: topology.agents,
            isConnected: true, isConnecting: false)
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-docs")

        let gone = topology.agents.filter { $0.paneID != "pane-docs" }
        navigation.reconcile(
            topology: topology, agents: gone,
            isConnected: true, isConnecting: false)
        XCTAssertNil(navigation.openedTerminal)
    }

    func testRevealTerminalFocusesSameTargetWithoutClearingWorkspace() throws {
        let topology = try Self.topology()
        let shell = try XCTUnwrap(
            CompanionTerminalDestination(pane: try XCTUnwrap(topology.panes.first { $0.paneID == "pane-shell" })))
        var navigation = CompanionSplitNavigationState()
        navigation.selectWorkspace("workspace-app")
        navigation.revealTerminal(shell, keepingWorkspace: true)
        XCTAssertTrue(navigation.focusedTerminal)
        XCTAssertTrue(navigation.isSelectedWorkspace("workspace-app"))
        navigation.focusedTerminal = false
        navigation.revealTerminal(shell, keepingWorkspace: true)
        XCTAssertTrue(navigation.focusedTerminal)
        XCTAssertEqual(navigation.openedTerminal?.pane.paneID, "pane-shell")
    }

    func testCollidingLeafFoldersExposeUniqueSuffix() {
        let a = CompanionTargetContext(
            title: "zsh", workspace: "App", path: "/Users/fixture/ios/companion", paneID: "pane-a")
        let b = CompanionTargetContext(
            title: "zsh", workspace: "App", path: "/Users/fixture/mac/companion", paneID: "pane-b")
        let map = CompanionTargetContext.discriminators(for: [a, b])
        XCTAssertEqual(map["pane-a"], "ios/companion")
        XCTAssertEqual(map["pane-b"], "mac/companion")
        let unique = CompanionTargetContext(
            title: "docs-pass", workspace: "Docs", path: "/Users/fixture/docs", paneID: "pane-docs")
        XCTAssertTrue(CompanionTargetContext.discriminators(for: [unique]).isEmpty)
    }

    func testMixedDuplicatePathsKeepDistinctPaneHints() {
        let a1 = CompanionTargetContext(
            title: "zsh", workspace: "App", path: "/Users/a/companion", paneID: "pane-aaaaaa")
        let a2 = CompanionTargetContext(
            title: "zsh", workspace: "App", path: "/Users/a/companion", paneID: "pane-bbbbbb")
        let b = CompanionTargetContext(
            title: "zsh", workspace: "App", path: "/Users/b/companion", paneID: "pane-cccccc")
        let map = CompanionTargetContext.discriminators(for: [a1, a2, b])
        XCTAssertNotEqual(map["pane-aaaaaa"], map["pane-bbbbbb"])
        XCTAssertNotEqual(map["pane-aaaaaa"], map["pane-cccccc"])
        XCTAssertNotEqual(map["pane-bbbbbb"], map["pane-cccccc"])
        XCTAssertNotNil(map["pane-aaaaaa"])
        XCTAssertNotNil(map["pane-bbbbbb"])
        XCTAssertNotNil(map["pane-cccccc"])
    }

    func testIdenticalCwdPairUsesDistinctPaneHints() {
        let a = CompanionTargetContext(
            title: "zsh", workspace: "App", path: "/same/path", paneID: "id-aaaaaa")
        let b = CompanionTargetContext(
            title: "zsh", workspace: "App", path: "/same/path", paneID: "id-bbbbbb")
        let map = CompanionTargetContext.discriminators(for: [a, b])
        XCTAssertEqual(Set(map.values).count, 2)
        XCTAssertNotEqual(map["id-aaaaaa"], map["id-bbbbbb"])
    }

    func testTruncatedLongTitlesWithSharedFolderGetDiscriminators() {
        let a = CompanionTargetContext(
            title: "Very Long Agent Title Alpha", workspace: "App",
            path: "/proj/ios/src", paneID: "pane-long-a")
        let b = CompanionTargetContext(
            title: "Very Long Agent Title Beta", workspace: "App",
            path: "/proj/mac/src", paneID: "pane-long-b")
        XCTAssertEqual(
            CompanionPathLabel.visiblePrefix(a.title),
            CompanionPathLabel.visiblePrefix(b.title))
        let map = CompanionTargetContext.discriminators(for: [a, b])
        XCTAssertEqual(map["pane-long-a"], "ios/src")
        XCTAssertEqual(map["pane-long-b"], "mac/src")
    }

    func testWideGlyphTitlesDifferingBeforeCutoffGetLayoutSuffix() {
        let a = CompanionTargetContext(
            title: "WWWWWWWWWA terminal", workspace: "Companion App",
            path: "/proj/a/src", paneID: "pane-wide-a")
        let b = CompanionTargetContext(
            title: "WWWWWWWWWB terminal", workspace: "Companion App",
            path: "/proj/b/src", paneID: "pane-wide-b")
        XCTAssertNotEqual(a.title, b.title)
        XCTAssertNotEqual(
            CompanionPathLabel.visiblePrefix(a.title),
            CompanionPathLabel.visiblePrefix(b.title))
        XCTAssertNotEqual(a.path, b.path)
        XCTAssertEqual(a.folder, b.folder)
        XCTAssertEqual(a.layoutIdentity, b.layoutIdentity)
        let map = CompanionTargetContext.discriminators(for: [a, b])
        XCTAssertEqual(map["pane-wide-a"], "a/src")
        XCTAssertEqual(map["pane-wide-b"], "b/src")
        XCTAssertNotEqual(map["pane-wide-a"], map["pane-wide-b"])
        XCTAssertTrue(map["pane-wide-a"]?.hasPrefix("a/") == true)
        XCTAssertTrue(map["pane-wide-b"]?.hasPrefix("b/") == true)
    }

    func testLongSharedParentSuffixDiffersAfterCommonPrefix() {
        let token = String(repeating: "a", count: 32)
        let a = CompanionTargetContext(
            title: "long-parent", workspace: "Companion App",
            path: "/proj/\(token)A/src", paneID: "pane-long-parent-a")
        let b = CompanionTargetContext(
            title: "long-parent", workspace: "Companion App",
            path: "/proj/\(token)B/src", paneID: "pane-long-parent-b")
        XCTAssertEqual(a.layoutIdentity, b.layoutIdentity)
        let map = CompanionTargetContext.discriminators(for: [a, b])
        XCTAssertEqual(map["pane-long-parent-a"], "\(token)A/src")
        XCTAssertEqual(map["pane-long-parent-b"], "\(token)B/src")
        XCTAssertTrue(map["pane-long-parent-a"]?.hasSuffix("A/src") == true)
        XCTAssertTrue(map["pane-long-parent-b"]?.hasSuffix("B/src") == true)
    }

    func testLongNearEqualLeavesAreNotLayoutGrouped() {
        let token = String(repeating: "a", count: 32)
        let a = CompanionTargetContext(
            title: "long-leaf", workspace: "Companion App",
            path: "/proj/\(token)A", paneID: "pane-long-leaf-a")
        let b = CompanionTargetContext(
            title: "long-leaf", workspace: "Companion App",
            path: "/proj/\(token)B", paneID: "pane-long-leaf-b")
        XCTAssertNotEqual(a.folder, b.folder)
        XCTAssertNotEqual(a.layoutIdentity, b.layoutIdentity)
        XCTAssertTrue(CompanionTargetContext.discriminators(for: [a, b]).isEmpty)
        XCTAssertEqual(a.folder, "\(token)A")
        XCTAssertEqual(b.folder, "\(token)B")
    }

    func testPaneHintGrowsWhenTrailingSixCharactersCollide() {
        let hint = CompanionTargetContext.uniquePaneHint(
            paneID: "xxAAAAAA", among: ["yyAAAAAA", "zzBBBBBB"])
        XCTAssertEqual(hint, "xAAAAAA")
        XCTAssertGreaterThan(hint.count, 6)
    }

    func testFullContextIncludesTitleWorkspacePathAndPane() {
        let ctx = CompanionTargetContext(
            title: "reviewer", workspace: "Companion App",
            path: "/Users/fixture/companion", paneID: "pane-reviewer")
        XCTAssertTrue(ctx.fullContext.contains("reviewer"))
        XCTAssertTrue(ctx.fullContext.contains("Companion App"))
        XCTAssertTrue(ctx.fullContext.contains("/Users/fixture/companion"))
        XCTAssertTrue(ctx.fullContext.contains("pane-reviewer"))
    }

    func testStoppedAgentIsIdleFilterNotAttention() throws {
        let topology = try Self.topology()
        let idle = CompanionOverviewSnapshot(
            agents: topology.agents, topology: topology, scope: .idle,
            query: "", isConnected: true, isConnecting: false)
        XCTAssertTrue(idle.matchedRows.contains { $0.info.displayName == "idle-notes" })
        XCTAssertEqual(idle.matchedRows.first { $0.info.displayName == "idle-notes" }?.group, .stopped)
    }

    static func topology(
        agents: Bool = true, workspaces: Bool = true,
        reviewerWorking: Bool = false, replacedShell: Bool = false, shellBecameAgent: Bool = false
    ) throws -> SessionTopology {
        let json: String
        if !workspaces {
            json = #"{"version":"0.9.0","protocol":22,"workspaces":[],"tabs":[],"panes":[],"agents":[]}"#
        } else if !agents {
            json = #"{"version":"0.9.0","protocol":22,"workspaces":[{"workspace_id":"workspace-app","number":1,"label":"Companion App","focused":true,"pane_count":1,"tab_count":1,"active_tab_id":"tab-app","agent_status":"unknown"}],"tabs":[{"tab_id":"tab-app","workspace_id":"workspace-app","number":1,"label":"shells","focused":true,"pane_count":1,"agent_status":"unknown"}],"panes":[{"pane_id":"pane-shell","terminal_id":"term-shell","workspace_id":"workspace-app","tab_id":"tab-app","focused":true,"cwd":"/Users/fixture/companion","foreground_cwd":"/Users/fixture/companion","label":"zsh","agent_status":"unknown","revision":1}],"agents":[]}"#
        } else {
            json = #"{"version":"0.9.0","protocol":22,"focused_workspace_id":"workspace-app","focused_tab_id":"tab-app","focused_pane_id":"pane-reviewer","workspaces":[{"workspace_id":"workspace-app","number":1,"label":"Companion App","focused":true,"pane_count":4,"tab_count":2,"active_tab_id":"tab-app","agent_status":"blocked"},{"workspace_id":"workspace-docs","number":2,"label":"Docs","focused":false,"pane_count":1,"tab_count":1,"active_tab_id":"tab-docs","agent_status":"working"}],"tabs":[{"tab_id":"tab-app","workspace_id":"workspace-app","number":1,"label":"review","focused":true,"pane_count":3,"agent_status":"blocked"},{"tab_id":"tab-shell","workspace_id":"workspace-app","number":2,"label":"shell","focused":false,"pane_count":1,"agent_status":"unknown"},{"tab_id":"tab-docs","workspace_id":"workspace-docs","number":1,"label":"notes","focused":false,"pane_count":1,"agent_status":"working"}],"panes":[{"pane_id":"pane-reviewer","terminal_id":"term-reviewer","workspace_id":"workspace-app","tab_id":"tab-app","focused":true,"cwd":"/Users/fixture/companion","foreground_cwd":"/Users/fixture/companion","agent":"codex","display_agent":"Codex","agent_status":"blocked","revision":4},{"pane_id":"pane-calendar","terminal_id":"term-calendar","workspace_id":"workspace-app","tab_id":"tab-app","focused":false,"cwd":"/Users/fixture/companion","agent":"claude","display_agent":"Claude","agent_status":"working","revision":3},{"pane_id":"pane-mystery","terminal_id":"term-mystery","workspace_id":"workspace-app","tab_id":"tab-app","focused":false,"cwd":"/Users/fixture/companion","agent":"gemini","display_agent":"Gemini","agent_status":"unknown","revision":1},{"pane_id":"pane-shell","terminal_id":"term-shell","workspace_id":"workspace-app","tab_id":"tab-shell","focused":false,"cwd":"/Users/fixture/companion","label":"zsh","agent_status":"unknown","revision":1},{"pane_id":"pane-docs","terminal_id":"term-docs","workspace_id":"workspace-docs","tab_id":"tab-docs","focused":false,"cwd":"/Users/fixture/docs","agent":"codex","display_agent":"Codex","agent_status":"working","revision":2}],"agents":[{"terminal_id":"term-reviewer","name":"reviewer","agent":"codex","agent_status":"blocked","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-reviewer","cwd":"/Users/fixture/companion","revision":4},{"terminal_id":"term-calendar","name":"calendar-bot","agent":"claude","agent_status":"working","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-calendar","cwd":"/Users/fixture/companion","revision":3},{"terminal_id":"term-mystery","name":"mystery-bot","agent":"gemini","agent_status":"unknown","workspace_id":"workspace-app","tab_id":"tab-app","pane_id":"pane-mystery","cwd":"/Users/fixture/companion","revision":1},{"terminal_id":"term-docs","name":"docs-pass","agent":"codex","agent_status":"working","workspace_id":"workspace-docs","tab_id":"tab-docs","pane_id":"pane-docs","cwd":"/Users/fixture/docs","revision":2},{"terminal_id":"term-idle","name":"idle-notes","agent":"codex","agent_status":"idle","workspace_id":"workspace-docs","tab_id":"tab-docs","pane_id":"pane-missing","cwd":"/Users/fixture/docs","revision":1}]}"#
        }
        var mutated = json
        if reviewerWorking {
            mutated = mutated.replacingOccurrences(
                of: "\"name\":\"reviewer\",\"agent\":\"codex\",\"agent_status\":\"blocked\"",
                with: "\"name\":\"reviewer\",\"agent\":\"codex\",\"agent_status\":\"working\"")
            mutated = mutated.replacingOccurrences(
                of: "\"agent\":\"codex\",\"display_agent\":\"Codex\",\"agent_status\":\"blocked\",\"revision\":4",
                with: "\"agent\":\"codex\",\"display_agent\":\"Codex\",\"agent_status\":\"working\",\"revision\":4")
        }
        if replacedShell {
            mutated = mutated.replacingOccurrences(of: "\"terminal_id\":\"term-shell\"", with: "\"terminal_id\":\"term-shell-replaced\"")
        }
        if shellBecameAgent {
            mutated = mutated.replacingOccurrences(
                of: "\"pane_id\":\"pane-shell\",\"terminal_id\":\"term-shell\",\"workspace_id\":\"workspace-app\",\"tab_id\":\"tab-shell\",\"focused\":false,\"cwd\":\"/Users/fixture/companion\",\"label\":\"zsh\",\"agent_status\":\"unknown\",\"revision\":1",
                with: "\"pane_id\":\"pane-shell\",\"terminal_id\":\"term-shell\",\"workspace_id\":\"workspace-app\",\"tab_id\":\"tab-shell\",\"focused\":false,\"cwd\":\"/Users/fixture/companion\",\"agent\":\"codex\",\"display_agent\":\"Codex\",\"agent_status\":\"working\",\"revision\":1")
        }
        return try JSONDecoder().decode(SessionTopology.self, from: Data(mutated.utf8))
    }
}
