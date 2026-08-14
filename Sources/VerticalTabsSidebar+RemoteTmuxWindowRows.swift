import AppKit
import SwiftUI

/// The t3code-style agent inbox for remote tmux mirrors: a "Needs
/// attention" section pinned above the machine sections, listing only the
/// tmux WINDOWS — the user's unit of agent work (one agent per window) —
/// whose agent needs the user right now, with the shared attention pill
/// and click-to-jump. Quiet windows never get rows; motion shows on the
/// session row's colored indicator instead.
extension VerticalTabsSidebar {
    /// The attention phase for ONE tmux window, resolved over exactly that
    /// window's pane panels: their lifecycle entries, the Feed's pending
    /// blocking decisions attributed to them, and unread turn-complete
    /// notifications on their surfaces. Session-scoped signals (decisions
    /// with no panel identity) stay on the session row's pill.
    static func remoteTmuxWindowAttentionPhase(
        workspace: Workspace,
        windowPanelId: UUID,
        showsAttentionStates: Bool
    ) -> SidebarAgentAttentionPhase? {
        guard showsAttentionStates else { return nil }
        var panelIds = Set(
            workspace.remoteTmuxControlPanes(containerPanelID: windowPanelId)
                .map { $0.pane.panel.id }
        )
        panelIds.insert(windowPanelId)
        let statesByPanelId = workspace.agentLifecycleStatesByPanelId
            .filter { panelIds.contains($0.key) }
        let pendingKinds = FeedCoordinator.shared
            .pendingBlockingDecisions(forWorkspace: workspace.id)
            .filter { decision in decision.panelId.map(panelIds.contains) ?? false }
            .map(\.kind)
        let hasUnreadTurnComplete = TerminalNotificationStore.shared
            .hasUnreadTurnComplete(forTabId: workspace.id, surfaceIds: panelIds)
        return SidebarAgentAttentionResolver.phase(
            pendingDecisionKinds: pendingKinds,
            statesByPanelId: statesByPanelId,
            hasUnreadTurnComplete: hasUnreadTurnComplete
        )
    }

