import Foundation
import Testing
@testable import CmuxRemoteSession

/// Tests the kitty graphics support query responder used on mirrored `%output`.
/// The pane's owning terminal core (tmux) never answers `ESC _ G ... a=q ... ESC \`
/// and the mirror surface's own reply is suppressed, so the responder must produce
/// the protocol reply a program waits for, survive chunk splits, and stay silent
/// exactly where the protocol says so.
@Suite struct RemoteTmuxKittyGraphicsQueryResponderTests {
    private let ESC = "\u{1b}"
    private let ST = "\u{1b}\\"

    private func replies(_ chunks: [String]) -> [String] {
        var responder = RemoteTmuxKittyGraphicsQueryResponder()
        return chunks.flatMap { chunk in
            responder.replies(for: Data(chunk.utf8)).map { String(decoding: $0, as: UTF8.self) }
        }
    }
    private func replies(_ s: String) -> [String] { replies([s]) }

    /// The support query a TUI sends before its first image (after the tmux
    /// envelope has been unwrapped).
    private var query: String { "\(ESC)_Gi=31337,s=1,v=1,a=q,t=d,f=24;AAAA\(ST)" }

    @Test func answersASupportQueryWithOkAndTheImageId() {
        #expect(replies(query) == ["\(ESC)_Gi=31337;OK\(ST)"])
    }

    @Test func answersInStreamOrderAndLeavesSurroundingBytesAlone() {
        let stream = "text\(ESC)[31m\(query)more\(ESC)_Gi=5,a=q\(ST)\(ESC)[c"
        #expect(replies(stream) == ["\(ESC)_Gi=31337;OK\(ST)", "\(ESC)_Gi=5;OK\(ST)"])
    }

    @Test func echoesImageNumberAndPlacementId() {
        #expect(replies("\(ESC)_Ga=q,I=7,p=3;AAAA\(ST)") == ["\(ESC)_GI=7,p=3;OK\(ST)"])
        #expect(replies("\(ESC)_Ga=q,i=2,I=7\(ST)") == ["\(ESC)_Gi=2,I=7;OK\(ST)"])
    }

    @Test func staysSilentWithoutAnImageIdOrNumber() {
        // The reply is addressed by id; the protocol has nothing to send back.
        #expect(replies("\(ESC)_Ga=q,s=1,v=1;AAAA\(ST)").isEmpty)
        #expect(replies("\(ESC)_Ga=q,i=0;AAAA\(ST)").isEmpty)
    }

    @Test func honorsTheQuietKey() {
        #expect(replies("\(ESC)_Gi=1,a=q,q=2;AAAA\(ST)").isEmpty)
        #expect(replies("\(ESC)_Gi=1,a=q,q=1;AAAA\(ST)").isEmpty)
        // q=1 still reports failures.
        #expect(replies("\(ESC)_Gi=1,a=q,q=1,t=f;/tmp/x\(ST)") == ["\(ESC)_Gi=1;EINVAL: unsupported medium\(ST)"])
    }

    @Test func rejectsMediumsAndFormatsTheMirrorCannotServe() {
        // File and shared memory paths name the program's host, not ours.
        #expect(replies("\(ESC)_Gi=1,a=q,t=f;L3RtcC94\(ST)") == ["\(ESC)_Gi=1;EINVAL: unsupported medium\(ST)"])
        #expect(replies("\(ESC)_Gi=1,a=q,t=s;bmFtZQ\(ST)") == ["\(ESC)_Gi=1;EINVAL: unsupported medium\(ST)"])
        #expect(replies("\(ESC)_Gi=1,a=q,f=8;AAAA\(ST)") == ["\(ESC)_Gi=1;EINVAL: unsupported format\(ST)"])
        // Direct transmission in every format the surface decodes, with and
        // without compression.
        for format in ["24", "32", "100"] {
            #expect(replies("\(ESC)_Gi=1,a=q,t=d,f=\(format),o=z;AAAA\(ST)") == ["\(ESC)_Gi=1;OK\(ST)"])
        }
        #expect(replies("\(ESC)_Gi=1,a=q;AAAA\(ST)") == ["\(ESC)_Gi=1;OK\(ST)"])
    }

    @Test func ignoresOtherGraphicsCommandsAndOtherApcs() {
        // Transmit, put and delete are not acknowledged here.
        #expect(replies("\(ESC)_Gi=1,a=t,f=100,q=2;iVBOR\(ST)").isEmpty)
        #expect(replies("\(ESC)_Gi=1,a=t,f=100;iVBOR\(ST)").isEmpty)
        #expect(replies("\(ESC)_Ga=p,i=1,U=1,c=10,r=4\(ST)").isEmpty)
        #expect(replies("\(ESC)_Ga=d,d=I,i=1\(ST)").isEmpty)
        // A non graphics APC, and a screen title, are not queries either.
        #expect(replies("\(ESC)_Xi=1,a=q\(ST)\(ESC)ktitle\(ST)").isEmpty)
        // Plain escapes never trigger a reply.
        #expect(replies("\(ESC)[?1049h\(ESC)]0;title\u{07}\(ESC)P>|tmux 3.6b\(ST)").isEmpty)
    }

    @Test func survivesChunkSplitsAtEveryBoundary() {
        let full = "X\(query)Y"
        let bytes = Array(full.utf8)
        for cut in 1..<bytes.count {
            var responder = RemoteTmuxKittyGraphicsQueryResponder()
            var out = responder.replies(for: Data(bytes[0..<cut]))
            out.append(contentsOf: responder.replies(for: Data(bytes[cut...])))
            #expect(out == [Data("\(ESC)_Gi=31337;OK\(ST)".utf8)], "split at \(cut)")
        }
    }

    @Test func aStrayEscAbortsTheSequenceWithoutAReply() {
        // ESC followed by anything but `\` ends the string state; the query is
        // never completed and the bytes that follow are ordinary text.
        #expect(replies("\(ESC)_Gi=1,a=q\(ESC)[0m\(ST)").isEmpty)
        // A new ESC inside the string starts over, so a query right after it
        // still counts.
        #expect(replies("\(ESC)_Gi=1,a=q\(ESC)\(query)") == ["\(ESC)_Gi=31337;OK\(ST)"])
    }

    @Test func boundsRunawayControlData() {
        let long = String(repeating: "k=1,", count: RemoteTmuxKittyGraphicsQueryResponder.controlLimit)
        #expect(replies("\(ESC)_Gi=1,a=q,\(long)\(ST)").isEmpty)
        // And recovers for the next sequence.
        #expect(replies(["\(ESC)_Gi=1,a=q,\(long)\(ST)", query]) == ["\(ESC)_Gi=31337;OK\(ST)"])
    }
}
