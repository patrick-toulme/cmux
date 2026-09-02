import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator sidebar v1 dispatch")
struct ControlCommandCoordinatorSidebarV1Tests {
    @Test func agentPIDClearForwardsOwnedKeyRequirement() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "clear_agent_pid",
            args: "omp.stale --tab=\(workspaceID.uuidString) --panel=\(panelID.uuidString) "
                + "--clear-status --require-owned-key"
        )

        #expect(response == "OK")
        #expect(context.agentPIDClearCall?.target == .workspace(workspaceID))
        #expect(context.agentPIDClearCall?.key == "omp.stale")
        #expect(context.agentPIDClearCall?.panelID == panelID)
        #expect(context.agentPIDClearCall?.clearStatus == true)
        #expect(context.agentPIDClearCall?.requireOwnedKey == true)
    }

    /// Field regression: agent activity text carrying a bare apostrophe
    /// (`bash: find p0's layer range`) opened a quote that never closed, the
    /// tokenizer swallowed every later option into the value, and the write
    /// (now without `--tab`) landed on whatever workspace was selected.
    @Test func statusUpsertWithUnbalancedQuoteKeepsOptionsAndTarget() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "set_status",
            args: "opencode.activity bash: Find p0's layer range, stage counts --priority=-1 --lease=1 "
                + "--tab=\(workspaceID.uuidString) --panel=\(panelID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.statusUpsertCall?.target == .workspace(workspaceID))
        #expect(context.statusUpsertCall?.key == "opencode.activity")
        #expect(context.statusUpsertCall?.value == "bash: Find p0's layer range, stage counts")
        #expect(context.statusUpsertCall?.priority == -1)
        #expect(context.statusUpsertCall?.panelID == panelID)
        #expect(context.registeredLeases == [.status(tabId: workspaceID.uuidString, key: "opencode.activity")])
    }

    /// Balanced quoting keeps working exactly as before (a quoted value may
    /// carry spaces, the other quote mark, and escaped quotes).
    @Test func statusUpsertHonorsBalancedQuotes() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "set_status",
            args: "opencode.activity \"bash: echo it's a \\\"quoted\\\" thing\" --priority=-1 "
                + "--tab=\(workspaceID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.statusUpsertCall?.target == .workspace(workspaceID))
        #expect(context.statusUpsertCall?.value == "bash: echo it's a \"quoted\" thing")
        #expect(context.statusUpsertCall?.priority == -1)
    }

    @Test func statusClearForwardsPanelScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "clear_status",
            args: "omp --tab=\(workspaceID.uuidString) --panel=\(panelID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.statusClearCall?.target == .workspace(workspaceID))
        #expect(context.statusClearCall?.key == "omp")
        #expect(context.statusClearCall?.panelID == panelID)
    }

    @Test func workspaceLoadingFailureReasonReturnsErrorLine() {
        let context = FakeSidebarV1ControlCommandContext()
        context.workspaceLoadingResult = ControlSidebarWorkspaceLoadingState(
            before: false,
            after: false,
            failureReason: "Manual workspace loading limit reached"
        )
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "workspace_loading",
            args: "manual on --tab=workspace-1"
        )

        #expect(response == "ERROR: Manual workspace loading limit reached")
        #expect(context.workspaceLoadingCall?.tabArg == "workspace-1")
        #expect(context.workspaceLoadingCall?.key == "manual")
        #expect(context.workspaceLoadingCall?.on == true)
    }

    @Test func workspaceLoadingRejectsExplicitEmptyTabBeforeMutation() {
        let context = FakeSidebarV1ControlCommandContext()
        context.workspaceLoadingResult = ControlSidebarWorkspaceLoadingState(before: false, after: true)
        let coordinator = ControlCommandCoordinator(context: context)

        let blankForms = [
            "manual on --tab",
            "manual on --tab=",
        ]

        for args in blankForms {
            let response = coordinator.handleSidebarV1(
                command: "workspace_loading",
                args: args
            )

            #expect(response == "ERROR: Invalid --tab; expected a workspace id, ref, or index")
            #expect(context.workspaceLoadingCall == nil)
        }
    }

    @Test func shellStateForwardsTerminalLifecycleScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        let workspaceID = UUID()
        let panelID = UUID()
        let terminalLifecycleID = UUID()

        let response = coordinator.handleSidebarV1(
            command: "report_shell_state",
            args: "prompt --tab=\(workspaceID.uuidString) "
                + "--panel=\(panelID.uuidString) "
                + "--terminal-lifecycle-id=\(terminalLifecycleID.uuidString)"
        )

        #expect(response == "OK")
        #expect(context.shellStateCall?.scope.workspaceID == workspaceID)
        #expect(context.shellStateCall?.scope.panelID == panelID)
        #expect(
            context.shellStateCall?.scope.terminalLifecycleID
                == terminalLifecycleID
        )
        #expect(context.shellStateCall?.stateRawValue == "promptIdle")
    }

    @Test func shellStateRejectsMalformedTerminalLifecycleScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "report_shell_state",
            args: "prompt --tab=\(UUID().uuidString) "
                + "--panel=\(UUID().uuidString) "
                + "--terminal-lifecycle-id=not-a-uuid"
        )

        #expect(response == "ERROR: Terminal session is out of date; restart the shell and try again")
        #expect(context.shellStateCall == nil)
    }

    @Test func shellStateRejectsLifecycleIdentityWithoutCompleteScope() {
        let context = FakeSidebarV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        let response = coordinator.handleSidebarV1(
            command: "report_shell_state",
            args: "prompt --tab=\(UUID().uuidString) "
                + "--terminal-lifecycle-id=\(UUID().uuidString)"
        )

        #expect(response == "ERROR: Terminal session is out of date; restart the shell and try again")
        #expect(context.shellStateCall == nil)
    }
}
