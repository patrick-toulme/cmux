import Foundation

/// Owns the per-endpoint ``RemoteTmuxSSHTransport`` instances ``RemoteTmuxController``
/// uses for SSH discovery, keyed by ``RemoteTmuxHost/connectionHash`` (destination +
/// port + identity).
///
/// Factored out of the controller so the get-or-create lifecycle and the scattered
/// dictionary bookkeeping live behind a small `@MainActor` surface. It only manages
/// the transport handles: dropping a handle never touches the host's master, which
/// keeps serving for the next attach (see `RemoteTmuxController.detachAll`); only
/// ``disconnectMaster(host:)`` exits one.
@MainActor
final class RemoteTmuxTransportRegistry {
    private var transports: [String: RemoteTmuxSSHTransport] = [:]

    /// Invoked with the connection hash of every transport this registry
    /// drops (remove, disconnect, removeAll), so per-endpoint state that
    /// only makes sense next to a transport (the tunnel healer) ends with it.
    var onTransportRemoved: ((String) -> Void)?

    /// Returns (creating if needed) the transport for a host.
    func transport(for host: RemoteTmuxHost) -> RemoteTmuxSSHTransport {
        if let existing = transports[host.connectionHash] {
            return existing
        }
        let transport = RemoteTmuxSSHTransport(host: host)
        transports[host.connectionHash] = transport
        return transport
    }

    /// Tears down a host's shared SSH master (used when removing a host).
    func disconnectMaster(host: RemoteTmuxHost) async {
        let transport = transports.removeValue(forKey: host.connectionHash)
        if transport != nil { onTransportRemoved?(host.connectionHash) }
        await transport?.shutdownMaster()
    }

    /// Whether a transport already exists for `connectionHash` (the reattach-reclaim check).
    func contains(connectionHash: String) -> Bool {
        transports[connectionHash] != nil
    }

    /// Removes and returns the transport for `connectionHash`, if any.
    @discardableResult
    func remove(connectionHash: String) -> RemoteTmuxSSHTransport? {
        let removed = transports.removeValue(forKey: connectionHash)
        if removed != nil { onTransportRemoved?(connectionHash) }
        return removed
    }

    /// The hosts of every currently-tracked transport.
    func allHosts() -> [RemoteTmuxHost] {
        transports.values.map(\.host)
    }

    /// Drops every tracked transport (does not exit their masters).
    func removeAll() {
        let hashes = Array(transports.keys)
        transports.removeAll()
        for hash in hashes { onTransportRemoved?(hash) }
    }
}
