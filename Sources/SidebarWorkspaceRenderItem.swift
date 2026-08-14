import CmuxWorkspaces
import Foundation

/// One entry of the agent inbox: a mirrored tmux window whose agent needs
/// the user right now (approval, question, or unseen completion). The
/// caller resolves phases and ordering; the render pipeline only needs the
/// stable identities.
struct SidebarAgentInboxItemRef: Hashable, Sendable {
    let workspaceId: UUID
    let windowPanelId: UUID
}

/// Stable value identity for one drawable item in the workspace sidebar.
///
/// Keep live `Workspace` / `WorkspaceGroup` references out of this value. A
/// `LazyVStack` copies and diffs its `ForEach` data while placing rows; carrying
/// the models through that path made scrolling copy the live sidebar graph and
/// blurred the ownership boundary between layout data and observed state.
/// Models are resolved from the parent-owned render context only when SwiftUI
/// asks to realize a row.
@MainActor
enum SidebarWorkspaceRenderItem {
    case groupHeader(groupId: UUID, anchorWorkspaceId: UUID)
    case workspace(workspaceId: UUID)
    /// One remote tmux machine's collapsible section header. Unlike a
    /// workspace group header, it represents no anchor workspace — every one
    /// of the machine's session workspaces stays a real child row.
    /// `firstWorkspaceId` is the machine's first mirror workspace, used only
    /// where a row must nominate a representative workspace (pointer frames,
    /// scroll anchoring).
    case remoteHostSection(hostKey: String, firstWorkspaceId: UUID)
    /// The "Needs attention" section header above the agent inbox rows
    /// (t3code-style: the inbox only exists while something is actionable).
    /// `firstWorkspaceId` nominates the first inbox item's workspace where a
    /// row must name a representative workspace.
    case agentInboxHeader(firstWorkspaceId: UUID)
    /// One agent inbox row: a mirrored tmux window (the user's unit of agent
    /// work — one agent per window) that currently needs attention. The id
    /// is the window's stable container panel.
    case remoteTmuxWindow(workspaceId: UUID, windowPanelId: UUID)

