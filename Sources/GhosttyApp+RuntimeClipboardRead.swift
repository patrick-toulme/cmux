import AppKit
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit
import os

nonisolated private let runtimeClipboardLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.cmuxterm.app",
    category: "RuntimeClipboard"
)

extension GhosttyApp {
    /// Once per run: a paste whose pasteboard ADVERTISES plain text but
    /// yields nil from every flavor means macOS denied clipboard access
    /// (types are always readable; data is what the privacy gate blocks).
    /// Observed live: repeated Cmd+V presses logged `prepared=reject` while
    /// `pbpaste` read the same clipboard fine, and the user saw nothing at
    /// all. The advisory names the fix instead of eating the paste.
    @MainActor private static var didPresentPasteboardAccessDeniedAdvisory = false

    @MainActor
    static func presentPasteboardAccessDeniedAdvisoryIfNeeded(
        pasteboard: NSPasteboard
    ) {
        guard terminalPasteboard.advertisesPlainText(in: pasteboard) else { return }
        runtimeClipboardLogger.error(
            "Paste rejected with plain-text flavors advertised: macOS likely denied pasteboard access"
        )
        guard !didPresentPasteboardAccessDeniedAdvisory else { return }
        didPresentPasteboardAccessDeniedAdvisory = true
        // Detach from the clipboard-completion stack before running a modal.
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = String(
                localized: "clipboard.accessDenied.title",
                defaultValue: "macOS blocked cmux's clipboard access"
            )
            alert.informativeText = String(
                localized: "clipboard.accessDenied.body",
                defaultValue: """
                The clipboard has text, but macOS returned nothing when cmux \
                tried to read it, so the paste stayed empty. Open System \
                Settings > Privacy & Security > Pasteboard and allow clipboard \
                access for this app, then paste again.
                """
            )
            alert.addButton(withTitle: String(
                localized: "clipboard.accessDenied.openSettings",
                defaultValue: "Open Privacy Settings"
            ))
            alert.addButton(withTitle: String(
                localized: "clipboard.accessDenied.dismiss",
                defaultValue: "OK"
            ))
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(
                string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
               ) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    static func runtimeReadClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let callbackContext = Self.callbackContext(from: userdata) else {
            return false
        }
        let clipboardRequestID = UInt(bitPattern: state)
        let requestSurfaceView = callbackContext.surfaceView
        let operation = TerminalImageTransferOperation()
        guard let pasteboardReadLease = terminalPasteboard
            .reserveClipboardRead(from: location) else {
            return false
        }
        // Ghostty exposes the request kind only at confirmation. The callback
        // context instead claims a synchronous paste intent from native input;
        // independent reads such as OSC 52 remain unsequenced.
        guard let requestSurfaceAddress = callbackContext.registerRuntimeClipboardRead(
            id: clipboardRequestID,
            stateAddress: clipboardRequestID,
            operation: operation,
            surfaceView: requestSurfaceView
        ) else {
            pasteboardReadLease.finish()
            return false
        }

        // In-event fast path: read plain text NOW, synchronously, while this
        // callback still runs inside the user's paste event. macOS pasteboard
        // privacy attributes an in-event read to the paste and allows it; the
        // same read after the preparation task's async hop counts as
        // background clipboard access, which the OS can silently deny (types
        // stay visible, every data read returns nil, and Cmd+V looks dead).
        // Only pasteboards needing file/image/RTFD work take the async pipe.
        var inEventPreparedContent: TerminalImageTransferPreparedContent?
        if let eventPasteboard = terminalPasteboard.pasteboard(for: location),
           !terminalPasteboard.requiresAsynchronousPastePreparation(eventPasteboard) {
            inEventPreparedContent = TerminalImageTransferPlanner.prepareSynchronously(
                pasteboard: eventPasteboard,
                mode: .paste,
                pasteboardService: terminalPasteboard
            )
        }

        let (startEvents, startContinuation) = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let preparationTask = Task {
            @MainActor [weak callbackContext, weak requestSurfaceView] in
            defer { pasteboardReadLease.finish() }
            var startIterator = startEvents.makeAsyncIterator()
            guard await startIterator.next() != nil,
                  !Task.isCancelled else {
                return
            }
            guard let callbackContext else { return }
            guard let requestSurfaceView,
                  let requestTerminalSurface = callbackContext.terminalSurface,
                  requestTerminalSurface.isActiveRuntimeCallbackContext(
                    callbackContext
                  ),
                  let requestSurfaceIdentity = TerminalClipboardRequestSurfaceIdentity(
                    terminalSurface: requestTerminalSurface
                  ),
                  requestSurfaceIdentity.surfaceAddress
                    == requestSurfaceAddress else {
                callbackContext.invalidateRuntimeClipboardRequest(
                    clipboardRequestID,
                    completingNativeRequest: true,
                    deferredInputDisposition: .discard
                )
                return
            }
            guard let preparationService = requestSurfaceView
                .imageTransferPreparation else {
                runtimeClipboardLogger.warning(
                    "Clipboard read rejected: missing paste preparation service"
                )
                callbackContext.invalidateRuntimeClipboardRequest(
                    clipboardRequestID,
                    completingNativeRequest: true,
                    deferredInputDisposition: .replay
                )
                return
            }
            guard let inputAdmission = callbackContext
                .markRuntimeClipboardRequestAdmitted(
                clipboardRequestID
            ) else {
                return
            }
            var overflowCleanup: () -> Void = {}

            @MainActor
            func completeClipboardRequestOnMain(with text: String) {
                callbackContext.completeRuntimeClipboardRead(
                    text,
                    requestID: clipboardRequestID,
                    stateAddress: clipboardRequestID,
                    surfaceAddress: requestSurfaceAddress,
                    surfaceIdentity: requestSurfaceIdentity
                )
            }

            func completeClipboardRequest(with text: String) {
                Task { @MainActor [weak callbackContext] in
                    callbackContext?.completeRuntimeClipboardRead(
                        text,
                        requestID: clipboardRequestID,
                        stateAddress: clipboardRequestID,
                        surfaceAddress: requestSurfaceAddress,
                        surfaceIdentity: requestSurfaceIdentity
                    )
                }
            }

            requestSurfaceView.beginClipboardRead(
                clipboardRequestID,
                inputAdmission: inputAdmission,
                onOverflow: {
                    _ = operation.cancel()
                    overflowCleanup()
                    completeClipboardRequestOnMain(with: "")
                }
            )

            defer { pasteboardReadLease.finish() }
            guard await pasteboardReadLease.waitUntilReady(),
                  !Task.isCancelled else {
                return
            }

            guard let pasteboard = terminalPasteboard.pasteboard(for: location) else {
                completeClipboardRequest(with: "")
                return
            }
            let pasteboardTypeDescription = (pasteboard.types ?? [])
                .map(\.rawValue)
                .joined(separator: ",")

            let preparedContent: TerminalImageTransferPreparedContent
            if let inEventPreparedContent {
                preparedContent = inEventPreparedContent
            } else {
                preparedContent = await TerminalImageTransferPlanner.prepare(
                    pasteboard: pasteboard,
                    mode: .paste,
                    using: preparationService
                )
            }
            pasteboardReadLease.finish()

            guard !operation.isCancelled else {
                if case .fileURLs(let fileURLs) = preparedContent {
                    preparationService.cleanupTransferredTemporaryFiles(
                        .fileURLs(fileURLs)
                    )
                }
                return
            }

            guard requestSurfaceIdentity.matches(requestTerminalSurface) else {
                if case .fileURLs(let fileURLs) = preparedContent {
                    preparationService.cleanupTransferredTemporaryFiles(
                        .fileURLs(fileURLs)
                    )
                }
                completeClipboardRequest(with: "")
                return
            }

#if DEBUG
            cmuxDebugLog(
                "terminal.clipboard.read surface=\(callbackContext.surfaceId.uuidString.prefix(5)) " +
                "types=\(pasteboardTypeDescription) " +
                "prepared=\(preparedContent.cmuxDebugDescription)"
            )
#endif

            switch preparedContent {
            case .reject:
                // A pasteboard that ADVERTISES plain text but yielded nothing
                // from any flavor is macOS denying clipboard access, not an
                // empty clipboard. Swallowing that silently made Cmd+V look
                // dead with no trail; say so, once, with the fix. Complete
                // the request first so the advisory never holds it open.
                completeClipboardRequest(with: "")
                Self.presentPasteboardAccessDeniedAdvisoryIfNeeded(
                    pasteboard: pasteboard
                )
            case .insertText(let text):
                completeClipboardRequest(with: text)
            case .fileURLs(let fileURLs):
                let indicatorView = requestTerminalSurface.hostedView
                indicatorView.beginImageTransferIndicator(
                    for: operation,
                    onCancel: {
                        completeClipboardRequest(with: "")
                    }
                )
                overflowCleanup = {
                    indicatorView.endImageTransferIndicator(for: operation)
                }

                let target = requestTerminalSurface
                    .resolvedImageTransferTarget()
                let plan = TerminalImageTransferPlanner.plan(
                    fileURLs: fileURLs,
                    target: target
                )

                let handledByCustomUpload = Self.handleCustomPasteUploadIfMatched(
                    plan: plan,
                    operation: operation,
                    callbackContext: callbackContext,
                    surfaceIdentity: requestSurfaceIdentity,
                    indicatorView: indicatorView,
                    completeClipboardRequest: completeClipboardRequest
                )

                if !handledByCustomUpload {
                    TerminalImageTransferPlanner.execute(
                        plan: plan,
                        operation: operation,
                        uploadWorkspaceRemote: { fileURLs, operation, finish in
                            let workspace: Workspace? = MainActor.assumeIsolated {
                                guard requestSurfaceIdentity.matches(
                                    requestTerminalSurface
                                ) else { return nil }
                                return requestTerminalSurface.owningWorkspace()
                            }
                            guard let workspace else {
                                finish(.failure(NSError(domain: "cmux.remote.paste", code: 3)))
                                preparationService.cleanupTransferredTemporaryFiles(
                                    .fileURLs(fileURLs)
                                )
                                return
                            }
                            workspace.uploadDroppedFilesForRemoteTerminal(
                                fileURLs,
                                operation: operation,
                                completion: { result in
                                    finish(result)
                                    preparationService.cleanupTransferredTemporaryFiles(
                                        .fileURLs(fileURLs)
                                    )
                                }
                            )
                        },
                        uploadDetectedSSH: { session, fileURLs, operation, finish in
                            guard MainActor.assumeIsolated({
                                requestSurfaceIdentity.matches(requestTerminalSurface)
                            }) else {
                                finish(.failure(NSError(domain: "cmux.remote.paste", code: 4)))
                                preparationService.cleanupTransferredTemporaryFiles(
                                    .fileURLs(fileURLs)
                                )
                                return
                            }
                            session.uploadDroppedFiles(
                                fileURLs,
                                operation: operation,
                                completion: { result in
                                    finish(result)
                                    preparationService.cleanupTransferredTemporaryFiles(
                                        .fileURLs(fileURLs)
                                    )
                                }
                            )
                        },
                        insertText: { text in
                            MainActor.assumeIsolated {
                                indicatorView.endImageTransferIndicator(
                                    for: operation
                                )
                            }
                            completeClipboardRequest(with: text)
                        },
                        onFailure: { _ in
                            let shouldPresentFailure = MainActor.assumeIsolated {
                                indicatorView.endImageTransferIndicator(
                                    for: operation
                                )
                                return requestSurfaceIdentity.matches(
                                    requestTerminalSurface
                                )
                            }
                            if shouldPresentFailure {
                                NSSound.beep()
#if DEBUG
                                cmuxDebugLog(
                                    "terminal.remotePasteUpload.failed " +
                                    "surface=\(callbackContext.surfaceId.uuidString.prefix(5))"
                                )
#endif
                            }
                            completeClipboardRequest(with: "")
                        }
                    )
                }
            }
        }
        let attached = callbackContext.attachRuntimeClipboardTask(
            preparationTask,
            requestID: clipboardRequestID
        )
        let committed = attached && callbackContext
            .commitRuntimeClipboardRequest(clipboardRequestID)
        if committed {
            startContinuation.yield()
        } else {
            preparationTask.cancel()
            pasteboardReadLease.finish()
        }
        startContinuation.finish()

        return committed
    }
}
