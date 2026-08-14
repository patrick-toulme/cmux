import Foundation

/// Classifies a remote tmux pane's foreground command
/// (`#{pane_current_command}`, a bare `comm` name) as a known coding agent,
/// and maps it onto the allowlisted lifecycle status key the rest of the
/// agent machinery uses.
///
/// This is the zero-install heuristic half of remote agent activity: it can
/// only say "an agent binary is in the foreground" (spinner on/off). Rich
/// states (idle at the prompt, needs input, tool activity) come from the
/// opencode plugin reporting over the forwarded control socket, which
/// publishes under the SAME status key so the two sources share one
/// lifecycle entry per panel instead of fighting each other.
enum RemoteTmuxAgentActivityClassifier {
    /// The allowlisted lifecycle status key for a foreground command, or nil
    /// when the command is not a recognizable agent binary.
    ///
    /// Matching uses the shared agent definitions' `directBasenames` only:
    /// tmux reports the kernel `comm` name, so argv needles cannot apply.
    /// Wrapper runtimes (`bun`, `node`, `python`) are deliberately NOT
    /// classified — a dev server would spin forever; wrapped agents get
    /// their fidelity from the plugin instead.
    static func lifecycleStatusKey(forCommand command: String) -> String? {
        let basename = (command as NSString).lastPathComponent.lowercased()
        guard !basename.isEmpty else { return nil }
        guard let definition = CmuxTaskManagerCodingAgentDefinition.builtIns.first(where: {
            $0.directBasenames.contains(basename)
        }) else { return nil }
        return statusKey(forDefinitionId: definition.id)
    }

    /// Maps an agent definition id onto its lifecycle status key, returning
    /// nil for agents without an allowlisted key (their lifecycle entries
    /// would be dropped by the socket-side validation anyway, and the sidebar
    /// treats unknown keys as noise).
    static func statusKey(forDefinitionId id: String) -> String? {
        // The definition ids and the allowlist agree except for Claude
        // ("claude" vs "claude_code").
        let candidate = id == "claude" ? "claude_code" : id
        guard AgentHibernationLifecycleStatusKeys.allowedStatusKeys.contains(candidate) else {
            return nil
        }
        return candidate
    }
}