    var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let groupId, _):
            return .group(groupId)
        case .workspace(let workspaceId):
            return .workspace(workspaceId)
        case .remoteHostSection(let hostKey, _):
            return .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: hostKey))
        case .agentInboxHeader:
            return .agentInboxHeader()
        case .remoteTmuxWindow(_, let windowPanelId):
            return .remoteTmuxWindow(windowPanelId)
        }
    }

    var rowWorkspaceId: UUID {
        switch self {
        case .groupHeader(_, let anchorWorkspaceId):
            return anchorWorkspaceId
        case .workspace(let workspaceId):
            return workspaceId
        case .remoteHostSection(_, let firstWorkspaceId):
            return firstWorkspaceId
        case .agentInboxHeader(let firstWorkspaceId):
            return firstWorkspaceId
        case .remoteTmuxWindow(let workspaceId, _):
            return workspaceId
        }
    }

    /// Whether this row is a numbered, reorderable workspace row (vs a
    /// container header that only nominates a representative workspace).
    var isWorkspaceRow: Bool {
        if case .workspace = self { return true }
        return false
    }

    static func renderItems(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup],
        remoteHostKeyByWorkspaceId: [UUID: String] = [:],
        collapsedRemoteHostKeys: Set<String> = [],
        agentInboxItems: [SidebarAgentInboxItemRef] = []
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty else { return [] }
        var items: [SidebarWorkspaceRenderItem] = []
        items.reserveCapacity(tabs.count + groupsById.count + agentInboxItems.count + 1)
        // The agent inbox leads the sidebar (t3code-style) and exists only
        // while something is actionable. Its rows are pinned above every
        // machine section, so host collapse never hides a pending decision.
        if let firstInboxItem = agentInboxItems.first {
            items.append(.agentInboxHeader(firstWorkspaceId: firstInboxItem.workspaceId))
            for inboxItem in agentInboxItems {
                items.append(.remoteTmuxWindow(
                    workspaceId: inboxItem.workspaceId,
                    windowPanelId: inboxItem.windowPanelId
                ))
            }
        }
        var lastEmittedGroupId: UUID? = nil
        var emittedHeaders: Set<UUID> = []
        var collapsedByGroupId: [UUID: Bool] = [:]
        var skipChildrenUntilNextGroup = false
        var lastEmittedHostKey: String? = nil
        var emittedHostKeys: Set<String> = []
        var skipChildrenUntilNextHost = false
        for tab in tabs {
            // Remote tmux mirrors render under per-machine sections; a mirror
            // workspace never belongs to a workspace group, so host sectioning
            // takes precedence when both somehow apply.
            if let hostKey = remoteHostKeyByWorkspaceId[tab.id] {
                lastEmittedGroupId = nil
                skipChildrenUntilNextGroup = false
                if hostKey != lastEmittedHostKey {
                    lastEmittedHostKey = hostKey
                    if !emittedHostKeys.contains(hostKey) {
                        items.append(.remoteHostSection(
                            hostKey: hostKey,
                            firstWorkspaceId: tab.id
                        ))
                        emittedHostKeys.insert(hostKey)
                    }
                    // A machine's workspaces can end up in several runs after
                    // sidebar reorders; every run honors the same collapse.
                    skipChildrenUntilNextHost = collapsedRemoteHostKeys.contains(hostKey)
                }
                if !skipChildrenUntilNextHost {
                    items.append(.workspace(workspaceId: tab.id))
                }
                continue
            }
            lastEmittedHostKey = nil
            skipChildrenUntilNextHost = false
            let groupId = tab.groupId
            if groupId != lastEmittedGroupId {
                lastEmittedGroupId = groupId
                skipChildrenUntilNextGroup = false
                if let groupId, let group = groupsById[groupId] {
                    if !emittedHeaders.contains(groupId) {
                        items.append(.groupHeader(
                            groupId: group.id,
                            anchorWorkspaceId: group.anchorWorkspaceId
                        ))
                        emittedHeaders.insert(groupId)
                        collapsedByGroupId[groupId] = group.isCollapsed
                    }
                    // If legacy reorder paths ever leave a group's members in
                    // two runs, keep honoring the same collapse decision.
                    skipChildrenUntilNextGroup = collapsedByGroupId[groupId] ?? false
                }
            }
            // Anchor workspaces are represented exclusively by the group header.
            if let groupId, let group = groupsById[groupId], group.anchorWorkspaceId == tab.id {
                continue
            }
            if groupId == nil || !skipChildrenUntilNextGroup {
                items.append(.workspace(workspaceId: tab.id))
            }
        }
        return items
    }

    /// Workspace ids represented by ordinary rows, in their rendered order.
    ///
    /// Group headers represent their anchor workspace for interaction, but are
    /// containers rather than numbered workspace rows.
    static func numberedWorkspaceIds(
        from renderItems: [SidebarWorkspaceRenderItem]
    ) -> [UUID] {
        renderItems.compactMap { item in
            guard case .workspace(let workspaceId) = item else { return nil }
            return workspaceId
        }
    }

    static func numberedWorkspaceIndexById(
        from renderItems: [SidebarWorkspaceRenderItem]
    ) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        result.reserveCapacity(renderItems.count)
        for item in renderItems {
            guard case .workspace(let workspaceId) = item else { continue }
            result[workspaceId] = result.count
        }
        return result
    }

    static func numberedWorkspaceIds(
        tabs: [Workspace],
        groupsById: [UUID: WorkspaceGroup]
    ) -> [UUID] {
        numberedWorkspaceIds(from: renderItems(tabs: tabs, groupsById: groupsById))
    }

    static func memberWorkspaceIdsByGroupId(tabs: [Workspace]) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        for tab in tabs {
            if let groupId = tab.groupId {
                result[groupId, default: []].append(tab.id)
            }
        }
        return result
    }
}
