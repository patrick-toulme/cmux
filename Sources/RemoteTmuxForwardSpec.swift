import Foundation

/// One ssh port forward as `ssh -O forward` / `ssh -O cancel` accept it: the
/// flag (`-R`, `-L`, `-D`) plus its specification string.
struct RemoteTmuxForwardSpec: Hashable, Sendable, CustomStringConvertible {
    enum Kind: String, Sendable, CaseIterable {
        case remote = "-R"
        case local = "-L"
        case dynamic = "-D"

        /// The `ssh -G` option name that lists forwards of this kind.
        var configOptionName: String {
            switch self {
            case .remote: return "remoteforward"
            case .local: return "localforward"
            case .dynamic: return "dynamicforward"
            }
        }
    }

    let kind: Kind
    /// The spec exactly as `-R`/`-L`/`-D` take it, e.g. `9998:localhost:9998`,
    /// `[::1]:3000:127.0.0.1:3000`, `/tmp/r.sock:/tmp/l.sock`, `1080`.
    let specification: String

    /// The argv fragment for `-O forward` / `-O cancel`.
    var arguments: [String] { [kind.rawValue, specification] }

    /// `R 9998:localhost:9998`: how the spec reads in logs and tooltips.
    var description: String {
        "\(kind.rawValue.dropFirst()) \(specification)"
    }

    /// A reverse unix-socket forward (the remote agent bridge).
    static func reverseUnixSocket(remotePath: String, localPath: String) -> RemoteTmuxForwardSpec {
        RemoteTmuxForwardSpec(kind: .remote, specification: "\(remotePath):\(localPath)")
    }

    // MARK: - ssh -G parsing

    /// The forwards `ssh -G` prints for a host, converted back into the specs
    /// `-O forward` needs. Every line has the shape
    /// `<option> <listen> [<connect>]` where each endpoint is one of
    /// `<path>`, `<port>`, or `[<host>]:<port>` (see `dump_cfg_forwards` in
    /// OpenSSH's readconf.c). Malformed lines and dynamically allocated
    /// remote listeners (`0`, which cannot be re-requested by number) are
    /// skipped; the order is the config's order.
    static func parseSSHConfigDump(_ output: String) -> [RemoteTmuxForwardSpec] {
        var specs: [RemoteTmuxForwardSpec] = []
        var localListeners: Set<String> = []
        var dynamicListeners: [String] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let fields = rawLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let option = fields.first?.lowercased(),
                  let kind = Kind.allCases.first(where: { $0.configOptionName == option })
            else { continue }
            let endpoints = Array(fields.dropFirst())
            switch kind {
            case .dynamic:
                guard endpoints.count == 1, let listen = endpointSpec(endpoints[0]) else { continue }
                dynamicListeners.append(listen)
            case .remote, .local:
                guard endpoints.count == 2,
                      let listen = endpointSpec(endpoints[0]),
                      let connect = endpointSpec(endpoints[1])
                else { continue }
                if kind == .remote, endpoints[0] == "0" { continue }
                if kind == .local { localListeners.insert(listen) }
                specs.append(RemoteTmuxForwardSpec(kind: kind, specification: "\(listen):\(connect)"))
            }
        }
        // OpenSSH's dump lists a LocalForward whose target is a unix socket
        // under `dynamicforward` as well (its dynamic filter only excludes
        // entries with a non-"socks" connect HOST, and a socket target has
        // none). A genuine DynamicForward can never share a listener with a
        // LocalForward, so those echoes are dropped.
        for listen in dynamicListeners where !localListeners.contains(listen) {
            specs.append(RemoteTmuxForwardSpec(kind: .dynamic, specification: listen))
        }
        return specs
    }

    /// `9998` → `9998`, `[localhost]:9998` → `localhost:9998`,
    /// `[::1]:9998` → `[::1]:9998` (IPv6 literals keep their brackets, as
    /// the `-R`/`-L` grammar requires), `/tmp/x.sock` → `/tmp/x.sock`.
    private static func endpointSpec(_ field: String) -> String? {
        guard !field.isEmpty else { return nil }
        if field.hasPrefix("/") { return field }
        if field.hasPrefix("["),
           let close = field.firstIndex(of: "]"),
           field[field.index(after: close)...].hasPrefix(":") {
            let host = String(field[field.index(after: field.startIndex)..<close])
            let port = String(field[field.index(close, offsetBy: 2)...])
            guard !host.isEmpty, !port.isEmpty, !port.contains(":") else { return nil }
            return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        }
        guard field.allSatisfy(\.isNumber) else { return nil }
        return field
    }
}
