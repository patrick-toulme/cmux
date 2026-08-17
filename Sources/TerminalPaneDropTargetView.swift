import AppKit
import Bonsplit
import Foundation
import SwiftUI
import CmuxTerminal

final class PaneDropTargetView: NSView {
    weak var hostedView: GhosttySurfaceScrollView?
    var dropContext: PaneDropContext? {
        didSet {
            if dropContext != oldValue {
                transferDropRouter.clear()
            }
        }
    }
    private var activeZone: DropZone?
    private let transferDropRouter = PaneTransferDropRouter()
    private let dropRoutingRegistration = PaneDropRoutingRegistration()
    private let dropZoneOverlayView = NSView(frame: .zero)
    private lazy var dropZoneOverlayAnimator = PaneDropZoneOverlayAnimator(overlayView: dropZoneOverlayView)
#if DEBUG
    private var lastHitTestSignature: String?
#endif

    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes(Array(Set([
            DragOverlayRoutingPolicy.bonsplitTabTransferType,
        ]).union(PasteboardFileURLReader.fileURLPasteboardTypes)))
        setupDropZoneOverlayView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil {
            dropRoutingRegistration.clear()
            transferDropRouter.clear()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    override func layout() {
        super.layout()
        updateStandaloneDropZoneOverlay()
    }

    static func shouldCaptureHitTesting(
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?,
        leftMouseButtonPressed: Bool = false
    ) -> Bool {
        let routingContext = WindowInputRoutingContext(eventType: eventType)
        guard routingContext.allowsPaneDropHitTesting else { return false }

        let hasTabTransfer = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
        let hasFileDropPayload = DragOverlayRoutingPolicy.hasFileDropPayload(pasteboardTypes)
        guard hasTabTransfer || hasFileDropPayload else { return false }

        if hasFileDropPayload, !hasTabTransfer {
            // External drags (Finder, screenshot thumbnails) hit-test with
            // whatever event ran last, never an in-app pointer drag; the
            // held button is their session signal (see the gate's doc).
            return routingContext.allowsFileDropPaneHitTesting(
                leftMouseButtonPressed: leftMouseButtonPressed
            )
        }
        return true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        performHitTest(at: point, currentEvent: NSApp.currentEvent)
    }

    func performHitTest(at point: NSPoint, currentEvent: NSEvent?) -> NSView? {
        guard bounds.contains(point), dropContext != nil else { return nil }
        let eventType = currentEvent?.type
        guard WindowInputRoutingContext.allowsPaneDropHitTesting(eventType: eventType) else { return nil }
        if shouldDeferToPaneTabBar(at: point) {
            return nil
        }

        let pasteboardTypes = NSPasteboard(name: .drag).types
        let capture = Self.shouldCaptureHitTesting(
            pasteboardTypes: pasteboardTypes,
            eventType: eventType,
            leftMouseButtonPressed: WindowInputRoutingContext.isLeftMouseButtonPressed
        )
#if DEBUG
        logHitTestDecision(capture: capture, pasteboardTypes: pasteboardTypes, eventType: eventType)
#endif
        return capture ? self : nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if let dropContext {
            transferDropRouter.begin(context: dropContext)
        } else {
            transferDropRouter.clear()
        }
        let operation = updateDragState(sender, phase: "entered")
        dropRoutingRegistration.update(sender, operation: operation, targetView: self)
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = updateDragState(sender, phase: "updated")
        dropRoutingRegistration.update(sender, operation: operation, targetView: self)
        return operation
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropRoutingRegistration.clear(sender)
        clearDragState(phase: "exited")
        transferDropRouter.clear()
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropRoutingRegistration.clear(sender)
        clearDragState(phase: "ended")
        transferDropRouter.clear()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let dropContext else {
            transferDropRouter.clear()
            return hostedView?.surfaceView != nil
                && DragOverlayRoutingPolicy.hasFileDropPayload(sender.draggingPasteboard.types)
        }
        guard let container = transferDropRouter.container(for: dropContext) else {
            return hostedView?.surfaceView != nil
                && DragOverlayRoutingPolicy.hasFileDropPayload(sender.draggingPasteboard.types)
        }

        let textDestinationKind = container.fileDropTextDestinationKind(
            in: dropContext.paneId,
            hasHostedTerminal: hostedView != nil
        )
        if DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
            pasteboardTypes: sender.draggingPasteboard.types,
            modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
            canDropAsText: textDestinationKind != nil
        ) {
            return !DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard).isEmpty
        }

