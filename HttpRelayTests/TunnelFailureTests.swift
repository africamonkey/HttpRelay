import Testing
import Foundation
@testable import HttpRelay

@Suite("Tunnel failure")
struct TunnelFailureTests {

    /// A tunnel that was never up leaves the client waiting for a status
    /// line, so it gets one.
    @Test @MainActor func a_tunnel_that_was_never_up_is_answered_with_a_status_line() {
        let manager = makeTunnelManager()

        #expect(manager.answerWhenTunnelBreaks == .statusLine)
        #expect(manager.answerWhenTargetBreaks == .statusLine)
    }

    /// A tunnel that was up carries another protocol - TLS for a CONNECT -
    /// so the client must not get a status line: it would corrupt the
    /// stream.
    @Test @MainActor func a_tunnel_that_was_up_is_not_answered_with_a_status_line() {
        let manager = makeTunnelManager()
        manager.markConnected()

        #expect(manager.answerWhenTunnelBreaks == .endOfConnection)
    }

    /// A target that already answered must not be answered again: the
    /// status line would land in the middle of its response.
    @Test @MainActor func a_target_that_already_answered_is_not_answered_again() {
        let manager = makeTunnelManager()
        manager.markResponseReceived()

        #expect(manager.answerWhenTargetBreaks == .endOfConnection)
    }

    @MainActor
    private func makeTunnelManager() -> TunnelManager {
        let logStore = LogStore()
        let entry = logStore.log(
            host: "example.com",
            port: 443,
            path: "",
            query: nil,
            method: .connect,
            requestHeaders: [:]
        )
        return TunnelManager(host: "example.com", port: 443, logStore: logStore, logEntry: entry)
    }
}
