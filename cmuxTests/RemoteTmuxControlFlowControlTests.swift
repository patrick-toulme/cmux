import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Flow-control protocol coverage: `%pause` / `%continue` / `%extended-output`
/// parse as notifications everywhere — INCLUDING inside `%begin` command
/// blocks, where tmux interleaves them from the pane-output path. The
/// regression this pins: a capture-pane seed's own pause ack ("%pause %N")
/// was swallowed as block content and painted into the very pane being
/// seeded, freezing mirrors at a literal "%pause %N" frame after wake.
@Suite struct RemoteTmuxControlFlowControlTests {
    private func feedLines(_ lines: [String]) -> [RemoteTmuxControlMessage] {
        var parser = RemoteTmuxControlStreamParser()
        var messages: [RemoteTmuxControlMessage] = []
        for line in lines {
            messages.append(contentsOf: parser.feed(Data((line + "\r\n").utf8)))
        }
        return messages
    }

    @Test func pauseAndContinueParseAsNotifications() {
        #expect(feedLines(["%pause %3"]) == [.paused(paneId: 3)])
        #expect(feedLines(["%continue %12"]) == [.continued(paneId: 12)])
    }

    @Test func pauseInsideCommandBlockIsANotificationNotContent() {
        let messages = feedLines([
            "%begin 1700000000 7 1",
            "captured row one",
            "%pause %3",
            "captured row two",
            "%end 1700000000 7 1",
        ])
        #expect(messages == [
            .paused(paneId: 3),
            .commandResult(
                commandNumber: 7,
                lines: ["captured row one", "captured row two"],
                isError: false
            ),
        ])
    }

    @Test func outputInsideCommandBlockRoutesToItsPane() {
        let messages = feedLines([
            "%begin 1700000000 4 1",
            "captured row",
            "%output %9 hi",
            "%end 1700000000 4 1",
        ])
        #expect(messages == [
            .output(paneId: 9, data: Data("hi".utf8)),
            .commandResult(commandNumber: 4, lines: ["captured row"], isError: false),
        ])
    }

    @Test func extendedOutputParsesAsPaneOutput() {
        #expect(feedLines([#"%extended-output %5 101 : hi\012there"#]) == [
            .output(paneId: 5, data: Data("hi\nthere".utf8))
        ])
    }

    @Test func extendedOutputWithExtraMetadataWordsParses() {
        #expect(feedLines(["%extended-output %5 101 0 1 : data"]) == [
            .output(paneId: 5, data: Data("data".utf8))
        ])
    }

    @Test func endLookalikeContentStillStaysContent() {
        let messages = feedLines([
            "%begin 1700000000 7 1",
            "%end 1700000000 9 1",
            "%end 1700000000 7 1",
        ])
        #expect(messages == [
            .commandResult(
                commandNumber: 7,
                lines: ["%end 1700000000 9 1"],
                isError: false
            )
        ])
    }

    @Test func pauseLookalikeWithTrailingTextStaysContent() {
        let messages = feedLines([
            "%begin 1700000000 7 1",
            "%pause %3 trailing words",
            "%end 1700000000 7 1",
        ])
        #expect(messages == [
            .commandResult(
                commandNumber: 7,
                lines: ["%pause %3 trailing words"],
                isError: false
            )
        ])
    }
}
