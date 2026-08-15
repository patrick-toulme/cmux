import AppKit
import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure mapping coverage for the zero-install remote agent-activity heuristic:
/// `#{pane_current_command}` → allowlisted lifecycle status key.
@Suite struct RemoteTmuxAgentActivityClassifierTests {
    @Test func recognizesAgentBasenames() {
        #expect(RemoteTmuxAgentActivityClassifier.lifecycleStatusKey(forCommand: "opencode") == "opencode")
        #expect(RemoteTmuxAgentActivityClassifier.lifecycleStatusKey(forCommand: "claude") == "claude_code")
        #expect(RemoteTmuxAgentActivityClassifier.lifecycleStatusKey(forCommand: "codex") == "codex")
        #expect(RemoteTmuxAgentActivityClassifier.lifecycleStatusKey(forCommand: "cursor-agent") == "cursor")
    }

    @Test func stripsPathAndNormalizesCase() {
        #expect(RemoteTmuxAgentActivityClassifier.lifecycleStatusKey(forCommand: "/usr/local/bin/opencode") == "opencode")
        #expect(RemoteTmuxAgentActivityClassifier.lifecycleStatusKey(forCommand: "OpenCode") == "opencode")
    }

    @Test func ignoresShellsAndUnknownCommands() {
        for command in ["bash", "zsh", "fish", "-zsh", "vim", "htop", "ssh", ""] {
            #expect(RemoteTmuxAgentActivityClassifier.lifecycleStatusKey(forCommand: command) == nil, "\(command)")
        }
    }

    /// Wrapper runtimes must never classify: a `node` dev server or `python`
    /// script would spin the sidebar forever. Wrapped agents get their
    /// fidelity from the opencode plugin instead.
    @Test func ignoresWrapperRuntimes() {
        for command in ["node", "bun", "python", "python3", "deno"] {
            #expect(RemoteTmuxAgentActivityClassifier.lifecycleStatusKey(forCommand: command) == nil, "\(command)")
        }
    }

    /// Agents without an allowlisted lifecycle key are dropped: their entries
    /// would fail socket-side validation and read as sidebar noise.
    @Test func dropsAgentsWithoutAllowlistedKeys() {
        #expect(RemoteTmuxAgentActivityClassifier.statusKey(forDefinitionId: "claude") == "claude_code")
        #expect(RemoteTmuxAgentActivityClassifier.statusKey(forDefinitionId: "opencode") == "opencode")
        #expect(RemoteTmuxAgentActivityClassifier.statusKey(forDefinitionId: "campfire") == nil)
        #expect(RemoteTmuxAgentActivityClassifier.statusKey(forDefinitionId: "ollama") == nil)
        #expect(RemoteTmuxAgentActivityClassifier.statusKey(forDefinitionId: "not-an-agent") == nil)
    }

    /// Every classifiable key must survive the socket allowlist, or the
    /// heuristic would publish entries `set_agent_lifecycle` rejects.
    @Test func everyClassifiedKeyIsAllowlisted() {
        for definition in CmuxTaskManagerCodingAgentDefinition.builtIns {
            for basename in definition.directBasenames {
                guard let key = RemoteTmuxAgentActivityClassifier.lifecycleStatusKey(forCommand: basename) else { continue }
                #expect(AgentHibernationLifecycleStatusKeys.isAllowed(key), "\(basename) → \(key)")
            }
        }
    }
}

/// A connected, in-process two-pane tmux mirror (window @2, panes %4/%5)
/// for remote agent-activity behavior tests. `beforeTopology` runs after the
/// mirror starts observing but BEFORE the window/pane topology arrives, so
/// tests can stage pre-attach foreground classifications.
@MainActor
private final class RemoteTmuxAgentActivityHarness {
    let windowID: UUID
    let controller: RemoteTmuxController
    let host: RemoteTmuxHost
    let sessionName: String
    let connection: RemoteTmuxControlConnection
    let writer: RemoteTmuxControlPipeWriter
    let pipe: Pipe
    let workspace: Workspace

