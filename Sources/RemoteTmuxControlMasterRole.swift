/// Who may CREATE the shared SSH ControlMaster for a remote-tmux endpoint —
/// the single place authentication (and a security-key touch) can happen —
/// versus who may only ride an existing master.
///
/// Historically every remote-tmux ssh invocation ran `ControlMaster=auto`,
/// which silently self-promotes to a brand-new authenticated connection
/// whenever the master socket is dead. With N mirrored sessions reconnecting
/// on independent backoff timers, that fanned out N racing publickey auths per
/// retry round — for FIDO keys, an invisible touch-request storm. Splitting
/// invocations into one explicit opener and mux-only clients makes "exactly
/// one authenticated connection per machine" a structural property instead of
/// a timing accident.
enum RemoteTmuxControlMasterRole: Sendable, Equatable {
    /// May open (and therefore authenticate) the shared master:
    /// `ControlMaster=auto`. Reserved for the single-flight readiness gate
    /// (``RemoteTmuxSSHTransport/ensureMasterReady()``) and the interactive
    /// `cmux ssh-tmux` ssh that runs in the user's terminal
    /// (``RemoteTmuxHost/interactiveAuthInvocation(sshExecutablePath:controlPersistSeconds:)``).
    case opener

    /// Multiplex-only: rides a live master and can NEVER fall back to a fresh
    /// authenticated connection. `ControlMaster=no` selects mux-client mode,
    /// and the direct-connection fallback is severed with a `ProxyCommand`
    /// that fails fast, emitting ``RemoteTmuxHost/masterUnavailableSentinel``
    /// on stderr — so callers classify "master gone" and route recovery
    /// through the readiness gate instead of authenticating on their own.
    /// A client also never carries the user's config port forwards (those are
    /// the master's) and pins `ControlPersist=no` so OpenSSH does not silence
    /// the sentinel; see
    /// ``RemoteTmuxHost/sshControlArguments(controlPersistSeconds:batchMode:role:)``.
    case client
}