        switch transferDropRouter.resolve(
            pasteboard: sender.draggingPasteboard,
            context: dropContext,
            proposedZone: paneDropZone(for: sender)
        ) {
        case .accepted:
            return true
        case .rejected:
            return false
        case .notTransfer:
            return DragOverlayRoutingPolicy.hasFileURL(sender.draggingPasteboard.types)
        }
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let modifierFlags = DragOverlayRoutingPolicy.currentModifierFlags
        defer {
            dropRoutingRegistration.clear(sender)
            clearDragState(phase: "perform.clear")
            transferDropRouter.clear()
        }

        guard let dropContext else {
#if DEBUG
            cmuxDebugLog("terminal.paneDrop.perform reason=missingContext fallback=terminal")
#endif
            return performTerminalFileDropFallback(sender)
        }

        guard let container = transferDropRouter.container(for: dropContext) else {
#if DEBUG
            cmuxDebugLog("terminal.paneDrop.perform reason=missingContainer fallback=terminal")
#endif
            return performTerminalFileDropFallback(sender)
        }

        let textDestinationKind = container.fileDropTextDestinationKind(
            in: dropContext.paneId,
            hasHostedTerminal: hostedView != nil
        )
        if DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
            pasteboardTypes: sender.draggingPasteboard.types,
            modifierFlags: modifierFlags,
            canDropAsText: textDestinationKind != nil
        ) {
            let urls = DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard)
            guard !urls.isEmpty else { return false }
            let handled = container.performFileDropAsText(
                urls,
                context: dropContext,
                hostedView: hostedView,
                window: window
            )
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.performAsText panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "fileURLs=\(urls.count) pane=\(dropContext.paneId.id.uuidString.prefix(5)) " +
                "handled=\(handled ? 1 : 0)"
            )
#endif
            return handled
        }

        let transferResolution = transferDropRouter.resolve(
            pasteboard: sender.draggingPasteboard,
            context: dropContext,
            proposedZone: paneDropZone(for: sender)
        )
        switch transferResolution {
        case .accepted(let plan):
            let handled = transferDropRouter.perform(
                plan,
                pasteboard: sender.draggingPasteboard
            )
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(plan.transfer.tabId.uuidString.prefix(5)) zone=\(plan.zone) " +
                "pane=\(dropContext.paneId.id.uuidString.prefix(5)) handled=\(handled ? 1 : 0)"
            )
#endif
            return handled
        case .rejected:
            return false
        case .notTransfer:
            break
        }

        let urls = DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard)
        if let handled = container.performSimulatorFileDrop(
            urls: urls,
            panelId: dropContext.panelId
        ) {
            return handled
        }
        guard !urls.isEmpty else {
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.perform allowed=0 panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "reason=missingTransferAndFiles"
            )
#endif
            return false
        }

        let zone = paneDropZone(for: sender)
        let handled = container.handleExternalFileDrop(BonsplitController.ExternalFileDropRequest(
            urls: urls,
            destination: PaneDropRouting.destination(
                targetPane: dropContext.paneId,
                zone: zone
            )
        ))
#if DEBUG
        cmuxDebugLog(
            "terminal.paneDrop.perform panel=\(dropContext.panelId.uuidString.prefix(5)) " +
            "fileURLs=\(urls.count) zone=\(zone) pane=\(dropContext.paneId.id.uuidString.prefix(5)) " +
            "handled=\(handled ? 1 : 0)"
        )
#endif
        return handled
    }

    /// Resolves the current drag operation using the owner fixed for this context.
    private func updateDragState(
        _ sender: any NSDraggingInfo,
        phase: String
    ) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)
        if shouldDeferToPaneTabBar(at: location) {
            clearDragState(phase: "\(phase).tabBar")
            return []
        }

        guard let dropContext else {
            clearDragState(phase: "\(phase).reject")
            return terminalFileDropFallbackOperation(sender, phase: phase)
        }

        guard let container = transferDropRouter.container(for: dropContext) else {
            clearDragState(phase: "\(phase).reject")
            return terminalFileDropFallbackOperation(sender, phase: phase)
        }

        let textDestinationKind = container.fileDropTextDestinationKind(
            in: dropContext.paneId,
            hasHostedTerminal: hostedView != nil
        )
        if DragOverlayRoutingPolicy.shouldRouteFileDropToTextDestination(
            pasteboardTypes: sender.draggingPasteboard.types,
            modifierFlags: DragOverlayRoutingPolicy.currentModifierFlags,
            canDropAsText: textDestinationKind != nil
        ) {
            clearDragState(phase: "\(phase).text")
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) fileDrop=1 textDestination=\(String(describing: textDestinationKind))"
            )
