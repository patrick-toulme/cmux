import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RemoteTmuxCapabilitiesTests {
    @Test func systemCapabilitiesAdvertisesRemoteTmuxMethods() throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"system.capabilities","params":{}}"#
        let responseText = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try #require(response["result"] as? [String: Any])
        let methods = try #require(result["methods"] as? [String])
        let advertisedMethods = Set(methods)

        let expected = [
            "remote.tmux.sessions",
            "remote.tmux.probe",
            "remote.tmux.attach",
            "remote.tmux.detach",
            "remote.tmux.state",
            "remote.tmux.mirror",
            "remote.tmux.window",
        ]
        let missing = expected.filter { !advertisedMethods.contains($0) }
        #expect(missing.isEmpty, "not advertised: \(missing)")
    }

    /// Requests without a host must fail a network-free guard, never dispatch as
    /// unknown methods or touch SSH. This covers both placement entry points and
    /// the probe preflight.
    ///
    /// The probe case is the multi-machine attach's capability check: the CLI
    /// sends exactly this empty-params request and treats `method_not_found` as
    /// "legacy app, run the sequential interactive path". A probe handler that
    /// exists in the worker switch but is missing from the execution policy is
    /// classified main-actor, where the main switch has no case for it and
    /// answers `method_not_found`: the pipeline then silently degrades on every
    /// attach. Pinning the structured guard error here (through the real
    /// dispatcher, not the policy table) catches that drift.
    @Test(arguments: ["remote.tmux.mirror", "remote.tmux.window", "remote.tmux.probe"])
    func mirrorWithoutHostReturnsStructuredErrorBeforeNetwork(method: String) throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{}}"#
        let responseText = TerminalController.shared.handleSocketLine(request)
        let responseData = try #require(responseText.data(using: .utf8))
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])

        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        let code = try #require(error["code"] as? String)

        #expect(code == "disabled" || code == "invalid_params", "\(method) answered \(code)")
    }
}
