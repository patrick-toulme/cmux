/// Parser state for ``RemoteTmuxPassthroughUnwrapper``.
enum RemoteTmuxPassthroughUnwrapperState: Equatable {
    case text                 // normal passthrough
    case esc                  // saw ESC, holding it until we know if it's `ESC P`
    case prefix(matched: Int) // inside `ESC P`, matched this many bytes of `tmux;`
    case payload              // inside the envelope, collapsing doubled ESC
    case payloadEsc           // inside the envelope, saw ESC; maybe the `ESC \` terminator
}
