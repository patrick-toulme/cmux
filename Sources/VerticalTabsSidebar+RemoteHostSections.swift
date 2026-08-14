import AppKit
import CmuxNotifications
import SwiftUI

/// Per-machine collapsible sidebar sections for remote tmux mirrors.
///
/// One section per mirrored machine (keyed by the endpoint's
/// `RemoteTmuxHost.connectionHash`), holding that machine's tmux session
/// workspaces as ordinary child rows. Unlike workspace groups there is no
/// anchor workspace: the header is a pure container row carrying the machine
/// identity, the collapse toggle, and machine-level verbs.
extension VerticalTabsSidebar {
    /// Builds the immutable presentation snapshot for one machine's header.
    func remoteHostSectionSnapshot(
        hostKey: String,
        runIndex: Int = 0,
        isPointerHovering: Bool,
        renderContext: WorkspaceListRenderContext,
        unreadCountForWorkspace: (UUID) -> Int
    ) -> SidebarRemoteHostSectionRowSnapshot {
        let members = renderContext.memberWorkspaceIdsByRemoteHostKey[hostKey] ?? []
        let isCollapsed = renderContext.collapsedRemoteHostKeys.contains(hostKey)
        // A collapsed section must not swallow unread signal: aggregate the
        // hidden members' counts onto the header, like collapsed groups do.
        let collapsedUnreadCount = isCollapsed
            ? members.reduce(0) { $0 + unreadCountForWorkspace($1) }
            : 0
        let sectionId = SidebarWorkspaceRenderItemID.remoteHostSection(
            SidebarRemoteHostSectionIdentity.uuid(forHostKey: hostKey, runIndex: runIndex)
        )
        return SidebarRemoteHostSectionRowSnapshot(
            hostKey: hostKey,
            label: renderContext.remoteHostLabelByHostKey[hostKey] ?? hostKey,
            isCollapsed: isCollapsed,
            memberCount: members.count,
            collapsedUnreadCount: collapsedUnreadCount,
            authRequired: renderContext.remoteHostAuthRequiredKeys.contains(hostKey),
            isPointerHovering: isPointerHovering,
            fontScale: renderContext.tabItemSettings.sidebarFontScale,
            rowSpacing: tabRowSpacing,
            isFirstRow: renderContext.workspaceRenderItems.first?.id == sectionId
        )
    }

    /// Assembles one machine header view; shared by the SwiftUI list rows and
    /// the AppKit table's hosted cells. Model references appear only inside
    /// user-invoked action closures.
    func sidebarRemoteHostSectionHeader(
        hostKey: String,
        runIndex: Int = 0,
        isPointerHovering: Bool,
        contextMenuActions: SidebarWorkspaceTableContextMenuActions?,
        renderContext: WorkspaceListRenderContext,
        unreadCountForWorkspace: (UUID) -> Int
    ) -> SidebarRemoteHostSectionHeaderView {
        let snapshot = remoteHostSectionSnapshot(
            hostKey: hostKey,
            runIndex: runIndex,
            isPointerHovering: isPointerHovering,
            renderContext: renderContext,
            unreadCountForWorkspace: unreadCountForWorkspace
        )
        return SidebarRemoteHostSectionHeaderView(
            snapshot: snapshot,
            onToggleCollapsed: { [weak tabManager] in
                tabManager?.toggleRemoteTmuxHostCollapsed(hostKey: hostKey)
            },
            onNewSession: {
                Task { @MainActor in
                    await AppDelegate.shared?.remoteTmuxController
                        .createSessionOnHost(connectionHash: hostKey)
                }
            },
            onDetachMachine: {
                AppDelegate.shared?.remoteTmuxController
                    .detachHost(connectionHash: hostKey)
            },
            onKillAllSessions: { [label = snapshot.label, memberCount = snapshot.memberCount] in
                guard confirmKillRemoteHostSessions(label: label, sessionCount: memberCount) else {
                    return
                }
                AppDelegate.shared?.remoteTmuxController
                    .killHostSessions(connectionHash: hostKey)
            },
            onContextMenuAppear: { contextMenuActions?.didOpen() },
            onContextMenuDisappear: { contextMenuActions?.didClose() }
        )
    }

