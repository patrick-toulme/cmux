import CmuxWorkspaces
import Foundation

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

    var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let groupId, _):
            return .group(groupId)
        case .workspace(let workspaceId):
            return .workspace(workspaceId)
        case .remoteHostSection(let hostKey, _):
            return .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: hostKey))
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
        collapsedRemoteHostKeys: Set<String> = []
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty else { return [] }
        var items: [SidebarWorkspaceRenderItem] = []
        items.reserveCapacity(tabs.count + groupsById.count)
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
