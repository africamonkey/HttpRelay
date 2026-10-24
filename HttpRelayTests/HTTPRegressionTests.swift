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

    /// A second proxy on a port that is already taken must report the
    /// failure instead of pretending to be running.
    @Test @MainActor func proxy_reports_the_failure_when_the_port_is_taken() async throws {
        let first = try await TestProxy.start(logStore: LogStore())
        defer { first.stop() }

        let second = ProxyServer(port: first.port.rawValue, logStore: LogStore())
        do {
            try second.start()
        } catch {
            // Failing while the listener is created is a valid outcome too,
            // but it has to be reported as well.
            #expect(second.failureMessage != nil, "the proxy did not report the failure")
            #expect(second.isRunning == false)
            return
        }
        defer { second.stop() }

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline, second.failureMessage == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(second.failureMessage != nil, "the proxy did not report the failure")
        #expect(second.boundPort == nil, "the dead listener is still bound")
    }

    /// A start that was requested and then cancelled before the listener
    /// existed must not bring the proxy up.
    ///
    /// The listener is created on a background queue, so the user can switch
    /// the server off while that is still happening. The stop has to win.
    @Test @MainActor func a_start_that_was_cancelled_does_not_bring_the_proxy_up() async throws {
        let server = ProxyServer(port: 0, logStore: LogStore())

        let runID = server.beginRun()
        server.stop()
        try server.start(runID: runID)

        // Give the listener a chance to come up, if it were going to.
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(server.isRunning == false, "the proxy came up although it was stopped")
        #expect(server.boundPort == nil, "the listener is still bound")
    }

    /// A start that arrives late must not take over a run that was started
    /// again in the meantime.
    ///
    /// This is the case the run id exists for: the user switches the server
    /// off and on again while the first listener is still being created, so
    /// two starts are in flight and the older one must be ignored.
    @Test @MainActor func a_stale_start_does_not_take_over_a_newer_run() async throws {
        let server = ProxyServer(port: 0, logStore: LogStore())

        let staleRunID = server.beginRun()
        server.stop()
        _ = server.beginRun()

        try server.start(runID: staleRunID)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(server.boundPort == nil, "the stale start brought the listener up")
        #expect(server.isRunning == false)
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
