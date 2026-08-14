import Darwin
import Foundation
import Testing
@testable import cmux_DEV

/// The forwarded-agent stable link: the refresh snippet cmux injects in
/// front of remote commands, the wrap that carries it on the control
/// client, and the post-attach tmux env pin. Together they keep `SSO auth` /
/// `ssh-add` working inside mirrored panes across master generations
/// (reconnects, app restarts, `cmux ssh-tmux` reruns) — forwarded agent
/// sockets are per SSH connection, but pane environments live forever.
@Suite struct RemoteTmuxAgentLinkTests {
    private let host = RemoteTmuxHost(destination: "user@example.test")

    // MARK: - Snippet shape (the silence/exit-0 contract)

    @Test func refreshScriptIsSingleSilentLine() {
        let script = RemoteTmuxHost.agentLinkRefreshScript(connectionHash: host.connectionHash)
        // One physical line: CR/LF would terminate the ssh remote command or
        // a control-mode line early.
        #expect(!script.contains("\n"))
        #expect(!script.contains("\r"))
        // Silent: stray ln/mkdir output on stderr would trip
        // `indicatesAuthRequired`, stdout would feed session-gone
        // classification on reconnect.
        #expect(script.contains(">/dev/null 2>&1"))
        // Guarded: no live socket in `SSH_AUTH_SOCK` means no writes at all.
        #expect(script.contains("[ -S \"$SSH_AUTH_SOCK\" ]"))
        // Keyed by the endpoint identity, same granularity as the master.
        #expect(script.contains("cmux-agent-\(host.connectionHash).sock"))
        // The `if` form (not `&&`-chaining into the payload) keeps exit 0.
        #expect(script.hasSuffix("fi"))
        // No single quotes: the snippet must survive single-quote wrapping.
        #expect(!script.contains("'"))
    }

    // MARK: - Snippet behavior (executed, sandbox HOME)

    @Test func refreshScriptCreatesAndRetargetsLink() throws {
        let root = try temporaryDirectory(prefix: "agent-link")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let socketA = try makeUnixSocket(shortName: "a")
        defer { close(socketA.fd); unlink(socketA.path) }
        let script = RemoteTmuxHost.agentLinkRefreshScript(connectionHash: host.connectionHash)
        let linkPath = home.appendingPathComponent(
            RemoteTmuxHost.agentLinkRelativePath(connectionHash: host.connectionHash)
        ).path

        // Live socket: link created, silent, exit 0.
        let created = try runShell(
            script,
            environment: ["HOME": home.path, "SSH_AUTH_SOCK": socketA.path]
        )
        #expect(created.status == 0)
        #expect(created.stdout.isEmpty)
        #expect(created.stderr.isEmpty)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkPath) == socketA.path
        )

