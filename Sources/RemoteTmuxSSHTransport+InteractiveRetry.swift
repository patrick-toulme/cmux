extension RemoteTmuxSSHTransport {
    /// Whether a failed `BatchMode=yes` connect failed because the local
    /// `ProxyCommand` closed the transport *silently* before SSH could surface
    /// an explicit auth error string.
    ///
    /// A `ProxyCommand` with its own pre-handshake authentication or 2FA leg
    /// can silently abort under BatchMode because it has no tty to prompt on.
    /// An interactive retry lets that prompt surface. The match is anchored to
    /// OpenSSH's pipe-transport placeholders (`to UNKNOWN port 65535`,
    /// `by UNKNOWN port 65535`) and suppressed when stderr also carries a
    /// diagnostic marker for a non-recoverable proxy failure.
    static func indicatesProxyCommandTransportClosed(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        let hasProxyPlaceholder = lowered.contains("to unknown port 65535")
            || lowered.contains("by unknown port 65535")
        guard hasProxyPlaceholder else { return false }
        return !Self.nonRecoverableProxyMarkers.contains(where: { lowered.contains($0) })
    }

    /// Lowercase substrings that indicate a `ProxyCommand` / `ProxyJump`
    /// closure was not silent, so an interactive ssh retry will not help.
    private static let nonRecoverableProxyMarkers: [String] = [
        "connect failed:",                  // ssh -W target connection refused/timeout
        ": open failed:",                   // channel N: open failed: ...
        "stdio forwarding failed",          // ProxyJump -W teardown
        "port forwarding failed",
        "connection refused",
        "no route to host",
        "network is unreachable",
        "operation timed out",              // BSD/macOS TCP connect timeout
        "connection timed out",             // Linux TCP connect timeout (nc / OpenSSH)
        "could not resolve hostname",       // OpenSSH DNS-resolution wrapper (all OSes)
        "name or service not known",        // Linux getaddrinfo NXDOMAIN
        "nodename nor servname provided",   // BSD/macOS getaddrinfo NXDOMAIN (e.g. ProxyCommand `nc`)
        "temporary failure in name resolution",
        "kex_exchange_identification:",     // target spoke no SSH / closed during key exchange
        "ssh_exchange_identification:",     // target closed during banner exchange
        "command not found",                // bash/zsh: ProxyCommand binary missing
        ": not found",                      // dash/busybox sh: ProxyCommand binary missing
        "no such file or directory",        // shell: ProxyCommand path does not exist
        "exec format error",                // shell: ProxyCommand binary for wrong architecture
    ]

    /// Convenience predicate composing the recovery rule the controller's
    /// BatchMode-discovery catch sites share: a failure where re-running ssh
    /// interactively will open the shared master and let the next batch probe
    /// succeed.
    ///
    /// All routing sites in ``RemoteTmuxController`` go through one name so a
    /// future recovery signal does not silently regress any catch site that
    /// spelled out only one constituent predicate.
    static func indicatesInteractiveRetryWillHelp(_ stderr: String) -> Bool {
        indicatesAuthRequired(stderr)
            || indicatesProxyCommandTransportClosed(stderr)
    }

    /// Whether a failed app-spawned connect was a DIRECT network failure that
    /// the user's TERMINAL environment may nonetheless fix.
    ///
    /// GUI processes inherit launchd's minimal environment, and corp ssh
    /// configs routinely gate their relay on that environment: `Match exec`
    /// probes and `ProxyCommand` helpers (corporate relay tools) that
    /// exist on the terminal's PATH but not the app's. When such a stanza
    /// silently fails to apply, ssh dials the resolved HostName directly and
    /// times out — while `ssh <host>` works fine in the user's shell. Routing
    /// these to the interactive terminal retry costs nothing when the host is
    /// genuinely down (the same error shows there, readable) and heals the
    /// environment-dependent case completely.
    ///
    /// ONLY for the initial `cmux ssh-tmux` attach flow (a terminal is
    /// present). The reconnect master gate deliberately keeps the strict
    /// predicate: a mid-outage network failure must keep retrying silently,
    /// never park N sessions waiting for a manual re-authentication.
    static func indicatesInteractiveNetworkRetryMayHelp(_ stderr: String) -> Bool {
        guard !indicatesMasterUnavailable(stderr) else { return false }
        let lowered = stderr.lowercased()
        return Self.directConnectFailureMarkers.contains(where: { lowered.contains($0) })
    }

    /// Lowercase substrings of OpenSSH's direct-dial failures.
    private static let directConnectFailureMarkers: [String] = [
        "operation timed out",              // BSD/macOS TCP connect timeout
        "connection timed out",             // Linux TCP connect timeout
        "connection refused",
        "no route to host",
        "network is unreachable",
        "could not resolve hostname",
        "name or service not known",        // Linux getaddrinfo NXDOMAIN
        "nodename nor servname provided",   // BSD/macOS getaddrinfo NXDOMAIN
        "temporary failure in name resolution",
        "kex_exchange_identification:",     // gateway spoke no SSH / closed mid-handshake
        "ssh_exchange_identification:",
    ]

    /// The recovery rule for the INITIAL attach flow only: everything the
    /// strict predicate accepts, plus direct network failures the terminal
    /// environment may fix. `cmux ssh-tmux` call sites route through this;
    /// the reconnect gate must keep ``indicatesInteractiveRetryWillHelp``.
    static func indicatesInteractiveAttachRetryWillHelp(_ stderr: String) -> Bool {
        indicatesInteractiveRetryWillHelp(stderr)
            || indicatesInteractiveNetworkRetryMayHelp(stderr)
    }
}
