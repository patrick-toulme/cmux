import CmuxFoundation
import Foundation

/// Identifies a remote host whose tmux server cmux mirrors over SSH.
///
/// A host is addressed by its SSH `destination` — either a `~/.ssh/config`
/// alias (e.g. `claude-box`) or an explicit `user@host`. cmux multiplexes
/// every operation against the host (discovery commands, the `tmux -CC`
/// control client, and one-shot mutations) over a single SSH ControlMaster
/// socket derived from the destination, so authentication happens once.
/// The ssh binary every remote-tmux spawn uses. DEBUG builds honor
/// `CMUX_REMOTE_TMUX_SSH_FOR_TESTING` so end-to-end tests can substitute a
/// shim that strips the ssh framing and execs the remote command locally —
/// the full mirror stack then runs hermetically (no sshd, no network).
struct RemoteTmuxHost: Sendable, Equatable, Identifiable {
    /// The ssh executable used when the caller doesn't inject one (the
    /// connection and transport inits both take `sshExecutablePath`).
    ///
    /// DEBUG builds honor `CMUX_REMOTE_TMUX_SSH_FOR_TESTING` because the
    /// sizing UI tests exercise the REAL app process, and a launch
    /// environment variable is the only injection channel that crosses the
    /// XCUITest process boundary — the same seam `CMUX_SOCKET_PATH` uses.
    static func defaultSSHExecutablePath() -> String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["CMUX_REMOTE_TMUX_SSH_FOR_TESTING"],
           !override.isEmpty {
            return override
        }
        #endif
        return "/usr/bin/ssh"
    }

    /// The SSH destination: a `~/.ssh/config` alias or `user@host`.
    let destination: String

    /// Optional explicit port (`-p`). `nil` defers to `~/.ssh/config`.
    let port: Int?

    /// Optional explicit identity file (`-i`). `nil` defers to `~/.ssh/config`.
    let identityFile: String?

    /// Stable identity matching the connection-uniqueness key. Two hosts with the
    /// same destination but a different port/identity are distinct endpoints (see
    /// ``connectionHash``), so `id` uses ``connectionHash`` rather than the
    /// destination alone — keeping ``Identifiable`` identity consistent with how
    /// ``RemoteTmuxController`` keys its per-endpoint state.
    var id: String { connectionHash }

    init(destination: String, port: Int? = nil, identityFile: String? = nil) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
    }

    /// A human-readable (but lossy) slug for the destination, used only for
    /// debuggability in the control socket filename. It lowercases and maps
    /// every non-alphanumeric character to `-`, so distinct destinations can
    /// collapse to the same slug — uniqueness comes from ``connectionHash``,
    /// never from the slug alone.
    ///
    /// The slug is *not* length-capped here: ``controlSocketPath`` trims it to
    /// whatever budget remains after the fixed parts of the path, so the socket
    /// (plus OpenSSH's transient bind suffix) always fits the AF_UNIX limit.
    var slug: String {
        let lowered = destination.lowercased()
        let mapped = lowered.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        }
        return mapped.isEmpty ? "host" : String(mapped)
    }

    /// A stable, deterministic, collision-resistant hex digest of this host's full
    /// **connection identity** — the case-sensitive ``destination`` plus the
    /// explicit ``port`` and ``identityFile`` — over a unit-separated fingerprint
    /// (FNV-1a/64).
    ///
    /// Two hosts that share a lossy ``slug`` (e.g. `alice@host` vs `alice.host`),
    /// *or* the same destination reached on a different port or with a different
    /// identity file, get different digests — so they never share a ControlMaster
    /// socket. That separation is a safety property, not just hygiene: the master
    /// multiplexes destructive commands (`kill-session`, `rename-window`), so two
    /// distinct endpoints must never collapse onto one socket and risk routing a
    /// command to the wrong server.
    var connectionHash: String {
        let fingerprint = "\(destination)\u{1f}\(port.map(String.init) ?? "")\u{1f}\(identityFile ?? "")"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV offset basis
        for byte in fingerprint.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3 // FNV prime
        }
        return String(format: "%016llx", hash)
    }

    /// The SSH ControlMaster socket path shared by every operation against this host.
    ///
    /// Namespaced under `~/.cmux/ssh/`. The filename combines the lossy
    /// human-readable ``slug`` with the collision-resistant ``connectionHash`` of
    /// the exact connection identity (destination + port + identity file), so two
    /// distinct endpoints never collide on one socket (which would otherwise route
    /// commands — including the destructive `kill-session` — to the wrong host
    /// through a shared master).
    ///
    /// The slug is trimmed so the final path *plus OpenSSH's transient bind
    /// suffix* stays within the AF_UNIX limit. OpenSSH never binds `ControlPath`
    /// directly: it binds `<ControlPath>.XXXXXXXXXXXXXXXX` (a 17-byte suffix) and
    /// atomically renames it into place, so the socket path budget must account
    /// for that suffix — otherwise long destinations fail with
    /// `unix_listener: path "…" too long for Unix domain socket`. The
    /// ``connectionHash`` is never trimmed, so uniqueness is preserved even when
    /// the slug is dropped entirely. ``ensureControlSocketDirectory()`` rejects
    /// the rare case where even an empty slug overflows (an unusually long home).
    var controlSocketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Fixed parts that can never be trimmed: directory, the `tmux-` prefix,
        // the `-<hash>.sock` tail, and the transient suffix OpenSSH binds first.
        let prefix = "\(home)/.cmux/ssh/tmux-"
        let suffix = "-\(connectionHash).sock"
        let fixedBytes = prefix.utf8.count + suffix.utf8.count + Self.opensshTransientSuffixLength
        let slugBudget = max(0, Self.maxUnixSocketPathLength - fixedBytes)
        return "\(prefix)\(Self.trimmedToUTF8ByteBudget(slug, slugBudget))\(suffix)"
    }

    /// macOS caps an AF_UNIX `sun_path` at 104 bytes (including the NUL
    /// terminator), so the usable path length is 103 bytes.
    private static let maxUnixSocketPathLength = 103

    /// Bytes OpenSSH appends to `ControlPath` for its transient pre-rename bind
    /// socket: a `.` plus 16 random characters (see `mux.c`). The bound path must
    /// fit the AF_UNIX limit, not just the final renamed `ControlPath`.
    private static let opensshTransientSuffixLength = 17

    /// Whether the path OpenSSH would actually bind for `controlPath` — i.e.
    /// `controlPath` plus its 17-byte transient suffix — fits the AF_UNIX limit.
    /// ``ensureControlSocketDirectory()`` checks this before opening the master so
    /// an un-bindable path fails with a clear error instead of the opaque
    /// `unix_listener: … too long`.
    static func controlSocketPathFitsUnixLimit(_ controlPath: String) -> Bool {
        controlPath.utf8.count + opensshTransientSuffixLength <= maxUnixSocketPathLength
    }

    /// Returns the longest whole-`Character` prefix of `value` whose UTF-8
    /// encoding fits `byteBudget`. Trims on Character (not byte) boundaries so a
    /// multi-byte scalar is never split, and counts bytes (not characters)
    /// because the AF_UNIX limit is measured in bytes.
    private static func trimmedToUTF8ByteBudget(_ value: String, _ byteBudget: Int) -> String {
        guard value.utf8.count > byteBudget else { return value }
        var result = ""
        var used = 0
        for ch in value {
            let chBytes = String(ch).utf8.count
            if used + chBytes > byteBudget { break }
            result.append(ch)
            used += chBytes
        }
        return result
    }

    /// Ensures the directory that holds the control socket exists.
    ///
    /// Also rejects up front the rare case where the home directory is long
    /// enough that the fixed path parts alone overflow the AF_UNIX limit, so even
    /// an empty slug can't fit (``controlSocketPath`` trims the slug but cannot
    /// shrink the home dir / hash / suffix). Without this guard `ssh` would still
    /// open, then die with the opaque `unix_listener: … too long` — surfacing it
    /// here gives a clear, actionable error instead.
    func ensureControlSocketDirectory() throws {
        let path = controlSocketPath
        guard Self.controlSocketPathFitsUnixLimit(path) else {
            let boundPathBytes = path.utf8.count + Self.opensshTransientSuffixLength
            let message = String(
                format: String(
                    localized: "remoteTmux.error.controlSocketPathTooLong",
                    defaultValue: "SSH control socket path is too long for a Unix domain socket (%lld > %lld bytes); home directory path is too long"
                ),
                boundPathBytes,
                Self.maxUnixSocketPathLength
            )
            throw RemoteTmuxError.unreachable(message)
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// `ControlPersist` value that keeps an opened master alive indefinitely
    /// (OpenSSH treats `0` as "persist forever"). The one authenticated
    /// connection per machine outlives idle gaps, long reconnect outages,
    /// window closes, detaches and cmux itself quitting: the master is a
    /// detached process on its own control socket, so the next launch finds
    /// it with `ssh -O check` and re-attaches with no fresh authentication
    /// (no security-key touch). Only an explicit host disconnect or a reauth
    /// of a dead master issues `ssh -O exit`.
    static let masterControlPersistIndefinitely = 0

    /// Seconds between `ServerAliveInterval` keepalives on every cmux ssh spawn.
    static let serverAliveIntervalSeconds = 20

    /// Unanswered keepalives (`ServerAliveCountMax`) before ssh declares the
    /// transport dead: 6 x 20s = 2 minutes of tolerance for network blips.
    static let serverAliveCountMax = 6

    /// Stable stderr marker a mux-only invocation emits when it finds no live
    /// master and its severed direct-connection fallback fails fast (see
    /// ``RemoteTmuxControlMasterRole/client``). Unique to cmux so
    /// classification can never confuse it with a genuine remote/proxy error.
    static let masterUnavailableSentinel = "cmux-remote-tmux-master-unavailable"

    /// The fail-fast `ProxyCommand` mux-only invocations use to sever ssh's
    /// direct-connection fallback: prints ``masterUnavailableSentinel`` to
    /// stderr and exits nonzero without ever touching the network. The outer
    /// command is executed by the user's login shell, so the body is wrapped
    /// in a portable `/bin/sh -c '…'`.
    static let muxOnlyProxyCommand =
        "/bin/sh -c 'echo \(masterUnavailableSentinel) >&2; exit 1'"

    /// SSH options that reuse — and, for ``RemoteTmuxControlMasterRole/opener``
    /// only, open — the shared ControlMaster.
    ///
    /// Deliberately does NOT pin `StrictHostKeyChecking`, so ssh honors the
    /// user's `~/.ssh/config` host-key policy. Under `batchMode` an unknown host
    /// key therefore fails fast ("Host key verification failed") instead of being
    /// silently trusted; ``RemoteTmuxController`` classifies that as needing
    /// interactive auth and routes the user to ``interactiveAuthInvocation()``
    /// (which likewise does not pin `StrictHostKeyChecking`, so ssh's default
    /// `ask` prompts) to confirm the fingerprint in their terminal — the native
    /// SSH first-contact experience.
    ///
    /// - Parameter controlPersistSeconds: how long the master lingers idle
    ///   after the last client detaches (`0` = indefinitely, see
    ///   ``masterControlPersistIndefinitely``). Only meaningful for
    ///   ``RemoteTmuxControlMasterRole/opener`` invocations — a mux-only
    ///   client never becomes the master — but always emitted so the argv
    ///   shape stays uniform.
    /// - Parameter batchMode: when `true`, ssh never prompts interactively.
    ///   Use this for discovery/mutation commands and for the pipe-backed local
    ///   `tmux -CC` control client; interactive prompts are handled only by
    ///   ``interactiveAuthInvocation()`` running in the user's terminal.
    /// - Parameter role: whether this invocation may create (and authenticate)
    ///   the master, or must fail fast when no live master exists. Only the
    ///   single-flight readiness gate and the interactive terminal ssh pass
    ///   ``RemoteTmuxControlMasterRole/opener`` — that restriction is what
    ///   guarantees at most one authenticated connection per machine.
    func sshControlArguments(
        controlPersistSeconds: Int,
        batchMode: Bool,
        role: RemoteTmuxControlMasterRole
    ) -> [String] {
        // Every ssh-tmux invocation supplies its own remote command (`true`,
        // `tmux -CC …`, one-shot discovery), which OpenSSH refuses while a
        // host-configured RemoteCommand is in effect (issue #7246).
        var args = SSHHostConfiguredRemoteCommand().overrideArguments
        switch role {
        case .opener:
            args += ["-o", "ControlMaster=auto"]
        case .client:
            // `ControlMaster=no` selects mux-client mode; the ProxyCommand
            // severs the direct-connection fallback so a dead master makes the
            // spawn fail fast with the sentinel instead of silently opening its
            // own authenticated connection (a hidden security-key touch —
            // multiplied by N reconnecting sessions, a touch storm).
            // `ProxyJump=none` clears any configured jump host so the explicit
            // ProxyCommand can never conflict with it; both options only govern
            // the never-taken fallback path, so a live master is unaffected.
            args += [
                "-o", "ControlMaster=no",
                "-o", "ProxyJump=none",
                "-o", "ProxyCommand=\(Self.muxOnlyProxyCommand)",
            ]
        }
        // Keepalives every 20s keep relay tunnels warm; a dead transport is
        // declared only after 2 minutes without a reply (6 misses). A shorter
        // window turned Wi-Fi roams and VPN renegotiations into master deaths,
        // and every master death is a reconnect that may need a security-key
        // touch, so the tolerance errs toward surviving the blip.
        args += [
            "-o", "ControlPath=\(controlSocketPath)",
            "-o", "ControlPersist=\(controlPersistSeconds)",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=\(Self.serverAliveIntervalSeconds)",
            "-o", "ServerAliveCountMax=\(Self.serverAliveCountMax)",
        ]
        if batchMode {
            args.append(contentsOf: ["-o", "BatchMode=yes"])
        }
        if let port {
            args.append(contentsOf: ["-p", String(port)])
        }
        if let identityFile, !identityFile.isEmpty {
            args.append(contentsOf: ["-i", identityFile])
        }
        return args
    }

    /// Builds the full `ssh` argv (executable first) for a one-shot **interactive**
    /// authentication that opens the shared ControlMaster, then exits.
    ///
    /// Runs `ssh <control opts, no BatchMode> -T -- <destination> true`: it
    /// authenticates against the host (password / host-key TOFU /
    /// keyboard-interactive MFA / FIDO touch all prompt on the controlling tty),
    /// runs the trivial remote `true`, and exits — leaving the master alive for
    /// ``controlPersistSeconds`` so the subsequent pipe-based discovery and
    /// `tmux -CC` control client multiplex over it with no further prompt.
    ///
    /// Intended to be run by the `cmux ssh-tmux` CLI **inside the user's terminal**
    /// (which supplies the tty); the local control client itself uses plain pipes
    /// and cannot prompt. It forces `BatchMode=no` so the interactive prompt always
    /// works even when the user's ssh_config sets `BatchMode yes`, but it does NOT
    /// pin `StrictHostKeyChecking`: the user's host-key policy is honored (a
    /// configured `StrictHostKeyChecking=yes` must not be silently downgraded to a
    /// TOFU prompt), and ssh's default `ask` already prompts to confirm a new
    /// fingerprint on this controlling tty.
    ///
    /// Critically, this opens the master in the **foreground** (no `-f`): ssh
    /// authenticates, opens the master, runs the remote `true`, and exits only once
    /// the control socket has served that session. So by the time the CLI's
    /// foreground ssh returns, the master is provably *serving* — the post-auth
    /// retry rides it deterministically, with no `ssh -O check` readiness poll.
    ///
    /// `-f` (background-after-auth) is deliberately NOT used: it returns before the
    /// backgrounded master binds its control socket, racing the immediate retry. The
    /// historical worry that a foreground master would keep the terminal's
    /// stdout/stderr and freeze window/app close does not apply: when `ControlPersist`
    /// backgrounds the master, OpenSSH's `control_persist_detach()` redirects the
    /// master's std fds to `/dev/null` (`stdfd_devnull(1, 1, …)` in `ssh.c`, identical
    /// across OpenSSH 9.6/9.8/9.9/10.2 — the versions macOS 14/15/26 ship), and forces
    /// that detach independent of `-f`. So the foreground ssh exits cleanly and the
    /// detached master never pins the tty.
    ///
    /// `-n` is kept explicitly: `-f` *implied* `-n` (stdin from `/dev/null`), and
    /// dropping `-f` would otherwise leave the controlling terminal as the remote
    /// command's stdin. With the trivial `true` that's usually harmless, but a host
    /// `ForceCommand` / forced wrapper, or noninteractive shell startup that reads
    /// stdin, could consume the user's terminal input or block. `-n` preserves the
    /// stdin-null behavior without backgrounding; auth prompts are unaffected (ssh
    /// reads them from the controlling tty, not stdin).
    ///
    /// - Parameter sshExecutablePath: the local `ssh` binary the CLI will exec.
    /// - Parameter controlPersistSeconds: idle lifetime of the opened master.
    ///   Defaults to ``masterControlPersistIndefinitely`` so the one
    ///   interactive authentication (the user's security-key touch) is never
    ///   silently forfeited to an idle timer; every teardown path closes the
    ///   master explicitly with `ssh -O exit`.
    /// - Returns: argv where element 0 is `sshExecutablePath`; the `--`
    ///   end-of-options guard precedes the destination so a dash-prefixed
    ///   destination can never be parsed as an ssh option.
    func interactiveAuthInvocation(
        sshExecutablePath: String = RemoteTmuxHost.defaultSSHExecutablePath(),
        controlPersistSeconds: Int = RemoteTmuxHost.masterControlPersistIndefinitely
    ) -> [String] {
        [sshExecutablePath]
            + sshControlArguments(
                controlPersistSeconds: controlPersistSeconds,
                batchMode: false,
                role: .opener
            )
            + [
                "-o", "BatchMode=no", "-n", "-T", "--", destination,
                Self.interactiveAuthRemoteCommand(connectionHash: connectionHash),
            ]
    }

    /// Single-quotes a value for safe interpolation into a `/bin/sh` command.
    static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Builds a remote shell command that resolves `tmux` before executing it.
    ///
    /// OpenSSH runs remote commands under the account's shell, but not as an
    /// interactive/login shell. On macOS that often means zsh starts with only
    /// `/usr/bin:/bin:/usr/sbin:/sbin`, so Homebrew's `tmux` is invisible even
    /// though it works in the user's normal terminal. Resolve the binary in a
    /// tiny `/bin/sh` wrapper, then `exec` it with the original arguments so both
    /// one-shot probes and `tmux -CC` use the same path behavior.
    static func tmuxRemoteCommand(arguments: [String]) -> String {
        RemoteTmuxCommandBuilder(arguments: arguments).remoteShellCommand
    }

    /// Stable stderr marker the resolver emits with exit 127 when no tmux binary is usable.
    static let tmuxNotFoundSentinel = RemoteTmuxCommandBuilder.notFoundSentinel

    // MARK: - Forwarded-agent stable link

    /// The remote directory expression the agent-link snippet writes into.
    ///
    /// Production uses `$HOME/.ssh`, expanded by the REMOTE shell (the app
    /// cannot know the remote home when it builds the snippet). DEBUG builds
    /// honor `CMUX_REMOTE_TMUX_AGENT_LINK_DIR_FOR_TESTING` — a literal
    /// absolute path — because the e2e ssh shim executes remote commands
    /// locally with the developer's real `$HOME`, and an unredirected snippet
    /// would write symlinks into their actual `~/.ssh`.
    static func agentLinkDirectoryExpression() -> String {
        #if DEBUG
        if let override = ProcessInfo.processInfo
            .environment["CMUX_REMOTE_TMUX_AGENT_LINK_DIR_FOR_TESTING"],
            !override.isEmpty, !override.contains("'"), !override.contains("\"") {
            return override
        }
        #endif
        return "$HOME/.ssh"
    }

    /// The stable forwarded-agent symlink path for this endpoint, relative to
    /// the remote home. One link per connection identity: same granularity as
    /// the ControlMaster whose per-generation socket it caches.
    static func agentLinkRelativePath(connectionHash: String) -> String {
        ".ssh/cmux-agent-\(connectionHash).sock"
    }

    /// One-line POSIX snippet that retargets the endpoint's stable agent
    /// symlink at the CURRENT connection's forwarded `SSH_AUTH_SOCK`.
    ///
    /// Forwarded-agent sockets live exactly as long as one SSH connection,
    /// but tmux panes capture the path into their environment forever — so
    /// every master reopen (reconnect, app restart, `cmux ssh-tmux` rerun)
    /// strands panes on a dead socket and `ssh-add`/SSO auth fail. Pointing
    /// the panes at a stable symlink instead (see ``agentEnvPinCommand``)
    /// and retargeting the link on every attach keeps one authentication
    /// working across master generations.
    ///
    /// Contract (each clause maps to an existing failure classifier that
    /// must not trip):
    /// - never writes to stdout (pre-`%enter` stdout feeds session-gone
    ///   classification on reconnect),
    /// - never writes to stderr (transport stderr feeds
    ///   `indicatesAuthRequired`; a stray `ln: Permission denied` would be
    ///   misread as an authentication failure),
    /// - always exits 0 (a nonzero opener probe aborts master readiness),
    /// - silently does nothing unless `SSH_AUTH_SOCK` names a live socket
    ///   (no ForwardAgent configured → behavior byte-identical to before).
    static func agentLinkRefreshScript(connectionHash: String) -> String {
        let dir = agentLinkDirectoryExpression()
        let link = "\(dir)/cmux-agent-\(connectionHash).sock"
        // /bin/mkdir and /bin/ln by absolute path: a non-interactive remote
        // shell can start with a degenerate PATH, and this snippet must work
        // (or no-op) everywhere without ever printing an error.
        return "cmux_l=\"\(link)\"; "
            + "if [ -n \"$SSH_AUTH_SOCK\" ] && [ -S \"$SSH_AUTH_SOCK\" ] && "
            + "[ \"$SSH_AUTH_SOCK\" != \"$cmux_l\" ]; then "
            + "{ /bin/mkdir -p \"\(dir)\" && /bin/ln -sfn \"$SSH_AUTH_SOCK\" \"$cmux_l\"; } "
            + ">/dev/null 2>&1; fi"
    }

    /// Wraps an already-quoted remote command string so the agent-link
    /// refresh runs first, then the original command execs with its argv
    /// untouched: `'/bin/sh' '-c' '<snippet>; exec "$@"' 'cmux-agent-link'
    /// <original words>`. A PREFIX wrap by design — every existing assertion
    /// on the resolver command (`contains`, `hasSuffix`) stays true, and the
    /// remote login shell only needs to word-split quoted words, the same
    /// portability contract as the tmux resolver itself.
    static func agentLinkWrappedRemoteCommand(
        _ remoteCommand: String,
        connectionHash: String
    ) -> String {
        let script = agentLinkRefreshScript(connectionHash: connectionHash) + "; exec \"$@\""
        return "'/bin/sh' '-c' \(shellSingleQuoted(script)) 'cmux-agent-link' " + remoteCommand
    }

    /// The interactive auth invocation's remote command: refresh the agent
    /// link, then succeed like the old bare `true`. Rerunning `cmux ssh-tmux`
    /// therefore heals every stable-path pane at authentication time.
    static func interactiveAuthRemoteCommand(connectionHash: String) -> String {
        let script = agentLinkRefreshScript(connectionHash: connectionHash) + "; true"
        return "'/bin/sh' '-c' \(shellSingleQuoted(script))"
    }

    /// One tmux control-mode line that pins the server's `SSH_AUTH_SOCK` to
    /// the endpoint's stable link — session-scoped (overwrites what
    /// `update-environment` captured from this attach) plus `-g` for sessions
    /// later created detached. Guarded by a server-side `test -S` so users
    /// without ForwardAgent keep tmux's native behavior bit-for-bit, and a
    /// dangling link is never pinned over a live value.
    ///
    /// Returns `nil` when `home` cannot be embedded safely (relative, control
    /// characters, or quote characters) — the pin silently skips and the next
    /// reconnect retries with a fresh resolution.
    static func agentEnvPinCommand(home: String, connectionHash: String) -> String? {
        #if DEBUG
        let dir = agentLinkDirectoryExpression()
        let link: String
        if dir != "$HOME/.ssh" {
            link = "\(dir)/cmux-agent-\(connectionHash).sock"
        } else {
            guard let validated = validatedRemoteHome(home) else { return nil }
            link = "\(validated)/\(agentLinkRelativePath(connectionHash: connectionHash))"
        }
        #else
        guard let validated = validatedRemoteHome(home) else { return nil }
        let link = "\(validated)/\(agentLinkRelativePath(connectionHash: connectionHash))"
        #endif
        return "if-shell -b 'test -S \"\(link)\"' "
            + "'set-environment -g SSH_AUTH_SOCK \"\(link)\" ; "
            + "set-environment SSH_AUTH_SOCK \"\(link)\"'"
    }

    /// Validates a remote home directory for safe embedding in the agent
    /// pin line: absolute, line-safe, and free of quote characters (either
    /// would break the nested tmux/if-shell quoting).
    static func validatedRemoteHome(_ home: String) -> String? {
        let trimmed = home.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              controlModeLineSafeName(trimmed) != nil,
              !trimmed.contains("'"),
              !trimmed.contains("\"") else { return nil }
        return trimmed == "/" ? trimmed : (trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)
    }

    /// Returns a non-empty tmux control-mode command argument, or `nil` when the
    /// value could break the line-oriented control stream. Shell quoting is not
    /// enough here: CR/LF/control bytes can terminate a `rename-*` command line
    /// before tmux parses the quoted argument.
    static func controlModeCommandName(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return controlModeLineSafeName(trimmed)
    }

    /// Validates a name already received from tmux. Unlike
    /// ``controlModeCommandName(_:)``, this preserves surrounding spaces because
    /// tmux is the source of truth for confirmed session/window names.
    static func controlModeLineSafeName(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard value.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        return value
    }

    /// Builds the `ssh` argv (for direct `Process` execution, no shell) that
    /// runs `tmux -CC` control mode for `sessionName` on this host.
    ///
    /// Uses `ssh -tt` to force a remote PTY (the remote `tmux attach` needs a
    /// tty); the local side is plain pipes. The remote command is one argument
    /// that the remote login shell parses, so the session name is single-quoted.
    /// A `--` end-of-options marker precedes the destination so a destination
    /// that begins with `-` can never be parsed by `ssh` as an option (which
    /// would allow `-oProxyCommand=…` local command injection).
    ///
    /// Always a mux-only ``RemoteTmuxControlMasterRole/client``: the control
    /// stream rides the shared master and must never self-authenticate. When
    /// the master is dead (reconnect after an outage), the spawn fails fast
    /// with ``masterUnavailableSentinel`` and the reconnect loop routes
    /// recovery through the controller's master gate — N sessions coalescing
    /// on one reopen instead of N racing authentications.
    ///
    /// - Parameters:
    ///   - sessionName: the tmux session to attach to (or create).
    ///   - createIfMissing: `new-session -A -s` (attach or create) vs `attach-session -t`.
    func controlModeArguments(
        sessionName: String,
        createIfMissing: Bool,
        controlPersistSeconds: Int = 180
    ) -> [String] {
        var args = ["-tt"]
        args.append(contentsOf: sshControlArguments(
            controlPersistSeconds: controlPersistSeconds,
            batchMode: true,
            role: .client
        ))
        let remoteCommand = Self.tmuxRemoteCommand(arguments: createIfMissing
            ? ["-CC", "new-session", "-A", "-s", sessionName]
            : ["-CC", "attach-session", "-t", sessionName])
        // Every attach (first connect AND each reconnect re-attach) refreshes
        // the endpoint's stable forwarded-agent link before tmux starts, so
        // the post-attach env pin always names a live socket.
        let wrappedRemoteCommand = Self.agentLinkWrappedRemoteCommand(
            remoteCommand,
            connectionHash: connectionHash
        )
        args.append(contentsOf: ["--", destination, wrappedRemoteCommand])
        return args
    }

    /// Builds a ``DetectedSSHSession`` that uploads files to this host over SSH,
    /// reusing the same ControlMaster socket the control connection already opened
    /// (so an `scp` multiplexes over the existing authenticated master — no second
    /// prompt while a mirror is live).
    ///
    /// Used by the image-paste path: a screenshot pasted into a mirrored remote
    /// tmux pane is uploaded to the host and the remote path is inserted, so a
    /// remote CLI (e.g. claude) can read it — instead of inserting a macOS-local
    /// path that doesn't exist on the remote.
    ///
    /// Mux-only, like every other non-opener invocation: the fail-fast
    /// ProxyCommand (see ``muxOnlyProxyCommand``) severs scp/ssh's
    /// direct-connection fallback, so an upload attempted while the master is
    /// down fails immediately with ``masterUnavailableSentinel`` instead of
    /// silently opening its own authenticated connection (an invisible
    /// security-key touch that would hang the paste until it timed out).
    func detectedSSHSession() -> DetectedSSHSession {
        DetectedSSHSession(
            destination: destination,
            port: port,
            identityFile: identityFile,
            configFile: nil,
            jumpHost: nil,
            controlPath: controlSocketPath,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: [
                "ProxyJump=none",
                "ProxyCommand=\(Self.muxOnlyProxyCommand)",
            ]
        )
    }
}
