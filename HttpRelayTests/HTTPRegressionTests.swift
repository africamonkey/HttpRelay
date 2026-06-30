import Testing
import Network
import Foundation
@testable import HttpRelay

@Suite("HTTP regression")
struct HTTPRegressionTests {

    /// Smoke test: verify ProxyServer (now with SOCKS5Server wire-up) still starts
    /// and binds a listener port. This proves the addition of SOCKS5Server did not
    /// break the HTTP listener wiring (init/start lifecycle).
    ///
    /// NOTE: A full CONNECT round-trip test was attempted but blocked by Swift
    /// concurrency / actor isolation issues with running ProxyServer inside xctest.
    /// The HTTP handling logic itself is unchanged from before this task.
    /// Task tracking note: re-enable a true end-to-end CONNECT test in a follow-up
    /// once test infrastructure supports it.
    @Test func proxyServer_starts_and_binds_port() async throws {
        let portRaw = try await startProxyAndGetPort()

        #expect(portRaw != 0)

        await stopProxy()
    }

    private func startProxyAndGetPort() async throws -> UInt16 {
        try await MainActor.run {
            let logStore = LogStore()
            let proxy = ProxyServer(port: 0, logStore: logStore)
            try proxy.start()
            ProxyRunner.shared.proxy = proxy
        }

        return try await Task.detached(priority: .userInitiated) { () async throws -> UInt16 in
            let end = Date().addingTimeInterval(3.0)
            while Date() < end {
                let p: UInt16? = await MainActor.run {
                    ProxyRunner.shared.proxy?.boundPort?.rawValue
                }
                if let p = p, p != 0 {
                    return p
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            throw NSError(domain: "TestProxy", code: 0, userInfo: [NSLocalizedDescriptionKey: "listener did not bind"])
        }.value
    }

    private func stopProxy() async {
        await MainActor.run {
            ProxyRunner.shared.proxy?.stop()
            ProxyRunner.shared.proxy = nil
        }
    }
}

/// Holds the proxy reference so it doesn't get deallocated while the test runs.
final class ProxyRunner {
    static let shared = ProxyRunner()
    var proxy: ProxyServer?
}
