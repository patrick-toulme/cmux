import Foundation

/// Multicast observer registry for one remote-tmux control connection.
///
/// A single ``RemoteTmuxControlConnection`` is shared by every consumer of the
/// same host+session (``RemoteTmuxController.attach`` reuses it), so events MUST
/// fan out to all consumers — a single overwritable closure silently cut off
/// whichever consumer wired up first. This type owns the per-event registries and
/// emits to every registered callback, snapshotting each registry before iterating
/// so a callback that unregisters itself (mutating the dictionary) can't trap on a
/// live collection.
@MainActor
final class RemoteTmuxConnectionObservers {
    /// Opaque token identifying a registered observer (pass to ``remove(_:)``).
    typealias Token = UUID

    private var paneOutputObservers: [Token: (_ paneId: Int, _ data: Data) -> Void] = [:]
    private var paneSeedObservers: [Token: (_ paneId: Int, _ seed: RemoteTmuxPaneSeed) -> Void] = [:]
    private var paneCwdObservers: [Token: (_ paneId: Int, _ path: String) -> Void] = [:]
    private var paneReflowObservers: [Token: (_ paneId: Int, _ noReflow: Bool) -> Void] = [:]
    private var paneForegroundObservers: [Token: (_ paneId: Int, _ state: RemoteTmuxPaneForegroundState) -> Void] = [:]
    private var activePaneObservers: [Token: (_ windowId: Int, _ paneId: Int) -> Void] = [:]
    private var sessionChangedObservers: [Token: (_ oldName: String, _ newName: String) -> Void] = [:]
    private var sessionsChangedObservers: [Token: () -> Void] = [:]
    private var topologyObservers: [Token: () -> Void] = [:]
    private var reconnectReadyObservers: [Token: () -> Void] = [:]
    private var reconnectAuthRequiredObservers: [Token: () -> Void] = [:]
    private var exitObservers: [Token: () -> Void] = [:]
    private var stateObservers: [Token: (RemoteTmuxControlConnection.ConnectionState) -> Void] = [:]

    /// Registers a consumer's callbacks and returns a token to deregister them.
    ///
    /// Multiple mirrored workspaces can observe the same shared connection
    /// concurrently; every callback
    /// fires for every event. Pass the returned token to ``remove(_:)`` when the
    /// consumer goes away.
    ///
    /// - Parameters:
    ///   - onPaneOutput: receives every `%output` (raw, octal-unescaped bytes).
    ///   - onPaneSeed: receives an authoritative snapshot and its ordered live cutover.
    ///   - onPaneCwd: receives a pane's working directory (`pane_current_path`),
    ///     both the initial value and live changes.
    ///   - onPaneReflow: receives a pane's reflow classification (`true` =
    ///     suppress reflow on resize, for alt-screen / inline-TUI panes like
    ///     claude; `false` = a plain shell whose primary-screen scrollback may
    ///     reflow), both the initial value and live changes.
    ///   - onActivePaneChanged: fires when a window's active pane changes
    ///     (`%window-pane-changed`), so consumers can re-project per-pane state
    ///     (e.g. the active pane's directory) onto the window's tab.
    ///   - onSessionChanged: fires when tmux confirms a session name change via
    ///     `%session-changed` or `%session-renamed`; consumers must treat this as
    ///     the authoritative point for re-keying session-owned state.
    ///   - onSessionsChanged: fires on `%sessions-changed` (the server's session
    ///     set changed: a session was created, destroyed, or renamed), so the
    ///     controller can re-list the host and mirror sessions born after attach.
    ///   - onTopologyChanged: fires when the window/pane topology changes.
    ///   - onReconnectReady: fires after reconnect attach drainage and reseeding.
    ///   - onReconnectAuthRequired: fires when the reconnect loop parks because
    ///     reopening the shared master needs interactive authentication (see
    ///     ``RemoteTmuxControlConnection/resumeReconnectAfterAuth()``), so the
    ///     controller can surface one "re-authenticate" notice per host.
    ///   - onExit: fires once when the connection PERMANENTLY ends (a genuine tmux
    ///     `%exit`, or a session found gone on reconnect). A transient transport loss
    ///     does NOT fire this — the connection reconnects instead.
    ///   - onConnectionStateChanged: fires on every connection-state transition
    ///     (e.g. `.connected` → `.reconnecting` on a transport loss), so consumers
    ///     can show a disconnected/reconnecting indicator without tearing down.
    /// - Returns: a ``Token`` to pass to ``remove(_:)``.
    func add(
        onPaneOutput: ((_ paneId: Int, _ data: Data) -> Void)?,
        onPaneSeed: ((_ paneId: Int, _ seed: RemoteTmuxPaneSeed) -> Void)?,
        onPaneCwd: ((_ paneId: Int, _ path: String) -> Void)?,
        onPaneReflow: ((_ paneId: Int, _ noReflow: Bool) -> Void)?,
        onPaneForegroundStateChanged: ((_ paneId: Int, _ state: RemoteTmuxPaneForegroundState) -> Void)? = nil,
        onActivePaneChanged: ((_ windowId: Int, _ paneId: Int) -> Void)?,
        onSessionChanged: ((_ oldName: String, _ newName: String) -> Void)?,
        onSessionsChanged: (() -> Void)? = nil,
        onTopologyChanged: (() -> Void)?,
        onReconnectReady: (() -> Void)?,
        onReconnectAuthRequired: (() -> Void)? = nil,
        onExit: (() -> Void)?,
        onConnectionStateChanged: ((RemoteTmuxControlConnection.ConnectionState) -> Void)?
    ) -> Token {
        let token = Token()
        if let onPaneOutput { paneOutputObservers[token] = onPaneOutput }
        if let onPaneSeed { paneSeedObservers[token] = onPaneSeed }
        if let onPaneCwd { paneCwdObservers[token] = onPaneCwd }
        if let onPaneReflow { paneReflowObservers[token] = onPaneReflow }
        if let onPaneForegroundStateChanged { paneForegroundObservers[token] = onPaneForegroundStateChanged }
        if let onActivePaneChanged { activePaneObservers[token] = onActivePaneChanged }
        if let onSessionChanged { sessionChangedObservers[token] = onSessionChanged }
        if let onSessionsChanged { sessionsChangedObservers[token] = onSessionsChanged }
        if let onTopologyChanged { topologyObservers[token] = onTopologyChanged }
        if let onReconnectReady { reconnectReadyObservers[token] = onReconnectReady }
        if let onReconnectAuthRequired { reconnectAuthRequiredObservers[token] = onReconnectAuthRequired }
        if let onExit { exitObservers[token] = onExit }
        if let onConnectionStateChanged { stateObservers[token] = onConnectionStateChanged }
        return token
    }

