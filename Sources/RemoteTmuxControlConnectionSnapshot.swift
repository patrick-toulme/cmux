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
    let totalOutputBytes: Int
    let recentEvents: [String]
}