    init(beforeTopology: ((RemoteTmuxControlConnection) -> Void)? = nil) throws {
        let appDelegate = try #require(AppDelegate.shared)
        windowID = appDelegate.createMainWindow()
        let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
        controller = appDelegate.remoteTmuxController
        host = RemoteTmuxHost(destination: "agent-activity-\(UUID().uuidString)@host")
        sessionName = "dogfood-agent-activity"
        connection = RemoteTmuxControlConnection(host: host, sessionName: sessionName)
        pipe = Pipe()
        writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-agent-activity-test",
            maxPendingBytes: 1 << 16,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(
            .commandResult(commandNumber: 0, lines: [], isError: false)
        )
        controller.cacheConnection(connection)
        try controller.mirrorSession(
            host: host,
            sessionName: sessionName,
            into: manager
        )
        workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })

        beforeTopology?(connection)

        connection.handleMessageForTesting(.commandResult(
            commandNumber: 1,
            lines: [
                "@2 abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} "
                    + "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5} [] main",
            ],
            isError: false
        ))
        while let kind = connection.pendingCommandKindsForTesting.first {
            let lines: [String]
            switch kind {
            case .paneRects:
                lines = [
                    "%4 0 0 60 40 1 off :0 \"remote-host\"",
                    "%5 61 0 59 40 0 off :1 \"remote-host\"",
                ]
            case .paneReflow(let paneId):
                // Real tmux reports the pane's LIVE foreground command in the
                // one-shot seed query; echo any staged classification instead
                // of an empty (= unparseable) value that would overwrite it.
                let state = connection.paneForegroundStates[paneId]
                lines = ["\(state?.alternateOn == true ? "1" : "0")|\(state?.command ?? "zsh")"]
            default:
                lines = []
            }
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 2, lines: lines, isError: false)
            )
        }
    }

    func panelId(forPane paneId: Int) throws -> UUID {
        let mirror = try #require(
            controller.sessionMirrors.values.first {
                $0.host.connectionHash == host.connectionHash && $0.sessionName == sessionName
            }
        )
        let windowId = try #require(mirror.windowIdByPane[paneId])
        return try #require(mirror.windowMirrorByWindowId[windowId]?.panelsByPaneId[paneId]).id
    }

    func lifecycle(panelId: UUID, key: String) -> AgentHibernationLifecycleState? {
        workspace.agentLifecycleStatesByPanelId[panelId]?[key]
    }

    func emitForeground(paneId: Int, rawValue: String) {
        connection.classifyAndEmitReflow(paneId: paneId, rawValue: rawValue, source: "test")
    }

    func tearDown() {
        controller.detach(host: host, sessionName: sessionName)
        writer.close()
        try? pipe.fileHandleForReading.close()
        let identifier = "cmux.main.\(windowID.uuidString)"
        NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
    }
}

/// Behavior coverage for the remote agent-activity pipeline: foreground
/// classifications driving per-panel lifecycle entries, and the pane→UUID
/// resolution the remote agent bridge's plugin depends on.
@MainActor
@Suite(.serialized)
struct RemoteTmuxAgentActivityMirrorTests {
    @Test func foregroundAgentSetsAndClearsPanelLifecycle() throws {
        let harness = try RemoteTmuxAgentActivityHarness()
        defer { harness.tearDown() }
        let panelId = try harness.panelId(forPane: 4)

        harness.emitForeground(paneId: 4, rawValue: "0|opencode")
        #expect(harness.lifecycle(panelId: panelId, key: "opencode") == .running)

        harness.emitForeground(paneId: 4, rawValue: "0|zsh")
        #expect(harness.lifecycle(panelId: panelId, key: "opencode") == nil)
    }

    @Test func switchingAgentsSwapsLifecycleKeys() throws {
        let harness = try RemoteTmuxAgentActivityHarness()
        defer { harness.tearDown() }
        let panelId = try harness.panelId(forPane: 4)

        harness.emitForeground(paneId: 4, rawValue: "0|claude")
        #expect(harness.lifecycle(panelId: panelId, key: "claude_code") == .running)

        harness.emitForeground(paneId: 4, rawValue: "0|opencode")
        #expect(harness.lifecycle(panelId: panelId, key: "claude_code") == nil)
        #expect(harness.lifecycle(panelId: panelId, key: "opencode") == .running)
    }

    @Test func panesTrackLifecycleIndependently() throws {
        let harness = try RemoteTmuxAgentActivityHarness()
        defer { harness.tearDown() }
        let firstPanel = try harness.panelId(forPane: 4)
        let secondPanel = try harness.panelId(forPane: 5)

        harness.emitForeground(paneId: 4, rawValue: "0|opencode")
        harness.emitForeground(paneId: 5, rawValue: "0|claude")
        #expect(harness.lifecycle(panelId: firstPanel, key: "opencode") == .running)
        #expect(harness.lifecycle(panelId: secondPanel, key: "claude_code") == .running)

        harness.emitForeground(paneId: 5, rawValue: "0|zsh")
        #expect(harness.lifecycle(panelId: firstPanel, key: "opencode") == .running)
        #expect(harness.lifecycle(panelId: secondPanel, key: "claude_code") == nil)
    }

