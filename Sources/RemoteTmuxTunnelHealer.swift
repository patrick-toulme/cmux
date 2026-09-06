import Foundation

/// The user-visible state of one machine's configured tunnels.
struct RemoteTmuxTunnelStatus: Equatable, Sendable {
    /// A forward the server (or a local bind) refused, with ssh's reason.
    struct Failure: Equatable, Sendable {
        let spec: RemoteTmuxForwardSpec
        let reason: String
    }

    /// The master generation the status describes.
    let generation: UInt64
    /// Forwards the master is known to carry.
    let established: [RemoteTmuxForwardSpec]
    /// Forwards the healer keeps retrying.
    let failed: [Failure]

    var hasProblem: Bool { !failed.isEmpty }
}

/// Keeps the user's configured ssh tunnels (`RemoteForward`, `LocalForward`,
/// `DynamicForward` for the host) established on the machine's shared master.
///
/// OpenSSH requests the config's forwards once, when the master opens, and
/// never retries a refused one. A master that opens while a previous
/// generation's server-side session still holds the remote port (the
/// session lingers through a relay until sshd's ClientAlive reaps it,
/// minutes after the local master died) therefore runs for its whole life
/// without the tunnel, and every relay blip costs the tunnels again. The
/// healer owns the retry: for each master generation it re-registers every
/// configured forward through the live master (`-O cancel` then `-O
/// forward`, both scoped to that one forward, so an unestablished
/// registration left by the refused open is cleared first), then keeps
/// re-requesting only the refused ones on a capped backoff until they land
/// or the master changes. The one-time cancel+forward of an already
/// established tunnel is a sub-second listener blip; in-flight forwarded
/// connections are channels and never notice.
///
/// One instance per endpoint, owned by ``RemoteTmuxController`` and driven
/// from the same edges as the agent bridge (a confirmed master, a
/// user-driven attach). All ssh work goes through `Operations`, so the
/// healer is testable against a fake transport.
@MainActor
final class RemoteTmuxTunnelHealer {
    /// The transport surface the healer needs.
    struct Operations: Sendable {
        var configuredForwards: @Sendable () async -> [RemoteTmuxForwardSpec]
        var cancel: @Sendable (RemoteTmuxForwardSpec) async -> Void
        var request: @Sendable (RemoteTmuxForwardSpec) async throws -> RemoteTmuxCommandResult
        /// The transport's current master generation; a cycle stops the
        /// moment it no longer matches the generation it heals.
        var currentGeneration: @Sendable () async -> UInt64
    }

    /// Retry delays after a refused forward, then the last one forever.
    nonisolated static let defaultBackoff: [Duration] = [
        .seconds(15), .seconds(30), .seconds(60), .seconds(120), .seconds(300),
    ]

    /// How long after a healthy cycle a `force` is treated as already done.
    /// An attach fires the gate's heal and the user-driven forced heal within
    /// seconds of each other; re-registering every tunnel twice would blip
    /// each listener twice for nothing.
    nonisolated static let defaultForceCooldown: Duration = .seconds(60)

    let host: RemoteTmuxHost
    private let operations: Operations
    private let connectionLog: RemoteTmuxConnectionLog
    private let backoff: [Duration]
    private let forceCooldown: Duration
    private let onStatusChanged: @MainActor (RemoteTmuxTunnelStatus?) -> Void

    private(set) var status: RemoteTmuxTunnelStatus? {
        didSet {
            guard oldValue != status else { return }
            onStatusChanged(status)
        }
    }
    /// The generation of the running (or last finished) cycle.
    private var cycleGeneration: UInt64 = 0
    /// Whether the last cycle for `cycleGeneration` ended with every forward established.
    private var cycleHealthy = false
    private var lastHealthyCompletion: ContinuousClock.Instant?
    private var cycleTask: Task<Void, Never>?

    init(
        host: RemoteTmuxHost,
        operations: Operations,
        connectionLog: RemoteTmuxConnectionLog,
        backoff: [Duration] = RemoteTmuxTunnelHealer.defaultBackoff,
        forceCooldown: Duration = RemoteTmuxTunnelHealer.defaultForceCooldown,
        onStatusChanged: @escaping @MainActor (RemoteTmuxTunnelStatus?) -> Void = { _ in }
    ) {
        self.host = host
        self.operations = operations
        self.connectionLog = connectionLog
        self.backoff = backoff.isEmpty ? RemoteTmuxTunnelHealer.defaultBackoff : backoff
        self.forceCooldown = forceCooldown
        self.onStatusChanged = onStatusChanged
    }

