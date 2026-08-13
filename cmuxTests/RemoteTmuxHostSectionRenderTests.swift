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
            .workspace(local.id),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl")),
            .workspace(xxlSession1.id),
            .workspace(xxlSession2.id),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl2")),
            .workspace(xxl2Session.id),
        ])
        // The header nominates the machine's first mirror as its representative
        // row (scroll anchoring), and numbered navigation skips headers.
        guard case .remoteHostSection(let hostKey, let firstWorkspaceId) = items[1] else {
            Issue.record("expected a host section at index 1")
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

    @Test func splitRunsShareOneHeaderAndItsCollapseDecision() throws {
        // Sidebar reorders can interleave machines; every later run of an
        // already-sectioned machine reuses the SAME header (no duplicate) and
        // honors the same collapse decision.
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
        let xxlHeaderId = SidebarWorkspaceRenderItemID.remoteHostSection(
            SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl")
        )
        #expect(expanded.filter { $0.id == xxlHeaderId }.count == 1)
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
        #expect(collapsed.filter { $0.id == xxlHeaderId }.count == 1)
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
            .workspace(harness.local.id),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl")),
            .workspace(a1.id),
            .workspace(a2.id),
            .remoteHostSection(SidebarRemoteHostSectionIdentity.uuid(forHostKey: "hash-xxl2")),
            .workspace(b1.id),
        ])
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
