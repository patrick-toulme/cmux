import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Locks in the single-authentication guarantee for remote tmux mirroring:
/// exactly ONE place may open (and therefore authenticate) a host's shared SSH
/// ControlMaster — the transport's single-flight readiness gate (plus the
/// interactive `cmux ssh-tmux` ssh in the user's terminal). Every other spawn
/// is a mux-only client that rides a live master or fails fast, never
/// authenticating on its own.
///
/// The regression this prevents: under the old all-`ControlMaster=auto`
/// scheme, any spawn that found a dead master socket silently self-promoted to
/// a brand-new authenticated connection. After a network blip killed a host's
/// master, its N mirrored sessions reconnected on independent backoff timers —
/// N racing publickey authentications per retry round, forever (auth failures
/// were classified transient). For FIDO/security-key users that was an
/// invisible touch-request storm; the key blinked with no prompt anywhere.
@Suite struct RemoteTmuxSingleAuthTests {

    // MARK: - Invocation shapes (who may create the master)

    @Test func clientControlArgsAreMuxOnly() {
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.sshControlArguments(controlPersistSeconds: 180, batchMode: true, role: .client)
        #expect(consecutive(args, "-o", "ControlMaster=no"))
        #expect(!args.contains("ControlMaster=auto"))
        // The direct-connection fallback must be severed: a dead master makes
        // the spawn fail fast with the sentinel instead of self-authenticating.
        #expect(consecutive(args, "-o", "ProxyJump=none"))
        #expect(consecutive(args, "-o", "ProxyCommand=\(RemoteTmuxHost.muxOnlyProxyCommand)"))
        // Still a mux client of the SHARED socket.
        #expect(consecutive(args, "-o", "ControlPath=\(host.controlSocketPath)"))
    }

    @Test func openerControlArgsMayCreateMasterAndKeepUserProxyConfig() {
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.sshControlArguments(controlPersistSeconds: 180, batchMode: true, role: .opener)
        #expect(consecutive(args, "-o", "ControlMaster=auto"))
        // The opener performs the real connection, so the user's configured
        // ProxyCommand/ProxyJump must NOT be overridden.
        #expect(!args.contains(where: { $0.hasPrefix("ProxyCommand=") }))
        #expect(!args.contains(where: { $0.hasPrefix("ProxyJump=") }))
    }

    @Test func controlModeClientIsMuxOnly() {
        // The long-lived `tmux -CC` stream (one per mirrored session) must never
        // self-authenticate: on reconnect, N of these re-spawn concurrently.
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.controlModeArguments(sessionName: "work", createIfMissing: false)
        #expect(consecutive(args, "-o", "ControlMaster=no"))
        #expect(!args.contains("ControlMaster=auto"))
        #expect(consecutive(args, "-o", "ProxyCommand=\(RemoteTmuxHost.muxOnlyProxyCommand)"))
    }

    @Test func interactiveAuthInvocationIsAnIndefinitelyPersistedOpener() {
        let host = RemoteTmuxHost(destination: "user@host")
        let argv = host.interactiveAuthInvocation(sshExecutablePath: "/usr/bin/ssh")
        // The user's terminal ssh IS the interactive authenticator, so it must
        // be allowed to create the master…
        #expect(consecutive(argv, "-o", "ControlMaster=auto"))
        #expect(!argv.contains(where: { $0.hasPrefix("ProxyCommand=") }))
        // …and the authentication it performs (one security-key touch) must not
        // be forfeited to an idle timer: ControlPersist=0 persists until the
        // explicit `ssh -O exit` teardown paths close the master.
        #expect(consecutive(argv, "-o", "ControlPersist=\(RemoteTmuxHost.masterControlPersistIndefinitely)"))
    }

    @Test func uploadSessionIsMuxOnly() {
        // The scp/cleanup-ssh upload path (image paste into a mirror pane) must
        // ride the live master or fail fast — never direct-connect with a
        // fresh authentication while the master is down.
        let session = RemoteTmuxHost(destination: "user@host").detectedSSHSession()
        #expect(session.sshOptions.contains("ProxyJump=none"))
        #expect(session.sshOptions.contains("ProxyCommand=\(RemoteTmuxHost.muxOnlyProxyCommand)"))
    }

