import AppKit
import CmuxControlSocket
import CmuxRemoteSession
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Attention is scoped to the tmux WINDOW (one agent per tab): a remote
/// agent's lifecycle and turn-complete notification, addressed to its own
/// pane over the forwarded socket, light exactly that window in the inbox
/// and in `debug.attention_state`, and reading one window leaves its
/// neighbour's unseen completion in place.
@MainActor
@Suite(.serialized)
struct RemoteTmuxPerWindowAttentionTests {
    /// A mirrored session with two single-pane windows (@2 -> %4, @3 -> %6).
    @MainActor
    private final class Harness {
        let windowID: UUID
        let controller: RemoteTmuxController
        let host: RemoteTmuxHost
        let sessionName = "per-window-attention"
        let connection: RemoteTmuxControlConnection
        let writer: RemoteTmuxControlPipeWriter
        let pipe: Pipe
        let manager: TabManager
        let workspace: Workspace

        init() throws {
            let appDelegate = try #require(AppDelegate.shared)
            windowID = appDelegate.createMainWindow()
            manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
            controller = appDelegate.remoteTmuxController
            host = RemoteTmuxHost(destination: "per-window-\(UUID().uuidString)@host")
            connection = RemoteTmuxControlConnection(host: host, sessionName: sessionName)
            pipe = Pipe()
            writer = RemoteTmuxControlPipeWriter(
                handle: pipe.fileHandleForWriting,
                label: "remote-tmux-per-window-attention-test",
                maxPendingBytes: 1 << 16,
                onFailure: {}
            )
            connection.installStdinWriterForTesting(writer)
            connection.handleMessageForTesting(.enter)
            connection.handleMessageForTesting(
                .commandResult(commandNumber: 0, lines: [], isError: false)
            )
            controller.cacheConnection(connection)
            try controller.mirrorSession(host: host, sessionName: sessionName, into: manager)
            workspace = try #require(manager.tabs.first { $0.isRemoteTmuxMirror })

            connection.handleMessageForTesting(.commandResult(
                commandNumber: 1,
                lines: [
                    "@2 abcd,120x40,0,0,4 abcd,120x40,0,0,4 [*] first",
                    "@3 abcd,120x40,0,0,6 abcd,120x40,0,0,6 [] second",
                ],
                isError: false
            ))
            while let kind = connection.pendingCommandKindsForTesting.first {
                let lines: [String]
                switch kind {
                case .paneRects(let windowId, _):
                    lines = windowId == 2
                        ? ["%4 0 0 120 40 1 off :0 \"host\""]
                        : ["%6 0 0 120 40 1 off :0 \"host\""]
                case .paneReflow:
                    lines = ["0|zsh"]
                default:
                    lines = []
                }
                connection.handleMessageForTesting(
                    .commandResult(commandNumber: 2, lines: lines, isError: false)
                )
            }
        }

        /// The stable container panel that IS the tab for tmux window `windowId`.
        func windowPanelId(_ windowId: Int) throws -> UUID {
            let sessionMirror = try #require(workspace.remoteTmuxSessionMirror)
            return try #require(sessionMirror.panelIdByWindow[windowId])
        }

        /// The mirror pane panel the remote agent bridge resolves `%paneId` to.
        func panePanelId(windowId: Int, paneId: Int) throws -> UUID {
            let mirror = try #require(
                workspace.remoteTmuxWindowMirror(forPanelId: try windowPanelId(windowId))
            )
            return try #require(mirror.panel(forPane: paneId)).id
        }

        func windowPhase(_ windowId: Int) throws -> SidebarAgentAttentionPhase? {
            VerticalTabsSidebar.remoteTmuxWindowAttentionPhase(
                workspace: workspace,
                windowPanelId: try windowPanelId(windowId),
                showsAttentionStates: true
            )
        }

        func inboxWindowPanelIds() -> [UUID] {
            VerticalTabsSidebar.agentInboxItems(
                tabs: [workspace],
                remoteHostKeyByWorkspaceId: [workspace.id: host.connectionHash],
                showsAttentionStates: true
            ).map(\.windowPanelId)
        }

