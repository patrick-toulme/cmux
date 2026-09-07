import Foundation
import Testing
@testable import CmuxRemoteSession

/// Tests the tmux DCS passthrough unwrapper used on mirrored `%output`.
/// A program inside tmux wraps escapes meant for the outer terminal (kitty
/// graphics queries, image transfers) as `ESC P tmux; <payload with doubled ESC>
/// ESC \`. A control mode client receives the wrapped bytes verbatim, so the
/// unwrapper must yield exactly what a passthrough enabled tmux would write to a
/// real terminal, survive chunk splits, and leave every other DCS and escape byte
/// identical.
///
/// Assertions compare raw `Data` (not decoded strings): the unwrapper transforms a
/// byte stream, and `String(decoding:as:)` silently replaces invalid UTF-8, which
/// would mask a byte corruption regression instead of failing.
@Suite struct RemoteTmuxPassthroughUnwrapperTests {
    private func run(_ chunks: [String]) -> Data {
        var u = RemoteTmuxPassthroughUnwrapper()
        var out = Data()
        for c in chunks { out.append(u.filter(Data(c.utf8))) }
        return out
    }
    private func run(_ s: String) -> Data { run([s]) }

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private let ESC = "\u{1b}"
    private let ST = "\u{1b}\\"

    /// The kitty graphics support query as a TUI inside tmux emits it.
    private var wrappedKittyQuery: String {
        "\(ESC)Ptmux;\(ESC)\(ESC)_Gi=4102,s=1,v=1,a=q,t=d,f=24;AAAA\(ESC)\(ESC)\\\(ST)"
    }
    private var kittyQuery: String {
        "\(ESC)_Gi=4102,s=1,v=1,a=q,t=d,f=24;AAAA\(ST)"
    }

    @Test func unwrapsWrappedKittyQueryToExactInnerApc() {
        #expect(run(wrappedKittyQuery) == bytes(kittyQuery))
    }

    @Test func preservesSurroundingTextByteIdentical() {
        let input = "before\r\n\(wrappedKittyQuery)after\(ESC)[0m\r\n"
        #expect(run(input) == bytes("before\r\n\(kittyQuery)after\(ESC)[0m\r\n"))
    }