    /// Richer states published for the SAME key by the opencode plugin must
    /// survive foreground churn that does not change the classification
    /// (e.g. the agent toggling the alternate screen).
    @Test func unchangedClassificationPreservesPluginPublishedState() throws {
        let harness = try RemoteTmuxAgentActivityHarness()
        defer { harness.tearDown() }
        let panelId = try harness.panelId(forPane: 4)

        harness.emitForeground(paneId: 4, rawValue: "0|opencode")
        #expect(harness.lifecycle(panelId: panelId, key: "opencode") == .running)

        // The plugin reports idle-at-prompt over the forwarded socket.
        harness.workspace.setAgentLifecycle(key: "opencode", panelId: panelId, lifecycle: .idle)

        // Alternate-screen flip re-emits a CHANGED foreground state whose
        // classification is unchanged — the heuristic must not stomp idle.
        harness.emitForeground(paneId: 4, rawValue: "1|opencode")
        #expect(harness.lifecycle(panelId: panelId, key: "opencode") == .idle)
    }

    /// An agent behind a wrapper binary the classifier cannot recognize
    /// publishes running over the forwarded socket, but cannot say goodbye
    /// when it dies. The pane returning to a plain shell is the death
    /// signal: plugin-reported entries are dropped.
    @Test func shellForegroundClearsPluginPublishedEntriesForWrapperAgents() throws {
        let harness = try RemoteTmuxAgentActivityHarness()
        defer { harness.tearDown() }
        let panelId = try harness.panelId(forPane: 4)

        // Wrapper binary comes to the foreground (classifier: unknown).
        harness.emitForeground(paneId: 4, rawValue: "0|acme-agent")
        // The agent's plugin reports running over the socket.
        harness.workspace.setAgentLifecycle(key: "opencode", panelId: panelId, lifecycle: .running)

        // Switching to another non-shell command must NOT clear (the agent
        // may still own the pane, e.g. it spawned a pager).
        harness.emitForeground(paneId: 4, rawValue: "0|less")
        #expect(harness.lifecycle(panelId: panelId, key: "opencode") == .running)

        // The wrapper exits: shell foreground drops the plugin's entry.
        harness.emitForeground(paneId: 4, rawValue: "0|zsh")
        #expect(harness.lifecycle(panelId: panelId, key: "opencode") == nil)
    }

    /// An agent already running at attach is only visible via replay: tmux
    /// emits foreground values before the pane topology exists, then never
    /// re-emits unchanged ones.
    @Test func rebuildReplaysPreTopologyClassifications() throws {
        let harness = try RemoteTmuxAgentActivityHarness(beforeTopology: { connection in
            connection.classifyAndEmitReflow(paneId: 4, rawValue: "0|opencode", source: "test-seed")
        })
        defer { harness.tearDown() }
        let panelId = try harness.panelId(forPane: 4)
        #expect(harness.lifecycle(panelId: panelId, key: "opencode") == .running)
    }

    @Test func unknownPaneClassificationIsIgnored() throws {
        let harness = try RemoteTmuxAgentActivityHarness()
        defer { harness.tearDown() }
        harness.emitForeground(paneId: 99, rawValue: "0|opencode")
        #expect(harness.workspace.agentLifecycleStatesByPanelId.values.allSatisfy { $0["opencode"] == nil })
    }

    @Test func resolveRemotePaneMapsPaneToWorkspaceAndSurface() throws {
        let harness = try RemoteTmuxAgentActivityHarness()
        defer { harness.tearDown() }
        let panelId = try harness.panelId(forPane: 4)

        let resolved = try #require(
            harness.controller.resolveRemotePane(
                connectionHash: harness.host.connectionHash,
                paneId: 4
            )
        )
        #expect(resolved.workspaceId == harness.workspace.id)
        #expect(resolved.panelId == panelId)
    }

    @Test func resolveRemotePaneMissesReturnNil() throws {
        let harness = try RemoteTmuxAgentActivityHarness()
        defer { harness.tearDown() }
        #expect(harness.controller.resolveRemotePane(
            connectionHash: harness.host.connectionHash,
            paneId: 99
        ) == nil)
        #expect(harness.controller.resolveRemotePane(
            connectionHash: "not-a-connection-hash",
            paneId: 4
        ) == nil)
    }
}