#endif
            return DragOverlayRoutingPolicy.textDropOperation(pasteboardTypes: sender.draggingPasteboard.types)
        }

        let transferResolution = transferDropRouter.resolve(
            pasteboard: sender.draggingPasteboard,
            context: dropContext,
            proposedZone: paneDropZone(for: sender)
        )
        switch transferResolution {
        case .accepted(let plan):
            setActiveDropZone(plan.zone)
#if DEBUG
            cmuxDebugLog(
                "terminal.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) " +
                "tab=\(plan.transfer.tabId.uuidString.prefix(5)) zone=\(plan.zone)"
            )
#endif
            return .move
        case .rejected:
            clearDragState(phase: "\(phase).reject")
            return []
        case .notTransfer:
            break
        }

        guard DragOverlayRoutingPolicy.hasFileURL(sender.draggingPasteboard.types) else {
            clearDragState(phase: "\(phase).reject")
            return []
        }

        let urls = DragOverlayRoutingPolicy.fileURLs(from: sender.draggingPasteboard)
        if let operation = container.simulatorFileDropOperation(
            urls: urls,
            panelId: dropContext.panelId
        ) {
            clearDragState(phase: "\(phase).simulator")
            return operation
        }

        let zone = paneDropZone(for: sender)
        setActiveDropZone(zone)
#if DEBUG
        cmuxDebugLog(
            "terminal.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) " +
            "fileURL=1 zone=\(zone)"
        )
#endif
        return .copy
    }

    /// File drags targeting a pane whose panel is NOT in the workspace's outer
    /// bonsplit (remote-tmux mirror panes: their panels live in the window
    /// mirror's own tree) resolve no ``PaneDropContainer``. This drop target
    /// sits ABOVE the terminal as the pane's topmost subview and is registered
    /// for the same file types, so a silent `[]` here SHADOWS the terminal's
    /// own drag handling and the whole pane refuses Finder/screenshot drops
    /// (observed live: drops onto mirror panes bounced with no log). Hand the
    /// drag to the hosted terminal surface instead: its own destination logic
    /// accepts file payloads, rejects tab transfers, and its perform path
    /// already uploads to the tmux host for mirror surfaces.
    private func terminalFileDropFallbackOperation(
        _ sender: any NSDraggingInfo,
        phase: String
    ) -> NSDragOperation {
        guard let surfaceView = hostedView?.surfaceView,
              DragOverlayRoutingPolicy.hasFileDropPayload(sender.draggingPasteboard.types)
        else { return [] }
        let operation = phase == "entered"
            ? surfaceView.draggingEntered(sender)
            : surfaceView.draggingUpdated(sender)
#if DEBUG
        cmuxDebugLog(
            "terminal.paneDrop.\(phase) fallback=terminal operation=\(operation.rawValue)"
        )
#endif
        return operation
    }

    /// Perform-phase counterpart of
    /// ``terminalFileDropFallbackOperation(_:phase:)``.
    private func performTerminalFileDropFallback(_ sender: any NSDraggingInfo) -> Bool {
        guard let surfaceView = hostedView?.surfaceView,
              DragOverlayRoutingPolicy.hasFileDropPayload(sender.draggingPasteboard.types)
        else { return false }
        let handled = surfaceView.performDragOperation(sender)
#if DEBUG
        cmuxDebugLog("terminal.paneDrop.perform fallback=terminal handled=\(handled ? 1 : 0)")
#endif
        return handled
    }

    static func simulatorFileDropOperation(
        urls: [URL],
        workspace: Workspace,
        panelId: UUID
    ) -> NSDragOperation? {
        guard let canHandle = workspace.canHandleSimulatorExternalFileDrop(
            urls: urls,
            panelId: panelId
        ) else {
            return nil
        }
        return canHandle ? .copy : []
    }

    private func paneDropZone(for sender: any NSDraggingInfo) -> DropZone {
        let location = convert(sender.draggingLocation, from: nil)
        return PaneDropRouting.zone(for: location, in: bounds.size)
    }

    func shouldDeferToPaneTabBar(at point: NSPoint) -> Bool {
        let windowPoint = convert(point, to: nil)
        return BonsplitTabBarPassThrough
            .shouldPassThroughToPaneTabBar(windowPoint: windowPoint, below: self)
            .result
    }

    private func setupDropZoneOverlayView() {
        _ = dropZoneOverlayAnimator
        dropZoneOverlayView.autoresizingMask = []
        addSubview(dropZoneOverlayView)
    }

    private func setActiveDropZone(_ zone: DropZone?) {
        activeZone = zone
        if let hostedView {
            hostedView.setDropZoneOverlay(zone: zone)
            dropZoneOverlayView.isHidden = true
        } else {
            updateStandaloneDropZoneOverlay()
        }
    }

    private func updateStandaloneDropZoneOverlay() {
        guard hostedView == nil else {
            dropZoneOverlayAnimator.hideImmediately()
            return
        }
        dropZoneOverlayAnimator.setZone(
            activeZone,
            frameForZone: { [weak self] zone in
                guard let self else { return .zero }
                return PaneDropRouting.overlayFrame(for: zone, in: self.bounds)
            },
            ensureAttached: { [weak self] in
                guard let self else { return }
                if self.dropZoneOverlayView.superview !== self {
                    self.dropZoneOverlayView.removeFromSuperview()
                    self.addSubview(self.dropZoneOverlayView)
                }
            },
            bringToFront: { [weak self] in
                guard let self else { return }
                guard self.dropZoneOverlayView.superview === self,
                      self.subviews.last !== self.dropZoneOverlayView else { return }
                self.addSubview(self.dropZoneOverlayView, positioned: .above, relativeTo: nil)
            }
        )
    }

    private func clearDragState(phase: String) {
        guard activeZone != nil else { return }
        setActiveDropZone(nil)
#if DEBUG
        if let dropContext {
            cmuxDebugLog(
                "terminal.paneDrop.\(phase) panel=\(dropContext.panelId.uuidString.prefix(5)) zone=none"
            )
        }
#endif
    }

