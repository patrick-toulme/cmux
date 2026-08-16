struct RemoteTmuxControlConnectionSnapshot: Sendable {
    let started: Bool
    let enterReceived: Bool
    let exited: Bool
    /// Reconnect loop parked awaiting the user's interactive re-authentication
    /// (see ``RemoteTmuxControlConnection/resumeReconnectAfterAuth()``).
    let reconnectSuspendedAwaitingAuth: Bool
    let sessionId: Int?
    let windowCount: Int
    let windowIDs: [Int]
    let paneOutputByteCounts: [Int: Int]
    /// Seed snapshot bytes delivered per pane; the scrollback-depth signal
    /// (captures ride command replies, which the output counters miss).
    let paneSeedByteCounts: [Int: Int]
    let totalOutputBytes: Int
    let recentEvents: [String]
}
