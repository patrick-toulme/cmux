import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The row subtitle must say what the agent is on right now. Live symptom:
/// remote Morris rows kept showing a previous turn's answer (or a stray
/// notification that landed on the workspace) while the user had already
/// prompted the agent again, so the line read as old or as another
/// session's.
@Suite("Sidebar workspace subtitle policy")
struct SidebarWorkspaceSubtitlePolicyTests {
    private let notifiedAt = Date(timeIntervalSince1970: 1_000)

    @Test func latestNotificationStandsUntilANewerPromptArrives() {
        // No prompt at all: the notification is the line.
        #expect(SidebarWorkspaceSubtitlePolicy.resolve(
            latestNotificationText: "Stack of CLs: 1. cl/976388734 …",
            latestNotificationCreatedAt: notifiedAt,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil
        ) == "Stack of CLs: 1. cl/976388734 …")
        // The prompt that produced this notification predates it: still the answer.
        #expect(SidebarWorkspaceSubtitlePolicy.resolve(
            latestNotificationText: "Stack of CLs: 1. cl/976388734 …",
            latestNotificationCreatedAt: notifiedAt,
            latestSubmittedMessage: "So what is the stack of CLs",
            latestSubmittedAt: notifiedAt.addingTimeInterval(-30)
        ) == "Stack of CLs: 1. cl/976388734 …")
        // Same instant counts as answered, not superseded.
        #expect(SidebarWorkspaceSubtitlePolicy.resolve(
            latestNotificationText: "done",
            latestNotificationCreatedAt: notifiedAt,
            latestSubmittedMessage: "prompt",
            latestSubmittedAt: notifiedAt
        ) == "done")
    }

    @Test func aPromptNewerThanTheNotificationTakesTheLine() {
        #expect(SidebarWorkspaceSubtitlePolicy.resolve(
            latestNotificationText: "Stack of CLs: 1. cl/976388734 …",
            latestNotificationCreatedAt: notifiedAt,
            latestSubmittedMessage: "  can you refactor all CL descriptions to be in markdown \n",
            latestSubmittedAt: notifiedAt.addingTimeInterval(83)
        ) == "can you refactor all CL descriptions to be in markdown")
        // A stray notification with no timestamp cannot outrank a real prompt.
        #expect(SidebarWorkspaceSubtitlePolicy.resolve(
            latestNotificationText: "Dogfood ready: …",
            latestNotificationCreatedAt: nil,
            latestSubmittedMessage: "fix the tests",
            latestSubmittedAt: notifiedAt
        ) == "fix the tests")
    }

    @Test func aPromptWithNoNotificationYetIsShownAndBlankPromptsAreNot() {
        #expect(SidebarWorkspaceSubtitlePolicy.resolve(
            latestNotificationText: nil,
            latestNotificationCreatedAt: nil,
            latestSubmittedMessage: "run the benchmark",
            latestSubmittedAt: notifiedAt
        ) == "run the benchmark")
        #expect(SidebarWorkspaceSubtitlePolicy.resolve(
            latestNotificationText: "done",
            latestNotificationCreatedAt: notifiedAt,
            latestSubmittedMessage: "   ",
            latestSubmittedAt: notifiedAt.addingTimeInterval(10)
        ) == "done")
        // A prompt preview without a timestamp is not a superseding event.
        #expect(SidebarWorkspaceSubtitlePolicy.resolve(
            latestNotificationText: "done",
            latestNotificationCreatedAt: notifiedAt,
            latestSubmittedMessage: "prompt",
            latestSubmittedAt: nil
        ) == "done")
        #expect(SidebarWorkspaceSubtitlePolicy.resolve(
            latestNotificationText: nil,
            latestNotificationCreatedAt: nil,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil
        ) == nil)
    }
}
