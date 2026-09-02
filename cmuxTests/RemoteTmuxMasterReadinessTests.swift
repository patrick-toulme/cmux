import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the shared-ControlMaster readiness gate that fixes the
/// "only ~2 of N sessions mirror on first attach" race
/// (https://github.com/manaflow-ai/cmux/issues/6732).
///
/// The bug: ``RemoteTmuxController`` fires the per-session `tmux -CC attach`
/// connections (each `ControlMaster=auto`) in a tight burst. On a cold first
/// attach they all race to *create* the master at the same `ControlPath`; all but
/// one fail with "ControlSocket … already exists, disabling multiplexing", so only
/// one or two sessions mirror. The fix —
/// ``RemoteTmuxSSHTransport/ensureMasterReady()`` — opens the master exactly once (a
/// single connection can't lose the creation race), then confirms with one
/// authoritative `ssh -O check`. The open's exit code is NOT trusted: under
/// `ControlMaster=auto` ssh can fall back to a non-multiplexed direct connection and
/// still exit 0 without a live shared master, so only the `-O check` proves the
/// burst can ride a live master.
///
/// The OpenSSH creation race itself isn't hermetically reproducible (it needs a
/// real multi-session host), so these tests lock in the *mechanism* that prevents
/// it: a fake `ssh` that records its invocations and tracks a master-up sentinel,
/// asserting the gate opens the master once when cold, is idempotent when warm, and
/// — crucially — reports not-ready when the open succeeds but no master is actually
/// up (the non-multiplexed-fallback hole). The single-flight coalescing of
/// concurrent callers is an actor-reentrancy property verified by review rather than
/// a (necessarily timing-dependent) unit test.
@Suite struct RemoteTmuxMasterReadinessTests {

    @Test func coldMasterIsOpenedOnceThenConfirmedReady() async throws {
        let env = try FakeSSHEnvironment(behavior: .opensOnFirstRun)
        defer { env.cleanUp() }

        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        let ready = try await transport.ensureMasterReady()

        #expect(ready)
        // The master must be opened exactly once — a single creator can't lose the
        // burst's creation race. More than one open would reintroduce it.
        #expect(env.openCount() == 1)
        // Readiness is confirmed by an authoritative `ssh -O check` AFTER the open,
        // not assumed from the open's exit code: one initial warm-path probe plus
        // one post-open confirmation = two checks.
        #expect(env.checkCount() == 2)
    }

    @Test func warmMasterShortCircuitsWithoutReopening() async throws {
        let env = try FakeSSHEnvironment(behavior: .alreadyRunning)
        defer { env.cleanUp() }

        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        let ready = try await transport.ensureMasterReady()

        #expect(ready)
        // Already-live master (e.g. just opened by discovery): confirmed by the
        // first check, never re-opened.
        #expect(env.openCount() == 0)
    }

    @Test func openSucceedingWithoutLiveMasterReportsNotReady() async throws {
        // The regression for the non-multiplexed-fallback hole: `run(["true"])`
        // exits 0 (ssh fell back to a direct connection) but no shared master is
        // accepting clients. Trusting the open's exit code here would report ready
        // and fire the attach burst into the cold-master race; the post-open
        // `ssh -O check` must catch it and report not-ready instead.
        let env = try FakeSSHEnvironment(behavior: .openSucceedsButMasterStaysDown)
        defer { env.cleanUp() }

        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )

        let ready = try await transport.ensureMasterReady()