    /// Whether a heal cycle is currently running (or sleeping between retries).
    var isHealing: Bool { cycleTask != nil }

    /// Starts a heal cycle for `generation` unless one already ran it to a
    /// healthy end or is in flight. `force` (a user-driven attach) restarts
    /// the cycle now: a refused tunnel gets an immediate retry instead of
    /// waiting out its backoff, and a healthy generation older than
    /// ``defaultForceCooldown`` is re-verified. Generation `0` (no master
    /// observed) is a no-op.
    func heal(generation: UInt64, force: Bool = false) {
        guard generation > 0 else { return }
        if generation == cycleGeneration {
            if cycleHealthy {
                guard force, !healthyWithinForceCooldown else { return }
            } else if cycleTask != nil, !force {
                return
            }
        }
        cycleTask?.cancel()
        cycleGeneration = generation
        cycleHealthy = false
        cycleTask = Task { [weak self] in
            await self?.runCycle(generation: generation)
        }
    }

    private var healthyWithinForceCooldown: Bool {
        guard let lastHealthyCompletion else { return false }
        return ContinuousClock.now - lastHealthyCompletion < forceCooldown
    }

    /// Stops any running cycle (the host was detached or disconnected).
    func stop() {
        cycleTask?.cancel()
        cycleTask = nil
        status = nil
    }

    private func runCycle(generation: UInt64) async {
        defer {
            // Only the task that owns the cycle clears it; a `force` restart
            // already replaced `cycleTask` with the new one.
            if !Task.isCancelled { cycleTask = nil }
        }
        let specs = await operations.configuredForwards()
        guard !Task.isCancelled, generation == cycleGeneration else { return }
        guard !specs.isEmpty else {
            markHealthy()
            status = RemoteTmuxTunnelStatus(generation: generation, established: [], failed: [])
            return
        }
        var established: [RemoteTmuxForwardSpec] = []
        var failures = specs.map { RemoteTmuxTunnelStatus.Failure(spec: $0, reason: "") }
        var loggedReasons: [RemoteTmuxForwardSpec: String] = [:]
        var attempt = 0
        while !failures.isEmpty {
            guard !Task.isCancelled, await operations.currentGeneration() == generation else { return }
            var stillFailing: [RemoteTmuxTunnelStatus.Failure] = []
            for failure in failures {
                let spec = failure.spec
                if Task.isCancelled { return }
                // Clear whatever registration the master holds for this spec
                // (a refused open leaves one that would short-circuit the
                // request below with "found existing forwarding").
                await operations.cancel(spec)
                let result = try? await operations.request(spec)
                if let result, result.succeeded {
                    established.append(spec)
                    connectionLog.record(
                        host: host,
                        kind: .tunnelRestored,
                        message: "tunnel \(spec) established on the master",
                        detail: "\(spec)",
                        generation: generation
                    )
                } else {
                    let reason = Self.failureReason(result)
                    stillFailing.append(RemoteTmuxTunnelStatus.Failure(spec: spec, reason: reason))
                    if loggedReasons[spec] != reason {
                        loggedReasons[spec] = reason
                        connectionLog.record(
                            host: host,
                            kind: .tunnelFailed,
                            message: "tunnel \(spec) unavailable: \(reason); retrying",
                            detail: "\(spec)\n\(result?.stderr ?? "")",
                            generation: generation
                        )
                    }
                }
            }
            failures = stillFailing
            guard generation == cycleGeneration else { return }
            status = RemoteTmuxTunnelStatus(
                generation: generation,
                established: established,
                failed: failures
            )
            if failures.isEmpty { break }
            let delay = backoff[min(attempt, backoff.count - 1)]
            attempt += 1
            do { try await Task.sleep(for: delay) } catch { return }
        }
        if generation == cycleGeneration { markHealthy() }
    }

    private func markHealthy() {
        cycleHealthy = true
        lastHealthyCompletion = .now
    }

    /// The first informative stderr line of a refused `-O forward` (OpenSSH
    /// prefixes it with the function name; the CLI-facing reason drops that).
    static func failureReason(_ result: RemoteTmuxCommandResult?) -> String {
        guard let result else { return "ssh -O forward could not be run" }
        let lines = result.stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let preferred = lines.first { $0.contains("forwarding request failed") || $0.contains("forwarding failed") }
            ?? lines.first { !$0.hasPrefix("muxclient:") }
            ?? lines.first
        guard var reason = preferred else { return "ssh -O forward exited \(result.exitCode)" }
        if let colon = reason.range(of: "forwarding request failed: ") {
            reason = String(reason[colon.upperBound...])
        }
        return reason
    }
}
