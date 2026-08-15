import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI

/// Immutable presentation state for one remote tmux machine's sidebar section
/// header. Live models are reduced to this value before the lazy-list
/// boundary; only action closures are bound when a row is realized.
struct SidebarRemoteHostSectionRowSnapshot: Equatable {
    let hostKey: String
    /// The SSH destination as the user typed it (`xxl`, `dev@host`).
    let label: String
    let isCollapsed: Bool
    let memberCount: Int
    /// Aggregated unread count across the machine's session workspaces while
    /// collapsed (a collapsed section must not swallow unread signal); 0 when
    /// expanded — the member rows carry their own badges then.
    let collapsedUnreadCount: Int
    /// The machine's reconnect loops are parked awaiting interactive
    /// re-authentication (`cmux ssh-tmux <destination>`).
    let authRequired: Bool
    let isPointerHovering: Bool
    let fontScale: CGFloat
    let rowSpacing: CGFloat
    let isFirstRow: Bool
}

/// Collapsible per-machine section header for remote tmux mirrors.
///
/// Unlike ``SidebarWorkspaceGroupHeaderView`` this header represents no anchor
/// workspace: every session of the machine stays a real child row, and the
/// header itself only carries the machine identity, the collapse toggle, and
/// machine-level verbs (new session, detach, kill).
struct SidebarRemoteHostSectionHeaderView: View, Equatable {
    // Closures are excluded: the parent recreates them on each evaluation.
    // The snapshot carries every render input.
    nonisolated static func == (
        lhs: SidebarRemoteHostSectionHeaderView,
        rhs: SidebarRemoteHostSectionHeaderView
    ) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    let snapshot: SidebarRemoteHostSectionRowSnapshot
    let onToggleCollapsed: () -> Void
    let onNewSession: () -> Void
    let onDetachMachine: () -> Void
    let onReauthenticateAll: () -> Void
    let onKillAllSessions: () -> Void
    let onContextMenuAppear: () -> Void
    let onContextMenuDisappear: () -> Void

    @State private var contextMenuVisible = false

    private var metrics: SidebarWorkspaceGroupHeaderMetrics {
        SidebarWorkspaceGroupHeaderMetrics(fontScale: snapshot.fontScale)
    }

    private var expandCollapseA11yLabel: String {
        snapshot.isCollapsed
            ? String(localized: "remoteTmuxHostSection.expand.a11y", defaultValue: "Expand machine")
            : String(localized: "remoteTmuxHostSection.collapse.a11y", defaultValue: "Collapse machine")
    }

    private var authRequiredTooltip: String {
        String(
            format: String(
                localized: "remoteTmuxHostSection.authRequired.tooltip",
                defaultValue: "Authentication needed. Run: cmux ssh-tmux %@"
            ),
            snapshot.label
        )
    }