    @Test func masterUnavailableSentinelClassification() {
        #expect(RemoteTmuxSSHTransport.indicatesMasterUnavailable(
            "\(RemoteTmuxHost.masterUnavailableSentinel)\nkex_exchange_identification: Connection closed"
        ))
        #expect(!RemoteTmuxSSHTransport.indicatesMasterUnavailable("Permission denied (publickey)."))
        #expect(!RemoteTmuxSSHTransport.indicatesMasterUnavailable(""))
    }

    // MARK: - Transport gating (fake ssh)

    @Test func coldOneShotOpensMasterExactlyOnceThenRetries() async throws {
        let env = try SingleAuthFakeSSH(behavior: .normal)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        let result = try await transport.run(["remote-echo"])

        #expect(result.succeeded)
        // Exact recovery shape: the mux-only client fails fast on the dead
        // socket, the gate opens the master ONCE (confirmed by check), and the
        // command retries as a mux client. No self-promotion anywhere.
        #expect(env.invocations() == ["client", "check", "open", "check", "client"])
    }

    @Test func warmOneShotRidesMasterWithNoGateTraffic() async throws {
        let env = try SingleAuthFakeSSH(behavior: .normal, masterInitiallyUp: true)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        let result = try await transport.run(["remote-echo"])

        #expect(result.succeeded)
        // The hot path costs nothing: one mux-client spawn, zero checks/opens.
        #expect(env.invocations() == ["client"])
    }

    @Test func concurrentColdOneShotsCoalesceOnOneOpen() async throws {
        let env = try SingleAuthFakeSSH(behavior: .normal)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        async let first = transport.run(["remote-echo"])
        async let second = transport.run(["remote-echo"])
        let results = try await [first, second]

        let allSucceeded = results.allSatisfy { $0.succeeded }
        #expect(allSucceeded)
        // The single-flight gate is what turns "N cold commands" into "one
        // authentication": exactly one open, no matter the interleaving.
        #expect(env.count("open") == 1)
    }

    @Test func teardownKillNeverReopensTheMaster() async throws {
        let env = try SingleAuthFakeSSH(behavior: .normal)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        let result = try await transport.runTmux(
            ["kill-session", "-t", "gone"],
            reopeningMasterIfNeeded: false
        )

        // Best-effort semantics: the kill fails fast on the dead socket and
        // NOTHING attempts to reopen (no check, no open, no authentication) —
        // a closing window / quitting app must not blink the security key.
        #expect(!result.succeeded)
        #expect(RemoteTmuxSSHTransport.indicatesMasterUnavailable(result.stderr))
        #expect(env.invocations() == ["client"])
    }

    @Test func openerAuthFailureThrowsClassifiableErrorWithoutRetryStorm() async throws {
        let env = try SingleAuthFakeSSH(behavior: .openFailsAuth)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        do {
            _ = try await transport.run(["remote-echo"])
            Issue.record("expected the gate's auth failure to throw")
        } catch let error as RemoteTmuxError {
            guard case .commandFailed(_, let stderr) = error else {
                Issue.record("expected commandFailed, got \(error)")
                return
            }
            // The opener's stderr must survive verbatim so the existing
            // decision layer routes the user to the interactive terminal ssh.
            #expect(RemoteTmuxSSHTransport.indicatesInteractiveRetryWillHelp(stderr))
        }
        // One client fail-fast, one readiness probe, ONE authentication
        // attempt. The storm (open, open, open, …) is structurally gone.
        #expect(env.invocations() == ["client", "check", "open", "check"])
    }

    @Test func masterDyingAgainAfterReopenSurfacesUnreachable() async throws {
        let env = try SingleAuthFakeSSH(behavior: .clientAlwaysFindsDeadSocket)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        do {
            _ = try await transport.run(["remote-echo"])
            Issue.record("expected unreachable after the reopened master died again")
        } catch let error as RemoteTmuxError {
            guard case .unreachable = error else {
                Issue.record("expected unreachable, got \(error)")
                return
            }
        }
        // Exactly one reopen attempt — a flapping master must not turn a
        // one-shot command into an authentication loop.
        #expect(env.count("open") == 1)
    }

    // MARK: - Reconnect coordination (the touch-storm fix)

    @Test @MainActor func reconnectSuspendsWhenGateReportsAuthRequired() async throws {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let gate = GateProbe(outcome: .authRequired)
        connection.masterGate = { await gate.enter() }
        var authRequiredNotices = 0
        let token = connection.addObserver(onReconnectAuthRequired: {
            authRequiredNotices += 1
        })
        defer { connection.removeObserver(token) }

        connection.beginReconnecting()

        // First attempt fires after the 1s base backoff and must park the loop.
        #expect(await waitUntil { connection.reconnectSuspendedAwaitingAuth })
        #expect(gate.calls == 1)
        #expect(authRequiredNotices == 1)
        #expect(connection.connectionState == .reconnecting)

        // Parked means PARKED: no further gate traffic (each gate call is a
        // potential authentication attempt — the old behavior retried forever).
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(gate.calls == 1)
        #expect(authRequiredNotices == 1)
    }

    @Test @MainActor func resumeAfterAuthRetriesImmediatelyAndCanReSuspend() async throws {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let gate = GateProbe(outcome: .authRequired)
        connection.masterGate = { await gate.enter() }

        connection.beginReconnecting()
        #expect(await waitUntil { connection.reconnectSuspendedAwaitingAuth })
        #expect(gate.calls == 1)

        // The controller resumes suspended loops once a serving master is
        // confirmed; the retry is immediate (no residual backoff). Here the
        // gate still reports auth-required, so the loop re-parks instead of
        // spinning.
        connection.resumeReconnectAfterAuth()
        #expect(await waitUntil { gate.calls == 2 })
        #expect(await waitUntil { connection.reconnectSuspendedAwaitingAuth })
    }

    @Test @MainActor func transientGateFailureKeepsBackoffWithoutSuspension() async throws {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let gate = GateProbe(outcome: .retryLater)
        connection.masterGate = { await gate.enter() }

        connection.beginReconnecting()

        // Network-ish failures keep retrying on the capped backoff (attempts at
        // ~1s and ~3s) — and never park, never notify auth.
        #expect(await waitUntil(deadline: 6) { gate.calls >= 2 })
        #expect(!connection.reconnectSuspendedAwaitingAuth)
        #expect(connection.connectionState == .reconnecting)
    }

    @Test @MainActor func stopWhileSuspendedEndsCleanlyAndResumeIsInert() async throws {
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"), sessionName: "work"
        )
        let gate = GateProbe(outcome: .authRequired)
        connection.masterGate = { await gate.enter() }

        connection.beginReconnecting()
        #expect(await waitUntil { connection.reconnectSuspendedAwaitingAuth })

        connection.stop()
        #expect(connection.connectionState == .ended)
        #expect(!connection.reconnectSuspendedAwaitingAuth)

        connection.resumeReconnectAfterAuth()
        try await Task.sleep(for: .milliseconds(300))
        #expect(gate.calls == 1)
        #expect(connection.connectionState == .ended)
    }

    // MARK: - Helpers

    /// Counts master-gate calls on the MainActor (the gate closure is
    /// `@MainActor`, matching how the controller's gate runs).
    @MainActor
    private final class GateProbe {
        private(set) var calls = 0
        var outcome: RemoteTmuxMasterGateOutcome
        init(outcome: RemoteTmuxMasterGateOutcome) { self.outcome = outcome }
        func enter() -> RemoteTmuxMasterGateOutcome {
            calls += 1
            return outcome
        }
    }

    @MainActor
    private func waitUntil(
        deadline: TimeInterval = 5,
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(deadline))
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func consecutive(_ args: [String], _ a: String, _ b: String) -> Bool {
        for i in args.indices.dropLast() where args[i] == a && args[i + 1] == b {
            return true
        }
        return false
    }

    /// A fake `ssh` that mimics OpenSSH's multiplexing surface for the
    /// single-auth flow. It classifies each invocation purely from argv:
    ///
    /// - `-O check`  → `check`: succeeds iff the master sentinel file exists.
    /// - `ControlMaster=auto` present → `open` (the gate's opener): behavior
    ///   dependent — bring the master up, or fail like a BatchMode auth error.
    /// - `ControlMaster=no` present → `client` (a mux-only spawn): succeeds iff
    ///   the master is up, else emits the REAL fail-fast sentinel line a dead
    ///   socket's severed ProxyCommand produces and exits 255.
    private struct SingleAuthFakeSSH {
        enum Behavior {
            /// Opens on first open; clients ride it afterwards.
            case normal
            /// The opener fails like BatchMode hitting a FIDO/password prompt.
            case openFailsAuth
            /// Clients always find a dead socket, even after a "successful"
            /// open (a flapping master).
            case clientAlwaysFindsDeadSocket
        }

        let root: URL
        let executablePath: String
        private let statePath: String
        private let logPath: String

        init(behavior: Behavior, masterInitiallyUp: Bool = false) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("remote-tmux-single-auth-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            statePath = root.appendingPathComponent("master-up").path
            logPath = root.appendingPathComponent("calls.log").path
            if masterInitiallyUp {
                FileManager.default.createFile(atPath: statePath, contents: Data())
            }

            let openBody: String
            switch behavior {
            case .normal, .clientAlwaysFindsDeadSocket:
                openBody = ": > \"$STATE\"\nexit 0"
            case .openFailsAuth:
                openBody = "echo 'user@host: Permission denied (publickey).' >&2\nexit 255"
            }
            let clientUpCondition = behavior == .clientAlwaysFindsDeadSocket
                ? "false" : "[ -e \"$STATE\" ]"

            let script = """
            #!/bin/sh
            STATE='\(statePath)'
            LOG='\(logPath)'
            is_check=0; is_client=0; prev=''
            for arg in "$@"; do
                if [ "$prev" = "-O" ] && [ "$arg" = "check" ]; then is_check=1; fi
                if [ "$arg" = "ControlMaster=no" ]; then is_client=1; fi
                prev="$arg"
            done
            if [ "$is_check" = "1" ]; then
                printf 'check\\n' >> "$LOG"
                if [ -e "$STATE" ]; then exit 0; else exit 255; fi
            fi
            if [ "$is_client" = "1" ]; then
                printf 'client\\n' >> "$LOG"
                if \(clientUpCondition); then
                    printf 'ok\\n'
                    exit 0
                fi
                echo '\(RemoteTmuxHost.masterUnavailableSentinel)' >&2
                echo 'kex_exchange_identification: Connection closed by remote host' >&2
                exit 255
            fi
            printf 'open\\n' >> "$LOG"
            \(openBody)
            """
            let scriptURL = root.appendingPathComponent("ssh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            executablePath = scriptURL.path
        }

        func invocations() -> [String] {
            guard let contents = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
            return contents.split(separator: "\n").map(String.init)
        }

        func count(_ kind: String) -> Int { invocations().filter { $0 == kind }.count }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}
