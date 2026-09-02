import Foundation

/// Bounds how many shared master OPENS run at once across every host.
///
/// A master open is the only BatchMode (no prompt) authentication cmux performs
/// (``RemoteTmuxSSHTransport/ensureMasterReady()``), and authentication is a
/// serialized resource on the user's side: one ssh agent, one security key,
/// one relay helper. Firing every machine's open at once buys nothing and
/// costs a lot. Measured against an 11 machine corp fleet: 11 simultaneous
/// opens serialized behind the agent anyway (5 finished, then a 25s stall,
/// then the rest), and with the agent in a degraded state they all hung past
/// the attach probe's budget, so every machine failed while 11 orphaned ssh
/// openers kept authenticating in the background for minutes. The same fleet
/// opened in 15-23s with a few opens in flight and no stall.
///
/// The CLI already serializes the interactive authentication leg through its
/// terminal baton; this gate applies the same model to the BatchMode leg.
/// Slots hand over FIFO so a machine that waited longest goes next, and a
/// caller that had to wait learns so (``acquire()`` returns `true`) and can
/// check again whether the master came up behind its back before it
/// authenticates again.
actor RemoteTmuxMasterOpenGate {
    /// The gate every transport in the app opens through.
    static let shared = RemoteTmuxMasterOpenGate(limit: 4)

    /// Maximum concurrent opens.
    nonisolated let limit: Int

    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Peak number of concurrent holders (diagnostics and tests).
    private(set) var peakInFlight = 0

    /// Callers currently parked waiting for a slot.
    var waitingCount: Int { waiters.count }

    /// Slots currently held.
    var inFlightCount: Int { inFlight }

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Takes a slot, parking FIFO behind earlier callers when all are held.
    /// Returns `true` when the caller had to wait.
    ///
    /// Deliberately ignores task cancellation: the only caller is the transport's
    /// unstructured master warmup, which outlives any single requester (a
    /// probe that timed out must not abandon a slot that later callers coalesce on).
    func acquire() async -> Bool {
        if inFlight < limit {
            inFlight += 1
            peakInFlight = max(peakInFlight, inFlight)
            return false
        }
        await withCheckedContinuation { waiters.append($0) }
        // The releaser handed its slot straight to us; `inFlight` is unchanged.
        return true
    }

    /// Returns a slot: to the caller that has waited longest when one is parked,
    /// otherwise back to the pool.
    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else {
            inFlight = max(0, inFlight - 1)
        }
    }

    /// Runs `body` while holding a slot; `waited` tells it whether the slot
    /// was contended.
    func withSlot<T: Sendable>(
        _ body: @Sendable (_ waited: Bool) async throws -> T
    ) async rethrows -> T {
        let waited = await acquire()
        defer { release() }
        return try await body(waited)
    }
}
