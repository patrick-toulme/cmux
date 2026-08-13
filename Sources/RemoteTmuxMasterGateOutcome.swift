/// What a reconnecting control connection should do after asking the host's
/// master gate (``RemoteTmuxController``, backed by the transport's
/// single-flight ``RemoteTmuxSSHTransport/ensureMasterReady()``) to make the
/// shared SSH ControlMaster usable again.
///
/// The gate exists so that when a host's master dies with N sessions attached,
/// the N reconnect loops coalesce on ONE master reopen (at most one
/// authentication, one security-key touch) instead of racing N independent
/// ssh clients at a dead socket.
enum RemoteTmuxMasterGateOutcome: Sendable, Equatable {
    /// The master is live: spawn the mux-only `tmux -CC` client now.
    case ready

    /// The master could not be reopened for a transient reason (host
    /// unreachable, timeout): keep the capped-backoff retry loop going.
    case retryLater

    /// Reopening requires interactive authentication that BatchMode cannot
    /// service. Suspend the retry loop — retrying would only spam
    /// authentication attempts (blinking the user's security key) — until the
    /// user re-authenticates (e.g. re-runs `cmux ssh-tmux <destination>`) and
    /// the controller resumes the suspended connections.
    case authRequired
}
