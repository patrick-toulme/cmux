import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlCommandContext`` whose only real witness is the
/// external URL open: it records every request the coordinator hands it and
/// answers with a scripted outcome, so the tests pin the wire contract of
/// `system.open_url` (validation, payload, error mapping) without AppKit.
@MainActor
private final class FakeOpenURLControlCommandContext: ControlCommandContext {
    private(set) var requests: [ControlExternalURLOpenRequest] = []
    var outcome: ControlExternalURLOpenOutcome = .opened(handler: "Google Chrome")

    nonisolated func controlSystemOpenExternalURL(
        _ request: ControlExternalURLOpenRequest
    ) async -> ControlExternalURLOpenOutcome {
        await MainActor.run {
            requests.append(request)
            return outcome
        }
    }
}

@MainActor
@Suite("system.open_url")
struct ControlCommandCoordinatorSystemOpenURLTests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeOpenURLControlCommandContext) {
        let context = FakeOpenURLControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    private func request(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "system.open_url", params: params)
    }

    // MARK: - Request validation

    @Test func webURLsParseWithTheirSchemeAndHost() throws {
        let short = try ControlExternalURLOpenRequest.parse(params: ["url": .string(" http://cl/975315547 ")]).get()
        #expect(short.url.absoluteString == "http://cl/975315547")
        #expect(short.activates)

        let secure = try ControlExternalURLOpenRequest.parse(params: ["url": .string("HTTPS://b/1?x=1#frag")]).get()
        #expect(secure.url.host == "b")
        #expect(secure.url.scheme?.lowercased() == "https")
    }

    @Test func activateAcceptsTheCoordinatorBoolSpellings() throws {
        for value in [JSONValue.bool(false), .int(0), .string("no"), .string("OFF")] {
            let parsed = try ControlExternalURLOpenRequest.parse(params: ["url": .string("http://go/x"), "activate": value]).get()
            #expect(!parsed.activates, "\(value)")
        }
        for value in [JSONValue.bool(true), .int(1), .string("yes"), .string("garbage"), .null] {
            let parsed = try ControlExternalURLOpenRequest.parse(params: ["url": .string("http://go/x"), "activate": value]).get()
            #expect(parsed.activates, "\(value)")
        }
    }

    @Test func nonWebURLsAreRefusedBeforeReachingTheApp() {
        #expect(ControlExternalURLOpenRequest.parse(params: [:]) == .failure(.missingURL))
        #expect(ControlExternalURLOpenRequest.parse(params: ["url": .string("   ")]) == .failure(.missingURL))
        #expect(ControlExternalURLOpenRequest.parse(params: ["url": .int(42)]) == .failure(.missingURL))
        #expect(ControlExternalURLOpenRequest.parse(params: ["url": .string("cl/975315547")]) == .failure(.unsupportedScheme("")))
        #expect(ControlExternalURLOpenRequest.parse(params: ["url": .string("file:///etc/passwd")]) == .failure(.unsupportedScheme("file")))
        #expect(ControlExternalURLOpenRequest.parse(params: ["url": .string("ssh://evil.example")]) == .failure(.unsupportedScheme("ssh")))
        #expect(
            ControlExternalURLOpenRequest.parse(params: ["url": .string("x-apple.systempreferences:com.apple.preference")])
                == .failure(.unsupportedScheme("x-apple.systempreferences"))
        )
        #expect(ControlExternalURLOpenRequest.parse(params: ["url": .string("http:///no-host")]) == .failure(.missingHost))
        #expect(ControlExternalURLOpenRequest.parse(params: ["url": .string("http://exa mple.com/")]) == .failure(.invalidURL("http://exa mple.com/")))
    }

    // MARK: - Coordinator dispatch

    @Test func opensThroughTheSeamAndReportsTheHandler() async {
        let (coordinator, context) = makeCoordinator()
        let result = await coordinator.handleSystemAsync(request(["url": .string("http://cl/975315547")]), context: context)
        #expect(result == .ok(.object([
            "opened": .bool(true),
            "url": .string("http://cl/975315547"),
            "activated": .bool(true),
            "handler": .string("Google Chrome"),
        ])))
        #expect(context.requests.map(\.url.absoluteString) == ["http://cl/975315547"])
        #expect(context.requests.map(\.activates) == [true])
    }

    @Test func activateFalsePassesThroughToTheSeam() async {
        let (coordinator, context) = makeCoordinator()
        context.outcome = .opened(handler: nil)
        let result = await coordinator.handleSystemAsync(
            request(["url": .string("https://go/morris"), "activate": .bool(false)]),
            context: context
        )
        #expect(result == .ok(.object([
            "opened": .bool(true),
            "url": .string("https://go/morris"),
            "activated": .bool(false),
            "handler": .null,
        ])))
        #expect(context.requests.map(\.activates) == [false])
    }

    @Test func refusedURLsNeverReachTheSeam() async {
        let (coordinator, context) = makeCoordinator()
        let result = await coordinator.handleSystemAsync(request(["url": .string("file:///etc/passwd")]), context: context)
        guard case let .err(code, message, data)? = result else {
            Issue.record("expected invalid_params, got \(String(describing: result))")
            return
        }
        #expect(code == "invalid_params")
        #expect(message.contains("file"))
        #expect(data == .object(["url": .string("file:///etc/passwd")]))
        #expect(context.requests.isEmpty)

        let missing = await coordinator.handleSystemAsync(request([:]), context: context)
        #expect(missing == .err(code: "invalid_params", message: "system.open_url requires params.url", data: .object(["url": .null])))
        #expect(context.requests.isEmpty)
    }

    @Test func aFailedOpenIsAnUnavailableErrorNotASilentOK() async {
        let (coordinator, context) = makeCoordinator()
        context.outcome = .failed(message: "No application knows how to open URL http://cl/1")
        let result = await coordinator.handleSystemAsync(request(["url": .string("http://cl/1")]), context: context)
        #expect(result == .err(
            code: "unavailable",
            message: "No application knows how to open URL http://cl/1",
            data: .object(["url": .string("http://cl/1")])
        ))
    }

    @Test func aDetachedContextFailsClosed() async {
        let (coordinator, _) = makeCoordinator()
        let result = await coordinator.handleSystemAsync(request(["url": .string("http://cl/1")]), context: nil)
        #expect(result == .err(code: "unavailable", message: "System context not attached", data: nil))
    }

    @Test func onlyTheAsyncLaneAnswersAndOtherMethodsFallThrough() async {
        let (coordinator, context) = makeCoordinator()
        #expect(await coordinator.handleSystemAsync(
            ControlRequest(id: .int(1), method: "system.ping", params: [:]),
            context: context
        ) == nil)
        // The main-actor dispatch does not know the method: a main-lane entry
        // must answer method_not_found / invalid_dispatch upstream, never open.
        #expect(coordinator.handleSystem(request(["url": .string("http://cl/1")])) == nil)
        #expect(context.requests.isEmpty)
    }
}
