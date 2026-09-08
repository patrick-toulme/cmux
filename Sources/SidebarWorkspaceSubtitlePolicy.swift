import Foundation

/// The text a workspace row shows under its title.
///
/// The latest notification is the agent's last completed turn (or a
/// `cmux notify` aimed at the workspace). Once the user submits a newer
/// prompt, that text is history: the agent has moved on, and the row read as
/// stale (the previous answer under a session busy on the next question) or
/// as belonging to another session (a notification that landed on the
/// workspace from elsewhere). The newer prompt takes the line until the next
/// notification lands, so the row says what the agent is on right now. Both
/// stamps are app-side receipt times, so a remote agent's clock never enters
/// the comparison.
enum SidebarWorkspaceSubtitlePolicy {
    /// Resolves the row subtitle from the workspace's latest notification and
    /// its latest submitted prompt.
    ///
    /// - Parameters:
    ///   - latestNotificationText: The trimmed latest notification body/title,
    ///     already gated by the "show notification message" setting.
    ///   - latestNotificationCreatedAt: When that notification was received.
    ///   - latestSubmittedMessage: The preview of the last prompt the user
    ///     submitted to an agent in the workspace.
    ///   - latestSubmittedAt: When that prompt was recorded.
    /// - Returns: The subtitle, or nil when the row has nothing to say.
    static func resolve(
        latestNotificationText: String?,
        latestNotificationCreatedAt: Date?,
        latestSubmittedMessage: String?,
        latestSubmittedAt: Date?
    ) -> String? {
        let prompt = latestSubmittedMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prompt, !prompt.isEmpty, let submittedAt = latestSubmittedAt else {
            return latestNotificationText
        }
        guard let latestNotificationText, let createdAt = latestNotificationCreatedAt else {
            return prompt
        }
        return submittedAt > createdAt ? prompt : latestNotificationText
    }
}
