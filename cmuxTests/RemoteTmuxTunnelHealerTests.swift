import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// ``RemoteTmuxTunnelHealer``: the user's configured ssh tunnels are
/// re-registered on every master generation and refused ones are retried
/// until they land or the master changes.
@MainActor
@Suite struct RemoteTmuxTunnelHealerTests {
    private static let remote = RemoteTmuxForwardSpec(kind: .remote, specification: "9998:localhost:9998")
    private static let local = RemoteTmuxForwardSpec(kind: .local, specification: "3000:127.0.0.1:3000")

    /// A scripted transport: per-spec refusal counts, a call journal, and a
    /// settable master generation.
    private actor FakeTransport {
        var refusalsRemaining: [RemoteTmuxForwardSpec: Int]
        var generation: UInt64
        private(set) var calls: [String] = []
        var forwards: [RemoteTmuxForwardSpec]

        init(forwards: [RemoteTmuxForwardSpec], refusals: [RemoteTmuxForwardSpec: Int], generation: UInt64 = 1) {
            self.forwards = forwards
            self.refusalsRemaining = refusals
            self.generation = generation
        }

        func configured() -> [RemoteTmuxForwardSpec] {
            calls.append("configured")
            return forwards
        }

        func cancel(_ spec: RemoteTmuxForwardSpec) {
            calls.append("cancel \(spec)")
        }

        func request(_ spec: RemoteTmuxForwardSpec) -> RemoteTmuxCommandResult {
            calls.append("forward \(spec)")
            if let left = refusalsRemaining[spec], left > 0 {
                refusalsRemaining[spec] = left - 1
                return RemoteTmuxCommandResult(
                    exitCode: 255,
                    stdout: "",
                    stderr: "mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 9998\nmuxclient: master forward request failed\n"
                )
            }
            return RemoteTmuxCommandResult(exitCode: 0, stdout: "", stderr: "")
        }

        func setGeneration(_ value: UInt64) { generation = value }
        func currentGeneration() -> UInt64 { generation }
        func journal() -> [String] { calls }
    }

    private func makeHealer(
        transport: FakeTransport,
        log: RemoteTmuxConnectionLog,
        backoff: [Duration] = [.milliseconds(20)],
        forceCooldown: Duration = RemoteTmuxTunnelHealer.defaultForceCooldown,
        onStatus: @escaping @MainActor (RemoteTmuxTunnelStatus?) -> Void = { _ in }
    ) -> RemoteTmuxTunnelHealer {
        RemoteTmuxTunnelHealer(
            host: RemoteTmuxHost(destination: "xxl"),
            operations: RemoteTmuxTunnelHealer.Operations(
                configuredForwards: { await transport.configured() },
                cancel: { await transport.cancel($0) },
                request: { await transport.request($0) },
                currentGeneration: { await transport.currentGeneration() }
            ),
            connectionLog: log,
            backoff: backoff,
            forceCooldown: forceCooldown,
            onStatusChanged: onStatus
        )
    }

    /// Collects the statuses the healer publishes (what the sidebar would see).
    private final class StatusRecorder {
        var values: [RemoteTmuxTunnelStatus] = []
    }