/// Strict-priority resolution for the t3code-style attention phase.
@Suite struct SidebarAgentAttentionResolverTests {
    private let panel = UUID()

    @Test func priorityOrderIsApprovalInputWorkingDone() {
        #expect(SidebarAgentAttentionResolver.phase(
            pendingDecisionKinds: [.question, .permissionRequest],
            statesByPanelId: [panel: ["opencode": .running]],
            hasUnreadTurnComplete: true
        ) == .pendingApproval)
        #expect(SidebarAgentAttentionResolver.phase(
            pendingDecisionKinds: [.question],
            statesByPanelId: [panel: ["opencode": .running]],
            hasUnreadTurnComplete: true
        ) == .awaitingInput)
        #expect(SidebarAgentAttentionResolver.phase(
            pendingDecisionKinds: [],
            statesByPanelId: [panel: ["opencode": .running]],
            hasUnreadTurnComplete: true
        ) == .working)
        #expect(SidebarAgentAttentionResolver.phase(
            pendingDecisionKinds: [],
            statesByPanelId: [panel: ["opencode": .idle]],
            hasUnreadTurnComplete: true
        ) == .unreadCompleted)
        #expect(SidebarAgentAttentionResolver.phase(
            pendingDecisionKinds: [],
            statesByPanelId: [:],
            hasUnreadTurnComplete: false
        ) == nil)
    }

    @Test func exitPlanCountsAsApprovalAndNeedsInputAsInput() {
        #expect(SidebarAgentAttentionResolver.phase(
            pendingDecisionKinds: [.exitPlan],
            statesByPanelId: [:],
            hasUnreadTurnComplete: false
        ) == .pendingApproval)
        #expect(SidebarAgentAttentionResolver.phase(
            pendingDecisionKinds: [],
            statesByPanelId: [panel: ["cmux.feed.attention:opencode": .needsInput]],
            hasUnreadTurnComplete: false
        ) == .awaitingInput)
    }

    /// `workspace_loading` manual keys drive the loading spinner, not agent
    /// attention: a manual loader must never read as Working.
    @Test func manualLoaderKeysAreIgnored() {
        #expect(SidebarAgentAttentionResolver.phase(
            pendingDecisionKinds: [],
            statesByPanelId: [panel: ["manual": .running, "manual:build": .running]],
            hasUnreadTurnComplete: false
        ) == nil)
    }

    /// Only decisions, questions, and unseen completions earn inbox rows;
    /// motion stays on the session row's indicator. Ranks preserve that
    /// same order for inbox sorting.
    @Test func actionabilityAndRankMatchInboxSemantics() {
        #expect(SidebarAgentAttentionPhase.pendingApproval.isActionable)
        #expect(SidebarAgentAttentionPhase.awaitingInput.isActionable)
        #expect(SidebarAgentAttentionPhase.unreadCompleted.isActionable)
        #expect(!SidebarAgentAttentionPhase.working.isActionable)
        #expect(SidebarAgentAttentionPhase.pendingApproval.inboxRank
            < SidebarAgentAttentionPhase.awaitingInput.inboxRank)
        #expect(SidebarAgentAttentionPhase.awaitingInput.inboxRank
            < SidebarAgentAttentionPhase.unreadCompleted.inboxRank)
    }
}

