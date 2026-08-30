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
    /// `firstWorkspaceId` is the run's first mirror workspace, used only
    /// where a row must nominate a representative workspace (pointer frames,
    /// scroll anchoring). `runIndex` disambiguates the header when reorders
    /// split a machine's workspaces into several contiguous runs — every run
    /// re-renders the header, so sessions never float under another
    /// machine's section.
    case remoteHostSection(hostKey: String, firstWorkspaceId: UUID, runIndex: Int = 0)
    /// The "Local Mac" section header: local (non-mirror) workspaces
    /// interleaved among machine sections get their own header per run, so a
    /// local terminal never reads as one of a machine's sessions. Emitted
    /// only while at least one machine section exists — a purely local
    /// sidebar keeps its classic headerless list.
    case localMacSection(firstWorkspaceId: UUID, runIndex: Int = 0)
    /// The "Needs attention" section header above the agent inbox rows
    /// (t3code-style: the inbox only exists while something is actionable).
    /// `firstWorkspaceId` nominates the first inbox item's workspace where a
    /// row must name a representative workspace.
    case agentInboxHeader(firstWorkspaceId: UUID)
    /// One agent inbox row: a mirrored tmux window (the user's unit of agent
    /// work — one agent per window) that currently needs attention. The id
    /// is the window's stable container panel.
    case remoteTmuxWindow(workspaceId: UUID, windowPanelId: UUID)
    /// The one-press "Reauthenticate" row: reruns the attach command for
    /// every machine in this window (interactive auth happens in the
    /// terminal it opens). Emitted only while machine sections exist, above
    /// the first section, so the post-wake ritual is one click instead of a
    /// remembered command line. `firstWorkspaceId` nominates the first
    /// remote workspace as the row's representative.
    case reauthenticate(firstWorkspaceId: UUID)

    var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let groupId, _):
            return .group(groupId)
        case .workspace(let workspaceId):
            return .workspace(workspaceId)
        case .remoteHostSection(let hostKey, _, let runIndex):
            return .remoteHostSection(
                SidebarRemoteHostSectionIdentity.uuid(forHostKey: hostKey, runIndex: runIndex)
            )
        case .localMacSection(_, let runIndex):
            return .localMacSection(SidebarRemoteHostSectionIdentity.uuid(
                forHostKey: SidebarRemoteHostSectionIdentity.localMacSectionKey,
                runIndex: runIndex
            ))
        case .agentInboxHeader:
            return .agentInboxHeader()
        case .remoteTmuxWindow(_, let windowPanelId):
            return .remoteTmuxWindow(windowPanelId)
        case .reauthenticate:
            return .reauthenticate()
        }
    }

    var rowWorkspaceId: UUID {
        switch self {
        case .groupHeader(_, let anchorWorkspaceId):
            return anchorWorkspaceId
        case .workspace(let workspaceId):
            return workspaceId
        case .remoteHostSection(_, let firstWorkspaceId, _):
            return firstWorkspaceId
        case .localMacSection(let firstWorkspaceId, _):
            return firstWorkspaceId
        case .agentInboxHeader(let firstWorkspaceId):
            return firstWorkspaceId
        case .remoteTmuxWindow(let workspaceId, _):
            return workspaceId
        case .reauthenticate(let firstWorkspaceId):
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
        collapsedRemoteHostKeys: Set<String> = [],
        agentInboxItems: [SidebarAgentInboxItemRef] = [],
        visibleWorkspaceIds: Set<UUID>? = nil
    ) -> [SidebarWorkspaceRenderItem] {
        guard !tabs.isEmpty else { return [] }
        // Search filtering: when a visible-id set is supplied, only member
        // workspaces render as rows. Section and group headers surface
        // lazily with their first surviving child so empty containers
        // disappear, collapse state is ignored so a match inside a
        // collapsed machine or group is always shown, and the inbox and
        // reauthenticate chrome stay untouched.
        let filtering = visibleWorkspaceIds != nil
        func survives(_ workspaceId: UUID) -> Bool {
            visibleWorkspaceIds?.contains(workspaceId) ?? true
        }
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
        // Section runs: reorders (drag, sort-by-recent, attention moves) can
        // split any section's workspaces into several contiguous runs. EVERY
        // run renders a header — the bug this replaces emitted a machine's
        // header only for its first run, so a session moved to the top took
        // the header with it and the machine's remaining sessions floated
        // under the previous section. Local workspaces get the same
        // treatment ("Local Mac") whenever machine sections exist at all.
        let localKey = SidebarRemoteHostSectionIdentity.localMacSectionKey
        let hasMachineSections = tabs.contains { remoteHostKeyByWorkspaceId[$0.id] != nil }
        // One-press reauth for every machine in the window, pinned above the
        // first section (after the inbox: pending decisions outrank chrome).
        // Derived from the UNFILTERED tabs: the ritual stays one click away
        // while a search narrows the list.
        if let firstRemote = tabs.first(where: { remoteHostKeyByWorkspaceId[$0.id] != nil }) {
            items.append(.reauthenticate(firstWorkspaceId: firstRemote.id))
        }
        var currentSectionKey: String? = nil
        var nextRunIndexBySectionKey: [String: Int] = [:]
        var skipChildrenInSection = false
        // While filtering, headers buffer here until a surviving child row
        // proves their container non-empty.
        var pendingSectionHeader: SidebarWorkspaceRenderItem? = nil
        var pendingGroupHeader: (groupId: UUID, item: SidebarWorkspaceRenderItem, isCollapsed: Bool)? = nil
        func flushPendingSectionHeader() {
            guard let header = pendingSectionHeader else { return }
            items.append(header)
            pendingSectionHeader = nil
        }
        func flushPendingGroupHeader() {
            guard let pending = pendingGroupHeader else { return }
            flushPendingSectionHeader()
            items.append(pending.item)
            emittedHeaders.insert(pending.groupId)
            collapsedByGroupId[pending.groupId] = pending.isCollapsed
            pendingGroupHeader = nil
        }
        for tab in tabs {
            let hostKey = remoteHostKeyByWorkspaceId[tab.id]
            let sectionKey = hostKey ?? localKey
            // A purely local sidebar keeps its classic headerless list.
            let isSectioned = hostKey != nil || hasMachineSections
            if isSectioned, sectionKey != currentSectionKey {
                currentSectionKey = sectionKey
                let runIndex = nextRunIndexBySectionKey[sectionKey, default: 0]
                nextRunIndexBySectionKey[sectionKey] = runIndex + 1
                let header: SidebarWorkspaceRenderItem = if let hostKey {
                    .remoteHostSection(
                        hostKey: hostKey,
                        firstWorkspaceId: tab.id,
                        runIndex: runIndex
                    )
                } else {
                    .localMacSection(
                        firstWorkspaceId: tab.id,
                        runIndex: runIndex
                    )
                }
                if filtering {
                    pendingSectionHeader = header
                } else {
                    items.append(header)
                }
                // Every run of a section honors the one collapse decision;
                // an active search overrides collapse so matches show.
                skipChildrenInSection = !filtering
                    && collapsedRemoteHostKeys.contains(sectionKey)
            }
            // Remote tmux mirrors render under per-machine sections; a mirror
            // workspace never belongs to a workspace group, so host sectioning
            // takes precedence when both somehow apply.
            if hostKey != nil {
                lastEmittedGroupId = nil
                skipChildrenUntilNextGroup = false
                if !skipChildrenInSection, survives(tab.id) {
                    flushPendingSectionHeader()
                    items.append(.workspace(workspaceId: tab.id))
                }
                continue
            }
            // A collapsed Local Mac section hides its group headers with its
            // rows; the groups keep their own collapse state for when the
            // section reopens.
            if isSectioned, skipChildrenInSection {
                lastEmittedGroupId = nil
                skipChildrenUntilNextGroup = false
                continue
            }
            let groupId = tab.groupId
            if groupId != lastEmittedGroupId {
                lastEmittedGroupId = groupId
                skipChildrenUntilNextGroup = false
                pendingGroupHeader = nil
                if let groupId, let group = groupsById[groupId] {
                    if !emittedHeaders.contains(groupId) {
                        let header = SidebarWorkspaceRenderItem.groupHeader(
                            groupId: group.id,
                            anchorWorkspaceId: group.anchorWorkspaceId
                        )
                        if filtering {
                            pendingGroupHeader = (group.id, header, group.isCollapsed)
                        } else {
                            items.append(header)
                            emittedHeaders.insert(groupId)
                            collapsedByGroupId[groupId] = group.isCollapsed
                        }
                    }
                    // If legacy reorder paths ever leave a group's members in
                    // two runs, keep honoring the same collapse decision.
                    skipChildrenUntilNextGroup = !filtering
                        && (collapsedByGroupId[groupId] ?? false)
                }
            }
            // Anchor workspaces are represented exclusively by the group header.
            if let groupId, let group = groupsById[groupId], group.anchorWorkspaceId == tab.id {
                // A matching anchor keeps its group header visible even when
                // no other member matches.
                if filtering, survives(tab.id) {
                    flushPendingGroupHeader()
                }
                continue
            }
            if groupId == nil || !skipChildrenUntilNextGroup {
                if survives(tab.id) {
                    flushPendingSectionHeader()
                    if groupId != nil {
                        flushPendingGroupHeader()
                    }
                    items.append(.workspace(workspaceId: tab.id))
                }
            }
        }
        return items
    }

    /// Resolves a sidebar search query to the set of workspace ids that stay
    /// visible, or `nil` when the query is empty (no filtering). Matching is
    /// case- and diacritic-insensitive on the workspace title (the tmux
    /// session name for remote mirrors); a machine-label match admits every
    /// session of that machine so a hostname query shows the whole section.
    /// The selected workspace always survives: keyboard cycling and CLI
    /// selection must never land on a hidden row.
    static func visibleWorkspaceIds(
        matching query: String,
        tabs: [Workspace],
        remoteHostKeyByWorkspaceId: [UUID: String],
        remoteHostLabelByHostKey: [String: String],
        alwaysVisibleWorkspaceId: UUID? = nil
    ) -> Set<UUID>? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let matchingHostKeys = Set(
            remoteHostLabelByHostKey
                .filter { hostKey, label in
                    label.localizedStandardContains(trimmed)
                        || hostKey.localizedStandardContains(trimmed)
                }
                .map(\.key)
        )
        var visible = Set<UUID>()
        for tab in tabs {
            if tab.title.localizedStandardContains(trimmed) {
                visible.insert(tab.id)
                continue
            }
            if let hostKey = remoteHostKeyByWorkspaceId[tab.id],
               matchingHostKeys.contains(hostKey) {
                visible.insert(tab.id)
            }
        }
        if let alwaysVisibleWorkspaceId, tabs.contains(where: { $0.id == alwaysVisibleWorkspaceId }) {
            visible.insert(alwaysVisibleWorkspaceId)
        }
        return visible
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
