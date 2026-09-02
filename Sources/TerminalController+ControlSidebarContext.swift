import CmuxControlSocket
import Foundation
import CmuxSidebar

/// Identity of one control-socket connection for agent-state leasing.
///
/// `handleClient` installs a token in its connection thread's dictionary for
/// the connection's whole lifetime (one connection == one thread), so the
/// nonisolated lease registration called mid-command can attribute the paint
/// to the connection without threading identity through the coordinator.
final class SocketConnectionAgentLeaseToken: @unchecked Sendable {
    private static let threadKey = "cmux.socket.agentLeaseToken"

    static func installOnCurrentThread(_ token: SocketConnectionAgentLeaseToken) {
        Thread.current.threadDictionary[threadKey] = token
    }

    static func removeFromCurrentThread() {
        Thread.current.threadDictionary.removeObject(forKey: threadKey)
    }

    static func current() -> SocketConnectionAgentLeaseToken? {
        Thread.current.threadDictionary[threadKey] as? SocketConnectionAgentLeaseToken
    }
}

/// Ownership ledger for `--lease=1` agent-state paints: slot -> the last
/// connection that painted it. When a connection closes, every slot it still
/// owns is swept (cleared) on the main actor; a slot repainted by a newer
/// connection is that connection's to keep. Connection liveness is the
/// ground truth here: a painter that dies without its idle edge (killed
/// agent, rebooted host, torn-down forward) can no longer strand a running
/// dot or a stale status line.
final class RemoteAgentStateLeaseRegistry: @unchecked Sendable {
    static let shared = RemoteAgentStateLeaseRegistry()

    private let lock = NSLock()
    private var ownerBySlot: [ControlAgentStateLease: ObjectIdentifier] = [:]
    private var slotsByOwner: [ObjectIdentifier: Set<ControlAgentStateLease>] = [:]

    /// Records `owner` as the current painter of `slot` (stealing it from any
    /// earlier connection, which then has nothing left to sweep for it).
    func register(_ slot: ControlAgentStateLease, owner: SocketConnectionAgentLeaseToken) {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(owner)
        if let previous = ownerBySlot[slot], previous != id {
            slotsByOwner[previous]?.remove(slot)
        }
        ownerBySlot[slot] = id
        slotsByOwner[id, default: []].insert(slot)
    }

    /// Ends `owner`'s leases and returns the slots it still owned (the ones
    /// the caller must clear). Slots stolen by newer connections are not
    /// returned.
    func connectionClosed(_ owner: SocketConnectionAgentLeaseToken) -> [ControlAgentStateLease] {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(owner)
        guard let slots = slotsByOwner.removeValue(forKey: id) else { return [] }
        var expired: [ControlAgentStateLease] = []
        for slot in slots where ownerBySlot[slot] == id {
            ownerBySlot.removeValue(forKey: slot)
            expired.append(slot)
        }
        return expired
    }
}

/// The live-app half of the v1 sidebar metadata commands (`set_status` /
/// `report_meta` / `report_meta_block` / agent PID + lifecycle / `log` /
/// `set_progress` and their clears + listings): the exact mutation/read bodies
/// the former `TerminalController` v1 handlers ran, minus the parsing and
/// reply formatting that moved into `ControlCommandCoordinator`.
extension TerminalController: ControlSidebarContext {

    nonisolated func controlSidebarRegisterAgentStateLease(_ lease: ControlAgentStateLease) {
        guard let token = SocketConnectionAgentLeaseToken.current() else { return }
        RemoteAgentStateLeaseRegistry.shared.register(lease, owner: token)
    }

    /// Clears every slot an expired connection still owned. Lifecycle slots
    /// drop their painted state (running dots included) and status slots drop
    /// their entries; workspaces gone by sweep time are skipped.
    @MainActor
    static func sweepExpiredAgentStateLeases(
        _ slots: [ControlAgentStateLease],
        workspaces workspaceOverride: [Workspace]? = nil
    ) {
        guard !slots.isEmpty else { return }
        let live = workspaceOverride ?? AppDelegate.shared?.allLiveWorkspaces() ?? []
        var workspacesById: [UUID: Workspace] = [:]
        for workspace in live {
            workspacesById[workspace.id] = workspace
        }
        for slot in slots {
            switch slot {
            case .lifecycle(let tabId, let panelId, let key):
                guard let id = UUID(uuidString: tabId), let workspace = workspacesById[id] else { continue }
                workspace.clearAgentLifecycle(
                    key: key,
                    panelId: panelId.flatMap { UUID(uuidString: $0) }
                )
                cmuxDebugLog(
                    "agentState.lease.sweep lifecycle ws=\(id.uuidString.prefix(5)) key=\(key)"
                )
            case .status(let tabId, let key):
                guard let id = UUID(uuidString: tabId), let workspace = workspacesById[id] else { continue }
                workspace.statusEntries.removeValue(forKey: key)
                cmuxDebugLog(
                    "agentState.lease.sweep status ws=\(id.uuidString.prefix(5)) key=\(key)"
                )
            }
        }
    }
    // MARK: - Availability

