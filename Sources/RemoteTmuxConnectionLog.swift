import CmuxSettings
import Foundation

/// One persisted remote tmux connection event (see ``RemoteTmuxConnectionLog``).
struct RemoteTmuxConnectionEvent: Codable, Equatable, Sendable {
    /// The event vocabulary. Persisted as raw strings so a log written by a
    /// newer cmux still reads (unknown kinds render as plain events).
    enum Kind: String, Sendable, CaseIterable {
        /// A serving master was observed; `generation` counts dead-to-serving edges.
        case masterServing = "master.serving"
        /// The master was observed dead (its socket answered no `-O check`).
        case masterDead = "master.dead"
        /// The BatchMode opener authenticated and the master came up.
        case masterOpened = "master.opened"
        /// The BatchMode opener failed; `detail` carries ssh's stderr.
        case masterOpenFailed = "master.open_failed"
        /// The BatchMode opener was killed after the authentication budget.
        case masterOpenStalled = "master.open_stalled"
        /// A machine was handed to the interactive terminal for authentication.
        case interactiveAuth = "auth.interactive"
        /// Reconnects parked awaiting the user's re-authentication.
        case reauthParked = "auth.parked"
        /// A serving master ended the park.
        case reauthCleared = "auth.cleared"
        /// A one-shot command over the master failed; `detail` carries stderr.
        case commandFailed = "command.failed"
        /// A `tmux -CC` control stream ended or was lost.
        case controlStreamEnded = "control.ended"
        /// A lost `tmux -CC` control stream is attached again.
        case controlStreamReconnected = "control.reconnected"
        /// The remote agent bridge (reverse-forwarded control socket) is registered.
        case bridgeConfigured = "bridge.configured"
        /// The remote agent bridge could not be (re)configured.
        case bridgeFailed = "bridge.failed"
        /// A configured tunnel (`RemoteForward`/`LocalForward`/`DynamicForward`) is established.
        case tunnelRestored = "tunnel.restored"
        /// A configured tunnel could not be established; cmux keeps retrying.
        case tunnelFailed = "tunnel.failed"
        /// The user disconnected the machine (`ssh -O exit`).
        case disconnected = "master.disconnected"
    }

    let time: Date
    let kind: String
    let generation: UInt64?
    /// One line, human readable.
    let message: String
    /// Longer diagnostic text (ssh stderr, a forward spec, an exit code…),
    /// control characters flattened, capped.
    let detail: String?

    var knownKind: Kind? { Kind(rawValue: kind) }

    /// Whether the event marks something the user may need to act on.
    var isFailure: Bool {
        switch knownKind {
        case .masterDead, .masterOpenFailed, .masterOpenStalled, .reauthParked,
             .commandFailed, .bridgeFailed, .tunnelFailed:
            return true
        default:
            return false
        }
    }
}

/// Persisted, per-machine event log for the remote tmux transport: master
/// generations, opens and re-authentications (with ssh's stderr), bridge and
/// tunnel outcomes, control-stream exits, one-shot command failures.
///
/// Why a file and not the unified log: the transport's events are `.info`
/// lines OSLog does not persist, so after an outage nothing remained to
/// explain WHY a machine went dark or why the user had to touch their key
/// again. One JSONL file per endpoint under `~/.cmux/remote-tmux/logs/`
/// (next to the control sockets in `~/.cmux/ssh/`) survives app restarts,
/// is trivially `tail -f`-able, and is also rendered to a sibling markdown
/// file the sidebar can open in a live-reloading panel.
///
/// Appends are serialized on one queue and never block the caller; reads
/// run on the same queue so they observe every completed append. Files are
/// mode 0600 in a 0700 directory. A file past ``maxFileBytes`` is rotated
/// to `<name>.1.jsonl` (one predecessor kept), so a flapping machine cannot
/// grow the log without bound.
final class RemoteTmuxConnectionLog: @unchecked Sendable {
    static let shared = RemoteTmuxConnectionLog(directoryURL: defaultDirectoryURL())

