import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The multi-machine attach pipeline (`cmux ssh-tmux a b c`): probes run
/// concurrently, interactive authentications serialize in command order on
/// the terminal baton, and each machine's mirror overlaps the NEXT
/// machine's authentication — the wall-time collapse the sequential loop
/// could not deliver. Driven end-to-end through the real bundled CLI
/// against a mock control socket and a fake interactive ssh.
@Suite(.serialized)
struct CLIRemoteTmuxParallelAttachTests {
    private static let authSleepSeconds = 0.6
    private static let mirrorSleepSeconds = 0.8
    private static let windowId = "57ADFA00-0000-4000-8000-00000000CAFE"

    @Test func parallelAttachPipelinesAuthAndOverlapsMirrors() throws {
        let socketPath = Self.makeSocketPath("par-attach")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let authLog = Self.makeTempFilePath("auth-log")
        defer { unlink(authLog) }
        let shim = try Self.writeAuthShim(logPath: authLog, sleepSeconds: Self.authSleepSeconds)
        defer { unlink(shim) }

        let timeline = TimelineState()
        Self.startDetachedServer(listenerFD: listenerFD, timeline: timeline, shim: shim) { method, host, id, params in
            switch method {
            case "remote.tmux.probe":
                guard let host else {
                    return Self.v2Response(
                        id: id, ok: false,
                        error: ["code": "invalid_params", "message": "host is required"]
                    )
                }
                timeline.record(kind: "probe", host: host)
                return Self.v2Response(id: id, ok: true, result: [
                    "host": host,
                    "auth_required": true,
                    "ssh_argv": [shim, "-o", "BatchMode=no", "--", host, "true"],
                ])
            case "remote.tmux.window", "remote.tmux.mirror":
                guard let host else {
                    return Self.v2Response(
                        id: id, ok: false,
                        error: ["code": "invalid_params", "message": "host is required"]
                    )
                }
                timeline.record(
                    kind: "mirror", host: host,
                    windowParam: params["window_id"] as? String
                )
                Thread.sleep(forTimeInterval: Self.mirrorSleepSeconds)
                return Self.v2Response(id: id, ok: true, result: [
                    "mirrored": true,
                    "host": host,
                    "window_id": Self.windowId,
                    "workspace_ids": ["ws-\(host)"],
                ])
            default:
                return Self.v2Response(
                    id: id, ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        let started = Date()
        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: ["ssh-tmux", "hostA", "hostB", "hostC", "--new-window"],
            environment: Self.cliEnvironment(socketPath: socketPath, shim: shim, authLog: authLog),
            timeout: 30
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))

        // Completion lines stay in command order (mirrors are order-batoned).
        let okLines = result.stdout.split(separator: "\n").filter { $0.hasPrefix("OK host=") }
        #expect(okLines.count == 3, Comment(rawValue: result.stdout))
        #expect(okLines.map { String($0.split(separator: " ")[1]) }
            == ["host=hostA", "host=hostB", "host=hostC"])

        // Probes fired concurrently: every probe arrived before the FIRST
        // authentication finished (a sequential loop cannot do that — its
        // second probe waits for the first machine's whole attach).
        let probes = timeline.events(kind: "probe")
        let auths = try Self.parseAuthLog(at: authLog)
        #expect(probes.count == 3)
        #expect(auths.count == 3, Comment(rawValue: "auth log: \(auths)"))
        let firstAuthEnd = try #require(auths.first?.end)
        for probe in probes {
            #expect(probe.time < firstAuthEnd, Comment(rawValue: "probe \(probe.host) after first auth end"))
        }

        // Authentications never overlap and run in command order: the
        // terminal and the security key belong to one machine at a time.
        #expect(auths.map(\.host) == ["hostA", "hostB", "hostC"])
        for (earlier, later) in zip(auths, auths.dropFirst()) {
            #expect(earlier.end <= later.start + 0.05, Comment(rawValue: "auth overlap: \(earlier) vs \(later)"))
        }

        // The pipeline overlap itself: hostA's mirror reached the server
        // while hostB's authentication was still running.
        let mirrors = timeline.events(kind: "mirror")
        #expect(mirrors.map(\.host) == ["hostA", "hostB", "hostC"])
        let mirrorA = try #require(mirrors.first)
        let authB = try #require(auths.dropFirst().first)
        #expect(
            mirrorA.time < authB.end,
            Comment(rawValue: "hostA mirror (\(mirrorA.time)) did not overlap hostB auth (ends \(authB.end))")
        )
        // The wall-time win, checked RELATIVELY (an absolute bound flaked
        // under CI load): each later machine's authentication began before
        // the previous machine's mirror (0.8s in this mock) could have
        // completed, which a sequential loop cannot do. It mirrors, then
        // authenticates the next machine.
        for (earlierMirror, laterAuth) in zip(mirrors, auths.dropFirst()) {
            #expect(
                laterAuth.start < earlierMirror.time + Self.mirrorSleepSeconds,
                Comment(rawValue: "\(laterAuth.host) auth started \(laterAuth.start - earlierMirror.time)s after \(earlierMirror.host) mirror (elapsed \(elapsed)s)")
            )
        }

        // Followers joined the window the first machine created.
        #expect(mirrors[0].windowParam == nil)
        #expect(mirrors[1].windowParam == Self.windowId)
        #expect(mirrors[2].windowParam == Self.windowId)
    }

    @Test func parallelAttachSurvivesOneUnreachableMachine() throws {
        let socketPath = Self.makeSocketPath("par-fail")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let timeline = TimelineState()
        Self.startDetachedServer(listenerFD: listenerFD, timeline: timeline, shim: nil) { method, host, id, params in
            switch method {
            case "remote.tmux.probe":
                guard let host else {
                    return Self.v2Response(
                        id: id, ok: false,
                        error: ["code": "invalid_params", "message": "host is required"]
                    )
                }
                if host == "hostB" {
                    return Self.v2Response(
                        id: id, ok: false,
                        error: ["code": "unreachable", "message": "ssh: connect to host hostB port 22: Operation timed out"]
                    )
                }
                return Self.v2Response(id: id, ok: true, result: ["host": host, "ready": true])
            case "remote.tmux.window", "remote.tmux.mirror":
                guard let host else {
                    return Self.v2Response(
                        id: id, ok: false,
                        error: ["code": "invalid_params", "message": "host is required"]
                    )
                }
                timeline.record(kind: "mirror", host: host, windowParam: params["window_id"] as? String)
                return Self.v2Response(id: id, ok: true, result: [
                    "mirrored": true,
                    "host": host,
                    "window_id": Self.windowId,
                    "workspace_ids": ["ws-\(host)"],
                ])
            default:
                return Self.v2Response(
                    id: id, ok: false,
                    error: ["code": "unexpected_method", "message": method]
                )
            }
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: ["ssh-tmux", "hostA", "hostB", "hostC", "--new-window"],
            environment: Self.cliEnvironment(socketPath: socketPath, shim: nil, authLog: nil),
            timeout: 30
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        // Partial success exits zero; the failure is reported per host.
        #expect(result.status == 0, Comment(rawValue: result.stderr + result.stdout))
        #expect(result.stdout.contains("OK host=hostA"))
        #expect(result.stdout.contains("OK host=hostC"))
        #expect(!result.stdout.contains("OK host=hostB"))
        #expect(result.stderr.contains("FAILED host=hostB"))
        #expect(result.stdout.contains("Attached 2 of 3 machines; failed: hostB"))
        // The healthy machines still landed in one window, in order.
        let mirrors = timeline.events(kind: "mirror")
        #expect(mirrors.map(\.host) == ["hostA", "hostC"])
        #expect(mirrors[1].windowParam == Self.windowId)
    }

    @Test func verboseFailureShowsTheFullSSHOutputAndPointsAtTheLog() throws {
        // The app caps the one-line error message but ships the whole ssh
        // stderr in the error's `data.detail`; `--verbose` prints it under the
        // FAILED line, `--json` carries it, and every failure points at
        // `cmux ssh-tmux-log <host>`.
        let sshOutput = "mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 9998\nmuxclient: master forward request failed\nConnection closed by UNKNOWN port 65535"
        func serve(_ socketPath: String, listenerFD: Int32) {
            Self.startDetachedServer(listenerFD: listenerFD, timeline: TimelineState(), shim: nil) { method, host, id, params in
                switch method {
                case "remote.tmux.probe":
                    guard let host else {
                        return Self.v2Response(id: id, ok: false, error: ["code": "invalid_params", "message": "host is required"])
                    }
                    if host == "hostB" {
                        return Self.v2Response(id: id, ok: false, error: [
                            "code": "vm_error",
                            "message": "remote command failed (exit 255): mux_client_forward: forwarding request failed…",
                            "data": ["kind": "command_failed", "exit_code": 255, "detail": sshOutput],
                        ])
                    }
                    return Self.v2Response(id: id, ok: true, result: ["host": host, "ready": true])
                case "remote.tmux.window", "remote.tmux.mirror":
                    return Self.v2Response(id: id, ok: true, result: [
                        "mirrored": true, "host": host ?? "", "window_id": Self.windowId, "workspace_ids": ["ws"],
                    ])
                default:
                    return Self.v2Response(id: id, ok: false, error: ["code": "unexpected_method", "message": method])
                }
            }
        }

        for (mode, arguments) in [
            ("verbose", ["ssh-tmux", "hostA", "hostB", "--new-window", "--verbose"]),
            ("plain", ["ssh-tmux", "hostA", "hostB", "--new-window"]),
            ("json", ["--json", "ssh-tmux", "hostA", "hostB", "--new-window"]),
        ] {
            let socketPath = Self.makeSocketPath("verbose-\(mode)")
            let listenerFD = try Self.bindUnixSocket(at: socketPath)
            defer {
                CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
                Darwin.close(listenerFD)
                unlink(socketPath)
            }
            serve(socketPath, listenerFD: listenerFD)
            let result = Self.runProcess(
                executablePath: try Self.bundledCLIPath(),
                arguments: arguments,
                environment: Self.cliEnvironment(socketPath: socketPath, shim: nil, authLog: nil),
                timeout: 30
            )
            let comment = Comment(rawValue: "\(mode)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
            #expect(!result.timedOut, comment)
            #expect(result.status == 0, comment)
            switch mode {
            case "verbose":
                #expect(result.stderr.contains("FAILED host=hostB: remote command failed (exit 255)"), comment)
                #expect(result.stderr.contains("  ssh output:\n    mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 9998\n    muxclient: master forward request failed\n    Connection closed by UNKNOWN port 65535"), comment)
                #expect(result.stdout.contains("Details: cmux ssh-tmux-log hostB"), comment)
                #expect(!result.stdout.contains("rerun with --verbose"), comment)
            case "plain":
                #expect(result.stderr.contains("FAILED host=hostB: remote command failed (exit 255)"), comment)
                #expect(!result.stderr.contains("ssh output:"), comment)
                #expect(result.stdout.contains("Details: cmux ssh-tmux-log hostB  (or rerun with --verbose for the full ssh output)"), comment)
            default:
                let payload = try #require(Self.jsonObject(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), comment)
                let failed = try #require(payload["failed_hosts"] as? [[String: Any]], comment)
                #expect(failed.count == 1)
                #expect(failed.first?["host"] as? String == "hostB")
                #expect(failed.first?["detail"] as? String == sshOutput)
                #expect(failed.first?["exit_code"] as? Int == 255)
            }
        }
    }

    @Test func sshTmuxLogPrintsTheMachinesConnectionLog() throws {
        let socketPath = Self.makeSocketPath("conn-log")
        let listenerFD = try Self.bindUnixSocket(at: socketPath)
        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        let seenParams = TimelineState()
        Self.startDetachedServer(listenerFD: listenerFD, timeline: seenParams, shim: nil) { method, host, id, params in
            guard method == "remote.tmux.connection_log", let host else {
                return Self.v2Response(id: id, ok: false, error: ["code": "unexpected_method", "message": method])
            }
            seenParams.record(kind: "limit", host: "\(params["limit"] ?? "nil")")
            seenParams.record(kind: "port", host: "\(params["port"] ?? "nil")")
            return Self.v2Response(id: id, ok: true, result: [
                "host": host,
                "path": "/Users/me/.cmux/remote-tmux/logs/xxl-abc.jsonl",
                "markdown_path": "/Users/me/.cmux/remote-tmux/logs/xxl-abc.md",
                "tunnels": [
                    "generation": 2,
                    "established": ["L 3000:127.0.0.1:3000"],
                    "failed": [["spec": "R 9998:localhost:9998", "reason": "remote port forwarding failed for listen port 9998"]],
                ],
                "entries": [
                    ["time": "2026-09-05T16:32:50.000Z", "kind": "master.serving", "message": "master serving (generation 2)", "failure": false, "generation": 2],
                    ["time": "2026-09-05T16:33:10.000Z", "kind": "tunnel.failed", "message": "tunnel R 9998:localhost:9998 unavailable: remote port forwarding failed for listen port 9998; retrying", "failure": true, "generation": 2,
                     "detail": "R 9998:localhost:9998\nmux_client_forward: forwarding request failed: remote port forwarding failed for listen port 9998"],
                ],
            ])
        }

        let result = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: ["ssh-tmux-log", "xxl", "--limit", "5", "--port", "2222"],
            environment: Self.cliEnvironment(socketPath: socketPath, shim: nil, authLog: nil),
            timeout: 30
        )
        let comment = Comment(rawValue: "stdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        #expect(!result.timedOut, comment)
        #expect(result.status == 0, comment)
        #expect(seenParams.events(kind: "limit").first?.host == "5")
        #expect(seenParams.events(kind: "port").first?.host == "2222")
        #expect(result.stdout.contains("Connection log for xxl (/Users/me/.cmux/remote-tmux/logs/xxl-abc.jsonl)"), comment)
        #expect(result.stdout.contains("Tunnels up: L 3000:127.0.0.1:3000"), comment)
        #expect(result.stdout.contains("Tunnel DOWN: R 9998:localhost:9998 (remote port forwarding failed for listen port 9998; cmux is retrying)"), comment)
        // Timestamps are rendered in the user's local time zone.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let servingStamp = local.string(from: try #require(iso.date(from: "2026-09-05T16:32:50.000Z")))
        let tunnelStamp = local.string(from: try #require(iso.date(from: "2026-09-05T16:33:10.000Z")))
        #expect(result.stdout.contains("\(servingStamp)   master serving (generation 2) (gen 2)"), comment)
        #expect(result.stdout.contains("\(tunnelStamp) ! tunnel R 9998:localhost:9998 unavailable"), comment)
        #expect(result.stdout.contains("                       mux_client_forward: forwarding request failed"), comment)

        // --json passes the payload through untouched.
        let json = Self.runProcess(
            executablePath: try Self.bundledCLIPath(),
            arguments: ["ssh-tmux-log", "xxl", "--json"],
            environment: Self.cliEnvironment(socketPath: socketPath, shim: nil, authLog: nil),
            timeout: 30
        )
        let payload = try #require(Self.jsonObject(json.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect((payload["entries"] as? [[String: Any]])?.count == 2)
        #expect(payload["host"] as? String == "xxl")
    }

    // MARK: - Mock server plumbing

    private struct TimelineEvent {
        let kind: String
        let host: String
        let time: TimeInterval
        let windowParam: String?
    }

    private final class TimelineState: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [TimelineEvent] = []

        func record(kind: String, host: String, windowParam: String? = nil) {
            lock.lock()
            recorded.append(TimelineEvent(
                kind: kind, host: host,
                time: Date().timeIntervalSince1970,
                windowParam: windowParam
            ))
            lock.unlock()
        }

        func events(kind: String) -> [TimelineEvent] {
            lock.lock()
            defer { lock.unlock() }
            return recorded.filter { $0.kind == kind }.sorted { $0.time < $1.time }
        }
    }

    /// Serves every connection the parallel workers open. The handler gets
    /// (method, host param, request id, params) and returns the JSON line.
    private static func startDetachedServer(
        listenerFD: Int32,
        timeline: TimelineState,
        shim: String?,
        handler: @escaping @Sendable (String, String?, String, [String: Any]) -> String
    ) {
        CLIMockAcceptLoopRegistry.shared.start(listenerFD: listenerFD, onConnection: { clientFD in
            defer { Darwin.close(clientFD) }
            cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                guard let payload = Self.jsonObject(line),
                      let id = payload["id"] as? String,
                      let method = payload["method"] as? String else {
                    return Self.v2Response(
                        id: "unknown", ok: false,
                        error: ["code": "malformed_request", "message": line]
                    )
                }
                let params = (payload["params"] as? [String: Any]) ?? [:]
                let host = (params["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return handler(method, host, id, params)
            }
        }, onListenerClosed: {})
    }

    /// The fake interactive ssh: logs `start <host> <t>` / `end <host> <t>`
    /// with sub-second timestamps and sleeps like a security-key touch.
    private static func writeAuthShim(logPath: String, sleepSeconds: Double) throws -> String {
        let path = makeTempFilePath("fake-auth-ssh")
        let script = """
        #!/bin/bash
        args=("$@")
        host=""
        for ((i = 0; i < ${#args[@]}; i++)); do
            if [[ "${args[$i]}" == "--" ]]; then
                host="${args[$((i + 1))]}"
                break
            fi
        done
        now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
        echo "start $host $(now)" >> "\(logPath)"
        sleep \(sleepSeconds)
        echo "end $host $(now)" >> "\(logPath)"
        exit 0
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private struct AuthSpan {
        let host: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private static func parseAuthLog(at path: String) throws -> [AuthSpan] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var starts: [String: TimeInterval] = [:]
        var spans: [AuthSpan] = []
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, let time = Double(parts[2]) else { continue }
            let host = String(parts[1])
            if parts[0] == "start" {
                starts[host] = time
            } else if parts[0] == "end", let start = starts[host] {
                spans.append(AuthSpan(host: host, start: start, end: time))
            }
        }
        return spans.sorted { $0.start < $1.start }
    }

    // MARK: - Process plumbing

    private static func cliEnvironment(
        socketPath: String, shim: String?, authLog: String?
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        // The pipeline authenticates through the DEBUG fake-ssh seam; the
        // non-tty seam lets the piped-stdio test process reach it.
        if let shim { environment["CMUX_REMOTE_TMUX_SSH_FOR_TESTING"] = shim }
        environment["CMUX_REMOTE_TMUX_ALLOW_NON_TTY_AUTH_FOR_TESTING"] = "1"
        if let authLog { environment["CMUX_TEST_AUTH_LOG"] = authLog }
        environment.removeValue(forKey: "CMUX_SURFACE_ID")
        environment.removeValue(forKey: "CMUX_WINDOW_ID")
        environment.removeValue(forKey: "CMUX_WORKSPACE_ID")
        environment.removeValue(forKey: "CMUX_SOCKET_PASSWORD")
        return environment
    }

    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutData = LockedData()
        let stderrData = LockedData()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutData.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrData.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        return ProcessRunResult(
            status: timedOut ? -1 : process.terminationStatus,
            stdout: stdoutData.string(),
            stderr: stderrData.string(),
            timedOut: timedOut
        )
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func string() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: - Socket plumbing

    private final class CLIRemoteTmuxParallelAttachBundleToken {}

    private static func bundledCLIPath() throws -> String {
        try BundledCLITestSupport.bundledCLIPath(for: CLIRemoteTmuxParallelAttachBundleToken.self)
    }

    private static func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "/tmp/cli-\(name.prefix(10))-\(shortID).sock"
    }

    private static func makeTempFilePath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(shortID)")
            .path
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8)
        guard utf8.count < maxPathLength else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG))
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Backlog sized for the whole fleet connecting at once — the
        // parallel workers each open their own control connection.
        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return fd
    }

    private static func v2Response(
        id: String,
        ok: Bool,
        result: [String: Any]? = nil,
        error: [String: Any]? = nil
    ) -> String {
        var payload: [String: Any] = ["id": id, "ok": ok]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        return String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }
}