    /// AppKit table row configuration for one machine header (a hosted
    /// SwiftUI cell; `isGroupHeader` selects the group-header height class).
    func sidebarRemoteHostSectionTableConfiguration(
        hostKey: String,
        firstWorkspaceId: UUID,
        runIndex: Int = 0,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableRowConfiguration {
        // The AppKit controller applies live unread snapshots per cell; this
        // row only needs the aggregate at construction, matching the group
        // header's collapsed-count behavior on the next rows rebuild.
        let unreadSnapshot = SidebarUnreadSnapshot()
        let unreadCountForWorkspace: (UUID) -> Int = {
            unreadSnapshot.unreadCount(forWorkspaceId: $0)
        }
        let equivalenceHeader = sidebarRemoteHostSectionHeader(
            hostKey: hostKey,
            runIndex: runIndex,
            isPointerHovering: false,
            contextMenuActions: nil,
            renderContext: renderContext,
            unreadCountForWorkspace: unreadCountForWorkspace
        )
        return SidebarWorkspaceTableRowConfiguration(
            id: .remoteHostSection(
                SidebarRemoteHostSectionIdentity.uuid(forHostKey: hostKey, runIndex: runIndex)
            ),
            workspaceId: firstWorkspaceId,
            groupId: nil,
            isGroupHeader: true,
            isPinned: false,
            environment: renderContext.environment,
            equivalenceValue: equivalenceHeader
        ) { isPointerHovering, contextMenuActions in
            AnyView(self.sidebarRemoteHostSectionHeader(
                hostKey: hostKey,
                runIndex: runIndex,
                isPointerHovering: isPointerHovering,
                contextMenuActions: contextMenuActions,
                renderContext: renderContext,
                unreadCountForWorkspace: unreadCountForWorkspace
            ))
        }
    }

    // MARK: - Local Mac section

    /// Builds the "Local Mac" header snapshot: local workspaces interleaved
    /// among machine sections carry their own header, so a local terminal
    /// never reads as one of a machine's sessions.
    func localMacSectionSnapshot(
        runIndex: Int,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarLocalMacSectionRowSnapshot {
        let localKey = SidebarRemoteHostSectionIdentity.localMacSectionKey
        let localWorkspaceIds = renderContext.workspaceById.keys.filter {
            renderContext.remoteHostKeyByWorkspaceId[$0] == nil
        }
        return SidebarLocalMacSectionRowSnapshot(
            isCollapsed: renderContext.collapsedRemoteHostKeys.contains(localKey),
            memberCount: localWorkspaceIds.count,
            fontScale: renderContext.tabItemSettings.sidebarFontScale
        )
    }

    /// Assembles one Local Mac header view; shared by both sidebar backends.
    func sidebarLocalMacSectionHeader(
        runIndex: Int,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarLocalMacSectionHeaderView {
        SidebarLocalMacSectionHeaderView(
            snapshot: localMacSectionSnapshot(runIndex: runIndex, renderContext: renderContext),
            onToggleCollapsed: { [weak tabManager] in
                tabManager?.toggleRemoteTmuxHostCollapsed(
                    hostKey: SidebarRemoteHostSectionIdentity.localMacSectionKey
                )
            }
        )
    }

    /// AppKit table row configuration for one Local Mac header.
    func sidebarLocalMacSectionTableConfiguration(
        firstWorkspaceId: UUID,
        runIndex: Int,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableRowConfiguration {
        let equivalenceHeader = sidebarLocalMacSectionHeader(
            runIndex: runIndex, renderContext: renderContext
        )
        return SidebarWorkspaceTableRowConfiguration(
            id: .localMacSection(SidebarRemoteHostSectionIdentity.uuid(
                forHostKey: SidebarRemoteHostSectionIdentity.localMacSectionKey,
                runIndex: runIndex
            )),
            workspaceId: firstWorkspaceId,
            groupId: nil,
            isGroupHeader: true,
            isPinned: false,
            environment: renderContext.environment,
            equivalenceValue: equivalenceHeader
        ) { _, _ in
            AnyView(self.sidebarLocalMacSectionHeader(
                runIndex: runIndex, renderContext: renderContext
            ))
        }
    }
}

/// Modal confirmation for the destructive machine-level kill.
@MainActor
func confirmKillRemoteHostSessions(label: String, sessionCount: Int) -> Bool {
    let alert = NSAlert()
    alert.messageText = String(
        format: String(
            localized: "remoteTmuxHostSection.killAll.title",
            defaultValue: "Kill all tmux sessions on %@?"
        ),
        label
    )
    alert.informativeText = String.localizedStringWithFormat(
        String(
            localized: "remoteTmuxHostSection.killAll.body",
            defaultValue: "This kills %lld tmux sessions on the remote machine. Programs running in them are terminated. Detach instead to keep them running."
        ),
        sessionCount
    )
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(
        localized: "remoteTmuxHostSection.killAll.confirm",
        defaultValue: "Kill Sessions"
    ))
    alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
    return alert.runModal() == .alertFirstButtonReturn
}