/// The agent inbox section in the sidebar (t3code-style: rows exist only
/// while actionable, pinned above the machine sections).
@Suite struct RemoteTmuxWindowRenderItemTests {
    @MainActor
    @Test func inboxLeadsTheSidebarAndSessionsStayChildless() {
        let workspaceA = UUID()
        let workspaceB = UUID()
        let windowOne = UUID()
        let windowTwo = UUID()
        let tabs = [makeStubWorkspace(id: workspaceA), makeStubWorkspace(id: workspaceB)]
        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: tabs,
            groupsById: [:],
            remoteHostKeyByWorkspaceId: [workspaceA: "host-a", workspaceB: "host-a"],
            collapsedRemoteHostKeys: [],
            agentInboxItems: [
                SidebarAgentInboxItemRef(workspaceId: workspaceB, windowPanelId: windowTwo),
                SidebarAgentInboxItemRef(workspaceId: workspaceA, windowPanelId: windowOne),
            ]
        )
        guard items.count == 7,
              case .agentInboxHeader(let headerWorkspaceId) = items[0],
              case .remoteTmuxWindow(let owner1, let panel1) = items[1],
              case .remoteTmuxWindow(let owner2, let panel2) = items[2],
              case .reauthenticate = items[3],
              case .remoteHostSection = items[4],
              case .workspace(let firstSession) = items[5],
              case .workspace(let secondSession) = items[6] else {
            Issue.record("unexpected items: \(items)")
            return
        }
        // Caller order is preserved verbatim (it pre-sorts by phase rank).
        #expect(headerWorkspaceId == workspaceB)
        #expect(owner1 == workspaceB && panel1 == windowTwo)
        #expect(owner2 == workspaceA && panel2 == windowOne)
        #expect(firstSession == workspaceA)
        #expect(secondSession == workspaceB)
    }

    @MainActor
    @Test func emptyInboxRendersNoHeaderAndNoWindowRows() {
        let workspaceA = UUID()
        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: [makeStubWorkspace(id: workspaceA)],
            groupsById: [:],
            remoteHostKeyByWorkspaceId: [workspaceA: "host-a"],
            collapsedRemoteHostKeys: [],
            agentInboxItems: []
        )
        #expect(items.count == 3)
        for item in items {
            switch item {
            case .agentInboxHeader, .remoteTmuxWindow:
                Issue.record("quiet sidebar must not render inbox items, got \(items)")
            case .groupHeader, .workspace, .remoteHostSection, .localMacSection,
                 .reauthenticate:
                break
            }
        }
    }

    /// Machine collapse governs session rows only: a pending decision must
    /// stay visible in the inbox even when its machine is collapsed.
    @MainActor
    @Test func collapsedMachineKeepsInboxRowsVisible() {
        let workspaceA = UUID()
        let windowOne = UUID()
        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: [makeStubWorkspace(id: workspaceA)],
            groupsById: [:],
            remoteHostKeyByWorkspaceId: [workspaceA: "host-a"],
            collapsedRemoteHostKeys: ["host-a"],
            agentInboxItems: [
                SidebarAgentInboxItemRef(workspaceId: workspaceA, windowPanelId: windowOne)
            ]
        )
        guard items.count == 4,
              case .agentInboxHeader = items[0],
              case .remoteTmuxWindow(_, let panel) = items[1],
              case .reauthenticate = items[2],
              case .remoteHostSection = items[3] else {
            Issue.record("unexpected items: \(items)")
            return
        }
        #expect(panel == windowOne)
    }

    /// Remote mirrors surface activity through the attention system; the
    /// legacy numeric unread badge stays local-only so a turn completion is
    /// signaled once (dot + inbox), not twice.
    @Test func remoteMirrorsHideTheLegacyNumericUnreadBadge() {
        #expect(SidebarWorkspaceRowInput.displayedUnreadCount(3, isRemoteTmuxMirror: true) == 0)
        #expect(SidebarWorkspaceRowInput.displayedUnreadCount(3, isRemoteTmuxMirror: false) == 3)
        #expect(SidebarWorkspaceRowInput.displayedUnreadCount(0, isRemoteTmuxMirror: true) == 0)
    }

    @MainActor
    private func makeStubWorkspace(id: UUID) -> Workspace {
        let workspace = Workspace(id: id)
        return workspace
    }
}

/// The remote path the agent bridge forwards the local control socket to.
@Suite struct RemoteTmuxAgentSocketPathTests {
    @Test func remoteAgentSocketPathIsStableAndCollisionResistant() {
        let a = RemoteTmuxController.remoteAgentSocketPath(
            localSocketPath: "/tmp/cmux-debug.sock", connectionHash: "hash-a")
        let again = RemoteTmuxController.remoteAgentSocketPath(
            localSocketPath: "/tmp/cmux-debug.sock", connectionHash: "hash-a")
        let otherHost = RemoteTmuxController.remoteAgentSocketPath(
            localSocketPath: "/tmp/cmux-debug.sock", connectionHash: "hash-b")
        let otherInstance = RemoteTmuxController.remoteAgentSocketPath(
            localSocketPath: "/tmp/cmux-prod.sock", connectionHash: "hash-a")

        #expect(a == again)
        #expect(a != otherHost)
        #expect(a != otherInstance)
        #expect(a.hasPrefix("/tmp/cmux-agent-"))
        #expect(a.hasSuffix(".sock"))
        // Unix socket sun_path budget is ~104 bytes on macOS/BSD; keep well under.
        #expect(a.utf8.count < 40)
    }
}
