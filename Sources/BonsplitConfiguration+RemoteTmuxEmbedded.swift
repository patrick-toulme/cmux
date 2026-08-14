import Bonsplit

extension BonsplitConfiguration {
    /// Workspace-derived policy for a nested remote-tmux split tree.
    var remoteTmuxEmbedded: BonsplitConfiguration {
        var configuration = self
        configuration.allowSplits = true
        configuration.allowCloseLastPane = false
        configuration.allowTabReordering = false
        configuration.allowCrossPaneTabMove = false
        configuration.allowsTabContextMenu = false
        configuration.autoCloseEmptyPanes = false
        configuration.contentViewLifecycle = .keepAllAlive
        configuration.newTabPosition = .end
        // A mirrored tmux pane is always exactly one tab, so `.multipleTabs`
        // never shows the nested per-pane tab bar: the workspace keeps the
        // single legacy tab row (the tmux window strip) instead of stacking
        // a second, redundant bar above every pane.
        configuration.tabBarVisibility = .multipleTabs
        configuration.dividerPositionRange = 0...1

        configuration.appearance.minimumPaneWidth = 1
        configuration.appearance.minimumPaneHeight = 1
        configuration.appearance.tabBarLeadingInset = 0
        configuration.appearance.enableAnimations = false
        configuration.appearance.splitButtons = configuration.appearance.splitButtons.filter {
            switch $0.action {
            case .splitRight, .splitDown:
                return true
            default:
                return false
            }
        }
        return configuration
    }
}