    /// Collects the agent inbox: every mirrored tmux window whose agent
    /// needs the user right now, decisions first, ties in tab-strip order.
    /// Working windows never qualify — motion belongs to the session row's
    /// colored indicator, so the inbox holds only actionable items.
    static func agentInboxItems(
        tabs: [Workspace],
        remoteHostKeyByWorkspaceId: [UUID: String],
        showsAttentionStates: Bool
    ) -> [SidebarAgentInboxItemRef] {
        guard showsAttentionStates else { return [] }
        var candidates: [(ref: SidebarAgentInboxItemRef, rank: Int)] = []
        for tab in tabs where remoteHostKeyByWorkspaceId[tab.id] != nil {
            for windowPanelId in tab.sidebarOrderedPanelIds()
            where tab.isRemoteTmuxControlContainer(windowPanelId) {
                guard let phase = remoteTmuxWindowAttentionPhase(
                    workspace: tab,
                    windowPanelId: windowPanelId,
                    showsAttentionStates: true
                ), phase.isActionable else { continue }
                candidates.append((
                    ref: SidebarAgentInboxItemRef(
                        workspaceId: tab.id,
                        windowPanelId: windowPanelId
                    ),
                    rank: phase.inboxRank
                ))
            }
        }
        // Swift's sort is not stability-guaranteed: pair the rank with the
        // discovery index so equal-rank items keep machine/session order.
        return candidates.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.ref)
    }

    /// Builds the immutable presentation snapshot for one inbox row.
    func remoteTmuxWindowRowSnapshot(
        workspaceId: UUID,
        windowPanelId: UUID,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarRemoteTmuxWindowRowSnapshot {
        let workspace = renderContext.workspaceById[workspaceId]
        let title = workspace?.panelTitles[windowPanelId]
            ?? String(localized: "remoteTmux.tab.window", defaultValue: "tmux window")
        let phase = workspace.flatMap {
            Self.remoteTmuxWindowAttentionPhase(
                workspace: $0,
                windowPanelId: windowPanelId,
                showsAttentionStates: renderContext.tabItemSettings.details.showAgentActivity
            )
        }
        let isActive = tabManager.selectedTabId == workspaceId
            && workspace?.focusedPanelId == windowPanelId
        // Inbox rows sit above the machine sections, so each names its
        // origin: "machine · session".
        let machineLabel = renderContext.remoteHostKeyByWorkspaceId[workspaceId]
            .flatMap { renderContext.remoteHostLabelByHostKey[$0] }
        let sessionLabel = workspace.map { $0.customTitle ?? $0.title }
        let contextLabel = [machineLabel, sessionLabel]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
        return SidebarRemoteTmuxWindowRowSnapshot(
            workspaceId: workspaceId,
            windowPanelId: windowPanelId,
            title: title,
            contextLabel: contextLabel.isEmpty ? nil : contextLabel,
            attentionPhase: phase,
            isActive: isActive,
            fontScale: renderContext.tabItemSettings.sidebarFontScale,
            rowSpacing: tabRowSpacing
        )
    }

    /// Assembles one window row view; shared by the SwiftUI list rows and
    /// the AppKit table's hosted cells.
    func sidebarRemoteTmuxWindowRow(
        workspaceId: UUID,
        windowPanelId: UUID,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarRemoteTmuxWindowRowView {
        SidebarRemoteTmuxWindowRowView(
            snapshot: remoteTmuxWindowRowSnapshot(
                workspaceId: workspaceId,
                windowPanelId: windowPanelId,
                renderContext: renderContext
            ),
            onSelect: { [weak tabManager] in
                guard let tabManager else { return }
                // Notification-jump semantics: select the workspace, focus
                // the window's container panel (the mirror projects focus to
                // its active pane), clear the visited window's unread.
                _ = tabManager.focusTabFromNotification(workspaceId, surfaceId: windowPanelId)
            }
        )
    }

    /// AppKit table row configuration for one inbox row (a hosted SwiftUI
    /// cell like the machine header).
    func sidebarRemoteTmuxWindowTableConfiguration(
        workspaceId: UUID,
        windowPanelId: UUID,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableRowConfiguration {
        let equivalenceRow = sidebarRemoteTmuxWindowRow(
            workspaceId: workspaceId,
            windowPanelId: windowPanelId,
            renderContext: renderContext
        )
        return SidebarWorkspaceTableRowConfiguration(
            id: .remoteTmuxWindow(windowPanelId),
            workspaceId: workspaceId,
            groupId: nil,
            isGroupHeader: true,
            isPinned: false,
            environment: renderContext.environment,
            equivalenceValue: equivalenceRow
        ) { _, _ in
            AnyView(self.sidebarRemoteTmuxWindowRow(
                workspaceId: workspaceId,
                windowPanelId: windowPanelId,
                renderContext: renderContext
            ))
        }
    }

    /// The "Needs attention" header view above the inbox rows.
    func sidebarAgentInboxHeader(
        renderContext: WorkspaceListRenderContext
    ) -> SidebarAgentInboxHeaderView {
        SidebarAgentInboxHeaderView(
            itemCount: renderContext.agentInboxItems.count,
            fontScale: renderContext.tabItemSettings.sidebarFontScale
        )
    }

    /// AppKit table row configuration for the inbox header.
    func sidebarAgentInboxHeaderTableConfiguration(
        firstWorkspaceId: UUID,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableRowConfiguration {
        let equivalenceRow = sidebarAgentInboxHeader(renderContext: renderContext)
        return SidebarWorkspaceTableRowConfiguration(
            id: .agentInboxHeader(),
            workspaceId: firstWorkspaceId,
            groupId: nil,
            isGroupHeader: true,
            isPinned: false,
            environment: renderContext.environment,
            equivalenceValue: equivalenceRow
        ) { _, _ in
            AnyView(self.sidebarAgentInboxHeader(renderContext: renderContext))
        }
    }
}