        func debugWindowPhases() -> [String: String] {
            var phases: [String: String] = [:]
            for entry in TerminalController.debugAttentionWindowPayloads(workspace: workspace) {
                guard let windowPanelId = entry["window_panel_id"] as? String,
                      let phase = entry["phase"] as? String else { continue }
                phases[windowPanelId] = phase
            }
            return phases
        }

        func tearDown() {
            TerminalNotificationStore.shared.clearAll()
            controller.detach(host: host, sessionName: sessionName)
            writer.close()
            try? pipe.fileHandleForReading.close()
            let identifier = "cmux.main.\(windowID.uuidString)"
            NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
            AppDelegate.shared?.forgetRecoverableMainWindowRoute(windowId: windowID)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    /// The plugin's `set_agent_lifecycle ... --tab=<session> --panel=<pane>`
    /// for one window's pane paints that window Working and nothing else:
    /// the neighbour window stays quiet, the inbox stays empty (motion is
    /// not actionable), and the per-window debug payload says the same.
    @Test func runningLifecycleOnOnePaneLightsOnlyItsWindow() throws {
        TerminalNotificationStore.shared.clearAll()
        let harness = try Harness()
        defer { harness.tearDown() }
        let firstWindow = try harness.windowPanelId(2)
        let secondWindow = try harness.windowPanelId(3)
        let firstPane = try harness.panePanelId(windowId: 2, paneId: 4)

        let reply = TerminalController.shared.handleSocketLine(
            "set_agent_lifecycle opencode running --lease=1 "
                + "--tab=\(harness.workspace.id.uuidString) --panel=\(firstPane.uuidString)"
        )
        #expect(reply == "OK")
        TerminalMutationBus.shared.drainForTesting()

        #expect(try harness.windowPhase(2) == .working)
        #expect(try harness.windowPhase(3) == nil)
        #expect(harness.inboxWindowPanelIds().isEmpty)
        #expect(harness.debugWindowPhases() == [
            firstWindow.uuidString: "working",
            secondWindow.uuidString: "none",
        ])

        // The session row still aggregates: any window working reads Working.
        #expect(SidebarAgentAttentionResolver.phase(
            pendingDecisionKinds: [],
            statesByPanelId: harness.workspace.agentLifecycleStatesByPanelId,
            hasUnreadTurnComplete: false
        ) == .working)
    }

    /// A turn-complete notification addressed to one window's pane is that
    /// window's unseen completion alone: it is the only inbox row, and
    /// reading the OTHER window (visiting its tab) leaves it in place.
    @Test func turnCompleteOnOnePaneIsThatWindowsUnseenCompletionAlone() throws {
        TerminalNotificationStore.shared.clearAll()
        let previousFocusOverride = AppFocusState.overrideIsFocused
        AppFocusState.overrideIsFocused = false
        defer { AppFocusState.overrideIsFocused = previousFocusOverride }
        let harness = try Harness()
        defer { harness.tearDown() }
        let firstWindow = try harness.windowPanelId(2)
        let secondWindow = try harness.windowPanelId(3)
        let firstPane = try harness.panePanelId(windowId: 2, paneId: 4)
        let secondPane = try harness.panePanelId(windowId: 3, paneId: 6)

        TerminalNotificationStore.shared.addNotification(
            tabId: harness.workspace.id,
            surfaceId: secondPane,
            title: "OpenCode",
            subtitle: "ship the fix",
            body: "Finished a turn",
            agentCategory: .turnComplete
        )

        #expect(try harness.windowPhase(3) == .unreadCompleted)
        #expect(try harness.windowPhase(2) == nil)
        #expect(harness.inboxWindowPanelIds() == [secondWindow])
        #expect(harness.debugWindowPhases() == [
            firstWindow.uuidString: "none",
            secondWindow.uuidString: "unreadCompleted",
        ])

        // Reading the first window (the notification-jump / visit path for
        // that tab) must not consume the second window's completion.
        TerminalNotificationStore.shared.markRead(forTabId: harness.workspace.id, surfaceId: firstPane)
        #expect(try harness.windowPhase(3) == .unreadCompleted)
        #expect(harness.inboxWindowPanelIds() == [secondWindow])

        // Reading the second window itself does.
        TerminalNotificationStore.shared.markRead(forTabId: harness.workspace.id, surfaceId: secondPane)
        #expect(try harness.windowPhase(3) == nil)
        #expect(harness.inboxWindowPanelIds().isEmpty)
    }
}