    /// Deregisters the callbacks registered under `token`.
    func remove(_ token: Token) {
        paneOutputObservers[token] = nil
        paneSeedObservers[token] = nil
        paneCwdObservers[token] = nil
        paneReflowObservers[token] = nil
        paneForegroundObservers[token] = nil
        activePaneObservers[token] = nil
        sessionChangedObservers[token] = nil
        sessionsChangedObservers[token] = nil
        topologyObservers[token] = nil
        reconnectReadyObservers[token] = nil
        reconnectAuthRequiredObservers[token] = nil
        exitObservers[token] = nil
        stateObservers[token] = nil
    }

    /// Fans `%output` bytes out to every pane-output observer.
    func emitPaneOutput(_ paneId: Int, _ data: Data) {
        // Snapshot before iterating: a callback may unregister an observer (mutating
        // the dict) synchronously, which would trap on the live collection.
        for callback in Array(paneOutputObservers.values) { callback(paneId, data) }
    }

    /// Fans a typed seed to seed-aware observers. Output-only observers receive
    /// one compatibility write, never both paths.
    func emitPaneSeed(_ paneId: Int, _ seed: RemoteTmuxPaneSeed) {
        for callback in Array(paneSeedObservers.values) { callback(paneId, seed) }
        for (token, callback) in Array(paneOutputObservers)
        where paneSeedObservers[token] == nil {
            callback(paneId, seed.renderedBytes)
        }
    }

    /// Fans a pane's working directory out to every cwd observer.
    func emitPaneCwd(_ paneId: Int, _ path: String) {
        for callback in Array(paneCwdObservers.values) { callback(paneId, path) }
    }

    /// Fans a pane's reflow classification out to every reflow observer.
    func emitPaneReflow(_ paneId: Int, _ noReflow: Bool) {
        for callback in Array(paneReflowObservers.values) { callback(paneId, noReflow) }
    }

    /// Notifies observers that a pane's foreground classification
    /// (`#{alternate_on}|#{pane_current_command}`) CHANGED — the input for
    /// remote agent-activity detection (sidebar spinner).
    func emitPaneForegroundState(_ paneId: Int, _ state: RemoteTmuxPaneForegroundState) {
        for callback in Array(paneForegroundObservers.values) { callback(paneId, state) }
    }

    /// Fans a window's new active pane out to every active-pane observer.
    func emitActivePaneChanged(_ windowId: Int, _ paneId: Int) {
        for callback in Array(activePaneObservers.values) { callback(windowId, paneId) }
    }

    /// Notifies every observer that the remote session name changed.
    func emitSessionChanged(oldName: String, newName: String) {
        for callback in Array(sessionChangedObservers.values) { callback(oldName, newName) }
    }

    /// Notifies every observer that the server's session set changed.
    func notifySessionsChanged() {
        for callback in Array(sessionsChangedObservers.values) { callback() }
    }

    /// Notifies every topology observer that the window/pane layout changed.
    func notifyTopologyChanged() {
        for callback in Array(topologyObservers.values) { callback() }
    }

    /// Notifies observers that reconnect commands are safe and the prior claims were reseeded.
    func notifyReconnectReady() {
        for callback in Array(reconnectReadyObservers.values) { callback() }
    }

    /// Notifies observers that the reconnect loop parked awaiting interactive
    /// authentication (the master gate reported it cannot silently reopen).
    func notifyReconnectAuthRequired() {
        for callback in Array(reconnectAuthRequiredObservers.values) { callback() }
    }

    /// Notifies every exit observer that the connection permanently ended.
    func notifyExit() {
        // Snapshot: notifyExit -> handleSessionEndedRemotely -> detachObserver ->
        // removeObserver mutates exitObservers synchronously during this loop.
        for callback in Array(exitObservers.values) { callback() }
    }

    /// Notifies every connection-state observer of a transition.
    func notifyStateChanged(_ state: RemoteTmuxControlConnection.ConnectionState) {
        for callback in Array(stateObservers.values) { callback(state) }
    }
}
