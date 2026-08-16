import CmuxSettings
import Foundation

/// Pure ordering engine for "sort by active sessions".
///
/// Consumes an immutable projection of the workspace strip and produces the
/// desired id order for a `WorkspaceActivitySortMode`. The live coordinator
/// feeds it real attention state; tests feed it fixtures. Guarantees:
/// - **Pin safety**: pinned rows never move; unpinned rows sort around them.
/// - **Group blocks**: a workspace group (anchor + members) moves as one
///   unit, ranked by its most urgent member, keeping its internal order.
/// - **Stability**: equal ranks keep their current relative order, so the
///   strip cannot oscillate while states are steady and applying the result
///   twice is a no-op.
/// - **Section scoping** (`.withinSections`): units sort only inside their
///   contiguous host run (machine section or local run); nothing crosses a
///   section boundary, so the sidebar's section topology is preserved.
/// - **Individual float** (`.global`): units sort across the whole sidebar,
///   so an active session rises to the top WITHOUT dragging its machine's
///   idle siblings along; they stay below in their own run. The sidebar
///   renders a header for every contiguous run of a section, so both the
///   floated session and the parked remainder keep their machine header.
///   (Deliberate, per dogfood preference: a section-cohesive variant that
///   moved whole machines was tried and rejected.)
enum WorkspaceActivitySorter {
    /// One workspace row's sort-relevant projection, in current strip order.
    struct Item {
        let id: UUID
        let isPinned: Bool
        /// Workspace group membership; members share their block's fate.
        let groupId: UUID?
        /// Machine section key (`nil` = local workspace).
        let hostKey: String?
        /// Attention rank (`SidebarAgentAttentionPhase.inboxRank`): lower is
        /// more urgent. `nil` = resting, sorts below every ranked row.
        let attentionRank: Int?

        init(
            id: UUID,
            isPinned: Bool = false,
            groupId: UUID? = nil,
            hostKey: String? = nil,
            attentionRank: Int? = nil
        ) {
            self.id = id
            self.isPinned = isPinned
            self.groupId = groupId
            self.hostKey = hostKey
            self.attentionRank = attentionRank
        }
    }

    /// A group block or an ungrouped singleton; the atomic reorder unit.
    private struct Unit {
        let items: [Item]
        let index: Int

        var isPinned: Bool { items.contains(where: \.isPinned) }
        var hostKey: String? { items[0].hostKey }
        var rank: Int { items.compactMap(\.attentionRank).min() ?? Int.max }
    }

    /// The desired workspace-id order for `mode`. `.off` returns the current
    /// order unchanged.
    static func desiredOrder(items: [Item], mode: WorkspaceActivitySortMode) -> [UUID] {
        guard mode != .off, items.count > 1 else { return items.map(\.id) }
        let units = makeUnits(items: items)
        let sortedUnits: [Unit]
        switch mode {
        case .off:
            return items.map(\.id)
        case .withinSections:
            sortedUnits = hostRuns(units: units).flatMap(sortWithinFixedPins)
        case .global:
            sortedUnits = sortWithinFixedPins(units)
        }
        return sortedUnits.flatMap { $0.items.map(\.id) }
    }

    /// Groups contiguous same-group items into blocks (group contiguity is a
    /// model invariant; a split group degrades to per-run blocks safely).
    private static func makeUnits(items: [Item]) -> [Unit] {
        var units: [Unit] = []
        var current: [Item] = []
        for item in items {
            if let last = current.last, let groupId = last.groupId, groupId == item.groupId {
                current.append(item)
                continue
            }
            if !current.isEmpty {
                units.append(Unit(items: current, index: units.count))
            }
            current = [item]
        }
        if !current.isEmpty {
            units.append(Unit(items: current, index: units.count))
        }
        return units
    }

    /// Splits the unit sequence into contiguous host runs (machine sections
    /// and local runs), the same topology the sidebar renders sections from.
    private static func hostRuns(units: [Unit]) -> [[Unit]] {
        var runs: [[Unit]] = []
        for unit in units {
            if let last = runs.last?.last, last.hostKey == unit.hostKey {
                runs[runs.count - 1].append(unit)
            } else {
                runs.append([unit])
            }
        }
        return runs
    }

    /// Stable-sorts the unpinned units of one region by (rank, current
    /// position); pinned units keep their exact slots.
    private static func sortWithinFixedPins(_ units: [Unit]) -> [Unit] {
        let movable = units.filter { !$0.isPinned }
        guard movable.count > 1 else { return units }
        let sortedMovable = movable.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
        var movableIterator = sortedMovable.makeIterator()
        return units.map { unit in
            unit.isPinned ? unit : movableIterator.next() ?? unit
        }
    }
}
