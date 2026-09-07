/// Parser state for ``RemoteTmuxKittyGraphicsQueryResponder``.
enum RemoteTmuxKittyGraphicsQueryResponderState: Equatable {
    case text            // outside any escape sequence
    case esc             // saw ESC, waiting to learn whether it opens an APC
    case apc             // saw `ESC _`, waiting for the graphics protocol marker `G`
    case control         // inside `ESC _ G`, accumulating control data up to `;` or ST
    case payload         // past `;`, skipping the payload up to ST
    case skip            // inside an APC that is not a graphics command, waiting for ST
    case stringEsc(back: RemoteTmuxKittyGraphicsQueryResponderStringState) // saw ESC inside a string, maybe ST
}

/// Which string state an ESC was seen in, so a non terminating ESC can
/// resume (or abort) the right one.
enum RemoteTmuxKittyGraphicsQueryResponderStringState: Equatable {
    case control
    case payload
    case skip
}
