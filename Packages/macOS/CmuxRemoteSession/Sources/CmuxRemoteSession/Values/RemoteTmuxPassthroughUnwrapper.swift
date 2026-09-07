public import Foundation

/// Unwraps the tmux DCS passthrough envelope (`ESC P tmux; <payload> ESC \`) in a
/// mirrored pane's output stream.
///
/// A program running inside tmux wraps escape sequences meant for the OUTER
/// terminal (kitty graphics, OSC 52, ...) in this envelope, doubling every ESC in
/// the payload. A tmux with `allow-passthrough on` unwraps it and writes the
/// payload to its client tty. A control mode client has no tty, and `%output` is
/// the raw pty copy, so cmux receives the WRAPPED bytes verbatim and the mirror
/// surface ignores them as an unknown DCS. iTerm2's tmux integration unwraps the
/// envelope for the same reason. The mirror surface is the terminal that stores
/// and draws inline images, so the payload must reach it as if a passthrough
/// enabled tmux had written it to a real terminal.
///
/// ESC handling inside the envelope follows tmux's own parser: `ESC` followed by
/// any byte other than `\` yields that byte (so `ESC ESC` is one `ESC` and the
/// payload's own terminator `ESC ESC \` becomes `ESC \`), and `ESC \` ends the
/// envelope. Every other DCS (`ESC P>|`, `ESC P$q`, `ESC P+q`, `ESC P1000p`) is
/// passed through byte identical; only an exact `tmux;` prefix is an envelope.
///
/// Stateful across calls: a `%output` chunk can split the envelope at any byte.
/// Like tmux, an unterminated envelope consumes until ST.
public struct RemoteTmuxPassthroughUnwrapper {
    private static let prefix: [UInt8] = Array("tmux;".utf8)

    private var state: RemoteTmuxPassthroughUnwrapperState = .text

    /// Creates an unwrapper with no buffered escape sequence state.
    public init() {}

    /// Returns `data` with every `ESC P tmux; … ESC \` envelope replaced by its
    /// payload, doubled ESCs collapsed to one.
    public mutating func filter(_ data: Data) -> Data {
        // Hot path: routeOutput calls this for every %output chunk. When we're not
        // mid sequence and the chunk has no ESC, there is nothing to unwrap: return
        // it unchanged and skip the per byte copy + allocation.
        if state == .text, !data.contains(0x1b) { return data }
        // Build into a `[UInt8]` buffer (cheaper than appending to `Data` byte by
        // byte) and wrap it once at the end.
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        for byte in data {
            switch state {
            case .text:
                consumeText(byte, into: &out)
            case .esc:
                if byte == UInt8(ascii: "P") {
                    state = .prefix(matched: 0)   // `ESC P`: maybe an envelope; keep buffering
                } else {
                    out.append(0x1b)              // not a DCS: emit the held ESC …
                    if byte == 0x1b {
                        // another ESC: keep holding it (stay in .esc)
                    } else {
                        out.append(byte)          // … followed by this byte
                        state = .text
                    }
                }
            case .prefix(let matched):
                if byte == Self.prefix[matched] {
                    let next = matched + 1
                    state = next == Self.prefix.count ? .payload : .prefix(matched: next)
                } else {
                    // Some other DCS: replay the buffered `ESC P` + matched prefix bytes
                    // untouched, then treat this byte as ordinary text (an ESC here
                    // may start a new sequence, so it is held like any other ESC).
                    out.append(0x1b)
                    out.append(UInt8(ascii: "P"))
                    out.append(contentsOf: Self.prefix[0..<matched])
                    state = .text
                    consumeText(byte, into: &out)
                }
            case .payload:
                if byte == 0x1b {
                    state = .payloadEsc           // maybe the `ESC \` terminator
                } else {
                    out.append(byte)
                }
            case .payloadEsc:
                if byte == 0x5c {
                    state = .text                 // `ESC \` (ST) ends the envelope
                } else {
                    out.append(byte)              // `ESC X` → `X`, including `ESC ESC` → `ESC`
                    state = .payload
                }
            }
        }
        return Data(out)
    }

    /// Handles one byte in the text state: ESC is held until the next byte tells
    /// whether it opens a DCS; everything else is emitted.
    private mutating func consumeText(_ byte: UInt8, into out: inout [UInt8]) {
        if byte == 0x1b {
            state = .esc
        } else {
            out.append(byte)
        }
    }
}