        // A NEW master generation (different socket): link retargeted.
        let socketB = try makeUnixSocket(shortName: "b")
        defer { close(socketB.fd); unlink(socketB.path) }
        let retargeted = try runShell(
            script,
            environment: ["HOME": home.path, "SSH_AUTH_SOCK": socketB.path]
        )
        #expect(retargeted.status == 0)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkPath) == socketB.path
        )
    }

    @Test func refreshScriptDoesNothingWithoutLiveAgentSocket() throws {
        let root = try temporaryDirectory(prefix: "agent-link-noop")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let script = RemoteTmuxHost.agentLinkRefreshScript(connectionHash: host.connectionHash)

        // Unset SSH_AUTH_SOCK: silent no-op, exit 0, nothing created.
        let unset = try runShell(script, environment: ["HOME": home.path])
        #expect(unset.status == 0)
        #expect(unset.stdout.isEmpty && unset.stderr.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".ssh").path))

        // A regular file is not an agent socket: same no-op.
        let regular = root.appendingPathComponent("not-a-socket")
        try Data().write(to: regular)
        let notSocket = try runShell(
            script,
            environment: ["HOME": home.path, "SSH_AUTH_SOCK": regular.path]
        )
        #expect(notSocket.status == 0)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".ssh").path))
    }

    // MARK: - Control client wrap (prefix transparency)

    @Test func wrappedControlCommandStillRunsResolverAndRefreshesLink() throws {
        let root = try temporaryDirectory(prefix: "agent-link-wrap")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let emptyPath = root.appendingPathComponent("empty-path", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyPath, withIntermediateDirectories: true)
        try writeExecutable(
            at: bin.appendingPathComponent("tmux"),
            contents: """
            #!/bin/sh
            printf 'fake-tmux'
            for arg in "$@"; do printf ' <%s>' "$arg"; done
            printf '\\n'
            """
        )
        let agentSocket = try makeUnixSocket(shortName: "wrap")
        defer { close(agentSocket.fd); unlink(agentSocket.path) }

        let args = host.controlModeArguments(sessionName: "work session", createIfMissing: false)
        let dashDash = try #require(args.firstIndex(of: "--"))
        let command = args[dashDash + 2]
        let result = try runShell(
            command,
            environment: [
                "HOME": home.path,
                "PATH": emptyPath.path,
                "SSH_AUTH_SOCK": agentSocket.path,
            ]
        )

        // The wrap is transparent: identical resolver behavior and stdout…
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "fake-tmux <-CC> <attach-session> <-t> <work session>\n")
        // …and the side effect happened: the stable link now names the live
        // socket of THIS (fake) connection.
        let linkPath = home.appendingPathComponent(
            RemoteTmuxHost.agentLinkRelativePath(connectionHash: host.connectionHash)
        ).path
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkPath) == agentSocket.path
        )
    }

    // MARK: - Env pin builder

    @Test func agentEnvPinCommandShapeAndValidation() {
        let hash = host.connectionHash
        let link = "/home/user/.ssh/cmux-agent-\(hash).sock"
        #expect(
            RemoteTmuxHost.agentEnvPinCommand(home: "/home/user", connectionHash: hash)
                == "if-shell -b 'test -S \"\(link)\"' "
                + "'set-environment -g SSH_AUTH_SOCK \"\(link)\" ; "
                + "set-environment SSH_AUTH_SOCK \"\(link)\"'"
        )
        // Trailing slash is normalized, not doubled.
        #expect(
            RemoteTmuxHost.agentEnvPinCommand(home: "/home/user/", connectionHash: hash)?
                .contains("/home/user/.ssh/") == true
        )
        // Homes that cannot be embedded safely skip the pin entirely.
        #expect(RemoteTmuxHost.agentEnvPinCommand(home: "relative/home", connectionHash: hash) == nil)
        #expect(RemoteTmuxHost.agentEnvPinCommand(home: "/ho'me", connectionHash: hash) == nil)
        #expect(RemoteTmuxHost.agentEnvPinCommand(home: "/ho\"me", connectionHash: hash) == nil)
        #expect(RemoteTmuxHost.agentEnvPinCommand(home: "/ho\nme", connectionHash: hash) == nil)
        #expect(RemoteTmuxHost.agentEnvPinCommand(home: "", connectionHash: hash) == nil)
    }

    @Test func validatedRemoteHomeAcceptsTypicalHomes() {
        #expect(RemoteTmuxHost.validatedRemoteHome("/usr/local/home/somedev")
            == "/usr/local/home/somedev")
        #expect(RemoteTmuxHost.validatedRemoteHome("/home/user\n") == "/home/user")
        #expect(RemoteTmuxHost.validatedRemoteHome("/") == "/")
        #expect(RemoteTmuxHost.validatedRemoteHome("home") == nil)
    }

    // MARK: - Attach-drain pin (fires on every attach, before list-windows)

    @Test @MainActor func attachDrainSendsAgentEnvPinBeforeWindowRequest() {
        let connection = RemoteTmuxControlConnection(
            host: host, sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-agent-pin-test",
            maxPendingBytes: 4096,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        defer {
            writer.close()
            try? pipe.fileHandleForReading.close()
        }
        let pin = RemoteTmuxHost.agentEnvPinCommand(
            home: "/home/user", connectionHash: host.connectionHash
        )
        connection.agentEnvPinCommandProvider = { pin }

        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(.commandResult(commandNumber: 1, lines: [], isError: false))

        // FIFO order: the pin's `.other` slot precedes the initial
        // list-windows, so `update-environment`'s raw value never outlives
        // the drain.
        #expect(connection.pendingCommandKindsForTesting == [
            .other,
            .listWindows(reorderGeneration: 0, retainedPaneIDs: []),
        ])
    }

    @Test @MainActor func attachDrainSkipsPinWhenProviderDeclines() {
        let connection = RemoteTmuxControlConnection(
            host: host, sessionName: "work"
        )
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-agent-pin-skip-test",
            maxPendingBytes: 4096,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        defer {
            writer.close()
            try? pipe.fileHandleForReading.close()
        }
        connection.agentEnvPinCommandProvider = { nil }

        connection.handleMessageForTesting(.enter)
        connection.handleMessageForTesting(.commandResult(commandNumber: 1, lines: [], isError: false))

        #expect(connection.pendingCommandKindsForTesting == [
            .listWindows(reorderGeneration: 0, retainedPaneIDs: [])
        ])
    }

    // MARK: - Helpers

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Binds a real AF_UNIX listener so `[ -S path ]` is true, like a live
    /// forwarded-agent socket. Bound under `/tmp` directly: the deep
    /// `NSTemporaryDirectory()` prefix overflows the 104-byte `sun_path`.
    private func makeUnixSocket(shortName: String) throws -> (fd: Int32, path: String) {
        let path = "/tmp/cmux-alt-\(getpid())-\(shortName).sock"
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        try #require(path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
        }
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bindResult == 0)
        try #require(listen(fd, 1) == 0)
        return (fd, path)
    }

    private func runShell(
        _ command: String,
        environment: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
    }
}
