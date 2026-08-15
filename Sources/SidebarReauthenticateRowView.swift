import SwiftUI

/// The one-press "Reauthenticate" row above the machine sections: reruns the
/// CLI attach for every machine in this window in a fresh local terminal
/// (interactive authentication needs a real tty). One shared mutation path —
/// `TabManager.reauthenticateRemoteHosts()` — also backs the machine section
/// header context menu entry.
struct SidebarReauthenticateRowView: View, Equatable {
    let fontScale: CGFloat
    let onReauthenticate: () -> Void
    @State private var isHovering = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.fontScale == rhs.fontScale
    }

    private var metrics: SidebarWorkspaceGroupHeaderMetrics {
        SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale)
    }

    private var tooltip: String {
        String(
            localized: "sidebar.reauthenticate.tooltip",
            defaultValue: "Opens a terminal and reruns the attach command for every machine in this window, so expired sessions authenticate again in one step."
        )
    }

    var body: some View {
        Button(action: onReauthenticate) {
            HStack(spacing: 6) {
                CmuxSystemSymbolImage(
                    systemName: "key.horizontal.fill",
                    pointSize: metrics.iconFontSize,
                    weight: .semibold,
                    appliesGlobalFontMagnification: true
                )
                .foregroundStyle(.secondary)
                .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                .accessibilityHidden(true)
                Text(String(
                    localized: "sidebar.reauthenticate.title",
                    defaultValue: "Reauthenticate"
                ))
                .cmuxFont(size: metrics.nameFontSize, weight: .medium)
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.leading, 4)
            .padding(.trailing, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
        )
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .onHover { isHovering = $0 }
        .safeHelp(tooltip)
        .accessibilityLabel(Text(String(
            localized: "sidebar.reauthenticate.a11y",
            defaultValue: "Reauthenticate all machines in this window"
        )))
    }
}