#if DEBUG
    private func logHitTestDecision(
        capture: Bool,
        pasteboardTypes: [NSPasteboard.PasteboardType]?,
        eventType: NSEvent.EventType?
    ) {
        let hasTransferType = DragOverlayRoutingPolicy.hasBonsplitTabTransfer(pasteboardTypes)
        let hasFileDropPayload = DragOverlayRoutingPolicy.hasFileDropPayload(pasteboardTypes)
        guard hasTransferType || hasFileDropPayload || capture else { return }

        let signature = [
            capture ? "1" : "0",
            hasTransferType ? "1" : "0",
            hasFileDropPayload ? "1" : "0",
            String(describing: dropContext != nil),
            eventType.map { String($0.rawValue) } ?? "nil",
        ].joined(separator: "|")
        guard lastHitTestSignature != signature else { return }
        lastHitTestSignature = signature

        let types = pasteboardTypes?.map(\.rawValue).joined(separator: ",") ?? "-"
        cmuxDebugLog(
            "terminal.paneDrop.hitTest capture=\(capture ? 1 : 0) " +
            "hasTransfer=\(hasTransferType ? 1 : 0) hasFileDrop=\(hasFileDropPayload ? 1 : 0) " +
            "ctx\(dropContext != nil ? 1 : 0) " +
            "evt\(eventType.map { String($0.rawValue) } ?? "-") " +
            "btn\(WindowInputRoutingContext.isLeftMouseButtonPressed ? 1 : 0) types=\(types)"
        )
    }
#endif
}

typealias TerminalPaneDropTargetView = PaneDropTargetView

struct PaneDropTargetRepresentable: NSViewRepresentable {
    let dropContext: PaneDropContext?

    func makeNSView(context: Context) -> PaneDropTargetView {
        PaneDropTargetView(frame: .zero)
    }

    func updateNSView(_ nsView: PaneDropTargetView, context: Context) {
        nsView.dropContext = dropContext
        nsView.hostedView = nil
        if dropContext == nil {
            nsView.draggingExited(nil)
        }
    }
}
