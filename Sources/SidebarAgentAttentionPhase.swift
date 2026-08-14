import AppKit
import CMUXAgentLaunch
import Foundation
import SwiftUI

/// Per-workspace agent attention phase for the sidebar row pill and the
/// Agent Inbox, resolved in strict priority order: a decision the user must
/// approve outranks a question, which outranks work in motion, which
/// outranks an unseen completion. Resting workspaces show nothing.
///
/// One resolver feeds every surface (shared-behavior policy): the pill, the
/// inbox rows, and any aggregate counts all derive from this value, so the
/// states can never disagree across surfaces.
enum SidebarAgentAttentionPhase: String, Equatable, Sendable {
    /// A blocking permission or plan decision is waiting (act now).
    case pendingApproval
    /// The agent asked a question, or a hook reported needs-input.
    case awaitingInput
    /// At least one agent is actively working.
    case working
    /// An agent finished a turn after the user last visited the workspace.
    case unreadCompleted
}

enum SidebarAgentAttentionResolver {
    /// Resolves the workspace's phase from the three shared inputs:
    /// - `pendingDecisionKinds`: the Feed's pending blocking decisions
    ///   (permission / exit-plan / question) attributed to the workspace.
    /// - `statesByPanelId`: the agent lifecycle map. Manual loader keys are
    ///   ignored — a `workspace_loading` spinner is not agent work.
    /// - `hasUnreadTurnComplete`: an unread turn-complete notification.
    static func phase(
        pendingDecisionKinds: [WorkstreamKind],
        statesByPanelId: [UUID: [String: AgentHibernationLifecycleState]],
        hasUnreadTurnComplete: Bool
    ) -> SidebarAgentAttentionPhase? {
        if pendingDecisionKinds.contains(where: { $0 == .permissionRequest || $0 == .exitPlan }) {
            return .pendingApproval
        }
        let sawQuestion = pendingDecisionKinds.contains(.question)
        var sawNeedsInput = false
        var sawRunning = false
        for states in statesByPanelId.values {
            for (key, state) in states {
                guard !AgentHibernationLifecycleStatusKeys.isManualKey(key) else { continue }
                switch state {
                case .needsInput: sawNeedsInput = true
                case .running: sawRunning = true
                case .idle, .unknown: break
                }
            }
        }
        if sawQuestion || sawNeedsInput { return .awaitingInput }
        if sawRunning { return .working }
        if hasUnreadTurnComplete { return .unreadCompleted }
        return nil
    }
}

extension SidebarAgentAttentionPhase {
    /// Short pill label. Three-color discipline: amber is "act now", indigo
    /// is "answer me", blue is "in motion", green is "finished unseen".
    var pillLabel: String {
        switch self {
        case .pendingApproval:
            String(localized: "sidebar.attention.approval", defaultValue: "Approval")
        case .awaitingInput:
            String(localized: "sidebar.attention.input", defaultValue: "Input")
        case .working:
            String(localized: "sidebar.attention.working", defaultValue: "Working")
        case .unreadCompleted:
            String(localized: "sidebar.attention.done", defaultValue: "Done")
        }
    }

    var pillTooltip: String {
        switch self {
        case .pendingApproval:
            String(
                localized: "sidebar.attention.approval.tooltip",
                defaultValue: "An agent is waiting for your approval"
            )
        case .awaitingInput:
            String(
                localized: "sidebar.attention.input.tooltip",
                defaultValue: "An agent is waiting for your input"
            )
        case .working:
            String(
                localized: "sidebar.attention.working.tooltip",
                defaultValue: "An agent is working"
            )
        case .unreadCompleted:
            String(
                localized: "sidebar.attention.done.tooltip",
                defaultValue: "An agent finished since you last looked"
            )
        }
    }

    var pillColor: Color {
        switch self {
        case .pendingApproval: .orange
        case .awaitingInput: .indigo
        case .working: .blue
        case .unreadCompleted: .green
        }
    }

    /// The same palette for AppKit-backed drawing (the activity spinner).
    var indicatorNSColor: NSColor {
        switch self {
        case .pendingApproval: .systemOrange
        case .awaitingInput: .systemIndigo
        case .working: .systemBlue
        case .unreadCompleted: .systemGreen
        }
    }

    /// Whether the phase earns an agent inbox row. Working is "in motion",
    /// not actionable: it shows on the session row's indicator only, so the
    /// inbox holds nothing but decisions to make and results to review.
    var isActionable: Bool {
        switch self {
        case .pendingApproval, .awaitingInput, .unreadCompleted: return true
        case .working: return false
        }
    }

    /// Inbox sort rank: decisions first, then questions, then unseen
    /// completions. Ties keep the caller's stable machine/session order.
    var inboxRank: Int {
        switch self {
        case .pendingApproval: 0
        case .awaitingInput: 1
        case .working: 2
        case .unreadCompleted: 3
        }
    }
}

/// The compact colored status pill on an agent inbox row.
struct SidebarAgentAttentionPill: View {
    let phase: SidebarAgentAttentionPhase
    let fontSize: CGFloat

    var body: some View {
        Text(phase.pillLabel)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(phase.pillColor.opacity(0.88)))
            .safeHelp(phase.pillTooltip)
            .accessibilityLabel(phase.pillTooltip)
    }
}

/// The compact wordless state indicator on a session row: the agent
/// activity spinner tinted by phase while work is in motion, a static
/// colored dot for the act-now and unseen-done phases. The inbox rows
/// carry the labels; the session row only needs the color.
struct SidebarAgentAttentionStatusIndicator: View {
    let phase: SidebarAgentAttentionPhase
    let side: CGFloat
    /// On the selected row the accent background would swallow the phase
    /// color, so the indicator joins the row's inverted foreground like
    /// every other accessory (the selected row is being looked at; the
    /// color signal matters on the rows that are not).
    var usesInvertedForeground: Bool = false

    private var dotColor: Color {
        usesInvertedForeground ? Color.white.opacity(0.92) : phase.pillColor.opacity(0.92)
    }

    private var spinnerColor: NSColor {
        usesInvertedForeground ? NSColor.white.withAlphaComponent(0.85) : phase.indicatorNSColor
    }

    var body: some View {
        Group {
            if phase == .working {
                SidebarAgentActivityIndicator(spinnerColor: spinnerColor, side: side)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: side * 0.66, height: side * 0.66)
                    .frame(width: side, height: side)
            }
        }
        .safeHelp(phase.pillTooltip)
        .accessibilityLabel(phase.pillTooltip)
    }
}
