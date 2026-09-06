import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The persisted per-machine connection log (``RemoteTmuxConnectionLog``):
/// what the transport and controller leave behind so an outage can be
/// explained after the fact.
@Suite struct RemoteTmuxConnectionLogTests {
    private func makeLog() throws -> (log: RemoteTmuxConnectionLog, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remote-tmux-connection-log-\(UUID().uuidString)", isDirectory: true)
        return (RemoteTmuxConnectionLog(directoryURL: root, markdownRenderDelay: .milliseconds(10)), root)
    }

    @Test func eventsPersistPerMachineAndReadBackOldestFirst() throws {
        let (log, root) = try makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        let xxl = RemoteTmuxHost(destination: "xxl")
        let cloudtop = RemoteTmuxHost(destination: "cloudtop")

        log.record(host: xxl, kind: .masterServing, message: "master serving (generation 1)", generation: 1)
        log.record(host: xxl, kind: .tunnelFailed, message: "tunnel R 9998:localhost:9998 unavailable",
                   detail: "R 9998:localhost:9998\nremote port forwarding failed for listen port 9998", generation: 1)
        log.record(host: cloudtop, kind: .masterDead, message: "master gone")
        log.flush()

        let xxlEvents = log.entries(for: xxl)
        #expect(xxlEvents.map(\.message) == ["master serving (generation 1)", "tunnel R 9998:localhost:9998 unavailable"])
        #expect(xxlEvents.map(\.knownKind) == [.masterServing, .tunnelFailed])
        #expect(xxlEvents.map(\.generation) == [1, 1])
        #expect(xxlEvents[1].detail == "R 9998:localhost:9998\nremote port forwarding failed for listen port 9998")
        #expect(xxlEvents[1].isFailure)
        #expect(!xxlEvents[0].isFailure)
        // Machines never share a file.
        #expect(log.entries(for: cloudtop).map(\.message) == ["master gone"])

        // A newer cmux writing a kind this build does not know still reads.
        let unknown = "{\"time\":\"2026-09-05T10:00:00Z\",\"kind\":\"future.kind\",\"message\":\"from the future\"}\n"
        let handle = try FileHandle(forWritingTo: log.logFileURL(for: cloudtop))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(unknown.utf8))
        try handle.close()
        let readBack = log.entries(for: cloudtop)
        #expect(readBack.count == 2)
        #expect(readBack.last?.knownKind == nil)
        #expect(readBack.last?.message == "from the future")

