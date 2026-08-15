import Bonsplit
import SwiftUI

@MainActor
struct RemoteTmuxWindowMirrorSplitView: View {
    let mirror: RemoteTmuxWindowMirror
    let appearance: PanelAppearance
    let isOuterFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onOuterFocus: () -> Void
    var unreadSurfaceIDs: Set<UUID> = []
    @Environment(\.displayScale) private var displayScale
    @State private var containerSize: CGSize = .zero
    /// This view instance's identity in the mirror's host registry. One
    /// mirror can be mounted by several live views at once (the same
    /// workspace in two app windows keeps both trees alive); every report
    /// carries the token so exactly one host owns sizing.
    @State private var hostToken = UUID()

    var body: some View {
        // The base color is the region, and it answers every proposal with
        // the proposal; the split tree renders in the overlay at its exact
        // grid-plus-chrome size. The two are separated because they disagree
        // under churn: the tree's frame is derived from the BANKED container
        // while the proposal comes from the live window, so a window shrink
        // leaves the tree momentarily wider than the region. In an overlay
        // the excess overflows in place. Sizing the tree inline let it leak —
        // a flexible frame with no minWidth reports its CHILD's width when
        // the child exceeds the proposal — so the imposed width became this
        // view's reported size, every space-filling ancestor up to the main
        // window's root content inherited it (observed live: the content
        // view marching wider than the display-pinned window a step per
        // layout pass), and the geometry callback below then read the
        // mirror's own imposed width back as its "container".
        //
        // The content shape keeps the (possibly clear) margin
        // click-targetable for the container focus gesture.
        Color(nsColor: Self.regionFillColor(for: appearance))
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                splitTree
            }
            .background(MirrorHostProbe(mirror: mirror, token: hostToken))
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                containerSize = newSize
                pushClientSize(pointSize: newSize)
            }
            .onAppear {
                // Visibility, sizing ownership, and the split tree's
                // AppKit-level interactivity all derive from the host
                // registry (the workspace keeps every tab's content alive
                // and hides deselected tabs at SwiftUI opacity 0, which
                // never reaches the AppKit split tree; and a duplicate
                // mount in another window must not stomp this one's state).
                mirror.noteHostVisibility(token: hostToken, visible: isVisibleInUI)
                if !isVisibleInUI {
                    mirror.cancelPendingControlPaneFocus()
                    mirror.cancelPendingCreatedPaneFocus()
                }
                if isVisibleInUI { becameVisible() }
            }
            .onDisappear {
                // Fires when this tree is genuinely discarded (window
                // closed, workspace removed), not on opacity-0 hides: a
                // dead host must not keep owning the size claim.
                mirror.removeHost(token: hostToken)
            }
            .onChange(of: isVisibleInUI) { _, visible in
                mirror.noteHostVisibility(token: hostToken, visible: visible)
                if !visible {
                    mirror.cancelPendingControlPaneFocus()
                    mirror.cancelPendingCreatedPaneFocus()
                }
                if visible { becameVisible() }
            }
            .onChange(of: mirror.layoutStructureVersion) { _, _ in
                pushClientSize(pointSize: containerSize)
            }
    }

    private var splitTree: some View {
        BonsplitView(controller: mirror.bonsplitController) { tab, paneId in
            if let tmuxPaneId = mirror.tmuxPaneId(forTab: tab.id),
               let panel = mirror.panel(forPane: tmuxPaneId) {
                TerminalPanelView(
                    panel: panel,
                    paneId: paneId,
                    isFocused: isOuterFocused && mirror.isFocused(tabId: tab.id),
                    isVisibleInUI: isVisibleInUI,
                    portalPaneOwnershipResolver: {
                        mirror.bonsplitController.selectedTab(inPane: paneId)?.id == tab.id
                    },
                    portalPriority: portalPriority,
                    isSplit: true,
                    appearance: appearance,
                    hasUnreadNotification: unreadSurfaceIDs.contains(panel.id),
                    terminalAgentContext: "",
                    onFocus: {
                        onOuterFocus()
                        mirror.setActivePane(tmuxPaneId, fromTmux: false)
                    },
                    onResumeAgentHibernation: {},
                    onAutoResumeAgentHibernation: {},
                    onTriggerFlash: {}
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture {
                    onOuterFocus()
                    mirror.bonsplitController.focusPane(paneId)
                }
            } else {
                Color(nsColor: Self.regionFillColor(for: appearance))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } emptyPane: { _ in
            Color(nsColor: Self.regionFillColor(for: appearance))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .internalOnlyTabDrag()
        // The tree renders at its exact grid-plus-chrome size; the region's
        // sub-cell remainder stays outside it as trailing margin (painted by
        // the base color), so no pane inherits a fraction of a cell along a
        // split axis and rounds onto an extra row or column. nil (before the
        // first sized pass) falls back to filling the region — the overlay
        // proposes the base's size.
        .frame(
            width: mirror.renderFrameSize?.width,
            height: mirror.renderFrameSize?.height,
            alignment: .topLeading
        )
    }

    /// The fill behind the exact-fit split tree, its placeholders, and the
    /// region margin outside the tree (up to the chrome rows tmux keeps back
    /// from the window-size claim, plus the sub-cell remainder).
    ///
    /// This MUST follow the shared pane composition policy
    /// (`contentBackgroundColor`), never `backgroundColor`: under a
    /// translucent theme the window backdrop paints the terminal fill
    /// exactly once and every pane surface keeps its content background
    /// clear. Painting the translucent theme color here stacked a second
    /// copy over the backdrop, and the margin below the grid rendered as a
    /// visibly lighter band whenever tmux landed the window a row or two
    /// short of the claim.
    static func regionFillColor(for appearance: PanelAppearance) -> NSColor {
        appearance.contentBackgroundColor
    }

    private func pushClientSize(pointSize: CGSize) {
        mirror.noteHostVisibility(token: hostToken, visible: isVisibleInUI)
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        mirror.noteHostContainerSize(
            token: hostToken, pointSize: pointSize, scale: displayScale
        )
    }

    /// A tab shown again may have had its views recreated while hidden, so
    /// identical sizing inputs do not mean the fresh views hold the plan —
    /// request the pass that ignores the settled check.
    private func becameVisible() {
        pushClientSize(pointSize: containerSize)
        mirror.setNeedsSizingPassIgnoringInputs()
    }
}

/// The zero-cost NSView ``MirrorHostProbe`` plants inside the mirror's own
/// view subtree so the mirror has a window handle that survives portal
/// churn, and an ancestor chain rooted at the mirror's real position for
/// geometry diagnostics.
final class MirrorHostProbeView: NSView {
    weak var mirror: RemoteTmuxWindowMirror?
    /// The host token of the view instance that planted this probe; probe
    /// registration and key-window activation report through it.
    var hostToken: UUID?
    private var keyWindowObserver: NSObjectProtocol?

    /// The probe backs the whole mirror region, including the sub-cell
    /// margin outside the split tree; it must never swallow a click there.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // A window live-resize whose final geometry arrived BEFORE mouse-up
        // leaves a parked oversized reading with no edge to consume it —
        // onGeometryChange fires only on value change, and the parked-reading
        // consumer holds while inLiveResize is true. By the time this
        // coalesced pass runs, inLiveResize is false so the consume proceeds.
        // setNeedsSizingPass (not IgnoringInputs): the consume sits above the
        // inputs == lastCompletedSizingInputs check.
        mirror?.setNeedsSizingPass()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer = keyWindowObserver {
            NotificationCenter.default.removeObserver(observer)
            keyWindowObserver = nil
        }
        guard let window else {
            // A tab re-show can recreate the probe, and AppKit delivers the
            // DYING probe's move-to-nil-window after the replacement already
            // registered — claiming here would shadow the live probe's
            // window handle with a windowless view until the next SwiftUI
            // update. Only the currently registered probe may clear its
            // token's slot; a superseded probe changes nothing.
            if let mirror, let hostToken {
                mirror.unregisterHostProbe(self, token: hostToken)
            }
            return
        }
        guard let mirror, let hostToken else { return }
        mirror.registerHostProbe(self, token: hostToken)
        // Sizing follows the window the user is actually using (tmux's
        // `window-size latest`): the host whose window becomes key takes
        // ownership, so typing into a second window showing the same
        // workspace resizes the remote to THAT window's slot.
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let token = self.hostToken else { return }
                self.mirror?.noteHostActivated(token: token)
            }
        }
    }
}

private struct MirrorHostProbe: NSViewRepresentable {
    let mirror: RemoteTmuxWindowMirror
    let token: UUID

    func makeNSView(context: Context) -> MirrorHostProbeView {
        let view = MirrorHostProbeView()
        view.mirror = mirror
        view.hostToken = token
        mirror.registerHostProbe(view, token: token)
        return view
    }

    func updateNSView(_ nsView: MirrorHostProbeView, context: Context) {
        nsView.mirror = mirror
        nsView.hostToken = token
        mirror.registerHostProbe(nsView, token: token)
    }
}
