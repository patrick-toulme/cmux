extension RemoteTmuxSSHTransport {
    /// Whether a failed remote command failed because the host has no usable tmux.
    static func indicatesTmuxMissing(exitCode: Int32, stderr: String) -> Bool {
        guard exitCode == 127 else { return false }
        let lowered = stderr.lowercased()
        return lowered.contains(RemoteTmuxHost.tmuxNotFoundSentinel)
            || lowered.contains("exec: tmux: not found")
            || lowered.contains("tmux: command not found")
            || lowered.contains("tmux: not found")
    }

    /// Builds the domain error for a failed remote tmux command. Every
    /// non-benign failure passes through here, so this is also where the
    /// command's stderr is preserved in the connection log (the error text
    /// the CLI shows is capped; the log keeps the whole thing).
    nonisolated func commandFailure(_ result: RemoteTmuxCommandResult) -> RemoteTmuxError {
        if Self.indicatesTmuxMissing(exitCode: result.exitCode, stderr: result.stderr) {
            connectionLog.record(
                host: host,
                kind: .commandFailed,
                message: "tmux not found on the machine (exit \(result.exitCode))",
                detail: result.stderr
            )
            return .tmuxNotFound(destination: host.destination)
        }
        connectionLog.record(
            host: host,
            kind: .commandFailed,
            message: "remote command failed (exit \(result.exitCode))",
            detail: result.stderr
        )
        return .commandFailed(exitCode: result.exitCode, stderr: result.stderr)
    }
}
