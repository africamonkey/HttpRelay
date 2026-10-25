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

    /// A CONNECT request must not log the authority as if it were a path.
    ///
    /// The request-target of a CONNECT request is `host:port` (RFC 9110
    /// §7.2), not a path. If it is stored as the path, the detail view
    /// prints `host:port` twice.
    @Test @MainActor func connect_request_does_not_log_the_authority_as_the_path() async throws {
        let logStore = LogStore()
        let proxy = try await TestProxy.start(logStore: logStore)

        let conn = NWConnection(host: .ipv4(.loopback), port: proxy.port, using: .tcp)
        conn.start(queue: .global())
        let request = "CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n"
        try await TestTCP.send(conn, request.data(using: .utf8)!, timeout: .seconds(2))
        _ = try await TestTCP.receive(conn, minIncomplete: 12, maxLength: 256, timeout: .seconds(2))
        conn.cancel()
        proxy.stop()

        // The entry is written from a MainActor task, so wait for it.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, logStore.entries.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let entry = try #require(logStore.entries.first)
        #expect(entry.method == .connect)
        #expect(entry.path != "127.0.0.1:9", "the authority was logged as the path")
        #expect(entry.fullURL == "127.0.0.1:9", "the URL repeats the authority: \(entry.fullURL)")
    }

    /// A plain HTTP request whose target carries no port must not be
    /// rejected.
    ///
    /// A proxy request uses the absolute form, and the port may be left
    /// out - it is then the default port of the scheme.
    @Test @MainActor func a_plain_http_request_without_a_port_is_not_rejected() async throws {
        let logStore = LogStore()
        let proxy = try await TestProxy.start(logStore: logStore)

        let conn = NWConnection(host: .ipv4(.loopback), port: proxy.port, using: .tcp)
        conn.start(queue: .global())
        let request = "GET http://127.0.0.1/ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        try await TestTCP.send(conn, request.data(using: .utf8)!, timeout: .seconds(2))
        let reply = try await TestTCP.receive(conn, minIncomplete: 12, maxLength: 256, timeout: .seconds(5))
        let statusLine = String(data: reply.prefix(12), encoding: .utf8) ?? ""
        conn.cancel()
        proxy.stop()

        // The entry is written from a MainActor task, so wait for it.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, logStore.entries.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(statusLine.hasPrefix("HTTP/1.1 "), "the proxy answered '\(statusLine)'")
        #expect(!statusLine.hasPrefix("HTTP/1.1 400"), "the proxy rejected the request: \(statusLine)")

        // The target of the request has no port, so the proxy has to use
        // the default port of the scheme.
        let entry = try #require(logStore.entries.first)
        #expect(entry.host == "127.0.0.1")
        #expect(entry.port == 80, "the proxy used the port \(entry.port) instead of the default port")
    }

    /// A plain HTTP request has to be forwarded to the target the way the
    /// client asked for it: with the path percent-encoded and with the
    /// Host header of the target.
    @Test @MainActor func a_plain_http_request_is_forwarded_as_it_was_asked_for() async throws {
        let echo = try await TestEcho.startTCP()
        defer { Task { await echo.stop() } }

        let proxy = try await TestProxy.start(logStore: LogStore())
        let conn = NWConnection(host: .ipv4(.loopback), port: proxy.port, using: .tcp)
        conn.start(queue: .global())
        let request = "GET http://127.0.0.1:\(echo.port.rawValue)/a%20b?q=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        try await TestTCP.send(conn, request.data(using: .utf8)!, timeout: .seconds(2))

        // The target echoes the request back, so the client sees what the
        // proxy forwarded.
        let reply = try await TestTCP.receive(conn, minIncomplete: 12, maxLength: 4096, timeout: .seconds(5))
        let forwarded = String(data: reply, encoding: .utf8) ?? ""
        conn.cancel()
        proxy.stop()

        #expect(forwarded.hasPrefix("GET /a%20b?q=1 HTTP/1.1\r\n"), "the proxy forwarded '\(forwarded)'")
        #expect(forwarded.contains("Host: 127.0.0.1:\(echo.port.rawValue)\r\n"), "the proxy forwarded '\(forwarded)'")
        #expect(!forwarded.contains("Host: 127.0.0.1\r\n"), "the proxy forwarded the Host header of the client: '\(forwarded)'")
    }

    /// A tunnel that could not be established has to be logged as failed.
    @Test @MainActor func a_tunnel_that_cannot_be_established_is_logged_as_failed() async throws {
        let logStore = LogStore()
        let proxy = try await TestProxy.start(logStore: logStore)

        let conn = NWConnection(host: .ipv4(.loopback), port: proxy.port, using: .tcp)
        conn.start(queue: .global())
        let request = "CONNECT 127.0.0.1:9 HTTP/1.1\r\nHost: 127.0.0.1:9\r\n\r\n"
        try await TestTCP.send(conn, request.data(using: .utf8)!, timeout: .seconds(2))
        _ = try await TestTCP.receive(conn, minIncomplete: 12, maxLength: 256, timeout: .seconds(5))
        conn.cancel()
        proxy.stop()

        // The entry is written from a MainActor task, so wait for it.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, logStore.entries.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let entry = try #require(logStore.entries.first)
        #expect(entry.status == .failed, "the failed tunnel is logged as '\(entry.status.rawValue)'")
    }

    /// A CONNECT to a port no connection can be made to has to be
    /// rejected, not crash the proxy.
    @Test @MainActor func a_connect_to_an_impossible_port_is_rejected() async throws {
        let proxy = try await TestProxy.start(logStore: LogStore())

        let conn = NWConnection(host: .ipv4(.loopback), port: proxy.port, using: .tcp)
        conn.start(queue: .global())
        let request = "CONNECT 127.0.0.1:70000 HTTP/1.1\r\nHost: 127.0.0.1:70000\r\n\r\n"
        try await TestTCP.send(conn, request.data(using: .utf8)!, timeout: .seconds(2))
        let reply = try await TestTCP.receive(conn, minIncomplete: 12, maxLength: 256, timeout: .seconds(5))
        let statusLine = String(data: reply.prefix(12), encoding: .utf8) ?? ""
        conn.cancel()
        proxy.stop()

        #expect(statusLine.hasPrefix("HTTP/1.1 400"), "the proxy answered '\(statusLine)'")
    }

    /// A tunnel that was up must not get an error status line any more
    /// when it breaks.
    ///
    /// The client speaks another protocol on an established tunnel, so a
    /// status line would only corrupt the stream.
    @Test @MainActor func a_tunnel_that_was_up_is_not_answered_with_an_error() async throws {
        let target = try TestResettingTarget.start()
        defer { target.stop() }

        let proxy = try await TestProxy.start(logStore: LogStore())
        let conn = NWConnection(host: .ipv4(.loopback), port: proxy.port, using: .tcp)
        conn.start(queue: .global())
        let request = "CONNECT 127.0.0.1:\(target.port) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        try await TestTCP.send(conn, request.data(using: .utf8)!, timeout: .seconds(2))

        // Read everything the client gets until the connection ends.
        var received = ""
        while let chunk = try? await TestTCP.receive(conn, minIncomplete: 1, maxLength: 4096, timeout: .seconds(3)) {
            received += String(data: chunk, encoding: .utf8) ?? ""
        }
        conn.cancel()
        proxy.stop()

        #expect(received.hasPrefix("HTTP/1.1 200 Connection Established"), "the client got '\(received)'")
        #expect(!received.contains("502"), "an error was injected into an established tunnel: '\(received)'")
    }

    /// The body of a request must reach the target, also when it arrives
    /// in the same segment as the header block.
    @Test @MainActor func the_body_of_a_plain_http_request_reaches_the_target() async throws {
        let echo = try await TestEcho.startTCP()
        defer { Task { await echo.stop() } }

        let proxy = try await TestProxy.start(logStore: LogStore())
        let conn = NWConnection(host: .ipv4(.loopback), port: proxy.port, using: .tcp)
        conn.start(queue: .global())
        let body = "name=agent"
        let request = "POST http://127.0.0.1:\(echo.port.rawValue)/form HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\n\r\n\(body)"
        try await TestTCP.send(conn, request.data(using: .utf8)!, timeout: .seconds(2))

        // The target echoes the request back, so the client sees what the
        // proxy forwarded.
        var forwarded = ""
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline, !forwarded.contains(body) {
            let reply = try await TestTCP.receive(conn, minIncomplete: 12, maxLength: 4096, timeout: .seconds(2))
            forwarded += String(data: reply, encoding: .utf8) ?? ""
        }
        conn.cancel()
        proxy.stop()

        #expect(forwarded.contains("Content-Length: \(body.count)"), "the proxy forwarded '\(forwarded)'")
        #expect(forwarded.hasSuffix(body), "the body did not reach the target: '\(forwarded)'")
    }

    /// The headers that belong to the connection between the client and
    /// the proxy must not be forwarded (RFC 9110 §7.6.1).
    @Test @MainActor func hop_by_hop_headers_are_not_forwarded() async throws {
        let echo = try await TestEcho.startTCP()
        defer { Task { await echo.stop() } }

        let proxy = try await TestProxy.start(logStore: LogStore())
        let conn = NWConnection(host: .ipv4(.loopback), port: proxy.port, using: .tcp)
        conn.start(queue: .global())
        let request = "GET http://127.0.0.1:\(echo.port.rawValue)/ HTTP/1.1\r\nHost: 127.0.0.1\r\nProxy-Connection: keep-alive\r\nConnection: keep-alive, X-Private\r\nX-Private: secret\r\n\r\n"
        try await TestTCP.send(conn, request.data(using: .utf8)!, timeout: .seconds(2))

        // The target echoes the request back, so the client sees what the
        // proxy forwarded.
        let reply = try await TestTCP.receive(conn, minIncomplete: 12, maxLength: 4096, timeout: .seconds(5))
        let forwarded = String(data: reply, encoding: .utf8) ?? ""
        conn.cancel()
        proxy.stop()

        #expect(!forwarded.lowercased().contains("proxy-connection"), "the proxy forwarded '\(forwarded)'")
        #expect(!forwarded.lowercased().contains("x-private"), "the proxy forwarded '\(forwarded)'")
        #expect(!forwarded.lowercased().contains("connection: keep-alive"), "the proxy forwarded '\(forwarded)'")
        #expect(forwarded.contains("Host: 127.0.0.1:\(echo.port.rawValue)"), "the proxy forwarded '\(forwarded)'")
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
