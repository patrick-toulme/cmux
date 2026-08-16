import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-order contract for the "sort by active sessions" engine: pin
/// safety, group blocks, stability, and section scoping. Ranks mirror
/// `SidebarAgentAttentionPhase.inboxRank` (approval 0, input 1, working 2,
/// unseen-done 3, resting nil).
@Suite struct WorkspaceActivitySortTests {
    private static let approval = 0
    private static let input = 1
    private static let working = 2
    private static let done = 3

    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    @Test func offModeReturnsIdentity() {
        let rowIds = ids(3)
        let items = [
            WorkspaceActivitySorter.Item(id: rowIds[0]),
            WorkspaceActivitySorter.Item(id: rowIds[1], attentionRank: Self.approval),
            WorkspaceActivitySorter.Item(id: rowIds[2], attentionRank: Self.working),
        ]
        #expect(WorkspaceActivitySorter.desiredOrder(items: items, mode: .off) == rowIds)
    }

    @Test func globalModeRanksAttentionAboveResting() {
        let rowIds = ids(5)
        let items = [
            WorkspaceActivitySorter.Item(id: rowIds[0]),
            WorkspaceActivitySorter.Item(id: rowIds[1], attentionRank: Self.done),
            WorkspaceActivitySorter.Item(id: rowIds[2], attentionRank: Self.working),
            WorkspaceActivitySorter.Item(id: rowIds[3], attentionRank: Self.input),
            WorkspaceActivitySorter.Item(id: rowIds[4], attentionRank: Self.approval),
        ]
        #expect(
            WorkspaceActivitySorter.desiredOrder(items: items, mode: .global)
                == [rowIds[4], rowIds[3], rowIds[2], rowIds[1], rowIds[0]]
        )
    }

    @Test func globalModeIsStableAmongEqualRanks() {
        let rowIds = ids(4)
        let items = [
            WorkspaceActivitySorter.Item(id: rowIds[0], attentionRank: Self.working),
            WorkspaceActivitySorter.Item(id: rowIds[1]),
            WorkspaceActivitySorter.Item(id: rowIds[2], attentionRank: Self.working),
            WorkspaceActivitySorter.Item(id: rowIds[3]),
        ]
        #expect(
            WorkspaceActivitySorter.desiredOrder(items: items, mode: .global)
                == [rowIds[0], rowIds[2], rowIds[1], rowIds[3]]
        )
    }

    @Test func pinnedRowsKeepTheirSlots() {
        let rowIds = ids(4)
        let items = [
            WorkspaceActivitySorter.Item(id: rowIds[0], isPinned: true),
            WorkspaceActivitySorter.Item(id: rowIds[1], isPinned: true, attentionRank: Self.done),
            WorkspaceActivitySorter.Item(id: rowIds[2]),
            WorkspaceActivitySorter.Item(id: rowIds[3], attentionRank: Self.approval),
        ]
        // Pinned rows (even a ranked one) hold slots 0/1; the unpinned pair
        // sorts among itself.
        #expect(
            WorkspaceActivitySorter.desiredOrder(items: items, mode: .global)
                == [rowIds[0], rowIds[1], rowIds[3], rowIds[2]]
        )
    }

    @Test func withinSectionsSortsInsideEachHostRun() {
        let rowIds = ids(6)
        let items = [
            WorkspaceActivitySorter.Item(id: rowIds[0]),
            WorkspaceActivitySorter.Item(id: rowIds[1], attentionRank: Self.working),
            WorkspaceActivitySorter.Item(id: rowIds[2], hostKey: "xxl5"),
            WorkspaceActivitySorter.Item(id: rowIds[3], hostKey: "xxl5", attentionRank: Self.approval),
            WorkspaceActivitySorter.Item(id: rowIds[4], hostKey: "xxl6"),
            WorkspaceActivitySorter.Item(id: rowIds[5], hostKey: "xxl6", attentionRank: Self.working),
        ]
        // Each run sorts internally; no row crosses a section boundary.
        #expect(
            WorkspaceActivitySorter.desiredOrder(items: items, mode: .withinSections)
                == [rowIds[1], rowIds[0], rowIds[3], rowIds[2], rowIds[5], rowIds[4]]
        )
    }

    @Test func withinSectionsKeepsSplitRunsSeparate() {
        let rowIds = ids(4)
        let items = [
            WorkspaceActivitySorter.Item(id: rowIds[0], hostKey: "xxl5"),
            WorkspaceActivitySorter.Item(id: rowIds[1]),
            WorkspaceActivitySorter.Item(id: rowIds[2], hostKey: "xxl5"),
            WorkspaceActivitySorter.Item(id: rowIds[3], hostKey: "xxl5", attentionRank: Self.approval),
        ]
        // The approval session sorts to the top of its OWN run (the second
        // xxl5 run); it does not join the first xxl5 run.
        #expect(
            WorkspaceActivitySorter.desiredOrder(items: items, mode: .withinSections)
                == [rowIds[0], rowIds[1], rowIds[3], rowIds[2]]
        )
    }

    @Test func globalModeMovesWholeSectionsByMostUrgentMember() {
        let rowIds = ids(4)
        let items = [
            WorkspaceActivitySorter.Item(id: rowIds[0], hostKey: "xxl5"),
            WorkspaceActivitySorter.Item(id: rowIds[1], hostKey: "xxl5"),
            WorkspaceActivitySorter.Item(id: rowIds[2], hostKey: "xxl6", attentionRank: Self.working),
            WorkspaceActivitySorter.Item(id: rowIds[3], hostKey: "xxl6"),
        ]
        // The active host's WHOLE section floats; sessions sort within it.
        // (Interleaving individual sessions split sections and rendered a
        // duplicate header per run.)
        #expect(
            WorkspaceActivitySorter.desiredOrder(items: items, mode: .global)
                == [rowIds[2], rowIds[3], rowIds[0], rowIds[1]]
        )
    }

    @Test func globalModeHealsASectionSplitByAnEarlierSort() {
        // The live repro: one xxl5 session's activity had floated it above
        // the local workspace, leaving [xxl5, local, xxl5, xxl5] and TWO
        // "xxl5" headers. Re-sorting must merge the host back into one
        // contiguous section (first-appearance position, most urgent first)
        // instead of preserving the split.
        let rowIds = ids(4)
        let items = [
            WorkspaceActivitySorter.Item(id: rowIds[0], hostKey: "xxl5", attentionRank: Self.done),
            WorkspaceActivitySorter.Item(id: rowIds[1]),
            WorkspaceActivitySorter.Item(id: rowIds[2], hostKey: "xxl5"),
            WorkspaceActivitySorter.Item(id: rowIds[3], hostKey: "xxl5", attentionRank: Self.approval),
        ]
        #expect(
            WorkspaceActivitySorter.desiredOrder(items: items, mode: .global)
                == [rowIds[3], rowIds[0], rowIds[2], rowIds[1]]
        )
    }

    @Test func groupBlocksMoveTogetherRankedByMostUrgentMember() {
        let rowIds = ids(5)
        let groupId = UUID()
        let items = [
            WorkspaceActivitySorter.Item(id: rowIds[0]),
            WorkspaceActivitySorter.Item(id: rowIds[1], groupId: groupId),
            WorkspaceActivitySorter.Item(id: rowIds[2], groupId: groupId, attentionRank: Self.input),
            WorkspaceActivitySorter.Item(id: rowIds[3], groupId: groupId),
            WorkspaceActivitySorter.Item(id: rowIds[4], attentionRank: Self.working),
        ]
        // The group hoists as one block (rank = input, its most urgent
        // member), keeping internal order; the working singleton follows.
        #expect(
            WorkspaceActivitySorter.desiredOrder(items: items, mode: .global)
                == [rowIds[1], rowIds[2], rowIds[3], rowIds[4], rowIds[0]]
        )
    }

    @Test func applyingTheOrderTwiceIsANoOp() {
        let rowIds = ids(5)
        let items = [
            WorkspaceActivitySorter.Item(id: rowIds[0]),
            WorkspaceActivitySorter.Item(id: rowIds[1], attentionRank: Self.working),
            WorkspaceActivitySorter.Item(id: rowIds[2], hostKey: "xxl5"),
            WorkspaceActivitySorter.Item(id: rowIds[3], hostKey: "xxl5", attentionRank: Self.done),
            WorkspaceActivitySorter.Item(id: rowIds[4], attentionRank: Self.approval),
        ]
        for mode in [WorkspaceActivitySortMode.withinSections, .global] {
            let once = WorkspaceActivitySorter.desiredOrder(items: items, mode: mode)
            let itemsById = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            let reordered = once.compactMap { itemsById[$0] }
            #expect(WorkspaceActivitySorter.desiredOrder(items: reordered, mode: mode) == once)
        }
    }

    @Test func attentionPhaseRanksMatchSorterExpectations() {
        // The sorter consumes `inboxRank`; pin the phase→rank contract so a
        // future inbox re-rank cannot silently invert session sorting.
        #expect(SidebarAgentAttentionPhase.pendingApproval.inboxRank == Self.approval)
        #expect(SidebarAgentAttentionPhase.awaitingInput.inboxRank == Self.input)
        #expect(SidebarAgentAttentionPhase.working.inboxRank == Self.working)
        #expect(SidebarAgentAttentionPhase.unreadCompleted.inboxRank == Self.done)
    }
}
