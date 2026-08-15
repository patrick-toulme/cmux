import AppKit
import CmuxFoundation
import CmuxSettings
import Foundation

/// Live engine for "sort by active sessions" (`app.sortByActiveSessions`).
///
/// Listens for changes to the three agent-attention inputs — lifecycle
/// states, pending blocking feed decisions, and unread turn-completes —
/// coalesces bursts, and applies `WorkspaceActivitySorter`'s order through
/// the window's reorder coordinator. Idempotent by construction: an
/// already-sorted strip computes an identical order and applies nothing,
/// so the trigger→reorder→trigger cycle cannot oscillate. Applies are
/// deferred while a sidebar drag is in flight and rescheduled when it ends,
/// so the sorter never yanks rows out from under the pointer.
@MainActor
final class WorkspaceActivitySortCoordinator {
    /// Posted (object-less) whenever any agent-attention input changes.
    /// Mutation funnels ping this; the coordinator is the only listener that
    /// reorders, so every surface stays on one shared mutation path.
    static let attentionInputsDidChange = Notification.Name("cmux.agentAttentionInputsDidChange")

    private static let applyDebounce: Duration = .milliseconds(400)

    private weak var tabManager: TabManager?
    private var observers: [NSObjectProtocol] = []
    private var pendingApply: Task<Void, Never>?
    private var dragActive = false
    private var applyDeferredByDrag = false

    init(tabManager: TabManager) {
        self.tabManager = tabManager
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: Self.attentionInputsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleApply() }
        })
        // Mode changes (Settings UI, cmux.json reload) take effect without a
        // dedicated channel: the defaults bump reschedules one apply, and an
        // `off` mode makes that apply a no-op.
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleApply() }
        })
        observers.append(center.addObserver(
            forName: SidebarDragLifecycleNotification.stateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let draggedTabId = SidebarDragLifecycleNotification().tabId(from: notification)
            MainActor.assumeIsolated { self?.noteDragState(active: draggedTabId != nil) }
        })
    }

    deinit {
        pendingApply?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func noteDragState(active: Bool) {
        guard dragActive != active else { return }
        dragActive = active
        if !active, applyDeferredByDrag {
            applyDeferredByDrag = false
            scheduleApply()
        }
    }

    private func scheduleApply() {
        pendingApply?.cancel()
        pendingApply = Task { [weak self] in
            try? await Task.sleep(for: Self.applyDebounce)
            guard !Task.isCancelled else { return }
            self?.applyNow()
        }
    }

    /// Computes the desired order from live attention state and applies it
    /// when it differs from the current strip order.
    func applyNow() {
        guard let tabManager else { return }
        let mode = UserDefaultsSettingsClient(defaults: .standard)
            .value(for: SettingCatalog().app.sortByActiveSessions)
        guard mode != .off else { return }
        if dragActive {
            applyDeferredByDrag = true
            return
        }
        let showsAttentionStates = UserDefaultsSettingsClient(defaults: .standard)
            .value(for: SettingCatalog().sidebar.showAgentActivity)
        guard showsAttentionStates else { return }
        let items = tabManager.tabs.map { workspace in
            WorkspaceActivitySorter.Item(
                id: workspace.id,
                isPinned: workspace.isPinned,
                groupId: workspace.groupId,
                hostKey: workspace.remoteTmuxHostKey,
                attentionRank: SidebarAgentAttentionResolver.phase(
                    pendingDecisionKinds: FeedCoordinator.shared
                        .pendingBlockingDecisions(forWorkspace: workspace.id)
                        .map(\.kind),
                    statesByPanelId: workspace.agentLifecycleStatesByPanelId,
                    hasUnreadTurnComplete: TerminalNotificationStore.shared
                        .hasUnreadTurnComplete(forTabId: workspace.id)
                )?.inboxRank
            )
        }
        let desired = WorkspaceActivitySorter.desiredOrder(items: items, mode: mode)
        guard desired != items.map(\.id) else { return }
        tabManager.workspaceReordering.reorderWorkspaces(orderedWorkspaceIds: desired)
    }
}
