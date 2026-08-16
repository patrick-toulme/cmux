import Foundation

/// Decides when the remote agent bridge (reverse-forwarded control socket +
/// tmux env pins + plugin push) must be (re)configured for an endpoint.
///
/// The bridge's reverse forward is registered on the shared SSH ControlMaster
/// with `ssh -O forward`, so it dies with the master. A master silently
/// reopened by the reconnect gate (sleep/wake, network blip, credential
/// refresh) therefore comes back with ZERO forward registrations while the
/// tmux server still advertises the forwarded socket path to every pane:
/// agents keep dialing a socket file nobody listens on and lifecycle
/// reporting goes dark until the user manually reruns `cmux ssh-tmux`.
///
/// This schedule pairs the transport's master generation (a count of observed
/// dead-to-serving transitions) with the generation the bridge was last
/// successfully configured for:
/// - a generation the bridge already covers is a no-op (a mere control-stream
///   blip on a surviving master never reconfigures),
/// - a new generation triggers exactly one reconfigure even when many parked
///   reconnect loops coalesce on the same reopened master,
/// - `force` (a user-driven attach) always reconfigures, so rerunning
///   `cmux ssh-tmux` stays the manual heal for env pins and plugin pushes,
/// - a failed attempt records nothing, keeping the endpoint eligible for the
///   caller's retry and for the next gate pass.
struct RemoteTmuxAgentBridgeSchedule {
    private var configuredGenerationByConnectionHash: [String: UInt64] = [:]
    private var inFlightConnectionHashes: Set<String> = []

    /// Claims the endpoint for one configuration attempt. Returns `false`
    /// while another attempt is in flight. Unless `force`, it also returns
    /// `false` when the generation is unobserved (`0`) or already configured.
    mutating func begin(connectionHash: String, generation: UInt64, force: Bool) -> Bool {
        guard !inFlightConnectionHashes.contains(connectionHash) else { return false }
        guard force
            || (generation > 0
                && configuredGenerationByConnectionHash[connectionHash] != generation)
        else { return false }
        inFlightConnectionHashes.insert(connectionHash)
        return true
    }

    /// Releases the in-flight claim; records the generation only when the
    /// bridge actually came up (the forward request succeeded).
    mutating func finish(connectionHash: String, generation: UInt64, configured: Bool) {
        inFlightConnectionHashes.remove(connectionHash)
        if configured {
            configuredGenerationByConnectionHash[connectionHash] = generation
        }
    }
}
