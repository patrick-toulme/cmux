import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// Immutable presentation state for one agent inbox row: a mirrored tmux
/// window (the user's unit of agent work — one agent per window) that
/// currently needs attention. Live models are reduced to this value before
/// the lazy-list boundary; only action closures are bound when a row is
/// realized.
struct SidebarRemoteTmuxWindowRowSnapshot: Equatable {
    let workspaceId: UUID
    /// The window's stable container panel (the workspace tab hosting the
    /// window's pane tree).
    let windowPanelId: UUID
    /// The tmux window name.
    let title: String
    /// Where the window lives ("machine · session"): inbox rows sit above
    /// the machine sections, so each row names its origin.
    let contextLabel: String?
    let attentionPhase: SidebarAgentAttentionPhase?
    /// The window is the selected tab of the selected workspace.
    let isActive: Bool
    let fontScale: CGFloat
    let rowSpacing: CGFloat
}

/// One agent inbox row: click to jump to the tmux window that wants the
/// user, with the labeled attention pill on the trailing edge.
struct SidebarRemoteTmuxWindowRowView: View, Equatable {
    // Closures are excluded: the parent recreates them on each evaluation.
    // The snapshot carries every render input.
    nonisolated static func == (
        lhs: SidebarRemoteTmuxWindowRowView,
        rhs: SidebarRemoteTmuxWindowRowView
    ) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    let snapshot: SidebarRemoteTmuxWindowRowSnapshot
    let onSelect: () -> Void

    private func scaled(_ size: CGFloat) -> CGFloat {
        size * snapshot.fontScale
    }

    var body: some View {
        HStack(spacing: 5) {
            CmuxSystemSymbolImage(
                systemName: "macwindow",
                pointSize: scaled(8.5),
                weight: .medium,
                appliesGlobalFontMagnification: true
            )
            .foregroundStyle(.secondary)
            .frame(width: scaled(12), height: scaled(12))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.title)
                    .cmuxFont(size: scaled(11), weight: snapshot.isActive ? .semibold : .regular)
                    .foregroundStyle(snapshot.isActive ? Color.primary : Color.primary.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let contextLabel = snapshot.contextLabel {
                    Text(contextLabel)
                        .cmuxFont(size: scaled(9))
                        .foregroundStyle(Color.secondary.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if let attentionPhase = snapshot.attentionPhase {
                SidebarAgentAttentionPill(
                    phase: attentionPhase,
                    fontSize: scaled(8.5)
                )
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, SidebarWorkspaceGroupingMetrics.memberIndent)
        .padding(.trailing, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(snapshot.isActive ? Color.accentColor.opacity(0.22) : Color.clear)
        )
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .onTapGesture { onSelect() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(snapshot.title))
        .accessibilityHint(Text(String(
            localized: "remoteTmuxWindowRow.a11yHint",
            defaultValue: "Jump to this tmux window"
        )))
        .accessibilityIdentifier("sidebarRemoteTmuxWindow.\(snapshot.windowPanelId.uuidString)")
    }
}

/// The "Needs attention" header above the agent inbox rows. Renders only
/// while the inbox is non-empty, so a quiet sidebar shows no trace of it.
struct SidebarAgentInboxHeaderView: View, Equatable {
    let itemCount: Int
    let fontScale: CGFloat

    private var metrics: SidebarWorkspaceGroupHeaderMetrics {
        SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale)
    }

    var body: some View {
        HStack(spacing: 6) {
            CmuxSystemSymbolImage(
                systemName: "tray.full",
                pointSize: metrics.iconFontSize,
                weight: .semibold,
                appliesGlobalFontMagnification: true
            )
            .foregroundStyle(.secondary)
            .frame(width: metrics.iconFrame, height: metrics.iconFrame)
            .accessibilityHidden(true)
            Text(String(localized: "sidebar.attention.inbox", defaultValue: "Needs attention"))
                .cmuxFont(size: metrics.nameFontSize, weight: .semibold)
                .foregroundStyle(Color.primary.opacity(0.9))
                .lineLimit(1)
            Text("\(itemCount)")
                .cmuxFont(size: metrics.unreadFontSize, weight: .medium)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.leading, 4)
        .padding(.trailing, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(String.localizedStringWithFormat(
            String(
                localized: "sidebar.attention.inbox.count.a11y",
                defaultValue: "%lld agents need attention"
            ),
            itemCount
        )))
    }
}
