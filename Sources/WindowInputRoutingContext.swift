import AppKit

struct WindowInputRoutingContext: Equatable {
    enum EventKind: Equatable {
        case noEvent
        case keyboard
        case pointerDown
        case pointerDrag
        case pointerUp
        case pointerHover
        case scroll
        case appKitRouting
        case other
    }

    let eventType: NSEvent.EventType?
    let eventKind: EventKind

    init(event: NSEvent?) {
        self.init(eventType: event?.type)
    }

    init(eventType: NSEvent.EventType?) {
        self.eventType = eventType
        self.eventKind = Self.kind(for: eventType)
    }

    var allowsFirstResponderHitTesting: Bool {
        eventKind == .pointerDown
    }

    var allowsPortalPointerHitTesting: Bool {
        switch eventKind {
        case .noEvent,
             .pointerDown,
             .pointerDrag,
             .pointerUp,
             .pointerHover,
             .scroll,
             .appKitRouting:
            return true
        case .keyboard, .other:
            return false
        }
    }

    var allowsTabBarPassThroughHitTesting: Bool {
        switch eventKind {
        case .noEvent,
             .pointerDown,
             .pointerDrag,
             .pointerUp,
             .pointerHover,
             .appKitRouting:
            return true
        case .keyboard, .scroll, .other:
            return false
        }
    }

    var allowsPaneDropHitTesting: Bool {
        switch eventKind {
        case .pointerDrag,
             .pointerUp,
             .pointerHover,
             .appKitRouting:
            return true
        case .noEvent, .keyboard, .pointerDown, .scroll, .other:
            return false
        }
    }

    /// Whether the left mouse button is physically held, per the shared event
    /// source. This is the one session signal an EXTERNAL drag gives the
    /// destination app: Finder, screenshot thumbnails, and browsers own the
    /// drag loop, so cmux never sees pointer events while their drag is over
    /// our window. `NSApp.currentEvent` stays whatever ran last (an
    /// appKitDefined tick, a stale hover, nil). Gating file-drop hit-testing
    /// purely on in-app pointer kinds therefore rejected every external drop
    /// (observed live: screenshot drags logging `capture=0` with the promise
    /// and PNG flavors advertised, and the image snapping back).
    static var isLeftMouseButtonPressed: Bool {
        NSEvent.pressedMouseButtons & 0x1 != 0
    }

    /// File-drop capture for pane drop targets. In-app drags identify
    /// themselves by pointer kind; the non-pointer kinds are admitted only
    /// while the button is held (an external drag in flight). Button-up
    /// hovers over a STALE drag pasteboard (macOS retains the last drag's
    /// types) stay rejected, so tracking areas and cursor updates never see
    /// a phantom drop target.
    func allowsFileDropPaneHitTesting(leftMouseButtonPressed: Bool) -> Bool {
        switch eventKind {
        case .pointerDrag, .pointerUp:
            return true
        case .noEvent, .pointerHover, .appKitRouting, .other:
            return leftMouseButtonPressed
        case .keyboard, .pointerDown, .scroll:
            return false
        }
    }

    func allowsFileDropOverlayHitTesting(leftMouseButtonPressed: Bool) -> Bool {
        switch eventKind {
        case .pointerDrag:
            return true
        case .noEvent, .pointerHover, .appKitRouting, .other:
            return leftMouseButtonPressed
        case .keyboard, .pointerDown, .pointerUp, .scroll:
            return false
        }
    }

    var allowsWorkspaceDropOverlayHitTesting: Bool {
        eventKind == .noEvent
            || eventKind == .pointerDrag
            || eventType == .cursorUpdate
            || eventType == .mouseMoved
    }

    var allowsBrowserPortalDragRouting: Bool {
        switch eventKind {
        case .pointerDrag, .pointerHover:
            return true
        case .noEvent, .keyboard, .pointerDown, .pointerUp, .scroll, .appKitRouting, .other:
            return false
        }
    }

    /// Terminal surfaces live behind the window portal, so a drag can only
    /// reach them when this admits the routing pass. Same external-drag rule
    /// as the pane gate above: non-pointer kinds count only while the button
    /// is held.
    func allowsTerminalPortalDragRouting(leftMouseButtonPressed: Bool) -> Bool {
        switch eventKind {
        case .pointerDrag, .pointerUp:
            return true
        case .noEvent, .pointerHover, .appKitRouting, .other:
            return leftMouseButtonPressed
        case .keyboard, .pointerDown, .scroll:
            return false
        }
    }

    static func allowsTabBarPassThroughHitTesting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsTabBarPassThroughHitTesting
    }

    static func allowsPaneDropHitTesting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsPaneDropHitTesting
    }

    static func allowsFileDropOverlayHitTesting(
        eventType: NSEvent.EventType?,
        leftMouseButtonPressed: Bool = false
    ) -> Bool {
        WindowInputRoutingContext(eventType: eventType)
            .allowsFileDropOverlayHitTesting(leftMouseButtonPressed: leftMouseButtonPressed)
    }

    static func allowsWorkspaceDropOverlayHitTesting(eventType: NSEvent.EventType?) -> Bool {
        WindowInputRoutingContext(eventType: eventType).allowsWorkspaceDropOverlayHitTesting
    }

    static func allowsTerminalPortalDragRouting(
        eventType: NSEvent.EventType?,
        leftMouseButtonPressed: Bool = false
    ) -> Bool {
        WindowInputRoutingContext(eventType: eventType)
            .allowsTerminalPortalDragRouting(leftMouseButtonPressed: leftMouseButtonPressed)
    }

    private static func kind(for eventType: NSEvent.EventType?) -> EventKind {
        guard let eventType else { return .noEvent }
        switch eventType {
        case .keyDown, .keyUp, .flagsChanged:
            return .keyboard
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .pointerDown
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return .pointerDrag
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return .pointerUp
        case .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate:
            return .pointerHover
        case .scrollWheel:
            return .scroll
        case .appKitDefined, .applicationDefined, .systemDefined, .periodic:
            return .appKitRouting
        default:
            return .other
        }
    }
}
