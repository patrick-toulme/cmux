public import Foundation

/// Answers kitty graphics protocol support queries found in a mirrored pane's
/// output, on behalf of the terminal core that owns the pane.
///
/// A program probes for the protocol with `ESC _ G i=<id>,a=q,... ESC \` and
/// only draws images once a reply names that id. In a remote tmux mirror
/// nobody answers: tmux has no graphics protocol, and the mirror surface runs
/// in manual mirror mode, which drops every parser generated reply so tmux
/// (which answers DA, DSR, XTVERSION, ...) stays the single responder. The
/// mirror surface is nevertheless what stores and draws the images, so the
/// support query has to be answered here and delivered to the pane like typed
/// input.
///
/// Only queries (`a=q`) are answered. Acknowledgements for transmit, put and
/// delete commands stay silent as before; programs that need them send `q=2`
/// or fall back on their own timeouts, exactly as they do under tmux today.
///
/// The reply follows the protocol and the terminal it stands in for: the
/// query's `i` (and `I`, `p` when present) come back, `OK` when the medium and
/// format are ones the surface renders, an `EINVAL` message otherwise, and
/// nothing at all when the query carries no image id, `q=2`, or `q=1` with an
/// `OK` result. A remote pane can only ever use direct transmission (`t=d`):
/// the file and shared memory mediums name paths on the host running the
/// program, which the surface cannot read.
///
/// Stateful across calls: `%output` chunks split the sequence anywhere. Feed
/// it the stream AFTER the tmux passthrough envelope has been unwrapped.
public struct RemoteTmuxKittyGraphicsQueryResponder {
    /// Control data longer than this cannot be a valid query; the sequence is
    /// skipped so a runaway APC cannot grow the buffer without bound.
    static let controlLimit = 4096

    private var state: RemoteTmuxKittyGraphicsQueryResponderState = .text
    private var control: [UInt8] = []

    /// Creates a responder with no buffered escape sequence state.
    public init() {}

    /// Returns one reply, in stream order, for every support query that
    /// `data` completes.
    public mutating func replies(for data: Data) -> [Data] {
        // Hot path: routeOutput calls this for every %output chunk. Outside a
        // sequence, a chunk without ESC cannot start or finish a query.
        if state == .text, !data.contains(0x1b) { return [] }
        var out: [Data] = []
        for byte in data {
            switch state {
            case .text:
                if byte == 0x1b { state = .esc }
            case .esc:
                switch byte {
                case UInt8(ascii: "_"):
                    state = .apc
                case 0x1b:
                    break                          // a new ESC starts over
                default:
                    state = .text
                }
            case .apc:
                switch byte {
                case UInt8(ascii: "G"):
                    control.removeAll(keepingCapacity: true)
                    state = .control
                case 0x1b:
                    state = .esc
                default:
                    state = .skip
                }
            case .control:
                switch byte {
                case 0x1b:
                    state = .stringEsc(back: .control)
                case UInt8(ascii: ";"):
                    state = .payload
                default:
                    if control.count < Self.controlLimit {
                        control.append(byte)
                    } else {
                        state = .skip
                    }
                }
            case .payload:
                if byte == 0x1b { state = .stringEsc(back: .payload) }
            case .skip:
                if byte == 0x1b { state = .stringEsc(back: .skip) }
            case .stringEsc(let back):
                if byte == 0x5c {                  // ESC \ (ST) ends the sequence
                    if back != .skip, let reply = Self.reply(control: control) {
                        out.append(reply)
                    }
                    state = .text
                } else if byte == 0x1b {
                    state = .esc                   // the string was cut short by a new escape
                } else {
                    state = .text                  // a lone ESC aborts the string
                }
            }
        }
        return out
    }

    /// Builds the reply for one graphics command's control data, or nil when
    /// the command is not a query or the protocol calls for silence.
    static func reply(control: [UInt8]) -> Data? {
        var keys: [UInt8: String] = [:]
        for pair in String(decoding: control, as: UTF8.self).split(separator: ",") {
            guard let eq = pair.firstIndex(of: "="), let key = pair[pair.startIndex].asciiValue,
                  pair.index(after: pair.startIndex) == eq
            else { continue }
            keys[key] = String(pair[pair.index(after: eq)...])
        }
        guard keys[UInt8(ascii: "a")] == "q" else { return nil }
        // A reply is addressed by image id or number; without either the
        // terminal cannot answer, exactly like the surface it stands in for.
        let id = UInt32(keys[UInt8(ascii: "i")] ?? "") ?? 0
        let number = UInt32(keys[UInt8(ascii: "I")] ?? "") ?? 0
        guard id > 0 || number > 0 else { return nil }
        let quiet = keys[UInt8(ascii: "q")] ?? "0"
        if quiet == "2" { return nil }

        let message: String
        if let medium = keys[UInt8(ascii: "t")], medium != "d" {
            message = "EINVAL: unsupported medium"
        } else if let format = keys[UInt8(ascii: "f")], !["24", "32", "100"].contains(format) {
            message = "EINVAL: unsupported format"
        } else {
            message = "OK"
        }
        if quiet == "1", message == "OK" { return nil }

        var fields: [String] = []
        if id > 0 { fields.append("i=\(id)") }
        if number > 0 { fields.append("I=\(number)") }
        if let placement = UInt32(keys[UInt8(ascii: "p")] ?? ""), placement > 0 {
            fields.append("p=\(placement)")
        }
        return Data("\u{1b}_G\(fields.joined(separator: ","));\(message)\u{1b}\\".utf8)
    }
}