        // Files are private to the user.
        let attributes = try FileManager.default.attributesOfItem(atPath: log.logFileURL(for: xxl).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((dirAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func limitReturnsTheNewestAndSpansTheRotatedPredecessor() throws {
        let (log, root) = try makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = RemoteTmuxHost(destination: "xxl")
        // Pad a rotated predecessor by hand: the rotation trigger is 1 MiB,
        // too much to write in a unit test, but the read path must stitch the
        // two files whenever the current one is short.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let older = (1...3).map {
            "{\"time\":\"2026-09-05T09:0\($0):00Z\",\"kind\":\"master.serving\",\"message\":\"older \($0)\"}"
        }.joined(separator: "\n") + "\n"
        try older.write(to: log.rotatedLogFileURL(for: host), atomically: true, encoding: .utf8)
        log.record(host: host, kind: .masterServing, message: "newer 1")
        log.record(host: host, kind: .masterServing, message: "newer 2")
        log.flush()

        #expect(log.entries(for: host, limit: 1).map(\.message) == ["newer 2"])
        #expect(log.entries(for: host, limit: 3).map(\.message) == ["older 3", "newer 1", "newer 2"])
        #expect(log.entries(for: host, limit: 10).map(\.message)
            == ["older 1", "older 2", "older 3", "newer 1", "newer 2"])
        #expect(log.entries(for: host, limit: 0).isEmpty)
    }

    @Test func detailsAreSanitizedAndBounded() throws {
        let (log, root) = try makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = RemoteTmuxHost(destination: "xxl")
        let hostile = "line one\u{1B}[31m\r\n\ttabbed\u{0}nul" + String(repeating: "x", count: 10_000)
        log.record(host: host, kind: .commandFailed, message: "bad\u{07}bell", detail: hostile)
        log.flush()
        let event = try #require(log.entries(for: host).first)
        // Control bytes are flattened; newlines and tabs survive in the detail.
        #expect(event.message == "bad bell")
        let detail = try #require(event.detail)
        #expect(detail.hasPrefix("line one [31m \n\ttabbed nul"))
        #expect(!detail.contains("\u{1B}"))
        #expect(!detail.contains("\u{0}"))
        #expect(detail.count <= RemoteTmuxConnectionLog.maxDetailCharacters + 1)
        #expect(detail.hasSuffix("…"))
    }

    @Test func markdownMirrorsTheLogWithACurrentStateSummary() throws {
        let (log, root) = try makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = RemoteTmuxHost(destination: "dev@xxl")
        log.record(host: host, kind: .masterServing, message: "master serving (generation 2)", generation: 2)
        log.record(host: host, kind: .bridgeConfigured, message: "agent bridge ready", detail: "/tmp/cmux-agent.sock", generation: 2)
        log.record(host: host, kind: .tunnelFailed, message: "tunnel R 9998:localhost:9998 unavailable: remote port forwarding failed for listen port 9998; retrying",
                   detail: "R 9998:localhost:9998\nmux_client_forward: forwarding request failed: remote port forwarding failed for listen port 9998", generation: 2)
        log.record(host: host, kind: .tunnelRestored, message: "tunnel R 9998:localhost:9998 established on the master", detail: "R 9998:localhost:9998", generation: 2)
        log.record(host: host, kind: .tunnelFailed, message: "tunnel L 3000:127.0.0.1:3000 unavailable: Port forwarding failed; retrying",
                   detail: "L 3000:127.0.0.1:3000\nPort forwarding failed", generation: 2)
        log.flush()

        let markdown = try String(contentsOf: log.markdownFileURL(for: host), encoding: .utf8)
        #expect(markdown.hasPrefix("# Connection log: dev@xxl"))
        #expect(markdown.contains(log.logFileURL(for: host).path))
        // The state summary reflects the LATEST outcome per tunnel.
        #expect(markdown.contains("Master: master serving (generation 2)"))
        #expect(markdown.contains("Agent bridge: agent bridge ready"))
        #expect(markdown.contains("Tunnel R 9998:localhost:9998: established"))
        #expect(markdown.contains("Tunnel L 3000:127.0.0.1:3000: unavailable, retrying"))
        // Newest event first in the table; failures are marked; pipes cannot break the table.
        let rows = markdown.split(separator: "\n").filter { $0.hasPrefix("| 20") }
        #expect(rows.count == 5)
        #expect(rows.first?.contains("⚠️ tunnel L 3000") == true)
        #expect(rows.last?.contains("master serving (generation 2)") == true)
        #expect(markdown.contains("⏎ mux_client_forward"))

        // The markdown is rewritten as events arrive (the panel live-reloads it).
        log.record(host: host, kind: .tunnelRestored, message: "tunnel L 3000:127.0.0.1:3000 established on the master", detail: "L 3000:127.0.0.1:3000", generation: 2)
        log.flush()
        let updated = try String(contentsOf: log.markdownFileURL(for: host), encoding: .utf8)
        #expect(updated.contains("Tunnel L 3000:127.0.0.1:3000: established"))
        #expect(log.renderMarkdownNow(for: host) == log.markdownFileURL(for: host))
    }

    @Test func fileNamesCombineSlugAndConnectionHash() throws {
        let (log, root) = try makeLog()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = RemoteTmuxHost(destination: "alice@host")
        let dotted = RemoteTmuxHost(destination: "alice.host")
        // Same lossy slug, different identity: different files.
        #expect(plain.slug == dotted.slug)
        #expect(log.logFileURL(for: plain) != log.logFileURL(for: dotted))
        #expect(log.logFileURL(for: plain).lastPathComponent == "alice-host-\(plain.connectionHash).jsonl")
        #expect(log.markdownFileURL(for: plain).lastPathComponent == "alice-host-\(plain.connectionHash).md")
    }
}
