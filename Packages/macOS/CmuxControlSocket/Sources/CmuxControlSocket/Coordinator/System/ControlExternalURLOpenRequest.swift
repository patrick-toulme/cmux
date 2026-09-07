public import Foundation

/// The validated `system.open_url` request: a web URL a client wants opened in
/// the Mac's default browser, outside cmux. The socket twin of `open <url>`
/// for callers that do not run on the Mac: an agent TUI inside a mirrored
/// remote tmux pane relays the link the user clicked through the reverse
/// forwarded control socket instead of copying it to the clipboard.
///
/// Only `http` and `https` are accepted. The control socket is reachable from
/// every mirrored machine through the agent bridge, so a `file:`, `ssh:`, or
/// custom app scheme arriving over it must never launch a handler on the Mac.
public struct ControlExternalURLOpenRequest: Sendable, Equatable {
    /// The URL schemes a request may carry.
    public static let allowedSchemes: Set<String> = ["http", "https"]

    /// The parsed URL.
    public let url: URL

    /// Whether the browser comes to the foreground. Defaults to true: the
    /// caller relays a user's click, and `open <url>` on the Mac activates
    /// the browser too. `activate: false` loads the page behind the current
    /// app for callers that only want it queued up.
    public let activates: Bool

    public init(url: URL, activates: Bool) {
        self.url = url
        self.activates = activates
    }

    /// Why a request was refused. Each case maps to one `invalid_params`
    /// reply so a client can tell a typo from an unsupported scheme.
    public enum Rejection: Error, Sendable, Equatable {
        /// `url` is missing or blank.
        case missingURL
        /// `url` does not parse as a URL.
        case invalidURL(String)
        /// `url` parses but its scheme is not in ``allowedSchemes``. Carries
        /// the lowercased scheme, empty for a scheme-less value such as a bare
        /// `cl/123` (which the browser would treat as a relative path).
        case unsupportedScheme(String)
        /// `url` has an allowed scheme but no host (`http:///path`).
        case missingHost

        /// The human-readable reply message.
        public var message: String {
            switch self {
            case .missingURL:
                return "system.open_url requires params.url"
            case .invalidURL(let raw):
                return "params.url is not a valid URL: \(raw)"
            case .unsupportedScheme(let scheme):
                let allowed = ControlExternalURLOpenRequest.allowedSchemes.sorted().joined(separator: ", ")
                return scheme.isEmpty
                    ? "params.url must be an absolute URL with one of these schemes: \(allowed)"
                    : "params.url scheme \(scheme) is not allowed; allowed: \(allowed)"
            case .missingHost:
                return "params.url must include a host"
            }
        }
    }

    /// Validates the raw request params.
    ///
    /// - Parameter params: The typed `system.open_url` params (`url`, and the
    ///   optional `activate`, which accepts the usual bool spellings).
    /// - Returns: The request, or the rejection that names the offending part.
    public static func parse(params: [String: JSONValue]) -> Result<ControlExternalURLOpenRequest, Rejection> {
        guard case .string(let raw)? = params["url"] else {
            return .failure(.missingURL)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.missingURL)
        }
        guard let components = URLComponents(string: trimmed), let url = components.url else {
            return .failure(.invalidURL(trimmed))
        }
        let scheme = (components.scheme ?? "").lowercased()
        guard allowedSchemes.contains(scheme) else {
            return .failure(.unsupportedScheme(scheme))
        }
        guard components.host?.isEmpty == false else {
            return .failure(.missingHost)
        }
        return .success(ControlExternalURLOpenRequest(url: url, activates: activateFlag(params) ?? true))
    }

    /// The `activate` param in the coordinator's bool spellings (JSON bool,
    /// number, or `1/true/yes/on` / `0/false/no/off`); `nil` when absent or
    /// unrecognized.
    private static func activateFlag(_ params: [String: JSONValue]) -> Bool? {
        switch params["activate"] {
        case .bool(let value)?:
            return value
        case .int(let value)?:
            return value != 0
        case .double(let value)?:
            return value != 0
        case .string(let value)?:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

/// What happened when the app asked the system to open a
/// ``ControlExternalURLOpenRequest``.
public enum ControlExternalURLOpenOutcome: Sendable, Equatable {
    /// Launch Services accepted the URL. `handler` names the application
    /// that took it (its localized name) when known.
    case opened(handler: String?)
    /// No application opened the URL; `message` carries the system error.
    case failed(message: String)
}
