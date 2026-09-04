import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The shared SSH master is the ONLY remote-tmux ssh that may carry the user's
/// `~/.ssh/config` port forwards (`RemoteForward`, `LocalForward`,
/// `DynamicForward`). Mux-only clients and the `-O` master control commands
/// must leave them alone.
///
/// The regression this pins: a whole fleet failed at once with
/// `mux_client_forward: forwarding request failed: remote port forwarding
/// failed for listen port 9998`. OpenSSH's `-O forward` / `-O cancel` act on
/// EVERY forward the config declares for the host, not only the `-R` on the
/// command line, so the agent bridge's `-O cancel` dropped the user's
/// `RemoteForward` from the master. Every later mux client (which inherits
/// the same config) re-requested it through the master; while anything else
/// held the remote port (the previous master generation's server-side
/// session, kept alive by a relay until sshd's ClientAlive reaped it) sshd
/// refused, the client fell back to its severed direct connection, and the
/// host went dark instead of one tunnel being unavailable. On top of that,
/// OpenSSH silences a ProxyCommand's stderr whenever `ControlPath` and
/// `ControlPersist` are both in effect, so the fail-fast sentinel the fallback
/// prints never reached cmux and the failure surfaced as an opaque
/// `Connection closed by UNKNOWN port 65535`.
///
/// Every test here runs the REAL OpenSSH client and never touches the network:
/// a `-F` config that declares forwards (and `ControlPersist yes`) for every
/// host stands in for the user's `~/.ssh/config`, `ssh -G` prints the
/// configuration ssh would act on, and the dead-master case dies at the
/// severed ProxyCommand.
@Suite struct RemoteTmuxConfigForwardIsolationTests {
    private static let sshExecutablePath = "/usr/bin/ssh"

    // MARK: - Mux-only clients

    @Test func oneShotClientCarriesNoConfigForwards() async throws {
        let lab = try Lab()
        defer { lab.cleanUp() }
        // The argv the transport really spawns for a one-shot command.
        let transport = RemoteTmuxSSHTransport(
            host: lab.host,
            sshExecutablePath: lab.recorder.executablePath
        )
        let result = try await transport.run(["true"])
        #expect(result.succeeded)
        let argv = try #require(lab.recorder.invocations().first)
        #expect(argv.contains("ControlMaster=no"))

        let effective = try lab.effectiveConfig(argv)
        expectNoPortForwards(effective, argv: argv)
        #expect(Self.settings("controlpersist", in: effective) == ["controlpersist no"])
        // Agent forwarding is a per-session request, not a port forward: the
        // config's ForwardAgent must survive (the forwarded-agent link rides it).
        #expect(Self.settings("forwardagent", in: effective) == ["forwardagent yes"])
    }

    @Test func controlStreamClientCarriesNoConfigForwards() throws {
        let lab = try Lab()
        defer { lab.cleanUp() }
        let argv = lab.host.controlModeArguments(sessionName: "work", createIfMissing: false)
        let effective = try lab.effectiveConfig(argv)
        expectNoPortForwards(effective, argv: argv)
        #expect(Self.settings("controlpersist", in: effective) == ["controlpersist no"])
        #expect(Self.settings("forwardagent", in: effective) == ["forwardagent yes"])
    }

    @Test func openerKeepsConfigForwardsForTheMaster() throws {
        // The master is the one connection that carries the user's tunnels,
        // whether the terminal opens it (interactive) or the app does (batch).
        let lab = try Lab()
        defer { lab.cleanUp() }
        let interactive = Array(
            lab.host.interactiveAuthInvocation(sshExecutablePath: Self.sshExecutablePath).dropFirst()
        )
        let batch = lab.host.sshControlArguments(
            controlPersistSeconds: RemoteTmuxHost.masterControlPersistIndefinitely,
            batchMode: true,
            role: .opener
        ) + ["--", lab.host.destination, "true"]
        for argv in [interactive, batch] {
            let effective = try lab.effectiveConfig(argv)
            let comment = Comment(rawValue: argv.joined(separator: " "))
            #expect(Self.settings("remoteforward", in: effective).first?.hasPrefix("remoteforward 9998 ") == true, comment)
            #expect(Self.settings("localforward", in: effective).first?.hasPrefix("localforward 3000 ") == true, comment)
            #expect(Self.settings("dynamicforward", in: effective).first?.hasPrefix("dynamicforward 1080") == true, comment)
        }
    }

    // MARK: - Master control commands

