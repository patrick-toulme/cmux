import Foundation

/// Mutable control-channel state for one pane snapshot transaction.
struct RemoteTmuxPendingPaneSeed {
    let id: UUID
    let kind: RemoteTmuxPaneSeedKind
    var discardedOutput: [Data] = []
    var snapshot: Data
    var catchUpOutput: [Data] = []
    var bufferedLiveByteCount = 0
    var isCaptureInstalled = false
    /// Rows the installed capture actually carried; the depth-parity
    /// verdict compares this against the pane's height and history size.
    var capturedLineCount: Int?

    var retainedByteCount: Int {
        snapshot.count + bufferedLiveByteCount
    }
}