    var body: some View {
        HStack(spacing: 4) {
            CmuxSystemSymbolImage(
                systemName: snapshot.isCollapsed ? "chevron.right" : "chevron.down",
                pointSize: metrics.chevronFontSize,
                weight: .semibold,
                appliesGlobalFontMagnification: true
            )
            .foregroundStyle(.secondary)
            .frame(width: metrics.chevronFrame, height: metrics.chevronFrame)
            .contentShape(Rectangle())
            .onTapGesture { onToggleCollapsed() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(expandCollapseA11yLabel))

            HStack(spacing: 6) {
                CmuxSystemSymbolImage(
                    systemName: "server.rack",
                    pointSize: metrics.iconFontSize,
                    weight: .semibold,
                    appliesGlobalFontMagnification: true
                )
                .foregroundStyle(.secondary)
                .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                .accessibilityHidden(true)
                Text(snapshot.label)
                    .cmuxFont(size: metrics.nameFontSize, weight: .semibold)
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(snapshot.memberCount)")
                    .cmuxFont(size: metrics.unreadFontSize, weight: .medium)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(String.localizedStringWithFormat(
                        String(
                            localized: "remoteTmuxHostSection.sessionCount.a11y",
                            defaultValue: "%lld tmux sessions"
                        ),
                        snapshot.memberCount
                    )))
                if snapshot.collapsedUnreadCount > 0 {
                    Text("\(snapshot.collapsedUnreadCount)")
                        .cmuxFont(size: metrics.unreadFontSize, weight: .semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, metrics.unreadHorizontalPadding)
                        .padding(.vertical, metrics.unreadVerticalPadding)
                        .background(Capsule().fill(Color.accentColor))
                        .accessibilityLabel(Text(String.localizedStringWithFormat(
                            String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                            snapshot.collapsedUnreadCount
                        )))
                }
                if snapshot.authRequired {
                    CmuxSystemSymbolImage(
                        systemName: "exclamationmark.triangle.fill",
                        pointSize: metrics.iconFontSize,
                        weight: .semibold,
                        appliesGlobalFontMagnification: true
                    )
                    .foregroundStyle(.yellow)
                    .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                    .safeHelp(authRequiredTooltip)
                    .accessibilityLabel(Text(authRequiredTooltip))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onToggleCollapsed() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(snapshot.label))
            .accessibilityHint(Text(expandCollapseA11yLabel))

            let plusVisible = snapshot.isPointerHovering && !contextMenuVisible
            Button(action: onNewSession) {
                CmuxSystemSymbolImage(
                    systemName: "plus",
                    pointSize: metrics.plusFontSize,
                    weight: .medium,
                    appliesGlobalFontMagnification: true
                )
                .foregroundStyle(.secondary)
                .frame(width: metrics.plusFrame, height: metrics.plusFrame)
                .contentShape(Rectangle())
                .opacity(plusVisible ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: metrics.plusFrame, height: metrics.plusFrame)
            .allowsHitTesting(plusVisible)
            .accessibilityHidden(!plusVisible)
            .accessibilityLabel(Text(String(
                localized: "remoteTmuxHostSection.newSession.a11y",
                defaultValue: "New tmux session on this machine"
            )))
        }
        .padding(.vertical, 5)
        .padding(.trailing, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
        .contentShape(Rectangle())
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .contextMenu {
            Button(
                String(
                    localized: "remoteTmuxHostSection.contextMenu.newSession",
                    defaultValue: "New tmux Session"
                ),
                action: onNewSession
            )
            .onAppear {
                contextMenuVisible = true
                onContextMenuAppear()
            }
            .onDisappear {
                contextMenuVisible = false
                onContextMenuDisappear()
            }
            Button(
                snapshot.isCollapsed
                    ? String(
                        localized: "remoteTmuxHostSection.contextMenu.expand",
                        defaultValue: "Expand Machine"
                    )
                    : String(
                        localized: "remoteTmuxHostSection.contextMenu.collapse",
                        defaultValue: "Collapse Machine"
                    ),
                action: onToggleCollapsed
            )
            Divider()
            Button(
                String(
                    localized: "remoteTmuxHostSection.contextMenu.reauthenticate",
                    defaultValue: "Reauthenticate All Machines"
                ),
                action: onReauthenticateAll
            )
            Button(
                String(
                    localized: "remoteTmuxHostSection.contextMenu.detach",
                    defaultValue: "Detach Machine (Keep Sessions Running)"
                ),
                action: onDetachMachine
            )
            Button(role: .destructive) {
                onKillAllSessions()
            } label: {
                Text(String(
                    localized: "remoteTmuxHostSection.contextMenu.killAll",
                    defaultValue: "Kill All Sessions…"
                ))
            }
        }
    }
}

/// Immutable presentation state for the "Local Mac" sidebar section header.
struct SidebarLocalMacSectionRowSnapshot: Equatable {
    let isCollapsed: Bool
    let memberCount: Int
    let fontScale: CGFloat
}

/// Collapsible section header for LOCAL workspaces interleaved among remote
/// machine sections. Purely a container: local workspaces need no machine
/// verbs, only the identity ("Local Mac"), the count, and the collapse
/// toggle — so a local terminal never reads as one of a machine's sessions.
struct SidebarLocalMacSectionHeaderView: View, Equatable {
    // Closures are excluded: the parent recreates them on each evaluation.
    nonisolated static func == (
        lhs: SidebarLocalMacSectionHeaderView,
        rhs: SidebarLocalMacSectionHeaderView
    ) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    let snapshot: SidebarLocalMacSectionRowSnapshot
    let onToggleCollapsed: () -> Void

    private var metrics: SidebarWorkspaceGroupHeaderMetrics {
        SidebarWorkspaceGroupHeaderMetrics(fontScale: snapshot.fontScale)
    }

    private var expandCollapseA11yLabel: String {
        snapshot.isCollapsed
            ? String(localized: "localMacSection.expand.a11y", defaultValue: "Expand Local Mac")
            : String(localized: "localMacSection.collapse.a11y", defaultValue: "Collapse Local Mac")
    }

    var body: some View {
        HStack(spacing: 4) {
            CmuxSystemSymbolImage(
                systemName: snapshot.isCollapsed ? "chevron.right" : "chevron.down",
                pointSize: metrics.chevronFontSize,
                weight: .semibold,
                appliesGlobalFontMagnification: true
            )
            .foregroundStyle(.secondary)
            .frame(width: metrics.chevronFrame, height: metrics.chevronFrame)
            .contentShape(Rectangle())
            .onTapGesture { onToggleCollapsed() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(expandCollapseA11yLabel))

            HStack(spacing: 6) {
                CmuxSystemSymbolImage(
                    systemName: "laptopcomputer",
                    pointSize: metrics.iconFontSize,
                    weight: .semibold,
                    appliesGlobalFontMagnification: true
                )
                .foregroundStyle(.secondary)
                .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                .accessibilityHidden(true)
                Text(String(localized: "localMacSection.title", defaultValue: "Local Mac"))
                    .cmuxFont(size: metrics.nameFontSize, weight: .semibold)
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(1)
                Text("\(snapshot.memberCount)")
                    .cmuxFont(size: metrics.unreadFontSize, weight: .medium)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(String.localizedStringWithFormat(
                        String(
                            localized: "localMacSection.workspaceCount.a11y",
                            defaultValue: "%lld local workspaces"
                        ),
                        snapshot.memberCount
                    )))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggleCollapsed() }
        }
        .padding(.vertical, 5)
        .padding(.leading, 4)
        .padding(.trailing, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .accessibilityElement(children: .combine)
    }
}