    /// `~/.cmux/remote-tmux/logs/`, next to the control sockets. Unit tests
    /// host the real transports (their fake ssh still drives the real
    /// recording paths), so under XCTest the shared log lives in the
    /// temporary directory instead of the developer's home.
    static func defaultDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if SocketControlSettings.isRunningUnderXCTest(environment: environment) {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-tests", isDirectory: true)
                .appendingPathComponent("remote-tmux-logs", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("remote-tmux", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    /// Rotation threshold for one endpoint's log.
    static let maxFileBytes = 1_048_576
    /// Cap on one event's `detail` (ssh stderr can be pages of `-v` output).
    static let maxDetailCharacters = 8_000
    /// Events kept in the rendered markdown (newest first).
    static let markdownEventLimit = 200

    let directoryURL: URL
    private let queue = DispatchQueue(label: "cmux.remote-tmux.connection-log", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    /// Pending markdown re-renders per endpoint key (debounced on `queue`).
    private var pendingMarkdownRenders: Set<String> = []
    /// The markdown re-render delay: a burst of events (an attach of many
    /// sessions) becomes one rewrite.
    private let markdownRenderDelay: DispatchTimeInterval

    init(directoryURL: URL, markdownRenderDelay: DispatchTimeInterval = .milliseconds(300)) {
        self.directoryURL = directoryURL
        self.markdownRenderDelay = markdownRenderDelay
    }

    // MARK: - Paths

    /// `<slug>-<connectionHash>`: the lossy human slug for `ls`, the hash for
    /// uniqueness (two endpoints sharing a slug never share a log).
    static func fileStem(for host: RemoteTmuxHost) -> String {
        "\(String(host.slug.prefix(40)))-\(host.connectionHash)"
    }

    func logFileURL(for host: RemoteTmuxHost) -> URL {
        directoryURL.appendingPathComponent("\(Self.fileStem(for: host)).jsonl")
    }

    func rotatedLogFileURL(for host: RemoteTmuxHost) -> URL {
        directoryURL.appendingPathComponent("\(Self.fileStem(for: host)).1.jsonl")
    }

    func markdownFileURL(for host: RemoteTmuxHost) -> URL {
        directoryURL.appendingPathComponent("\(Self.fileStem(for: host)).md")
    }

    // MARK: - Recording

    /// Appends one event for `host`. Returns immediately; the write (and the
    /// debounced markdown re-render) happen on the log's queue.
    func record(
        host: RemoteTmuxHost,
        kind: RemoteTmuxConnectionEvent.Kind,
        message: String,
        detail: String? = nil,
        generation: UInt64? = nil
    ) {
        let event = RemoteTmuxConnectionEvent(
            time: Date(),
            kind: kind.rawValue,
            generation: generation,
            message: Self.sanitized(message, maxCharacters: 400, preservingNewlines: false),
            detail: detail.flatMap { raw in
                let cleaned = Self.sanitized(raw, maxCharacters: Self.maxDetailCharacters, preservingNewlines: true)
                return cleaned.isEmpty ? nil : cleaned
            }
        )
        queue.async { [self] in
            append(event, for: host)
            scheduleMarkdownRender(for: host)
        }
    }

    /// Blocks until every append and render enqueued so far has completed.
    /// For tests and for readers that must observe an event they just caused.
    func flush() {
        queue.sync {}
        // A render scheduled by the flushed appends may still be pending.
        let deadline = Date().addingTimeInterval(2)
        while queue.sync(execute: { !pendingMarkdownRenders.isEmpty }), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        queue.sync {}
    }

    // MARK: - Reading

    /// The newest `limit` events for `host`, oldest first, spanning the
    /// rotated predecessor when the current file is short.
    func entries(for host: RemoteTmuxHost, limit: Int = 200) -> [RemoteTmuxConnectionEvent] {
        queue.sync { readEntries(for: host, limit: limit) }
    }

    /// Writes the markdown view for `host` now (a viewer is about to open it)
    /// and returns its path.
    @discardableResult
    func renderMarkdownNow(for host: RemoteTmuxHost) -> URL {
        queue.sync { renderMarkdownFile(for: host) }
        return markdownFileURL(for: host)
    }

    // MARK: - Queue-confined implementation

    private func append(_ event: RemoteTmuxConnectionEvent, for host: RemoteTmuxHost) {
        guard let line = try? encoder.encode(event) else { return }
        let url = logFileURL(for: host)
        do {
            try ensureDirectory()
            rotateIfNeeded(url: url, rotatedURL: rotatedLogFileURL(for: host))
            let handle = try openForAppend(url)
            defer { try? handle.close() }
            try handle.write(contentsOf: line + Data("\n".utf8))
        } catch {
            // A full or read-only disk must never take the transport down;
            // the event is simply lost from the file.
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func openForAppend(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func rotateIfNeeded(url: URL, rotatedURL: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size >= Self.maxFileBytes else { return }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }

    private func readEntries(for host: RemoteTmuxHost, limit: Int) -> [RemoteTmuxConnectionEvent] {
        let limit = max(0, limit)
        guard limit > 0 else { return [] }
        var events = decodeEvents(at: logFileURL(for: host))
        if events.count < limit {
            let older = decodeEvents(at: rotatedLogFileURL(for: host))
            events = older + events
        }
        return Array(events.suffix(limit))
    }

    private func decodeEvents(at url: URL) -> [RemoteTmuxConnectionEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(RemoteTmuxConnectionEvent.self, from: line)
        }
    }

    private func scheduleMarkdownRender(for host: RemoteTmuxHost) {
        let key = Self.fileStem(for: host)
        guard pendingMarkdownRenders.insert(key).inserted else { return }
        queue.asyncAfter(deadline: .now() + markdownRenderDelay) { [self] in
            pendingMarkdownRenders.remove(key)
            renderMarkdownFile(for: host)
        }
    }

    private func renderMarkdownFile(for host: RemoteTmuxHost) {
        let events = readEntries(for: host, limit: Self.markdownEventLimit)
        let markdown = Self.renderMarkdown(
            host: host,
            events: events,
            logFilePath: logFileURL(for: host).path
        )
        let url = markdownFileURL(for: host)
        do {
            try ensureDirectory()
            // Atomic replace: the markdown panel re-renders on the rename and
            // never observes a half-written file.
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Best-effort mirror of the JSONL; the log itself is intact.
        }
    }

    // MARK: - Rendering

    /// The markdown view of the newest events (newest first) with a short
    /// current-state summary derived from them.
    static func renderMarkdown(
        host: RemoteTmuxHost,
        events: [RemoteTmuxConnectionEvent],
        logFilePath: String
    ) -> String {
        var lines: [String] = []
        lines.append("# " + String(
            format: String(localized: "remoteTmux.connectionLog.title", defaultValue: "Connection log: %@"),
            host.destination
        ))
        lines.append("")
        lines.append(String(
            format: String(localized: "remoteTmux.connectionLog.file", defaultValue: "Log file: `%@`"),
            logFilePath
        ))
        lines.append("")
        lines.append("## " + String(localized: "remoteTmux.connectionLog.state", defaultValue: "Current state"))
        lines.append("")
        for line in stateSummary(events: events) {
            lines.append("- " + line)
        }
        lines.append("")
        lines.append("## " + String(localized: "remoteTmux.connectionLog.events", defaultValue: "Events (newest first)"))
        lines.append("")
        let timeColumn = String(localized: "remoteTmux.connectionLog.column.time", defaultValue: "Time")
        let eventColumn = String(localized: "remoteTmux.connectionLog.column.event", defaultValue: "Event")
        let detailColumn = String(localized: "remoteTmux.connectionLog.column.detail", defaultValue: "Detail")
        lines.append("| \(timeColumn) | \(eventColumn) | \(detailColumn) |")
        lines.append("| --- | --- | --- |")
        let formatter = timestampFormatter()
        for event in events.reversed() {
            let marker = event.isFailure ? "⚠️ " : ""
            let generation = event.generation.map { " (gen \($0))" } ?? ""
            lines.append(
                "| \(formatter.string(from: event.time)) | \(marker)\(plainCell(event.message))\(generation) | \(codeCell(event.detail ?? "")) |"
            )
        }
        if events.isEmpty {
            lines.append("")
            lines.append(String(localized: "remoteTmux.connectionLog.empty", defaultValue: "No events recorded yet."))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func timestampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    /// Latest master, authentication, bridge and per-tunnel outcomes.
    static func stateSummary(events: [RemoteTmuxConnectionEvent]) -> [String] {
        var summary: [String] = []
        let formatter = timestampFormatter()
        if let master = events.last(where: {
            [.masterServing, .masterDead, .masterOpened, .disconnected].contains($0.knownKind)
        }) {
            summary.append(String(
                format: String(localized: "remoteTmux.connectionLog.state.master", defaultValue: "Master: %@ (%@)"),
                master.message,
                formatter.string(from: master.time)
            ))
        }
        if let auth = events.last(where: { [.reauthParked, .reauthCleared].contains($0.knownKind) }),
           auth.knownKind == .reauthParked {
            summary.append(String(
                format: String(localized: "remoteTmux.connectionLog.state.authParked", defaultValue: "Authentication: waiting for the terminal since %@"),
                formatter.string(from: auth.time)
            ))
        }
        if let bridge = events.last(where: { [.bridgeConfigured, .bridgeFailed].contains($0.knownKind) }) {
            summary.append(String(
                format: String(localized: "remoteTmux.connectionLog.state.bridge", defaultValue: "Agent bridge: %@ (%@)"),
                bridge.message,
                formatter.string(from: bridge.time)
            ))
        }
        // Tunnels: the latest outcome per forward (the detail carries the spec).
        var latestTunnelBySpec: [String: RemoteTmuxConnectionEvent] = [:]
        var specOrder: [String] = []
        for event in events where [.tunnelRestored, .tunnelFailed].contains(event.knownKind) {
            let spec = event.detail?.split(whereSeparator: \.isNewline).first.map(String.init) ?? event.message
            if latestTunnelBySpec[spec] == nil { specOrder.append(spec) }
            latestTunnelBySpec[spec] = event
        }
        for spec in specOrder {
            guard let event = latestTunnelBySpec[spec] else { continue }
            summary.append(String(
                format: String(localized: "remoteTmux.connectionLog.state.tunnel", defaultValue: "Tunnel %@: %@ (%@)"),
                spec,
                event.knownKind == .tunnelRestored
                    ? String(localized: "remoteTmux.connectionLog.state.tunnel.up", defaultValue: "established")
                    : String(localized: "remoteTmux.connectionLog.state.tunnel.down", defaultValue: "unavailable, retrying"),
                formatter.string(from: event.time)
            ))
        }
        if summary.isEmpty {
            summary.append(String(localized: "remoteTmux.connectionLog.state.none", defaultValue: "No connection observed yet."))
        }
        return summary
    }

    /// One table cell of prose: pipes escaped so the row cannot break.
    private static func plainCell(_ text: String) -> String {
        flattenedCellText(text).replacingOccurrences(of: "|", with: "\\|")
    }

    /// One table cell of diagnostic text (ssh stderr, a spec) as inline code.
    private static func codeCell(_ text: String) -> String {
        let flattened = flattenedCellText(text)
        guard !flattened.isEmpty else { return "" }
        return "`" + flattened.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "`", with: "'") + "`"
    }

    private static func flattenedCellText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
    }

    /// Flattens control/format/separator scalars (terminal escapes, NUL, CR)
    /// to spaces, optionally keeping newlines and tabs, and caps the length.
    static func sanitized(_ raw: String, maxCharacters: Int, preservingNewlines: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if preservingNewlines, scalar == "\n" || scalar == "\t" {
                scalars.append(scalar)
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)) + "…"
    }
}