    @Test func unwrapsTwoEnvelopesBackToBack() {
        let second = "\(ESC)Ptmux;\(ESC)\(ESC)_Ga=d,d=A\(ESC)\(ESC)\\\(ST)"
        #expect(
            run(wrappedKittyQuery + second + "Z")
                == bytes(kittyQuery + "\(ESC)_Ga=d,d=A\(ST)Z")
        )
    }

    @Test func doubledEscInsidePayloadBecomesOneEsc() {
        // A payload may carry several sequences; every `ESC ESC` is one ESC and only
        // the envelope's own `ESC \` is dropped.
        let input = "\(ESC)Ptmux;\(ESC)\(ESC)[31mred\(ESC)\(ESC)[0m\(ST)"
        #expect(run(input) == bytes("\(ESC)[31mred\(ESC)[0m"))
    }

    @Test func escFollowedByOtherByteInsidePayloadDropsOnlyTheEsc() {
        // tmux's dcs_escape rule: ESC + X yields X for any X other than `\`.
        #expect(run("\(ESC)Ptmux;a\(ESC)bc\(ST)") == bytes("abc"))
    }

    @Test(arguments: [
        "\u{1b}P>|tmux 3.6b\u{1b}\\",                   // XTVERSION reply
        "\u{1b}P1$r0 q\u{1b}\\",                        // DECRQSS reply
        "\u{1b}P+q544e\u{1b}\\",                        // XTGETTCAP
        "\u{1b}P1000p%begin 1 1 0\r\n%end 1 1 0\r\n",   // tmux control mode banner
        "\u{1b}P\u{1b}\\",                              // empty DCS
    ])
    func passesOtherDcsThroughUnchanged(_ input: String) {
        #expect(run("x" + input + "y") == bytes("x" + input + "y"))
    }

    @Test func partialPrefixMismatchPassesThroughUnchanged() {
        let input = "\(ESC)Ptmuy;\(ESC)\(ESC)_G\(ST)tail"
        #expect(run(input) == bytes(input))
        // A mismatch on the very last prefix byte replays everything buffered.
        let almost = "\(ESC)Ptmux:\(ST)"
        #expect(run(almost) == bytes(almost))
    }

    @Test func mismatchOnEscStartsANewSequence() {
        // `ESC P t` cut short by a genuine envelope: the truncated DCS is replayed
        // unchanged and the envelope that follows is still unwrapped.
        #expect(run("\(ESC)Pt" + wrappedKittyQuery) == bytes("\(ESC)Pt" + kittyQuery))
    }

    @Test func preservesCsiOscAndPlainText() {
        let input = "\(ESC)[32mgreen\(ESC)[0m\(ESC)]0;title\u{07}\(ESC)[2J\(ESC)[Hplain\r\n"
        #expect(run(input) == bytes(input))
        #expect(run("echo \"ej\"\r\nej\r\n") == bytes("echo \"ej\"\r\nej\r\n"))
    }

    @Test func preservesEscFollowedByNonP() {
        #expect(run("\(ESC)\\done") == bytes("\(ESC)\\done"))
        #expect(run("\(ESC)kname\(ESC)\\") == bytes("\(ESC)kname\(ESC)\\"))
        // Consecutive ESCs stay held one at a time and come out in order.
        #expect(run("\(ESC)\(ESC)[0m") == bytes("\(ESC)\(ESC)[0m"))
    }

    @Test func holdsTrailingEscUntilTheNextChunkDecides() {
        // A chunk ending in `ESC P t` cannot be classified yet; the bytes surface
        // once the next chunk shows it was not an envelope.
        var u = RemoteTmuxPassthroughUnwrapper()
        #expect(u.filter(Data("ab\(ESC)Pt".utf8)) == bytes("ab"))
        #expect(u.filter(Data("x".utf8)) == bytes("\(ESC)Ptx"))
    }

    @Test func survivesChunkSplitsAtEveryBoundary() {
        let full = "X" + wrappedKittyQuery + "Y\(ESC)P>|tmux 3.6b\(ST)Z"
        let expected = bytes("X" + kittyQuery + "Y\(ESC)P>|tmux 3.6b\(ST)Z")
        let allBytes = Array(full.utf8)
        // Split the stream after each byte and confirm the result never changes.
        for cut in 1..<allBytes.count {
            var u = RemoteTmuxPassthroughUnwrapper()
            var out = Data()
            out.append(u.filter(Data(allBytes[0..<cut])))
            out.append(u.filter(Data(allBytes[cut...])))
            #expect(out == expected, "split at \(cut)")
        }
    }

    @Test func unterminatedEnvelopeConsumesToChunkEndAndResumes() {
        // The first chunk ends inside the payload with a dangling doubled ESC; the
        // second chunk finishes the payload and the envelope, then continues as text.
        let first = "pre\(ESC)Ptmux;\(ESC)\(ESC)_Gi=1,a=q;\(ESC)"
        let second = "\(ESC)\\\(ST)post"
        #expect(run([first, second]) == bytes("pre\(ESC)_Gi=1,a=q;\(ESC)\\post"))
        // With no ST at all the envelope keeps consuming, exactly like tmux.
        #expect(run(["\(ESC)Ptmux;abc", "def"]) == bytes("abcdef"))
    }

    @Test func splitInsideThePrefixReplaysOnMismatch() {
        // `ESC P tm` followed by a continuation that is not an envelope must come
        // out untouched.
        #expect(run(["\(ESC)Ptm", "ok\(ST)"]) == bytes("\(ESC)Ptmok\(ST)"))
    }
}
