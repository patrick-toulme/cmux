import Foundation

@MainActor
extension TabManager {
    /// Selects a workspace by the order of ordinary rows rendered in the sidebar.
    ///
    /// Group anchors are represented by group headers, so they are intentionally
    /// absent from this numbered order. Collapsed child rows and rows hidden by
    /// the sidebar search filter are absent as well, so the digit shown on a
    /// visible row is the digit that selects it.
    @discardableResult
    func selectWorkspaceByNumber(_ digit: Int) -> Int? {
        let groupsById = Dictionary(uniqueKeysWithValues: workspaceGroups.map { ($0.id, $0) })
        var remoteHostKeyByWorkspaceId: [UUID: String] = [:]
        var remoteHostLabelByHostKey: [String: String] = [:]
        for tab in tabs {
            guard let hostKey = tab.remoteTmuxHostKey else { continue }
            remoteHostKeyByWorkspaceId[tab.id] = hostKey
            if remoteHostLabelByHostKey[hostKey] == nil {
                remoteHostLabelByHostKey[hostKey] = tab.remoteTmuxHostLabel ?? hostKey
            }
        }
        let visibleWorkspaceIds = SidebarWorkspaceRenderItem.visibleWorkspaceIds(
            matching: sidebarWorkspaceSearchQuery,
            tabs: tabs,
            remoteHostKeyByWorkspaceId: remoteHostKeyByWorkspaceId,
            remoteHostLabelByHostKey: remoteHostLabelByHostKey,
            alwaysVisibleWorkspaceId: selectedTabId
        )
        let workspaceIds = SidebarWorkspaceRenderItem.numberedWorkspaceIds(
            from: SidebarWorkspaceRenderItem.renderItems(
                tabs: tabs,
                groupsById: groupsById,
                remoteHostKeyByWorkspaceId: remoteHostKeyByWorkspaceId,
                collapsedRemoteHostKeys: collapsedRemoteTmuxHostKeys,
                visibleWorkspaceIds: visibleWorkspaceIds
            )
        )
        guard let targetIndex = WorkspaceShortcutMapper.workspaceIndex(
            forDigit: digit,
            workspaceCount: workspaceIds.count
        ),
        let workspace = tabs.first(where: { $0.id == workspaceIds[targetIndex] }) else {
            return nil
        }
        selectWorkspace(workspace)
        return targetIndex
    }
}
