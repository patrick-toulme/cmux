import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// ``RemoteTmuxForwardSpec``: the forwards `ssh -G` prints for a host must
/// round-trip into `-R`/`-L`/`-D` specs the real ssh accepts as the same
/// forwards, since the tunnel healer re-requests them by spec.
@Suite struct RemoteTmuxForwardSpecTests {
    private static let sshExecutablePath = "/usr/bin/ssh"

    @Test func parsesEveryEndpointShapeOpenSSHPrints() {
        let dump = """
        host xxl
        remoteforward 9998 [localhost]:9998
        remoteforward [::1]:9999 [127.0.0.1]:9999
        remoteforward [*]:8080 [localhost]:80
        remoteforward /tmp/remote.sock /tmp/local.sock
        remoteforward 0 [localhost]:2222
        localforward 3000 [127.0.0.1]:3000
        localforward [127.0.0.1]:5432 /var/run/postgres.sock
        dynamicforward 1080
        dynamicforward [::1]:1081
        dynamicforward [127.0.0.1]:5432
        controlpersist yes
        remoteforward garbage
        localforward 1 2 3
        """
        let specs = RemoteTmuxForwardSpec.parseSSHConfigDump(dump)
        #expect(specs == [
            RemoteTmuxForwardSpec(kind: .remote, specification: "9998:localhost:9998"),
            RemoteTmuxForwardSpec(kind: .remote, specification: "[::1]:9999:127.0.0.1:9999"),
            RemoteTmuxForwardSpec(kind: .remote, specification: "*:8080:localhost:80"),
            RemoteTmuxForwardSpec(kind: .remote, specification: "/tmp/remote.sock:/tmp/local.sock"),
            // `remoteforward 0 …` (a server-allocated port) is skipped: it
            // cannot be re-requested by number.
            RemoteTmuxForwardSpec(kind: .local, specification: "3000:127.0.0.1:3000"),
            RemoteTmuxForwardSpec(kind: .local, specification: "127.0.0.1:5432:/var/run/postgres.sock"),
            RemoteTmuxForwardSpec(kind: .dynamic, specification: "1080"),
            RemoteTmuxForwardSpec(kind: .dynamic, specification: "[::1]:1081"),
            // `dynamicforward [127.0.0.1]:5432` is OpenSSH echoing the
            // unix-socket LocalForward on the same listener, not a SOCKS proxy.
        ])
        #expect(specs[0].arguments == ["-R", "9998:localhost:9998"])
        #expect(specs[0].description == "R 9998:localhost:9998")
        #expect(specs[6].arguments == ["-D", "1080"])
        #expect(RemoteTmuxForwardSpec.parseSSHConfigDump("").isEmpty)
    }

    @Test func specsRoundTripThroughTheRealSSH() throws {
        // The forwards a user config declares, resolved by the real ssh,
        // parsed into specs, handed back to the real ssh as -R/-L/-D, and
        // resolved again: both resolutions must print the same forward lines.
        try #require(FileManager.default.isExecutableFile(atPath: Self.sshExecutablePath))
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("forward-spec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("ssh_config")
        try """
        Host roundtrip
          HostName 127.0.0.1
          RemoteForward 9998 localhost:9998
          RemoteForward [::1]:9999 127.0.0.1:9999
          RemoteForward /tmp/cmux-rt-remote.sock /tmp/cmux-rt-local.sock
          LocalForward 3000 127.0.0.1:3000
          LocalForward 127.0.0.1:5432 /var/run/postgres.sock
          DynamicForward 1080

        """.write(to: config, atomically: true, encoding: .utf8)

        let fromConfig = try Self.effectiveConfig(["-F", config.path, "-G", "--", "roundtrip"])
        let specs = RemoteTmuxForwardSpec.parseSSHConfigDump(fromConfig)
        #expect(specs.count == 6)

        let replayed = try Self.effectiveConfig(
            ["-F", "/dev/null", "-G"] + specs.flatMap(\.arguments) + ["--", "roundtrip"]
        )
        let forwardLines = { (dump: String) -> [String] in
            dump.split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { $0.hasPrefix("remoteforward ") || $0.hasPrefix("localforward ") || $0.hasPrefix("dynamicforward ") }
                .sorted()
        }
        #expect(forwardLines(fromConfig) == forwardLines(replayed))
        #expect(!forwardLines(replayed).isEmpty)
    }

    private static func effectiveConfig(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, Comment(rawValue: String(decoding: errorOutput, as: UTF8.self)))
        return String(decoding: output, as: UTF8.self)
    }
}