    func controlSidebarTabManagerAvailable() -> Bool {
        tabManager != nil
    }

    // MARK: - Scheduled sidebar mutations (status / agent / blocks)

    nonisolated func controlSidebarScheduleStatusUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        value: String,
        icon: String?,
        color: String?,
        url: URL?,
        priority: Int,
        format: ControlSidebarMetadataFormat,
        panelID: UUID?,
        pid: Int32?
    ) {
        let appFormat = SidebarMetadataFormat(rawValue: format.rawValue) ?? .plain
        #if DEBUG
        // Mirror of the lifecycle write log: a `target=selected` here for an
        // agent-owned key means the client's --tab never parsed (the misroute
        // class that leaked one machine's activity text onto other rows).
        cmuxDebugLog(
            "agentState.write status key=\(key) len=\(value.count) prio=\(priority) "
            + "target=\(Self.controlSidebarTargetDescription(target)) "
            + "panel=\(panelID?.uuidString.prefix(5) ?? "nil") "
            + "conn=\(SocketConnectionAgentLeaseToken.current().map { String(describing: ObjectIdentifier($0)).suffix(6) } ?? "none")"
        )
        #endif
        // Remote tmux mirror panes are valid status targets too: the agent
        // plugin publishes its activity and goal lines with the same mirror
        // pane id it uses for lifecycle. Without this the strict `panels`
        // check dropped every such write on the floor (dot painted, text
        // never did), and the only activity text that ever reached a mirror
        // row was misrouted through the selected-workspace fallback.
        controlSidebarSchedulePanelOwnedMutation(
            target: target,
            panelID: panelID,
            includeRemoteTmuxPanes: true
        ) { _, owner in
            guard Self.shouldReplaceStatusEntry(
                current: owner.statusEntry(key: key, panelId: panelID),
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: appFormat
            ) else {
                // Still update PID tracking even if the status display hasn't changed.
                if let pid {
                    owner.recordAgentPID(key: key, pid: pid, panelId: panelID)
                }
                return
            }
            owner.setStatusEntry(SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: appFormat,
                timestamp: Date()
            ), key: key, panelId: panelID)
            if let pid {
                owner.recordAgentPID(key: key, pid: pid, panelId: panelID)
            }
        }
    }

    nonisolated func controlSidebarScheduleStatusClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?
    ) {
        // Same reach as the upsert: the plugin's end-of-turn clear names the
        // mirror pane too, and a dropped clear leaves stale text on the row.
        controlSidebarSchedulePanelOwnedMutation(
            target: target,
            panelID: panelID,
            includeRemoteTmuxPanes: true
        ) { _, owner in
            owner.clearStatusEntry(key: key, panelId: panelID)
            owner.clearAgentPID(key: key, panelId: panelID, clearStatus: false)
        }
    }

    nonisolated func controlSidebarScheduleAgentPIDRecord(
        target: ControlSidebarTabTarget,
        key: String,
        pid: Int32,
        panelID: UUID?
    ) {
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            let didReplaceAgentRuntime = owner.recordAgentPID(
                key: key,
                pid: pid,
                panelId: panelID
            )
            if didReplaceAgentRuntime, let panelID {
                TerminalNotificationStore.shared.clearNotifications(
                    forTabId: owner.id,
                    surfaceId: panelID,
                    discardQueuedNotifications: false
                )
            }
        }
    }

    nonisolated func controlSidebarParseAgentLifecycle(_ raw: String) -> String? {
        AgentHibernationLifecycleState.parseCLIValue(raw)?.rawValue
    }

    /// `nonisolated` so the vault-registry disk IO runs on the calling
    /// (socket-worker) thread; only the tab resolution + panel-directory
    /// candidate snapshot crosses to the main actor, as `set_agent_lifecycle`'s
    /// single hop. The legacy body resolved the tab before the registration-id
    /// syntax check; both are side-effect-free reads, so checking the pure
    /// syntax first (to skip the hop for non-registry keys) cannot change the
    /// result.
    nonisolated func controlSidebarIsAllowedAgentLifecycleKey(
        _ key: String,
        target: ControlSidebarTabTarget,
        panelID: UUID?
    ) -> Bool {
        if AgentHibernationLifecycleStatusKeys.isAllowed(key) {
            return true
        }
        // The manual namespace is reserved for workspace_loading; a custom
        // vault agent must not claim it (hibernation ignores manual keys).
        guard !AgentHibernationLifecycleStatusKeys.isManualKey(key) else {
            return false
        }
        guard CmuxVaultAgentRegistration.isValidID(key) else {
            return false
        }
        let scope: ControlSidebarAgentLifecycleRegistryScope? = v2MainSync {
            guard let owner = self.controlSidebarResolvePanelOwner(
                target: target,
                panelID: panelID
            ) else {
                return nil
            }
            return owner.agentLifecycleRegistryScope(panelId: panelID)
        }
        guard let scope else { return false }
        let registry = scope.loadRegistry()
        return registry.registration(id: key) != nil
    }

    nonisolated func controlSidebarScheduleAgentLifecycle(
        target: ControlSidebarTabTarget,
        key: String,
        lifecycleRawValue: String,
        panelID: UUID?
    ) {
        guard let lifecycle = AgentHibernationLifecycleState(rawValue: lifecycleRawValue) else {
            // Unreachable: the coordinator only forwards a value this app produced.
            return
        }
        #if DEBUG
        // Every remote-painted lifecycle write is forensics-grade: when a row
        // shows the wrong dot, this line says what arrived, from which socket
        // connection (lease token), and where it was aimed.
        cmuxDebugLog(
            "agentState.write lifecycle key=\(key) state=\(lifecycleRawValue) "
            + "target=\(Self.controlSidebarTargetDescription(target)) "
            + "panel=\(panelID?.uuidString.prefix(5) ?? "nil") "
            + "conn=\(SocketConnectionAgentLeaseToken.current().map { String(describing: ObjectIdentifier($0)).suffix(6) } ?? "none")"
        )
        #endif
        // Remote tmux mirror panes are valid lifecycle targets: agents on a
        // mirrored machine self-report over the forwarded control socket.
        controlSidebarSchedulePanelOwnedMutation(
            target: target,
            panelID: panelID,
            includeRemoteTmuxPanes: true
        ) { _, owner in
            owner.setAgentLifecycle(key: key, panelId: panelID, lifecycle: lifecycle)
        }
    }

    private nonisolated static func controlSidebarTargetDescription(_ target: ControlSidebarTabTarget) -> String {
        switch target {
        case .selected: return "selected"
        case .workspace(let id): return "ws:\(id.uuidString.prefix(5))"
        case .index(let index): return "index:\(index)"
        }
    }

    func controlSidebarSetWorkspaceLoading(
        tabArg: String?,
        key: String,
        on: Bool
    ) -> ControlSidebarWorkspaceLoadingState? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        let before = tab.hasRunningAgentLifecycle(key: key)
        if on {
            // Workspace-scoped: exactly one panel holds a manual key at a time,
            // so reasserting `on` after focus moves never duplicates the loader.
            _ = tab.clearAgentLifecycle(key: key, panelId: nil)
            // Bound distinct manual loaders per workspace so socket clients
            // can't grow lifecycle-key state without limit.
            let manualLoaderCount = tab.agentLifecycleStatesByPanelId.values.reduce(0) { partial, states in
                partial + states.keys.reduce(0) { AgentHibernationLifecycleStatusKeys.isManualKey($1) ? $0 + 1 : $0 }
            }
            guard manualLoaderCount < 32 else {
                return ControlSidebarWorkspaceLoadingState(
                    before: before,
                    after: tab.hasRunningAgentLifecycle(key: key),
                    failureReason: "Manual workspace loading limit reached"
                )
            }
            if let panelId = tab.focusedPanelId ?? tab.panels.keys.first {
                tab.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
            } else {
                return ControlSidebarWorkspaceLoadingState(
                    before: before,
                    after: false,
                    failureReason: "Workspace has no panel for manual loading"
                )
            }
        } else {
            // Workspace-scoped: clear from all panels, not just the caller's.
            _ = tab.clearAgentLifecycle(key: key, panelId: nil)
        }
        return ControlSidebarWorkspaceLoadingState(before: before, after: tab.hasRunningAgentLifecycle(key: key))
    }

    /// `nonisolated` with the settings write inside `agent_hibernation`'s
    /// single main hop: `setValues` posts the settings-did-change notification
    /// synchronously, and its observers assume the main thread (the legacy
    /// body always ran there). Keeping the hop synchronous also preserves the
    /// apply-then-reply ordering main-thread test callers rely on.
    nonisolated func controlSidebarSetAgentHibernation(enabled: Bool) {
        v2MainSync {
            AgentHibernationSettings.setValues(enabled: enabled)
        }
    }

    nonisolated func controlSidebarScheduleAgentPIDClear(
        target: ControlSidebarTabTarget,
        key: String,
        panelID: UUID?,
        clearStatus: Bool,
        requireOwnedKey: Bool = false
    ) {
        controlSidebarSchedulePanelOwnedMutation(target: target, panelID: panelID) { _, owner in
            owner.clearAgentPID(
                key: key,
                panelId: panelID,
                clearStatus: clearStatus,
                requireOwnedKey: requireOwnedKey
            )
        }
    }

    nonisolated func controlSidebarScheduleMetadataBlockUpsert(
        target: ControlSidebarTabTarget,
        key: String,
        markdown: String,
        priority: Int
    ) {
        controlSidebarScheduleMutation(target: target) { _, tab in
            guard Self.shouldReplaceMetadataBlock(
                current: tab.metadataBlocks[key],
                key: key,
                markdown: markdown,
                priority: priority
            ) else {
                return
            }
            tab.metadataBlocks[key] = SidebarMetadataBlock(
                key: key,
                markdown: markdown,
                priority: priority,
                timestamp: Date()
            )
        }
    }

    // MARK: - Synchronous metadata reads / writes

    func controlSidebarStatusEntries(tabArg: String?) -> [ControlSidebarStatusEntrySnapshot]? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        return tab.sidebarStatusEntriesInDisplayOrder().map(Self.controlSidebarStatusEntrySnapshot)
    }

    /// Converts one app status entry to its Sendable wire snapshot.
    private static func controlSidebarStatusEntrySnapshot(_ entry: SidebarStatusEntry) -> ControlSidebarStatusEntrySnapshot {
        ControlSidebarStatusEntrySnapshot(
            key: entry.key,
            value: entry.value,
            icon: entry.icon,
            color: entry.color,
            urlAbsoluteString: entry.url?.absoluteString,
            priority: entry.priority,
            format: ControlSidebarMetadataFormat(rawValue: entry.format.rawValue) ?? .plain
        )
    }

    func controlSidebarMetadataBlocks(tabArg: String?) -> [ControlSidebarMetadataBlockSnapshot]? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        return tab.sidebarMetadataBlocksInDisplayOrder().map(Self.controlSidebarMetadataBlockSnapshot)
    }

    /// Converts one app metadata block to its Sendable wire snapshot.
    private static func controlSidebarMetadataBlockSnapshot(_ block: SidebarMetadataBlock) -> ControlSidebarMetadataBlockSnapshot {
        ControlSidebarMetadataBlockSnapshot(
            key: block.key,
            markdown: block.markdown,
            priority: block.priority
        )
    }

    func controlSidebarClearMetadataBlock(tabArg: String?, key: String) -> ControlSidebarClearMetaBlockResolution {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return .tabNotFound
        }
        if tab.metadataBlocks.removeValue(forKey: key) == nil {
            return .keyNotFound
        }
        return .removed
    }

    nonisolated func controlSidebarIsValidLogLevel(_ raw: String) -> Bool {
        SidebarLogLevel(rawValue: raw) != nil
    }

    func controlSidebarAppendLog(
        tabArg: String?,
        message: String,
        levelRawValue: String,
        source: String?
    ) -> Bool {
        guard let level = SidebarLogLevel(rawValue: levelRawValue) else {
            // Unreachable: the coordinator validates the level first.
            return true
        }
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.logEntries.append(SidebarLogEntry(message: message, level: level, source: source, timestamp: Date()))
        let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
        let limit = max(1, min(500, configuredLimit))
        if tab.logEntries.count > limit {
            tab.logEntries.removeFirst(tab.logEntries.count - limit)
        }
        return true
    }

    func controlSidebarClearLog(tabArg: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.logEntries.removeAll()
        return true
    }

    func controlSidebarLogEntries(tabArg: String?) -> [ControlSidebarLogEntrySnapshot]? {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else { return nil }
        return tab.logEntries.map(Self.controlSidebarLogEntrySnapshot)
    }

    /// Converts one app log entry to its Sendable wire snapshot.
    private static func controlSidebarLogEntrySnapshot(_ entry: SidebarLogEntry) -> ControlSidebarLogEntrySnapshot {
        ControlSidebarLogEntrySnapshot(
            levelRawValue: entry.level.rawValue,
            message: entry.message,
            source: entry.source
        )
    }

    func controlSidebarSetProgress(tabArg: String?, value: Double, label: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.progress = SidebarProgressState(value: value, label: label)
        return true
    }

    func controlSidebarClearProgress(tabArg: String?) -> Bool {
        guard let tab = controlSidebarResolveTabForReport(tabArg: tabArg) else {
            return false
        }
        tab.progress = nil
        return true
    }
}
