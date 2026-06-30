import Testing
import Network
import Foundation
@testable import HttpRelay

@Suite("SOCKS5 protocol")
struct SOCKS5Tests {

    @Test @MainActor func greeting_noAuth_returns0x05_0x00() async throws {
        let server = try await TestSOCKS5.start()
        let conn = NWConnection(host: .ipv4(.loopback), port: server.port, using: .tcp)
        let recv = try await TestSOCKS5.connectAndReceive(conn, count: 2, timeout: .seconds(2))
        #expect(recv == Data([0x05, 0x00]))
        conn.cancel()
        await server.stop()
    }

    @Test @MainActor func greeting_noCompatibleMethod_returns0xFF_andCloses() async throws {
        let server = try await TestSOCKS5.start()
        let conn = NWConnection(host: .ipv4(.loopback), port: server.port, using: .tcp)
        let sendData = Data([0x05, 0x01, 0x02])
        let recv = try await TestTCP.sendAndRecv(conn, sendData, count: 2, timeout: .seconds(2))
        #expect(recv == Data([0x05, 0xFF]))

        // After receiving 0x05 0xFF, the server cancels. Verify by attempting
        // another receive — peer-close should manifest as immediate completion
        // with no data, error, or timeout. (iOS Simulator does NOT propagate
        // peer's cancel into client's `.cancelled` state, so we use a softer
        // signal: the connection is no longer sending data and is closed.)
        var peerClosed = false
        do {
            let more = try await TestTCP.receive(conn, minIncomplete: 1, maxLength: 1, timeout: .seconds(2))
            if more.isEmpty { peerClosed = true }
        } catch {
            peerClosed = true
        }
        #expect(peerClosed == true)

        conn.cancel()
        await server.stop()
    }
}

enum TestSOCKS5 {

    @MainActor
    static func start() async throws -> Running {
        let logStore = LogStore()
        let socks5Server = SOCKS5Server(logStore: logStore)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume() }
                case .failed(let error):
                    if !resumed { resumed = true; cont.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                socks5Server.handle(connection: connection)
            }
            listener.start(queue: .global())
        }

        guard let port = listener.port else {
            throw NSError(domain: "TestSOCKS5", code: 0, userInfo: [NSLocalizedDescriptionKey: "listener has no port"])
        }
        return Running(port: port, listener: listener, server: socks5Server)
    }

    static func connectAndReceive(_ conn: NWConnection, count: Int, timeout: Duration) async throws -> Data {
        try await TestTCP.sendAndRecv(conn, Data([0x05, 0x01, 0x00]), count: count, timeout: timeout)
    }
}

struct Running {
    let port: NWEndpoint.Port
    private let listener: NWListener
    private let server: SOCKS5Server

    init(port: NWEndpoint.Port, listener: NWListener, server: SOCKS5Server) {
        self.port = port
        self.listener = listener
        self.server = server
    }

    func stop() async {
        listener.cancel()
        server.stop()
    }
}