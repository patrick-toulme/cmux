import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
/// Sidebar projection coverage for per-machine remote tmux sections:
/// `cmux ssh-tmux xxl xxl2` mirrors several machines into ONE window, and the
/// sidebar must render every machine's tmux sessions under that machine's own
/// collapsible section header.
@MainActor
@Suite("Remote tmux host section rendering", .serialized)
struct RemoteTmuxHostSectionRenderTests {

    @Test func mirrorsRenderUnderPerMachineSections() throws {
        let harness = try SectionHarness()
        defer { harness.tearDown() }
        let local = harness.local
        let xxlSession1 = harness.addMirror(hostKey: "hash-xxl", label: "xxl")
        let xxlSession2 = harness.addMirror(hostKey: "hash-xxl", label: "xxl")
        let xxl2Session = harness.addMirror(hostKey: "hash-xxl2", label: "xxl2")

        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: harness.manager.tabs,
            groupsById: [:],
            remoteHostKeyByWorkspaceId: harness.hostKeyByWorkspaceId(),
            collapsedRemoteHostKeys: []
        )

        let itemIds = items.map { $0.id }
        #expect(itemIds == [
            .reauthenticate(),
            Self.localMacHeaderId(),
            .workspace(local.id),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl")),
            .workspace(xxlSession1.id),
            .workspace(xxlSession2.id),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl2")),
            .workspace(xxl2Session.id),
        ])
        // The header nominates the machine's first mirror as its representative
        // row (scroll anchoring), and numbered navigation skips headers.
        guard case .remoteHostSection(let hostKey, let firstWorkspaceId, _) = items[3] else {
            Issue.record("expected a host section at index 3")
            return
        }
        #expect(hostKey == "hash-xxl")
        #expect(firstWorkspaceId == xxlSession1.id)
        #expect(SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: items) == [
            local.id, xxlSession1.id, xxlSession2.id, xxl2Session.id,
        ])
    }

    @Test func collapsedMachineHidesItsSessionsAndTheirNumbering() throws {
        let harness = try SectionHarness()
        defer { harness.tearDown() }
        let local = harness.local
        _ = harness.addMirror(hostKey: "hash-xxl", label: "xxl")
        _ = harness.addMirror(hostKey: "hash-xxl", label: "xxl")
        let xxl2Session = harness.addMirror(hostKey: "hash-xxl2", label: "xxl2")

        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: harness.manager.tabs,
            groupsById: [:],
            remoteHostKeyByWorkspaceId: harness.hostKeyByWorkspaceId(),
            collapsedRemoteHostKeys: ["hash-xxl"]
        )

        let itemIds = items.map { $0.id }
        #expect(itemIds == [
            .reauthenticate(),
            Self.localMacHeaderId(),
            .workspace(local.id),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl")),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl2")),
            .workspace(xxl2Session.id),
        ])
        // Hidden sessions lose their ⌘number, exactly like collapsed groups.
        #expect(SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: items) == [
            local.id, xxl2Session.id,
        ])
    }

    @Test func splitRunsEachRenderAHeaderSharingOneCollapseDecision() throws {
        // Sidebar reorders (drag, sort-by-recent, attention moves) can split
        // a machine's sessions into several runs. EVERY run renders its own
        // header — the regression: only the first run kept the header, so a
        // session moved to the top took "cloudtop" with it and the machine's
        // remaining sessions floated under the previous section — and every
        // run honors the ONE collapse decision.
        let harness = try SectionHarness()
        defer { harness.tearDown() }
        let xxlSession1 = harness.addMirror(hostKey: "hash-xxl", label: "xxl")
        let xxl2Session = harness.addMirror(hostKey: "hash-xxl2", label: "xxl2")
        let xxlSession2 = harness.addMirror(hostKey: "hash-xxl", label: "xxl")

        let expanded = SidebarWorkspaceRenderItem.renderItems(
            tabs: harness.manager.tabs,
            groupsById: [:],
            remoteHostKeyByWorkspaceId: harness.hostKeyByWorkspaceId(),
            collapsedRemoteHostKeys: []
        )
        let xxlRun0HeaderId = SidebarWorkspaceRenderItemID.remoteHostSection(
            SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl")
        )
        let xxlRun1HeaderId = SidebarWorkspaceRenderItemID.remoteHostSection(
            SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl", runIndex: 1)
        )
        #expect(expanded.filter { $0.id == xxlRun0HeaderId }.count == 1)
        #expect(expanded.filter { $0.id == xxlRun1HeaderId }.count == 1)
        // The second run's header sits directly above its session, so the
        // session can never read as one of the previous machine's.
        let run1HeaderIndex = try #require(expanded.firstIndex { $0.id == xxlRun1HeaderId })
        #expect(expanded[expanded.index(after: run1HeaderIndex)].id == .workspace(xxlSession2.id))
        #expect(SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: expanded).contains(xxlSession2.id))

        let collapsed = SidebarWorkspaceRenderItem.renderItems(
            tabs: harness.manager.tabs,
            groupsById: [:],
            remoteHostKeyByWorkspaceId: harness.hostKeyByWorkspaceId(),
            collapsedRemoteHostKeys: ["hash-xxl"]
        )
        let visible = SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: collapsed)
        #expect(!visible.contains(xxlSession1.id))
        #expect(!visible.contains(xxlSession2.id))
        #expect(visible.contains(xxl2Session.id))
        #expect(collapsed.filter { $0.id == xxlRun0HeaderId }.count == 1)
        #expect(collapsed.filter { $0.id == xxlRun1HeaderId }.count == 1)
    }

    @Test func localWorkspacesBetweenMachinesGetALocalMacSection() throws {
        // A local workspace moved between machine runs must render under its
        // own "Local Mac" header — never as one of a machine's sessions. A
        // purely local sidebar (no machines) keeps its headerless list.
        let harness = try SectionHarness()
        defer { harness.tearDown() }
        let xxlSession = harness.addMirror(hostKey: "hash-xxl", label: "xxl")
        let strayLocal = harness.manager.addTab(select: false)
        let xxl2Session = harness.addMirror(hostKey: "hash-xxl2", label: "xxl2")

        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: harness.manager.tabs,
            groupsById: [:],
            remoteHostKeyByWorkspaceId: harness.hostKeyByWorkspaceId(),
            collapsedRemoteHostKeys: []
        )
        // Mirror placement clusters machines together, so the stray local
        // lands after them — in ITS OWN second "Local Mac" run, never under
        // the last machine's header.
        #expect(items.map { $0.id } == [
            .reauthenticate(),
            Self.localMacHeaderId(),
            .workspace(harness.local.id),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl")),
            .workspace(xxlSession.id),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl2")),
            .workspace(xxl2Session.id),
            Self.localMacHeaderId(runIndex: 1),
            .workspace(strayLocal.id),
        ])

        // Collapsing Local Mac hides every local run's workspaces.
        let collapsed = SidebarWorkspaceRenderItem.renderItems(
            tabs: harness.manager.tabs,
            groupsById: [:],
            remoteHostKeyByWorkspaceId: harness.hostKeyByWorkspaceId(),
            collapsedRemoteHostKeys: [SidebarRemoteHostSectionIdentity.localMacSectionKey]
        )
        let visible = SidebarWorkspaceRenderItem.numberedWorkspaceIds(from: collapsed)
        #expect(!visible.contains(harness.local.id))
        #expect(!visible.contains(strayLocal.id))
        #expect(visible.contains(xxlSession.id))
        #expect(visible.contains(xxl2Session.id))
    }

    @Test func purelyLocalSidebarStaysHeaderless() throws {
        let harness = try SectionHarness()
        defer { harness.tearDown() }
        let second = harness.manager.addTab(select: false)

        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: harness.manager.tabs,
            groupsById: [:],
            remoteHostKeyByWorkspaceId: [:],
            collapsedRemoteHostKeys: []
        )
        // No machines: no reauthenticate row, no headers — the classic list.
        #expect(items.map { $0.id } == [
            .workspace(harness.local.id),
            .workspace(second.id),
        ])
    }

    /// The one-press reauthenticate row leads the machine area exactly once,
    /// regardless of how many machines or runs exist, and the CLI command it
    /// composes quotes every destination.
    @Test func reauthenticateRowLeadsTheMachineAreaOnce() throws {
        let harness = try SectionHarness()
        defer { harness.tearDown() }
        _ = harness.addMirror(hostKey: "hash-xxl", label: "xxl")
        _ = harness.addMirror(hostKey: "hash-xxl2", label: "xxl2")

        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: harness.manager.tabs,
            groupsById: [:],
            remoteHostKeyByWorkspaceId: harness.hostKeyByWorkspaceId(),
            collapsedRemoteHostKeys: []
        )
        #expect(items.filter { $0.id == .reauthenticate() }.count == 1)
        #expect(items.first?.id == .reauthenticate())

        #expect(TabManager.reauthenticateCommand(destinations: []) == nil)
        #expect(
            TabManager.reauthenticateCommand(destinations: ["cloudtop", "xxl5"])
                == "cmux ssh-tmux 'cloudtop' 'xxl5'"
        )
    }

    @Test func hostSectionWinsOverWorkspaceGroupMembership() throws {
        // A mirror workspace never legitimately belongs to a workspace group,
        // but if state drift ever tags one, the machine section must win and
        // no group header may leak into the mirror run.
        let harness = try SectionHarness()
        defer { harness.tearDown() }
        let mirror = harness.addMirror(hostKey: "hash-xxl", label: "xxl")
        let groupMember = harness.manager.addTab(select: false)
        let groupId = try #require(harness.manager.createWorkspaceGroup(
            name: "Grouped",
            childWorkspaceIds: [groupMember.id]
        ))
        let group = try #require(harness.manager.workspaceGroups.first { $0.id == groupId })
        mirror.groupId = groupId

        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: harness.manager.tabs,
            groupsById: [groupId: group],
            remoteHostKeyByWorkspaceId: harness.hostKeyByWorkspaceId(),
            collapsedRemoteHostKeys: []
        )

        let mirrorIndex = try #require(items.firstIndex(where: { $0.id == .workspace(mirror.id) }))
        let sectionIndex = try #require(items.firstIndex(where: {
            $0.id == .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl"))
        }))
        #expect(sectionIndex < mirrorIndex)
    }

    @Test func interleavedAttachCompletionsStayClusteredPerMachine() throws {
        // Session mirrors are appended as their control streams finish
        // attaching; with several machines attaching concurrently the
        // completion order interleaves. The placement helper must keep each
        // machine's sessions physically contiguous — otherwise a session
        // renders under ANOTHER machine's section header (dogfood report:
        // "alpha" listed under the fakeb section).
        let harness = try SectionHarness()
        defer { harness.tearDown() }
        let a1 = harness.addMirror(hostKey: "hash-xxl", label: "xxl")
        harness.manager.placeMirrorWorkspaceWithItsHost(a1)
        let b1 = harness.addMirror(hostKey: "hash-xxl2", label: "xxl2")
        harness.manager.placeMirrorWorkspaceWithItsHost(b1)
        // The interleaved arrival: xxl's second session completes AFTER
        // xxl2's first.
        let a2 = harness.addMirror(hostKey: "hash-xxl", label: "xxl")
        harness.manager.placeMirrorWorkspaceWithItsHost(a2)

        let order = harness.manager.tabs.map { $0.id }
        #expect(order == [harness.local.id, a1.id, a2.id, b1.id])

        let items = SidebarWorkspaceRenderItem.renderItems(
            tabs: harness.manager.tabs,
            groupsById: [:],
            remoteHostKeyByWorkspaceId: harness.hostKeyByWorkspaceId(),
            collapsedRemoteHostKeys: []
        )
        let itemIds = items.map { $0.id }
        #expect(itemIds == [
            .reauthenticate(),
            Self.localMacHeaderId(),
            .workspace(harness.local.id),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl")),
            .workspace(a1.id),
            .workspace(a2.id),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl2")),
            .workspace(b1.id),
        ])
    }

    static func localMacHeaderId(runIndex: Int = 0) -> SidebarWorkspaceRenderItemID {
        .localMacSection(SidebarRemoteHostSectionIdentity.uuid(
            forHostKey: SidebarRemoteHostSectionIdentity.localMacSectionKey,
            runIndex: runIndex
        ))
    }

    @Test func sectionIdentityIsStableAndDistinct() {
        // Collapse persistence and row identity both key off the derived UUID,
        // so it must be a pure function of the host key — and different keys
        // must never collide.
        let a1 = SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl")
        let a2 = SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl")
        let b = SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl2")
        #expect(a1 == a2)
        #expect(a1 != b)
        // Run salting: run 0 keeps the historical plain-key identity (collapse
        // state persists across launches); later runs are distinct but stable.
        let run1a = SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl", runIndex: 1)
        let run1b = SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl", runIndex: 1)
        #expect(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl", runIndex: 0) == a1)
        #expect(run1a == run1b)
        #expect(run1a != a1)
    }

    @Test func selectingHiddenMirrorExpandsItsMachine() throws {
        let harness = try SectionHarness()
        defer { harness.tearDown() }
        let mirror = harness.addMirror(hostKey: "hash-xxl", label: "xxl")
        // Selection change is the trigger: park focus on the local workspace
        // first, then collapse the machine, then select the hidden mirror.
        harness.manager.selectWorkspace(harness.local)
        harness.manager.setRemoteTmuxHostCollapsed(hostKey: "hash-xxl", isCollapsed: true)
        #expect(harness.manager.isRemoteTmuxHostCollapsed(hostKey: "hash-xxl"))

        harness.manager.selectWorkspace(mirror)

        // A collapsed section must never hide the active workspace: selection
        // through ANY entrypoint (keyboard, notification jump, socket) expands
        // the machine.
        #expect(!harness.manager.isRemoteTmuxHostCollapsed(hostKey: "hash-xxl"))
    }

    // MARK: - Harness

    @MainActor
    private struct SectionHarness {
        let appDelegate: AppDelegate
        let windowId: UUID
        let manager: TabManager
        let local: Workspace

        init() throws {
            // Locals first: #require expands to closures, and a closure must
            // not capture self before every stored property is initialized.
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow()
            let context = try #require(
                appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }
            )
            let manager = context.tabManager
            let local = try #require(manager.selectedWorkspace)
            self.appDelegate = appDelegate
            self.windowId = windowId
            self.manager = manager
            self.local = local
            // Collapse state persists app-globally; tests must not inherit or
            // leak entries.
            for key in ["hash-xxl", "hash-xxl2"] {
                manager.setRemoteTmuxHostCollapsed(hostKey: key, isCollapsed: false)
            }
        }

        func addMirror(hostKey: String, label: String) -> Workspace {
            // Select each added workspace so consecutive adds chain in list
            // order (addTab inserts AFTER the selected workspace); the tests
            // assert exact sidebar order.
            let workspace = manager.addTab(select: true)
            workspace.isRemoteTmuxMirror = true
            workspace.remoteTmuxHostKey = hostKey
            workspace.remoteTmuxHostLabel = label
            return workspace
        }

        func hostKeyByWorkspaceId() -> [UUID: String] {
            Dictionary(uniqueKeysWithValues: manager.tabs.compactMap { tab in
                tab.remoteTmuxHostKey.map { (tab.id, $0) }
            })
        }

        func tearDown() {
            for key in ["hash-xxl", "hash-xxl2"] {
                manager.setRemoteTmuxHostCollapsed(hostKey: key, isCollapsed: false)
            }
            appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId)
        }
    }
}
#endif
