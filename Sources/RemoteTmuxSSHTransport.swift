import Foundation

/// Runs commands against a remote host's tmux server over a shared SSH
/// ControlMaster connection.
///
/// This is the non-interactive half of the remote-tmux feature: session
/// discovery (`tmux list-sessions`) and one-shot mutations (`new-session`,
/// `new-window`, `split-window`, `kill-*`, `send-keys`). The latency-sensitive
/// `tmux -CC` control stream is NOT run here — it runs in a ghostty surface so
/// it gets a PTY. Both share the same ControlMaster socket
/// (``RemoteTmuxHost/controlSocketPath``), so the first to connect authenticates
/// and the rest are subsecond.
///
/// Modeled as an `actor` because it owns the per-host connection lifecycle and
/// serializes process launches; reads/writes are `async`.
actor RemoteTmuxSSHTransport {
    private static let maxCapturedOutputBytes = 1_048_576

    /// The host this transport talks to.
    ///
    /// `nonisolated` so the controller can read it synchronously (it's an immutable
    /// `Sendable` value) when tearing down masters on quit/window-close.
    nonisolated let host: RemoteTmuxHost

    private let sshExecutablePath: String

    /// The bound on concurrent master opens across the app (see
    /// ``RemoteTmuxMasterOpenGate``); every host's transport shares one.
    private let openGate: RemoteTmuxMasterOpenGate

    /// How long the BatchMode opener may spend before cmux gives up on
    /// BatchMode authentication for this open (see
    /// ``defaultOpenerStallTimeout``).
    private let openerStallTimeout: Duration

    /// A healthy corp open, relay and agent included, completes in 2-10s
    /// (measured; 12s under heavy agent contention). A BatchMode connect
    /// still authenticating is waiting on a human or on a wedged agent. The
    /// human case is the one to size for: a security key agent shows its own
    /// on-screen touch prompt while the BatchMode ssh waits, and holds the
    /// request for roughly two minutes before refusing it, so a user who
    /// notices the prompt within that window authenticates the whole fleet
    /// with one touch and no terminal detour. The budget therefore stays
    /// under the agent's hold (and under sshd's default 120s login grace)
    /// but leaves most of it for the touch. Past it the opener is killed and
    /// ``RemoteTmuxError/authenticationStalled(destination:seconds:)`` hands
    /// the machine to the interactive terminal; the open gate parks every
    /// other machine at the same time (see ``RemoteTmuxMasterOpenGate``).
    static let defaultOpenerStallTimeout: Duration = .seconds(90)

    /// In-flight shared-master warmup, if any. ``ensureMasterReady()`` funnels every
    /// concurrent caller through this single task so the master is opened at most
    /// once even though the actor is reentrant across awaits (see that method).
    private var readinessTask: Task<Bool, Error>?

    /// Remote `$HOME`, resolved once per endpoint (double-optional: `nil` =
    /// never asked, `.some(nil)` = asked and unusable). Needed to build the
    /// ABSOLUTE agent-link path for the post-attach env pin — programs read
    /// `SSH_AUTH_SOCK` literally, so `~` or `$HOME` cannot ride in the value.
    private var cachedRemoteHome: String??

    /// The local `SSH_AUTH_SOCK` hint the CLI captured in the user's terminal
    /// (see the `agent_socket` param of the remote-tmux socket verbs). Agent
    /// relays are served by the MASTER process's agent, so when the app — not
    /// the terminal — reopens the master after an outage, spawning it with
    /// the terminal's agent keeps forwarding aligned with the user's real
    /// agent even when a shell rc points the terminal at a non-launchd agent
    /// (gpg, 1Password, hardware-token). Empty/vanished sockets fall back to the app
    /// environment.
    private var agentSocketHint: String?

    /// Records the CLI-captured agent socket for this endpoint.
    func setAgentSocketHint(_ path: String?) {
        agentSocketHint = path
    }

    /// Count of observed dead-to-serving master transitions. Every `-O forward`
    /// registration (the remote agent bridge) lives inside one master process,
    /// so consumers key their configuration to this number: a bridge configured
    /// for generation N is dead the moment generation N+1 exists, no matter how
    /// the old master died (sleep, network blip, ControlPersist expiry, quit).
    /// Starts at 0 = never observed serving; the first confirmation, including
    /// a master surviving from a previous app run, is generation 1.
    private(set) var masterGeneration: UInt64 = 0

    /// Whether the most recent `-O check` observation found the master serving,
    /// so ``noteMasterAliveObservation(_:)`` bumps the generation exactly once
    /// per dead-to-serving edge (not on every warm re-check).
    private var lastObservedMasterAlive = false

    private func noteMasterAliveObservation(_ alive: Bool) {
        if alive, !lastObservedMasterAlive { masterGeneration &+= 1 }
        lastObservedMasterAlive = alive
    }

    /// - Parameters:
    ///   - host: the remote destination.
    ///   - sshExecutablePath: the local `ssh` binary (overridable for tests).
    ///   - openGate: the bound on concurrent opens shared across hosts
    ///     (overridable for tests).
    ///   - openerStallTimeout: the BatchMode opener's authentication budget
    ///     (overridable for tests).
    init(
        host: RemoteTmuxHost,
        sshExecutablePath: String = RemoteTmuxHost.defaultSSHExecutablePath(),
        openGate: RemoteTmuxMasterOpenGate = .shared,
        openerStallTimeout: Duration = RemoteTmuxSSHTransport.defaultOpenerStallTimeout
    ) {
        self.host = host
        self.sshExecutablePath = sshExecutablePath
        self.openGate = openGate
        self.openerStallTimeout = openerStallTimeout
    }

    // MARK: - High-level tmux operations

    /// Lists the tmux sessions on the remote server.
    ///
    /// Returns an empty array when the remote tmux server is not running yet
    /// (cmux treats "no server running" / "no sessions" as zero sessions, not
    /// an error, so the sidebar can still offer to create one).
    func listSessions() async throws -> [RemoteTmuxSession] {
        let result = try await runTmux([
            "list-sessions", "-F", RemoteTmuxSessionListParser.formatString,
        ])
        if !result.succeeded {
            if Self.indicatesAuthRequired(result.stderr) {
                throw RemoteTmuxError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
            }
            if Self.indicatesNoServer(result.stderr) { return [] }
            throw commandFailure(result)
        }
        return RemoteTmuxSessionListParser.parse(result.stdout)
    }

    /// Probes the remote tmux client version via `tmux -V`.
    ///
    /// - Returns: the parsed version, or `nil` when `tmux -V` succeeds but its
    ///   output has no `<major>.<minor>` (a dev/distro build like `tmux master`),
    ///   which callers treat as "unknown, allow".
    /// - Throws: ``RemoteTmuxError/commandFailed`` when the command itself fails, or
    ///   ``RemoteTmuxError/tmuxNotFound(destination:)`` when `tmux` is not installed.
    func tmuxClientVersion() async throws -> RemoteTmuxVersion? {
        let result = try await run(["tmux", "-V"])
        guard result.succeeded else {
            throw commandFailure(result)
        }
        return RemoteTmuxVersion.parse(result.stdout)
    }

    /// Probes the running tmux server version via the server's `#{version}` format.
    private func tmuxServerVersionProbe() async throws -> (serverExists: Bool, version: RemoteTmuxVersion?) {
        let result = try await runTmux(["display-message", "-p", "#{version}"])
        guard result.succeeded else {
            if Self.indicatesNoServer(result.stderr) { return (serverExists: false, version: nil) }
            throw commandFailure(result)
        }
        if let version = RemoteTmuxVersion.parseServerFormat(result.stdout) {
            return (serverExists: true, version: version)
        }
        return (serverExists: true, version: nil)
    }

    /// Probes the live-subscription capability directly when server version text
    /// is unparseable. New tmux recognizes `-B` but may fail with "no current
    /// client" outside control mode; old tmux rejects the flag itself.
    private func serverSupportsRefreshClientSubscriptions() async throws -> Bool {
        let result = try await runTmux(["refresh-client", "-B", "cmux_probe::#{version}"])
        if result.succeeded { return true }
        if Self.indicatesRefreshClientSubscriptionUnsupported(result.stderr) { return false }
        if Self.indicatesRefreshClientNeedsCurrentClient(result.stderr) { return true }
        throw commandFailure(result)
    }

    /// Asserts that the remote server supports live mirroring.
    ///
    /// Call this before any `tmux -CC` control stream can launch. An unparseable
    /// running-server version falls back to a direct `refresh-client -B`
    /// capability probe so dev/distro builds are treated consistently with the
    /// cold-start path while old servers still fail before attach.
    /// When no server is running, pass `true` only for paths that will create one;
    /// those paths gate on the tmux client binary that will become the new server.
    func assertMinimumTmuxVersion(checkClientWhenNoServer: Bool) async throws {
        let serverProbe = try await tmuxServerVersionProbe()
        if serverProbe.serverExists {
            guard let version = serverProbe.version else {
                if try await serverSupportsRefreshClientSubscriptions() {
                    return
                }
                throw RemoteTmuxError.unsupportedTmux(detected: RemoteTmuxError.unknownVersionDisplayName)
            }
            try Self.assertSupportedTmuxVersion(version)
            return
        }
        guard checkClientWhenNoServer else { return }
        if let version = try await tmuxClientVersion() {
            try Self.assertSupportedTmuxVersion(version)
        }
    }

    private static func assertSupportedTmuxVersion(_ version: RemoteTmuxVersion) throws {
        if !version.meetsMinimum {
            throw RemoteTmuxError.unsupportedTmux(detected: version.displayString)
        }
    }

    /// Asserts that the remote server supports live mirroring, then discovers sessions.
    func discoverMirrorSessions(createIfEmpty: Bool) async throws -> [RemoteTmuxSession] {
        try await assertMinimumTmuxVersion(checkClientWhenNoServer: createIfEmpty)
        var sessions = try await listSessions()
        if sessions.isEmpty, createIfEmpty {
            _ = try? await runTmux(["new-session", "-d"])
            sessions = try await listSessions()
        }
        return sessions
    }

    /// Runs a `tmux <args…>` command on the remote host and returns its result.
    ///
    /// - Parameter reopeningMasterIfNeeded: see ``run(_:reopeningMasterIfNeeded:)``.
    @discardableResult
    func runTmux(
        _ args: [String],
        reopeningMasterIfNeeded: Bool = true
    ) async throws -> RemoteTmuxCommandResult {
        try await run(["tmux"] + args, reopeningMasterIfNeeded: reopeningMasterIfNeeded)
    }

    /// Runs an arbitrary remote command over the shared SSH master.
    ///
    /// `ssh` concatenates the post-destination argv with spaces and the remote
    /// login shell re-splits the result, so each remote token is single-quoted
    /// here; otherwise whitespace inside an argument (e.g. the tabs in a
    /// `list-sessions -F` format string) would be word-split on the remote.
    /// A leading literal `tmux` is the `runTmux(_:)` contract and selects the
    /// remote tmux resolver; other commands are treated as explicit remote argv.
    ///
    /// The spawn itself is always a mux-only ``RemoteTmuxControlMasterRole/client``
    /// — it can never authenticate on its own. When no live master is serving,
    /// the spawn fails fast (locally, no network) with
    /// ``RemoteTmuxHost/masterUnavailableSentinel`` and the command is routed
    /// through the single-flight ``ensureMasterReady()`` gate — the only place
    /// a one-shot command's authentication can happen — then retried once.
    /// Concurrent cold commands therefore coalesce on ONE master open (one
    /// authentication) instead of each self-promoting like the old
    /// `ControlMaster=auto` scheme. The warm path costs nothing extra: the
    /// client rides the live master directly.
    ///
    /// - Parameter reopeningMasterIfNeeded: `true` (default) reopens the master
    ///   through the gate when the client finds it dead. Pass `false` for
    ///   best-effort teardown commands (`kill-session` on close/quit): those
    ///   must ride an existing master or fail fast, never re-authenticate — a
    ///   dying window must not blink the user's security key.
    @discardableResult
    func run(
        _ remoteArgs: [String],
        reopeningMasterIfNeeded: Bool = true
    ) async throws -> RemoteTmuxCommandResult {
        let result = try await execute(remoteArgs, role: .client)
        guard reopeningMasterIfNeeded,
              !result.succeeded,
              Self.indicatesMasterUnavailable(result.stderr) else {
            return result
        }
        // No live master. Open it exactly once (single-flight across every
        // concurrent caller; auth failures throw with their stderr so callers
        // classify them for the interactive-retry flow) and rerun the command.
        guard try await ensureMasterReady() else {
            throw RemoteTmuxError.unreachable(host.destination)
        }
        let retried = try await execute(remoteArgs, role: .client)
        guard !retried.succeeded, Self.indicatesMasterUnavailable(retried.stderr) else {
            return retried
        }
        // The confirmed master died again before the retry could ride it —
        // an unusable connection, not a command failure.
        throw RemoteTmuxError.unreachable(host.destination)
    }

    /// Builds the ssh argv for `remoteArgs` and spawns it with `role`. The only
    /// caller allowed to pass ``RemoteTmuxControlMasterRole/opener`` is
    /// ``performMasterReady()`` — everything else is a mux client.
    private func execute(
        _ remoteArgs: [String],
        role: RemoteTmuxControlMasterRole
    ) async throws -> RemoteTmuxCommandResult {
        try host.ensureControlSocketDirectory()
        let remoteCommand: String
        if remoteArgs.first == "tmux" {
            remoteCommand = RemoteTmuxHost.tmuxRemoteCommand(arguments: Array(remoteArgs.dropFirst()))
        } else {
            remoteCommand = remoteArgs
                .map { RemoteTmuxHost.shellSingleQuoted($0) }
                .joined(separator: " ")
        }
        // `--` ends ssh option parsing so a destination beginning with `-`
        // (e.g. `-oProxyCommand=…`) can never be consumed as an ssh option.
        let sshArgs =
            host.sshControlArguments(
                controlPersistSeconds: RemoteTmuxHost.masterControlPersistIndefinitely,
                batchMode: true,
                role: role
            )
            + ["--", host.destination, remoteCommand]
        return try await Self.runProcess(
            executable: sshExecutablePath,
            arguments: sshArgs,
            environment: spawnEnvironment()
        )
    }

    /// The environment for transport spawns: the app environment with
    /// `SSH_AUTH_SOCK` overridden by the CLI-captured hint while that socket
    /// still exists (only the master opener's agent matters for relays, but
    /// applying it uniformly keeps every spawn consistent), and PATH extended
    /// for ssh-config helper tools. `nil` = inherit unchanged.
    private func spawnEnvironment() -> [String: String]? {
        var environment = ProcessInfo.processInfo.environment
        var changed = false
        if let hint = agentSocketHint, !hint.isEmpty,
           FileManager.default.fileExists(atPath: hint) {
            environment["SSH_AUTH_SOCK"] = hint
            changed = true
        }
        if let extended = Self.pathExtendedForSSHHelperTools(environment["PATH"]) {
            environment["PATH"] = extended
            changed = true
        }
        return changed ? environment : nil
    }

    /// Appends the standard helper-tool directories to a GUI process PATH so
    /// the user's ssh config behaves like it does in their terminal.
    ///
    /// GUI apps inherit launchd's minimal `/usr/bin:/bin:/usr/sbin:/sbin`,
    /// but ssh configs routinely shell out — `ProxyCommand` relay helpers
    /// (corporate relay tools) and `Match exec` network probes — from
    /// `/usr/local/bin` or `/opt/homebrew/bin`. When those silently fail or
    /// no-match, ssh dials the host DIRECTLY and times out even though
    /// `ssh <host>` works in a terminal. Appending (never prepending) keeps
    /// system binaries authoritative; only directories that exist are added.
    /// Returns `nil` when nothing needs appending.
    nonisolated static func pathExtendedForSSHHelperTools(
        _ path: String?,
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let extras = ["/usr/local/bin", "/opt/homebrew/bin"]
        let current = (path ?? "").split(separator: ":").map(String.init)
        let missing = extras.filter { !current.contains($0) && directoryExists($0) }
        guard !missing.isEmpty else { return nil }
        let joined = missing.joined(separator: ":")
        guard let path, !path.isEmpty else { return joined }
        return path + ":" + joined
    }

    /// Resolves (and caches) the remote account's `$HOME` over the shared
    /// master — a mux-only client, so it can never authenticate on its own.
    /// Returns `nil` when the probe fails or the value cannot be embedded
    /// safely in a control-mode line; callers skip the env pin then.
    func remoteHomeDirectory() async -> String? {
        if let cached = cachedRemoteHome { return cached }
        let resolved: String?
        do {
            let result = try await run(
                ["/bin/sh", "-c", "printf %s \"$HOME\""],
                reopeningMasterIfNeeded: false
            )
            resolved = result.succeeded
                ? RemoteTmuxHost.validatedRemoteHome(result.stdout)
                : nil
        } catch {
            resolved = nil
        }
        // Cache failures too: one probe per master generation is plenty, and
        // the attach path re-warms after reconnects (a fresh transport call
        // clears nothing — the home of an endpoint does not change while the
        // app runs; a wrong nil self-heals on the next app launch).
        cachedRemoteHome = .some(resolved)
        return resolved
    }

    /// Opens the shared SSH ControlMaster (if it isn't already up) and confirms it
    /// accepts multiplexed sessions, so the burst of `tmux -CC attach` connections
    /// the controller fires next — each a mux-only
    /// ``RemoteTmuxControlMasterRole/client`` (``RemoteTmuxHost/controlModeArguments``)
    /// — rides a *ready* master.
    ///
    /// This gate is the ONLY code path that may open (and therefore
    /// authenticate) the master; every other spawn is a mux-only client that
    /// fails fast when the socket is dead. That split is the single-auth
    /// guarantee: one machine, one authenticated connection, at most one
    /// security-key touch — regardless of how many sessions are mirrored or
    /// how many commands race a dead socket.
    ///
    /// Historical context: under the old all-`ControlMaster=auto` scheme, a cold
    /// first attach with many sessions raced to create the master at the same
    /// `ControlPath`; all-but-one failed with "ControlSocket … already exists,
    /// disabling multiplexing", so only one or two sessions mirrored (#6732) —
    /// and every loser silently opened its OWN authenticated connection. Even
    /// discovery left a brief background hand-off window where the socket
    /// existed but wasn't yet accepting sessions; `ssh -O check` is the
    /// authoritative "ready now" signal that closes it.
    ///
    /// Idempotent: returns `true` at once when a master is already live (warm path);
    /// otherwise opens it exactly once with `run(["true"])` — a single connection
    /// can't lose the creation race — and then confirms with one authoritative
    /// `ssh -O check` (a non-multiplexed fallback can make `run` succeed without a
    /// live master, so the open's exit code is not trusted). A single mux-socket
    /// query, never a timer or poll. Returns `false` only when readiness can't be
    /// confirmed; the controller fails closed on `false` (aborts the burst rather
    /// than racing the cold master).
    ///
    /// Single-flight: the actor is reentrant across `await`, so two concurrent
    /// bulk-mirror callers for the same host (e.g. a dedicated-window attach and a
    /// `remote.tmux.mirror` socket call) could otherwise both observe no master and
    /// both open it, recreating the race. Every caller shares one in-flight
    /// ``readinessTask``; the check-create-store below is a single synchronous actor
    /// step (no `await` between them), so only one caller becomes the creator.
    ///
    /// Not cancellation-aware by itself: the shared warmup is unstructured and
    /// bounded by `ConnectTimeout`, so a cancelled caller awaits its completion
    /// rather than tearing it down for the others. Callers that must bail re-check
    /// `Task.checkCancellation()` after this — as the controller does before
    /// creating the dedicated window.
    @discardableResult
    func ensureMasterReady() async throws -> Bool {
        if let existing = readinessTask {
            return try await existing.value
        }
        let task = Task { try await self.performMasterReady() }
        readinessTask = task
        defer { readinessTask = nil }
        return try await task.value
    }

    /// The actual warmup, run exactly once per ``readinessTask`` (see
    /// ``ensureMasterReady()`` for the single-flight + readiness rationale).
    ///
    /// This is the ONLY place a transport spawn may run as
    /// ``RemoteTmuxControlMasterRole/opener`` — i.e. the only place a
    /// non-interactive authentication can happen. When the open itself fails
    /// (BatchMode cannot service a password / host-key confirmation / FIDO
    /// touch), the failure is thrown as ``RemoteTmuxError/commandFailed`` with
    /// the captured stderr so callers classify it with the existing
    /// `indicatesInteractiveRetryWillHelp` decision layer and route the user to
    /// the interactive terminal ssh.
    private func performMasterReady() async throws -> Bool {
        try? host.ensureControlSocketDirectory()
        if try await observedMasterRunning() { return true }
        // Warm the shared master once, then confirm. The open's exit code is not
        // trusted (a non-multiplexed fallback can make the open exit 0 with no
        // live master — see the doc comment); the post-open `ssh -O check` is
        // authoritative. The probe also refreshes the endpoint's stable
        // forwarded-agent link: this opener is the FIRST session of every new
        // master generation, so the new connection's `SSH_AUTH_SOCK` is
        // already in its env (sshd installs the agent listener before exec),
        // and master reopens with no immediate control re-attach still
        // retarget the link. The snippet is stdout/stderr-silent and always
        // exits 0, so the readiness classification is untouched.
        //
        // The open itself (the authentication) runs under the shared open
        // gate: a fleet attach or a reconnect storm after wake must not
        // fire every machine's authentication at the agent at once (see
        // RemoteTmuxMasterOpenGate for the measured stall and hang).
        let openerCommand = [
            "/bin/sh", "-c",
            RemoteTmuxHost.agentLinkRefreshScript(connectionHash: host.connectionHash) + "; true",
        ]
        let opened: RemoteTmuxCommandResult? = try await openGate.withSlot { waited in
            // Time spent parked in the gate is exactly the window in which the
            // user's terminal (an interactive handover, an ssh-tmux rerun) may
            // have brought THIS master up; never authenticate a second time
            // for a master that is already serving.
            if waited, try await self.observedMasterRunning() { return nil }
            // An earlier open stalled on authentication and nothing has
            // proven the agent responsive since: opening now would only
            // cancel the touch prompt that open raised and raise another.
            // Refuse up front, exactly as if this open had stalled, so the
            // machine takes the same interactive route with no new prompt.
            if await self.openGate.isParked {
                throw RemoteTmuxError.authenticationStalled(
                    destination: self.host.destination,
                    seconds: Self.wholeSeconds(self.openerStallTimeout)
                )
            }
            return try await self.executeOpenerOrStall(openerCommand)
        }
        guard let opened else { return true }
        if try await observedMasterRunning() { return true }
        if !opened.succeeded {
            throw RemoteTmuxError.commandFailed(exitCode: opened.exitCode, stderr: opened.stderr)
        }
        return false
    }

    /// `duration` rounded up to whole seconds (at least 1) for the stall error.
    private static func wholeSeconds(_ duration: Duration) -> Int {
        let seconds = Int((Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18).rounded(.up))
        return max(seconds, 1)
    }

    /// Spawns the opener and races it against ``openerStallTimeout``. On a
    /// stall the ssh process is killed (task cancellation reaches
    /// ``runProcess``'s cancellation handler) so no orphaned authentication
    /// keeps the agent or a gate slot busy, and
    /// ``RemoteTmuxError/authenticationStalled(destination:seconds:)`` tells
    /// the callers to hand this machine to the interactive terminal.
    private func executeOpenerOrStall(_ command: [String]) async throws -> RemoteTmuxCommandResult {
        let budget = openerStallTimeout
        let destination = host.destination
        let result: RemoteTmuxCommandResult? = try await withThrowingTaskGroup(of: RemoteTmuxCommandResult?.self) { group in
            group.addTask { try await self.execute(command, role: .opener) }
            group.addTask {
                try await Task.sleep(for: budget)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw RemoteTmuxError.unreachable(destination)
            }
            return first
        }
        guard let result else {
            // Park the fleet before reporting: the sibling opens queued in
            // the gate must not each raise (and cancel) a fresh touch prompt.
            await openGate.noteOpenerStalled()
            throw RemoteTmuxError.authenticationStalled(destination: destination, seconds: Self.wholeSeconds(budget))
        }
        if result.succeeded {
            // A completed BatchMode authentication is the proof that clears a park.
            await openGate.noteAuthenticationSucceeded()
        }
        return result
    }

    /// ``masterIsRunning()`` plus generation bookkeeping: the ONLY way the
    /// warmup consults the check, so every dead-to-serving edge (including a
    /// master the interactive terminal or a previous app run opened) is
    /// counted exactly once.
    private func observedMasterRunning() async throws -> Bool {
        let alive = try await masterIsRunning()
        let wasAlive = lastObservedMasterAlive
        noteMasterAliveObservation(alive)
        // A dead-to-serving edge means someone authenticated this endpoint
        // out of band (the interactive terminal after a park, most likely):
        // the agent is answering again, so the fleet may open through the
        // gate once more.
        if alive, !wasAlive { await openGate.noteAuthenticationSucceeded() }
        return alive
    }

    /// Adds a reverse unix-socket forward (remote path → local path) to the
    /// LIVE master via `ssh -O forward`, so processes on the remote host can
    /// reach this cmux instance's control socket (the remote agent bridge).
    /// `-O forward` talks only to the local control socket of an existing
    /// master — it can never authenticate on its own and fails fast when no
    /// master is serving, preserving the single-auth guarantee. Scoped to
    /// exactly this forward (see
    /// ``RemoteTmuxHost/masterControlCommandArguments(_:options:)``): the
    /// user's config forwards are the master's business, and a refused one
    /// must not fail the bridge.
    func requestReverseUnixForward(
        remoteSocketPath: String,
        localSocketPath: String
    ) async throws -> Bool {
        let result = try await Self.runProcess(
            executable: sshExecutablePath,
            arguments: host.masterControlCommandArguments(
                "forward",
                options: ["-R", "\(remoteSocketPath):\(localSocketPath)"]
            )
        )
        return result.succeeded
    }

    /// Removes a previously registered reverse forward from the LIVE master.
    /// Bridge reconfiguration over a healthy master (an `ssh-tmux` rerun, a
    /// forced attach refresh) must drop the old registration first: without
    /// the cancel, the pre-bind `rm` unlinks the live listener's path and the
    /// duplicate `-O forward` stacks a second registration on an orphaned
    /// socket. Best-effort: a fresh master with nothing registered (or no
    /// master at all) just fails fast, like every other `-O` control command.
    /// Scoped to exactly this forward: an unscoped `-O cancel` also cancels
    /// every forward the user's config declares for the host, which is how
    /// the bridge used to tear down the user's `RemoteForward` tunnels on the
    /// shared master.
    func cancelReverseUnixForward(
        remoteSocketPath: String,
        localSocketPath: String
    ) async {
        _ = try? await Self.runProcess(
            executable: sshExecutablePath,
            arguments: host.masterControlCommandArguments(
                "cancel",
                options: ["-R", "\(remoteSocketPath):\(localSocketPath)"]
            )
        )
    }

    /// Whether the shared ControlMaster is live and accepting sessions, via the
    /// local `ssh -O check` control command. `-O check` hits the LOCAL control
    /// socket only (identified by `ControlPath`), so it never opens a network
    /// connection and returns in milliseconds.
    ///
    /// Propagates `CancellationError` (so a cancelled ``ensureMasterReady()`` aborts
    /// rather than mis-reading the cancellation as "no master"); collapses only
    /// ordinary launch/socket failures to `false`.
    private func masterIsRunning() async throws -> Bool {
        do {
            let result = try await Self.runProcess(
                executable: sshExecutablePath,
                arguments: host.masterControlCommandArguments("check")
            )
            return result.succeeded
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    /// Tears down the shared SSH master. The ONLY `ssh -O exit` cmux issues:
    /// an explicit host disconnect, or the reauth flows replacing a master
    /// whose tunnel is dead. Ordinary lifecycle (quit, window close, detach,
    /// last-mirror close) leaves masters serving so re-attaching never
    /// re-authenticates (see `RemoteTmuxController.detachAll`).
    func shutdownMaster() async {
        _ = try? await Self.runProcess(
            executable: sshExecutablePath,
            arguments: host.masterControlCommandArguments("exit")
        )
        // Deliberate teardown is a known dead edge: the next serving
        // confirmation is a new generation (its replacement master carries
        // none of this one's forward registrations).
        noteMasterAliveObservation(false)
    }

    /// Kills each `(transport, sessionTarget)` via `tmux kill-session`. Races the kill
    /// round-trips against a single `Task.sleep(timeout)` and returns at the first to
    /// finish (`group.next()` then `cancelAll()`) — so on a RESPONSIVE connection this
    /// returns as soon as the kills land (well under `timeout`). Kills to the SAME host
    /// serialize on that host's transport actor; different hosts run in parallel.
    ///
    /// `runProcess` force-stops its child when task cancellation follows the
    /// timeout, so the structured group also finishes within this boundary.
    /// The remote kill remains best-effort when the connection itself is dead.
    nonisolated static func killSessions(
        _ jobs: [(transport: RemoteTmuxSSHTransport, target: String)],
        timeout: Duration
    ) async {
        guard !jobs.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withTaskGroup(of: Void.self) { kills in
                    for job in jobs {
                        // Best-effort: ride an existing master or fail fast. A
                        // teardown kill must never reopen the master (a fresh
                        // authentication — security-key touch — from a dying
                        // window or the app-quit path).
                        kills.addTask {
                            _ = try? await job.transport.runTmux(
                                ["kill-session", "-t", job.target],
                                reopeningMasterIfNeeded: false
                            )
                        }
                    }
                    await kills.waitForAll()
                }
            }
            group.addTask { try? await ContinuousClock().sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Heuristics

    /// Whether stderr indicates the remote tmux server simply isn't running.
    static func indicatesNoServer(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no server running")
            || lowered.contains("no sessions")
            || (lowered.contains("error connecting to /") && lowered.contains("/tmux-"))
    }

    static func indicatesRefreshClientSubscriptionUnsupported(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        let tokens = lowered.split { character in
            !(character.isLetter || character.isNumber || character == "-")
        }.map(String.init)
        let mentionsBFlag = tokens.enumerated().contains { index, token in
            if token == "-b" || token == "--b" { return true }
            guard token == "b" else { return false }
            if index > 0, tokens[index - 1] == "flag" || tokens[index - 1] == "option" {
                return true
            }
            if index > 1, tokens[index - 1] == "--" {
                let optionNoun = tokens[index - 2]
                return optionNoun == "flag" || optionNoun == "option"
            }
            return false
        }
        let rejectsOption = lowered.contains("unknown flag")
            || lowered.contains("unknown option")
            || lowered.contains("invalid option")
            || lowered.contains("illegal option")
        return mentionsBFlag && rejectsOption
    }

    static func indicatesRefreshClientNeedsCurrentClient(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no current client")
            || lowered.contains("not a client")
            || lowered.contains("not a control client")
    }

    /// Whether a failed non-interactive (`BatchMode=yes`) connect failed because
    /// the host needs **interactive** authentication or host-key confirmation
    /// that batch mode cannot service — a password, an unknown/changed host key,
    /// keyboard-interactive MFA, or a FIDO touch. Used to decide whether to hand
    /// the user an interactive `ssh` (run in their terminal by `cmux ssh-tmux`) that
    /// opens the shared ControlMaster, versus surfacing a genuine
    /// unreachable/transient error.
    ///
    /// Matches the canonical OpenSSH failure phrases only. "Permission denied"
    /// already covers `Permission denied (publickey,keyboard-interactive)`, so
    /// the bare "keyboard-interactive" substring is intentionally omitted (it
    /// also appears in success-time banners). A *changed* host key ("remote host
    /// identification has changed") is included so the interactive terminal
    /// renders ssh's actionable message rather than an opaque alert — even though
    /// the user must fix `known_hosts` themselves. Algorithm-negotiation failures
    /// ("no matching host key type") are deliberately NOT matched: an interactive
    /// retry cannot fix them, so they surface as a normal error instead.
    static func indicatesAuthRequired(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("permission denied")
            || lowered.contains("host key verification failed")
            || lowered.contains("remote host identification has changed")
            || lowered.contains("authentication failed")
            || lowered.contains("too many authentication failures")
    }

    /// Whether a failed mux-only (``RemoteTmuxControlMasterRole/client``) spawn
    /// failed because no live ControlMaster was serving its socket: the severed
    /// direct-connection fallback ran the fail-fast ProxyCommand, which prints
    /// the cmux-unique sentinel. This is a LOCAL condition ("the shared master
    /// is gone"), never a remote error — callers route recovery through
    /// ``ensureMasterReady()`` instead of surfacing it. The sentinel reaches
    /// stderr only because client spawns pin `ControlPersist=no`: OpenSSH
    /// silences a ProxyCommand's stderr under `ControlPath` + `ControlPersist`.
    static func indicatesMasterUnavailable(_ stderr: String) -> Bool {
        stderr.contains(RemoteTmuxHost.masterUnavailableSentinel)
    }

    // MARK: - Process plumbing

    /// Launches a process and captures bounded stdout/stderr without blocking the actor.
    ///
    /// Each pipe is drained to EOF on a detached task so a chatty command can't
    /// deadlock against a full 64 KiB pipe buffer while we await termination.
    /// We capture only the raw fds (`Int32`, `Sendable`) across the task
    /// boundary — never the non-`Sendable` `FileHandle` — and the `Pipe`s stay
    /// alive because `process` retains them until this function returns.
    private static func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> RemoteTmuxCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let outFD = outPipe.fileHandleForReading.fileDescriptor
        let errFD = errPipe.fileHandleForReading.fileDescriptor
        let outRead = Task.detached { Self.drain(fd: outFD, maxBytes: Self.maxCapturedOutputBytes) }
        let errRead = Task.detached { Self.drain(fd: errFD, maxBytes: Self.maxCapturedOutputBytes) }
        let cancellation = RemoteTmuxProcessCancellation(
            process: process,
            stdout: outPipe.fileHandleForReading,
            stderr: errPipe.fileHandleForReading
        )

        // Install the termination handler BEFORE launching, then launch inside the
        // continuation. If `run()` and the handler assignment were separate steps, a
        // process that exits in the window between them would terminate before the
        // handler is installed — and Foundation does not invoke a terminationHandler
        // assigned after the process has already ended, so the continuation would
        // never resume and the caller would hang until its timeout. This matters for
        // the fast auth-failure exits the `cmux ssh-tmux` flow classifies.
        let exitCode: Int32
        do {
            exitCode = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { proc in
                        continuation.resume(returning: proc.terminationStatus)
                    }
                    do {
                        try process.run()
                        if Task.isCancelled {
                            cancellation.cancel()
                        }
                    } catch {
                        // The process never started, so the handler will not fire; resume
                        // exactly once here with the launch failure.
                        process.terminationHandler = nil
                        continuation.resume(throwing: RemoteTmuxError.launchFailed(error.localizedDescription))
                    }
                }
            } onCancel: {
                cancellation.cancel()
            }
            try Task.checkCancellation()
        } catch {
            cancellation.cancel()
            outRead.cancel()
            errRead.cancel()
            _ = await outRead.value
            _ = await errRead.value
            throw error
        }

        let outData = await outRead.value
        let errData = await errRead.value
        return RemoteTmuxCommandResult(
            exitCode: exitCode,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Reads a file descriptor to EOF, returning at most `maxBytes`.
    ///
    /// Uses the raw `read(2)` so nothing non-`Sendable` crosses the task
    /// boundary; the owning `Pipe` keeps `fd` open for the duration.
    private static func drain(fd: Int32, maxBytes: Int) -> Data {
        var data = Data()
        var remaining = max(0, maxBytes)
        let bufferSize = 65_536
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            if Task.isCancelled { break }
            let count = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, bufferSize)
            }
            if count > 0 {
                if remaining > 0 {
                    let kept = min(count, remaining)
                    data.append(contentsOf: buffer[0..<kept])
                    remaining -= kept
                }
            } else if count == 0 {
                break // EOF
            } else if errno == EINTR {
                continue // interrupted, retry
            } else {
                break // read error; return what we have
            }
        }
        return data
    }
}