        #expect(!ready)
        // The open ran (and "succeeded"), but the authoritative post-open check
        // still ran and is what determined the not-ready result.
        #expect(env.openCount() == 1)
        #expect(env.checkCount() == 2)
    }

    // MARK: - Master generation (the agent-bridge death signal)

    @Test func masterGenerationCountsDeadToServingEdges() async throws {
        let env = try FakeSSHEnvironment(behavior: .opensOnFirstRun)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )
        #expect(await transport.masterGeneration == 0)

        #expect(try await transport.ensureMasterReady())
        #expect(await transport.masterGeneration == 1)

        // Warm re-checks confirm the SAME master: no new generation, or every
        // reconnect blip would pointlessly reconfigure the agent bridge.
        #expect(try await transport.ensureMasterReady())
        #expect(await transport.masterGeneration == 1)

        // The master dies behind the app's back (sleep, network drop) and the
        // next gate pass reopens it. The replacement carries none of the old
        // master's reverse-forward registrations, so it MUST be a new
        // generation: this is the signal that restores the agent bridge.
        env.killMaster()
        #expect(try await transport.ensureMasterReady())
        #expect(await transport.masterGeneration == 2)
    }

    @Test func survivingMasterFromAPreviousRunIsTheFirstGeneration() async throws {
        // A fresh transport (new app run) over a master that outlived the old
        // app: the first confirmation is generation 1, so the forced attach
        // records a real generation and later reopen heals compare against it.
        let env = try FakeSSHEnvironment(behavior: .alreadyRunning)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )
        #expect(try await transport.ensureMasterReady())
        #expect(await transport.masterGeneration == 1)
        #expect(env.openCount() == 0)
    }

    @Test func unconfirmedMasterMintsNoGeneration() async throws {
        let env = try FakeSSHEnvironment(behavior: .openSucceedsButMasterStaysDown)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )
        #expect(try await transport.ensureMasterReady() == false)
        #expect(await transport.masterGeneration == 0)
    }

    @Test func shutdownThenExternalReopenIsANewGeneration() async throws {
        // The stale-master teardown → interactive-terminal handover flow: the
        // app tears the master down, the USER's terminal ssh reopens it, and
        // the transport's next probe sees "serving" without ever observing
        // dead via `-O check`. The deliberate shutdown must count as the dead
        // edge, or the handover would leave the agent bridge dead forever.
        let env = try FakeSSHEnvironment(behavior: .opensOnFirstRun)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )
        #expect(try await transport.ensureMasterReady())
        #expect(await transport.masterGeneration == 1)

        await transport.shutdownMaster()
        env.reviveMaster()

        #expect(try await transport.ensureMasterReady())
        #expect(await transport.masterGeneration == 2)
    }

    @Test func killDeadlineForceStopsCancellationBlindSSH() async throws {
        let env = try FakeSSHEnvironment(behavior: .hangsIgnoringTermination)
        defer { env.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host"),
            sshExecutablePath: env.executablePath
        )
        let start = ContinuousClock().now

        await RemoteTmuxSSHTransport.killSessions(
            [(transport: transport, target: "fixture")],
            timeout: .milliseconds(10)
        )

        // The invariant is "returns at its own 10ms deadline instead of
        // waiting out the SIGTERM-immune child's 5s sleep". The budget is
        // deliberately far above the deadline but well below the child's
        // sleep: under Swift Testing's parallel suite execution, task
        // scheduling contention alone was measured pushing the return past
        // 1s (isolated runs return in ~15ms), and a hang regression still
        // trips a 3s budget by seconds.
        #expect(
            ContinuousClock().now - start < .seconds(3),
            "Remote session cleanup must return at its own deadline"
        )
    }

    // MARK: - Fake ssh harness

    /// A throwaway `ssh` replacement plus the on-disk state it reads/writes.
    ///
    /// The script distinguishes the two invocations the gate makes purely from argv:
    /// `-O check` (readiness probe) versus everything else (the master-open `true`).
    /// It records each call to a log file and tracks "master up" with a sentinel
    /// file, so the test can assert call counts and ordering deterministically — no
    /// real network, no real `ssh`.
    private struct FakeSSHEnvironment {
        enum Behavior: Equatable {
            /// Cold: the first non-check run opens the master (sentinel) and exits 0.
            case opensOnFirstRun
            /// Warm: the master is already up before the first check.
            case alreadyRunning
            /// Fallback hole: the open exits 0 (non-multiplexed direct connection)
            /// but the shared master never comes up, so `-O check` keeps failing.
            case openSucceedsButMasterStaysDown
            /// A hung ssh process ignores graceful termination until its child exits.
            case hangsIgnoringTermination
        }

        let root: URL
        let executablePath: String
        private let statePath: String
        private let logPath: String

        init(behavior: Behavior) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("remote-tmux-master-ready-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            statePath = root.appendingPathComponent("master-up").path
            logPath = root.appendingPathComponent("calls.log").path

            if behavior == .alreadyRunning {
                FileManager.default.createFile(atPath: statePath, contents: Data())
            }

            // `-O check` (probe): succeed iff the sentinel exists.
            // Anything else is the `true` open; its body depends on the behavior.
            let openBody: String
            switch behavior {
            case .opensOnFirstRun, .alreadyRunning:
                // `.alreadyRunning` never reaches the open (warm check short-circuits),
                // but keep a well-formed success body that brings the master up.
                openBody = ": > \"$STATE\"\nexit 0"
            case .openSucceedsButMasterStaysDown:
                // Exit 0 like a non-multiplexed fallback, but never create the
                // sentinel — the shared master stays down, so `-O check` keeps failing.
                openBody = "exit 0"
            case .hangsIgnoringTermination:
                openBody = "trap '' TERM\nsleep 5\nexit 0"
            }

            let script = """
            #!/bin/sh
            STATE='\(statePath)'
            LOG='\(logPath)'
            is_check=0
            is_exit=0
            prev=''
            for arg in "$@"; do
                if [ "$prev" = "-O" ] && [ "$arg" = "check" ]; then is_check=1; fi
                if [ "$prev" = "-O" ] && [ "$arg" = "exit" ]; then is_exit=1; fi
                prev="$arg"
            done
            if [ "$is_check" = "1" ]; then
                printf 'check\\n' >> "$LOG"
                if [ -e "$STATE" ]; then exit 0; else exit 255; fi
            fi
            if [ "$is_exit" = "1" ]; then
                printf 'exit\\n' >> "$LOG"
                rm -f "$STATE"
                exit 0
            fi
            printf 'open\\n' >> "$LOG"
            \(openBody)
            """
            let scriptURL = root.appendingPathComponent("ssh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            executablePath = scriptURL.path
        }

        private func lines() -> [String] {
            guard let contents = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
            return contents.split(separator: "\n").map(String.init)
        }

        func openCount() -> Int { lines().filter { $0 == "open" }.count }
        func checkCount() -> Int { lines().filter { $0 == "check" }.count }

        /// The master dies behind the app's back (network drop, sleep, remote
        /// reboot): the sentinel vanishes without any local `-O exit`.
        func killMaster() { try? FileManager.default.removeItem(atPath: statePath) }

        /// Something OTHER than this transport's opener brings the master up
        /// (the user's interactive terminal ssh after an auth handover).
        func reviveMaster() { FileManager.default.createFile(atPath: statePath, contents: Data()) }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}

/// The bound on concurrent master opens across the app. Live repro on an 11 machine
/// corp fleet: the parallel attach fired 11 BatchMode openers at once, the
/// agent serialized them (5 done, a 25s stall, then the rest) and, with the
/// agent degraded, every opener hung past the probe budget so every machine
/// failed while the orphaned openers kept authenticating for minutes. Bounded
/// to a few in flight the same fleet opened in 15-23s with no stall.
@Suite struct RemoteTmuxMasterOpenGateTests {

    @Test func slotsAreBoundedAndHandOverInOrder() async throws {
        let gate = RemoteTmuxMasterOpenGate(limit: 2)

        #expect(await gate.acquire() == false)
        #expect(await gate.acquire() == false)
        #expect(await gate.inFlightCount == 2)

        // Third and fourth callers park, in order, until someone releases.
        let third = Task { await gate.acquire() }
        let waiting = await waitUntil { await gate.waitingCount == 1 }
        #expect(waiting)
        let fourth = Task { await gate.acquire() }
        #expect(await waitUntil { await gate.waitingCount == 2 })
        #expect(await gate.inFlightCount == 2)

        await gate.release()
        // The slot went straight to the longest waiter (FIFO): the third
        // caller resumes, reports it waited, and the fourth is still parked.
        #expect(await third.value == true)
        #expect(await gate.waitingCount == 1)
        #expect(await gate.inFlightCount == 2)

        await gate.release()
        #expect(await fourth.value == true)
        #expect(await gate.waitingCount == 0)

        await gate.release()
        await gate.release()
        #expect(await gate.inFlightCount == 0)
        #expect(await gate.peakInFlight == 2)
    }

    @Test func concurrentColdOpensAcrossHostsStayUnderTheGateLimit() async throws {
        let fleet = try FleetFakeSSH(openDuration: 0.25)
        defer { fleet.cleanUp() }
        let gate = RemoteTmuxMasterOpenGate(limit: 3)
        let hosts = (0..<8).map { "user@host-\($0)" }
        let transports = hosts.map {
            RemoteTmuxSSHTransport(
                host: RemoteTmuxHost(destination: $0),
                sshExecutablePath: fleet.executablePath,
                openGate: gate
            )
        }

        let ready = try await withThrowingTaskGroup(of: Bool.self) { group in
            for transport in transports {
                group.addTask { try await transport.ensureMasterReady() }
            }
            var all: [Bool] = []
            for try await value in group { all.append(value) }
            return all
        }

        #expect(ready.count == 8)
        #expect(ready.allSatisfy { $0 })
        // Every host authenticated exactly once (the gate queues, it never
        // drops or duplicates an open)...
        #expect(fleet.openCount() == 8)
        // ...and never more than `limit` authentications overlapped, measured
        // from the fake ssh's own start/end timestamps, not from what the gate
        // reports about itself.
        #expect(fleet.peakConcurrentOpens() <= 3, "opens overlapped: \(fleet.peakConcurrentOpens())")
        #expect(await gate.peakInFlight == 3)
    }

    @Test func aWaitedOpenerRechecksBeforeAuthenticatingAgain() async throws {
        // Slot holder A's authentication is in flight; B is parked behind it.
        // Meanwhile B's master comes up out of band (the user's terminal ssh
        // for B, an ssh-tmux rerun). When B finally gets the slot it must see
        // the serving master and NOT authenticate a second time.
        let fleet = try FleetFakeSSH(openDuration: 0)
        defer { fleet.cleanUp() }
        let gate = RemoteTmuxMasterOpenGate(limit: 1)
        let a = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host-a"),
            sshExecutablePath: fleet.executablePath,
            openGate: gate
        )
        let b = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host-b"),
            sshExecutablePath: fleet.executablePath,
            openGate: gate
        )

        fleet.holdOpen(for: "user@host-a")
        let readyA = Task { try await a.ensureMasterReady() }
        #expect(await waitUntil { fleet.openStarted(for: "user@host-a") })

        let readyB = Task { try await b.ensureMasterReady() }
        #expect(await waitUntil { await gate.waitingCount == 1 })

        fleet.bringMasterUp(for: "user@host-b")
        fleet.releaseOpen(for: "user@host-a")

        #expect(try await readyA.value)
        #expect(try await readyB.value)
        #expect(fleet.openCount(for: "user@host-a") == 1)
        #expect(fleet.openCount(for: "user@host-b") == 0)
    }

    @Test func aStalledOpenerIsKilledAndHandedToTheTerminal() async throws {
        // The live shape: a BatchMode open whose authentication never returns
        // (the agent waiting on a touch, or wedged). The transport must not sit
        // on it until the server's login grace closes it minutes later; it
        // kills the opener at the stall budget, frees the gate slot, and
        // reports the machine as needing interactive authentication.
        let fleet = try FleetFakeSSH(openDuration: 0)
        defer { fleet.cleanUp() }
        let gate = RemoteTmuxMasterOpenGate(limit: 1)
        let transport = RemoteTmuxSSHTransport(
            host: RemoteTmuxHost(destination: "user@host-stuck"),
            sshExecutablePath: fleet.executablePath,
            openGate: gate,
            openerStallTimeout: .milliseconds(300)
        )
        fleet.holdOpen(for: "user@host-stuck")

        let start = ContinuousClock().now
        var thrown: RemoteTmuxError?
        do {
            _ = try await transport.ensureMasterReady()
        } catch let error as RemoteTmuxError {
            thrown = error
        }
        let elapsed = ContinuousClock().now - start

        let error = try #require(thrown)
        #expect(error == .authenticationStalled(destination: "user@host-stuck", seconds: 1))
        #expect(RemoteTmuxSSHTransport.interactiveAttachRetryWillHelp(error))
        #expect(RemoteTmuxSSHTransport.interactiveRetryWillHelp(error))
        // Gave up at the budget, not at the process exit (which never arrives).
        #expect(elapsed < .seconds(3), "stall took \(elapsed)")
        // The opener was killed while it was still held (it never wrote its
        // completion line), and its slot went back to the gate.
        let pid = try #require(fleet.openerPid(for: "user@host-stuck"))
        #expect(await waitUntil { kill(pid, 0) != 0 }, "opener pid \(pid) still alive")
        #expect(!fleet.openFinished(for: "user@host-stuck"))
        #expect(await gate.inFlightCount == 0)
        #expect(await transport.masterGeneration == 0)
    }

    @Test func stallMessageNamesTheMachineAndTheRecovery() {
        let message = RemoteTmuxError.authenticationStalled(destination: "user@host", seconds: 30).message
        #expect(message.contains("user@host"))
        #expect(message.contains("30"))
        #expect(message.contains("cmux ssh-tmux user@host"))
        // Only stalls and classifiable stderr route to the terminal; a plain
        // unreachable host still surfaces as an error.
        #expect(!RemoteTmuxSSHTransport.interactiveRetryWillHelp(.unreachable("user@host")))
        #expect(!RemoteTmuxSSHTransport.interactiveAttachRetryWillHelp(.unreachable("user@host")))
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// A fake `ssh` shared by several hosts: a master sentinel and a hold file
    /// (parks an open until released) per destination, and a
    /// timestamped call log so overlap can be measured from the processes'
    /// own lifetimes. The destination is the token after `--`, exactly where
    /// the transport puts it for both `-O check` probes and opens.
    private struct FleetFakeSSH {
        let root: URL
        let executablePath: String
        private let logPath: String

        init(openDuration: Double) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("remote-tmux-open-gate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            logPath = root.appendingPathComponent("calls.log").path
            let script = """
            #!/bin/sh
            ROOT='\(root.path)'
            LOG="$ROOT/calls.log"
            dest=''
            prev=''
            is_check=0
            is_exit=0
            for arg in "$@"; do
                if [ "$prev" = "-O" ] && [ "$arg" = "check" ]; then is_check=1; fi
                if [ "$prev" = "-O" ] && [ "$arg" = "exit" ]; then is_exit=1; fi
                if [ "$prev" = "--" ] && [ -z "$dest" ]; then dest="$arg"; fi
                prev="$arg"
            done
            STATE="$ROOT/up-$dest"
            HOLD="$ROOT/hold-$dest"
            now() { perl -MTime::HiRes=time -e 'printf "%.6f", time'; }
            if [ "$is_check" = "1" ]; then
                printf 'check %s\\n' "$dest" >> "$LOG"
                if [ -e "$STATE" ]; then exit 0; else exit 255; fi
            fi
            if [ "$is_exit" = "1" ]; then
                rm -f "$STATE"
                exit 0
            fi
            printf 'open-start %s %s %s\\n' "$dest" "$(now)" "$$" >> "$LOG"
            while [ -e "$HOLD" ]; do sleep 0.02; done
            sleep \(openDuration)
            : > "$STATE"
            printf 'open-end %s %s\\n' "$dest" "$(now)" >> "$LOG"
            exit 0
            """
            let scriptURL = root.appendingPathComponent("ssh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            executablePath = scriptURL.path
        }

        private func lines() -> [String] {
            guard let contents = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
            return contents.split(separator: "\n").map(String.init)
        }

        func openCount() -> Int { lines().filter { $0.hasPrefix("open-start ") }.count }

        func openCount(for destination: String) -> Int {
            lines().filter { $0 == "open-start \(destination)" || $0.hasPrefix("open-start \(destination) ") }.count
        }

        func openStarted(for destination: String) -> Bool { openCount(for: destination) > 0 }

        func openFinished(for destination: String) -> Bool {
            lines().contains { $0.hasPrefix("open-end \(destination) ") }
        }

        /// The fake ssh process id recorded by the open for `destination`.
        func openerPid(for destination: String) -> pid_t? {
            for line in lines() where line.hasPrefix("open-start \(destination) ") {
                let parts = line.split(separator: " ")
                if parts.count == 4, let pid = pid_t(parts[3]) { return pid }
            }
            return nil
        }

        /// Maximum number of opens whose [start, end] intervals overlapped.
        func peakConcurrentOpens() -> Int {
            var events: [(time: Double, delta: Int)] = []
            for line in lines() {
                let parts = line.split(separator: " ")
                guard parts.count >= 3, let time = Double(parts[2]) else { continue }
                if parts[0] == "open-start" { events.append((time, 1)) }
                if parts[0] == "open-end" { events.append((time, -1)) }
            }
            // Ends sort before starts at equal timestamps so touching
            // intervals do not count as overlapping.
            events.sort { $0.time == $1.time ? $0.delta < $1.delta : $0.time < $1.time }
            var current = 0
            var peak = 0
            for event in events {
                current += event.delta
                peak = max(peak, current)
            }
            return peak
        }

        func holdOpen(for destination: String) {
            FileManager.default.createFile(atPath: root.appendingPathComponent("hold-\(destination)").path, contents: Data())
        }

        func releaseOpen(for destination: String) {
            try? FileManager.default.removeItem(atPath: root.appendingPathComponent("hold-\(destination)").path)
        }

        /// Something other than this transport's opener brings the master up.
        func bringMasterUp(for destination: String) {
            FileManager.default.createFile(atPath: root.appendingPathComponent("up-\(destination)").path, contents: Data())
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }
}

/// The scheduling half of the agent-bridge heal (the generation signal above
/// is the observing half): one bridge configuration per master generation, no
/// stacking across coalesced gate passes, forced refresh on user attach, and
/// retry eligibility after failures. Kept beside the readiness-gate tests
/// because the schedule is meaningless without the generation contract they
/// pin down.
@Suite struct RemoteTmuxAgentBridgeScheduleTests {

    @Test func newGenerationBeginsExactlyOnceAcrossCoalescedGatePasses() {
        var schedule = RemoteTmuxAgentBridgeSchedule()
        let first = schedule.begin(connectionHash: "h", generation: 1, force: false)
        #expect(first)
        // Five more parked reconnect loops ride the same reopened master:
        // the in-flight claim absorbs them all.
        for _ in 0..<5 {
            let stacked = schedule.begin(connectionHash: "h", generation: 1, force: false)
            #expect(!stacked)
        }
        schedule.finish(connectionHash: "h", generation: 1, configured: true)
        // Configured: the same generation never reconfigures (a control-stream
        // blip on a surviving master is a no-op)...
        let sameGeneration = schedule.begin(connectionHash: "h", generation: 1, force: false)
        #expect(!sameGeneration)
        // ...but the next master death+reopen does.
        let nextGeneration = schedule.begin(connectionHash: "h", generation: 2, force: false)
        #expect(nextGeneration)
    }

    @Test func forceAlwaysRefreshesAConfiguredGeneration() {
        var schedule = RemoteTmuxAgentBridgeSchedule()
        let first = schedule.begin(connectionHash: "h", generation: 1, force: true)
        #expect(first)
        schedule.finish(connectionHash: "h", generation: 1, configured: true)
        // An `ssh-tmux` rerun on the same generation still refreshes pins and
        // plugin (force is the user-driven manual heal)...
        let rerun = schedule.begin(connectionHash: "h", generation: 1, force: true)
        #expect(rerun)
        // ...but even force never stacks on an in-flight attempt.
        let stacked = schedule.begin(connectionHash: "h", generation: 1, force: true)
        #expect(!stacked)
    }

    @Test func failureKeepsTheEndpointEligibleForRetry() {
        var schedule = RemoteTmuxAgentBridgeSchedule()
        let first = schedule.begin(connectionHash: "h", generation: 1, force: false)
        #expect(first)
        schedule.finish(connectionHash: "h", generation: 1, configured: false)
        // Nothing was recorded, so the caller's retry (or the next gate pass)
        // may claim the same generation again.
        let retry = schedule.begin(connectionHash: "h", generation: 1, force: false)
        #expect(retry)
    }

    @Test func unobservedGenerationNeedsForce() {
        var schedule = RemoteTmuxAgentBridgeSchedule()
        // Generation 0 = the master was never observed serving; only a forced
        // attach (which just confirmed the master out-of-band) may configure.
        let unforced = schedule.begin(connectionHash: "h", generation: 0, force: false)
        #expect(!unforced)
        let forced = schedule.begin(connectionHash: "h", generation: 0, force: true)
        #expect(forced)
    }

    @Test func endpointsAreIndependent() {
        var schedule = RemoteTmuxAgentBridgeSchedule()
        let first = schedule.begin(connectionHash: "a", generation: 1, force: false)
        #expect(first)
        // One machine's in-flight configure never blocks another's.
        let second = schedule.begin(connectionHash: "b", generation: 1, force: false)
        #expect(second)
    }
}