    @Test func masterControlCommandsTouchOnlyTheirOwnForward() async throws {
        let lab = try Lab()
        defer { lab.cleanUp() }
        let transport = RemoteTmuxSSHTransport(
            host: lab.host,
            sshExecutablePath: lab.recorder.executablePath
        )
        let remoteSocket = "/tmp/cmux-agent-isolation.sock"
        let localSocket = "/tmp/cmux-local-isolation.sock"
        // `-O check` (the recorder reports the master serving, so no opener
        // runs), then the agent bridge's `-O forward` / `-O cancel`, then the
        // deliberate `-O exit`.
        let ready = try await transport.ensureMasterReady()
        #expect(ready)
        let registered = try await transport.requestReverseUnixForward(
            remoteSocketPath: remoteSocket,
            localSocketPath: localSocket
        )
        #expect(registered)
        await transport.cancelReverseUnixForward(
            remoteSocketPath: remoteSocket,
            localSocketPath: localSocket
        )
        await transport.shutdownMaster()

        let invocations = lab.recorder.invocations()
        #expect(
            invocations.map { Array($0.prefix(2)) }
                == [["-O", "check"], ["-O", "forward"], ["-O", "cancel"], ["-O", "exit"]]
        )
        for argv in invocations {
            let effective = try lab.effectiveConfig(argv)
            let comment = Comment(rawValue: argv.joined(separator: " "))
            let remoteForwards = Self.settings("remoteforward", in: effective)
            let command = argv.count > 1 ? argv[1] : ""
            if command == "forward" || command == "cancel" {
                // Exactly the bridge's own forward: never the config's.
                #expect(remoteForwards == ["remoteforward \(remoteSocket) \(localSocket)"], comment)
            } else {
                #expect(remoteForwards == [], comment)
            }
            #expect(Self.settings("localforward", in: effective) == [], comment)
            #expect(Self.settings("dynamicforward", in: effective) == [], comment)
        }
    }

    // MARK: - Dead master

    @Test func deadMasterClientFailsFastWithVisibleSentinel() throws {
        // The user's config sets ControlPersist, and OpenSSH redirects a
        // ProxyCommand's stderr to /dev/null whenever ControlPath and
        // ControlPersist are both in effect. The mux-only client must keep the
        // sentinel visible or a dead master is indistinguishable from a
        // dropped relay.
        let lab = try Lab()
        defer { lab.cleanUp() }
        let oneShot = lab.host.sshControlArguments(
            controlPersistSeconds: RemoteTmuxHost.masterControlPersistIndefinitely,
            batchMode: true,
            role: .client
        ) + ["--", lab.host.destination, "true"]
        let controlStream = lab.host.controlModeArguments(sessionName: "work", createIfMissing: false)
        for argv in [oneShot, controlStream] {
            let run = try lab.runWithConfig(argv)
            let comment = Comment(rawValue: "argv: \(argv.joined(separator: " "))\nstderr: \(run.stderr)")
            #expect(run.status == 255, comment)
            #expect(RemoteTmuxSSHTransport.indicatesMasterUnavailable(run.stderr), comment)
        }
    }

    // MARK: - Helpers

    private func expectNoPortForwards(_ effective: [String], argv: [String]) {
        let comment = Comment(rawValue: argv.joined(separator: " "))
        #expect(Self.settings("remoteforward", in: effective) == [], comment)
        #expect(Self.settings("localforward", in: effective) == [], comment)
        #expect(Self.settings("dynamicforward", in: effective) == [], comment)
    }

    /// The `ssh -G` lines for one option (`key` alone or `key value…`).
    private static func settings(_ key: String, in effective: [String]) -> [String] {
        effective.filter { $0 == key || $0.hasPrefix(key + " ") }
    }

    /// A stand-in for the user's `~/.ssh/config` (tunnels and ControlPersist
    /// for every host), a unique endpoint whose control socket cannot exist,
    /// and an ssh that records the argv it is spawned with.
    private struct Lab {
        let root: URL
        let configPath: String
        let host: RemoteTmuxHost
        let recorder: RecordingSSH

        init() throws {
            try #require(FileManager.default.isExecutableFile(
                atPath: RemoteTmuxConfigForwardIsolationTests.sshExecutablePath
            ))
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("remote-tmux-forward-isolation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let config = """
            Host *
              HostName 127.0.0.1
              ControlPersist yes
              ForwardAgent yes
              RemoteForward 9998 localhost:9998
              LocalForward 3000 127.0.0.1:3000
              DynamicForward 1080

            """
            let configURL = root.appendingPathComponent("ssh_config")
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            configPath = configURL.path
            host = RemoteTmuxHost(
                destination: "forward-isolation-" + UUID().uuidString.lowercased().prefix(8)
            )
            recorder = try RecordingSSH(root: root)
        }

        /// The configuration the real ssh would act on for `argv`, with the
        /// stand-in user config in effect first (a later `-F` in `argv` wins,
        /// exactly as an explicit `-F` beats `~/.ssh/config`).
        func effectiveConfig(_ argv: [String]) throws -> [String] {
            let run = try runWithConfig(["-G"] + argv)
            try #require(run.status == 0, Comment(rawValue: run.stderr))
            return run.stdout
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }

        func runWithConfig(_ argv: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath: RemoteTmuxConfigForwardIsolationTests.sshExecutablePath
            )
            process.arguments = ["-F", configPath] + argv
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus,
                String(decoding: stdoutData, as: UTF8.self),
                String(decoding: stderrData, as: UTF8.self)
            )
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// A fake ssh that succeeds silently and records each invocation's argv
    /// (NUL separated, one file per call) so a test can hand the exact argv
    /// cmux spawned to the real ssh.
    private struct RecordingSSH {
        let executablePath: String
        private let directory: URL

        init(root: URL) throws {
            directory = root.appendingPathComponent("argv", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            DIR='\(directory.path)'
            n=$(cat "$DIR/count" 2>/dev/null || printf 0)
            n=$((n + 1))
            printf '%s' "$n" > "$DIR/count"
            : > "$DIR/$n.argv"
            for arg in "$@"; do printf '%s\\0' "$arg" >> "$DIR/$n.argv"; done
            exit 0
            """
            let scriptURL = root.appendingPathComponent("ssh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            executablePath = scriptURL.path
        }

        func invocations() -> [[String]] {
            guard let raw = try? String(contentsOfFile: directory.appendingPathComponent("count").path, encoding: .utf8),
                  let count = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  count > 0 else { return [] }
            return (1...count).compactMap { index -> [String]? in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(index).argv")) else {
                    return nil
                }
                // Every argument is NUL terminated, so the split's trailing
                // empty piece is the terminator, not an argument.
                return data.split(separator: 0, omittingEmptySubsequences: false)
                    .dropLast()
                    .map { String(decoding: $0, as: UTF8.self) }
            }
        }
    }
}