    private func makeLog() -> (RemoteTmuxConnectionLog, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tunnel-healer-\(UUID().uuidString)", isDirectory: true)
        return (RemoteTmuxConnectionLog(directoryURL: root, markdownRenderDelay: .milliseconds(10)), root)
    }

    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func refusedForwardIsRetriedUntilItLandsWhileEstablishedOnesAreLeftAlone() async throws {
        let (log, root) = makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        // The remote port is held by a zombie for two attempts, then frees up.
        let transport = FakeTransport(forwards: [Self.remote, Self.local], refusals: [Self.remote: 2])
        let recorder = StatusRecorder()
        let healer = makeHealer(transport: transport, log: log, forceCooldown: .zero) { status in
            if let status { recorder.values.append(status) }
        }

        healer.heal(generation: 1)
        #expect(await waitUntil { !healer.isHealing })

        let journal = await transport.journal()
        // Round 1: every configured forward is cancelled then requested (a
        // refused open leaves a registration that would short-circuit the
        // request). Rounds 2 and 3: only the refused one.
        #expect(journal == [
            "configured",
            "cancel R 9998:localhost:9998", "forward R 9998:localhost:9998",
            "cancel L 3000:127.0.0.1:3000", "forward L 3000:127.0.0.1:3000",
            "cancel R 9998:localhost:9998", "forward R 9998:localhost:9998",
            "cancel R 9998:localhost:9998", "forward R 9998:localhost:9998",
        ])
        let final = try #require(healer.status)
        #expect(final.generation == 1)
        #expect(!final.hasProblem)
        #expect(Set(final.established) == [Self.remote, Self.local])
        // The sidebar saw the degraded state first, then the recovery.
        let firstStatus = try #require(recorder.values.first)
        #expect(firstStatus.failed.map(\.spec) == [Self.remote])
        #expect(firstStatus.failed.first?.reason == "remote port forwarding failed for listen port 9998")
        #expect(firstStatus.established == [Self.local])
        #expect(recorder.values.last?.hasProblem == false)

        // The log, in config order within a round: the refused forward's one
        // failure line (its reason never changed, so retries add nothing),
        // the other forward's establishment, then the recovery.
        log.flush()
        let events = log.entries(for: RemoteTmuxHost(destination: "xxl"))
        #expect(events.map(\.knownKind) == [.tunnelFailed, .tunnelRestored, .tunnelRestored])
        #expect(events[0].message == "tunnel R 9998:localhost:9998 unavailable: remote port forwarding failed for listen port 9998; retrying")
        #expect(events[0].detail?.hasPrefix("R 9998:localhost:9998\nmux_client_forward") == true)
        #expect(events[1].message == "tunnel L 3000:127.0.0.1:3000 established on the master")
        #expect(events[2].message == "tunnel R 9998:localhost:9998 established on the master")

        // A healthy generation is not healed twice; a forced heal (the user
        // reran ssh-tmux) re-registers everything once more (this healer has
        // no force cooldown).
        healer.heal(generation: 1)
        #expect(!healer.isHealing)
        #expect(await transport.journal().count == journal.count)
        healer.heal(generation: 1, force: true)
        #expect(await waitUntil { !healer.isHealing })
        #expect(await transport.journal().count == journal.count + 5)
    }

    @Test func aForcedHealRightAfterAHealthyCycleIsCoalesced() async throws {
        // An attach fires the gate's heal and then the user-driven forced
        // heal within seconds; the second must not blip every tunnel again.
        let (log, root) = makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport(forwards: [Self.remote], refusals: [:])
        let healer = makeHealer(transport: transport, log: log)
        healer.heal(generation: 1)
        #expect(await waitUntil { !healer.isHealing })
        let afterFirst = await transport.journal().count
        #expect(afterFirst == 3)
        healer.heal(generation: 1, force: true)
        #expect(!healer.isHealing)
        #expect(await transport.journal().count == afterFirst)
        // A forced heal while a refused tunnel is still being retried does
        // restart the cycle: the retry happens now instead of after backoff.
        let refusing = FakeTransport(forwards: [Self.remote], refusals: [Self.remote: 1_000])
        let retrying = makeHealer(transport: refusing, log: log, backoff: [.seconds(30)])
        retrying.heal(generation: 1)
        #expect(await waitUntil { retrying.status?.hasProblem == true })
        let beforeForce = await refusing.journal().count
        retrying.heal(generation: 1, force: true)
        #expect(await waitUntil { await refusing.journal().count >= beforeForce + 3 })
        retrying.stop()
    }

    @Test func aNewMasterGenerationAbandonsTheOldCycle() async throws {
        let (log, root) = makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        // Refused forever on generation 1.
        let transport = FakeTransport(forwards: [Self.remote], refusals: [Self.remote: 1_000])
        let healer = makeHealer(transport: transport, log: log, backoff: [.milliseconds(30)])

        healer.heal(generation: 1)
        #expect(await waitUntil { healer.status?.hasProblem == true })
        // The master is replaced: the transport now reports generation 2 and
        // the controller schedules a heal for it. The generation-1 cycle must
        // stop touching the (new) master.
        await transport.setGeneration(2)
        let callsBeforeSwitch = await transport.journal().count
        healer.heal(generation: 2)
        #expect(await waitUntil { healer.status?.generation == 2 })
        // Generation 2 is refused too, so the healer keeps retrying, but only
        // one cycle does: the journal grows in cancel+forward pairs, and the
        // old cycle's requests stopped.
        try? await Task.sleep(for: .milliseconds(120))
        let journal = await transport.journal()
        #expect(journal.count > callsBeforeSwitch)
        #expect(journal.filter { $0 == "configured" }.count == 2)
        #expect(healer.isHealing)
        healer.stop()
        #expect(!healer.isHealing)
        #expect(healer.status == nil)
    }

    @Test func noConfiguredForwardsIsHealthyWithoutAnySSHTraffic() async throws {
        let (log, root) = makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeTransport(forwards: [], refusals: [:])
        let healer = makeHealer(transport: transport, log: log)
        healer.heal(generation: 3)
        #expect(await waitUntil { !healer.isHealing })
        #expect(healer.status == RemoteTmuxTunnelStatus(generation: 3, established: [], failed: []))
        #expect(await transport.journal() == ["configured"])
        // Generation 0 means "no master observed yet": nothing to heal.
        healer.heal(generation: 0)
        #expect(!healer.isHealing)
    }

    @Test func failureReasonPrefersTheForwardingLine() {
        let refused = RemoteTmuxCommandResult(
            exitCode: 255,
            stdout: "",
            stderr: "mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 9998\nmuxclient: master forward request failed\n"
        )
        #expect(RemoteTmuxTunnelHealer.failureReason(refused) == "remote port forwarding failed for listen port 9998")
        let localBind = RemoteTmuxCommandResult(
            exitCode: 255,
            stdout: "",
            stderr: "mux_client_forward: forwarding request failed: Port forwarding failed\nmuxclient: master forward request failed\n"
        )
        #expect(RemoteTmuxTunnelHealer.failureReason(localBind) == "Port forwarding failed")
        let noMaster = RemoteTmuxCommandResult(
            exitCode: 255,
            stdout: "",
            stderr: "Control socket connect(/Users/x/.cmux/ssh/tmux-xxl.sock): No such file or directory\n"
        )
        #expect(RemoteTmuxTunnelHealer.failureReason(noMaster).hasPrefix("Control socket connect"))
        #expect(RemoteTmuxTunnelHealer.failureReason(nil) == "ssh -O forward could not be run")
        #expect(RemoteTmuxTunnelHealer.failureReason(RemoteTmuxCommandResult(exitCode: 1, stdout: "", stderr: ""))
            == "ssh -O forward exited 1")
    }
}
