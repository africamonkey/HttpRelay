import Testing
import Network
import Foundation
@testable import HttpRelay

@Suite("HTTP regression")
struct HTTPRegressionTests {

    /// Full HTTP CONNECT round-trip through the polyglot dispatcher:
    /// the proxy must accept the CONNECT bytes (uppercase 'C' first byte),
    /// parse them, and reply with an HTTP/1.1 status line. The reply may be
    /// 200 (target reachable) or a 5xx (target refused); either way it
    /// starts with `HTTP/1.1 `, which is what the dispatcher is responsible
    /// for producing.
    @Test @MainActor func http_CONNECT_through_polyglot_dispatch() async throws {
        let proxy = try await TestProxy.start(logStore: LogStore())
        let conn = NWConnection(host: .ipv4(.loopback), port: proxy.port, using: .tcp)
        conn.start(queue: .global())
        let sendData = ("CONNECT 127.0.0.1:1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").data(using: .utf8)!
        try await TestTCP.send(conn, sendData, timeout: .seconds(2))
        let reply = try await TestTCP.receive(conn, minIncomplete: 12, maxLength: 256, timeout: .seconds(2))
        let prefix = String(data: reply.prefix(9), encoding: .utf8) ?? ""
        #expect(prefix == "HTTP/1.1 ")
        conn.cancel()
        proxy.stop()
    }
}

/// Test helper that starts a real ProxyServer on an OS-assigned port.
/// Returns once the listener has bound a port. Tests must call `stop()`
/// to release the listener.
enum TestProxy {
    @MainActor
    static func start(logStore: LogStore) async throws -> RunningProxy {
        let proxy = ProxyServer(port: 0, logStore: logStore)
        try proxy.start()

        // Poll boundPort (set by the listener's state update handler on .main).
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if let port = proxy.boundPort, port.rawValue != 0 {
                return RunningProxy(port: port, proxy: proxy)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        proxy.stop()
        throw NSError(domain: "TestProxy", code: 0,
                      userInfo: [NSLocalizedDescriptionKey: "listener did not bind within 3s"])
    }
}

struct RunningProxy {
    let port: NWEndpoint.Port
    private let proxy: ProxyServer

    init(port: NWEndpoint.Port, proxy: ProxyServer) {
        self.port = port
        self.proxy = proxy
    }

    @MainActor
    func stop() {
        proxy.stop()
    }
}
