import Foundation
import Network

/// Test helper that runs a UDP `NWListener` and aggregates incoming
/// datagrams into an `AsyncStream`. Used to simulate a SOCKS5 client
/// sending UDP datagrams via UDP_ASSOCIATE.
enum TestUDPListener {

    /// Start a UDP listener on `.any` port. Returns once `.ready`.
    static func start() async throws -> RunningUDP {
        let l = try NWListener(using: .udp, on: .any)
        let pair = AsyncStream<Data>.makeStream()

        let ready = AsyncStream<Void>.makeStream()
        l.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield() }
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: .global())
            Self.receiveLoop(conn, into: pair.continuation)
        }
        l.start(queue: .global())
        _ = await ready.stream.first(where: { _ in true })
        guard let port = l.port else { throw TestError("TestUDPListener listener has no port") }

        return RunningUDP(port: port, listener: l, stream: pair.stream, continuation: pair.continuation)
    }

    /// Send a UDP datagram to `host:port`. Opens a fresh outbound
    /// `NWConnection`, waits for `.ready`, then sends.
    static func send(_ listener: RunningUDP, _ data: Data, toHost host: String, port: UInt16) async throws {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let conn = NWConnection(to: endpoint, using: .udp)
        conn.start(queue: .global())
        try await TestTCP.waitReady(conn, timeout: .seconds(2))
        try await TestTCP.send(conn, data, timeout: .seconds(2))
        conn.cancel()
    }

    /// Receive up to `count` bytes. Throws on timeout.
    static func recv(_ listener: RunningUDP, count: Int, timeout: Duration) async throws -> Data {
        let interval = TestTCP.seconds(timeout)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let lock = NSLock()
            var resumed = false
            func safeResume(_ block: () -> Void) {
                lock.lock()
                if resumed { lock.unlock(); return }
                resumed = true
                lock.unlock()
                block()
            }
            let deadline = DispatchWorkItem {
                safeResume {
                    cont.resume(throwing: NSError(domain: "TestUDPListener", code: 1, userInfo: [NSLocalizedDescriptionKey: "recv timeout"]))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: deadline)
            Task {
                var found: Data?
                for await data in listener.stream {
                    if data.count >= count {
                        found = data.prefix(count)
                        break
                    }
                }
                deadline.cancel()
                if let data = found {
                    safeResume { cont.resume(returning: Data(data)) }
                } else {
                    safeResume {
                        cont.resume(throwing: NSError(domain: "TestUDPListener", code: 2, userInfo: [NSLocalizedDescriptionKey: "stream ended"]))
                    }
                }
            }
        }
    }

    /// Receive up to `count` bytes. Returns empty `Data` on timeout instead of throwing.
    static func recvWithTimeout(_ listener: RunningUDP, count: Int, timeout: Duration) async throws -> Data {
        let interval = TestTCP.seconds(timeout)
        return await withTaskGroup(of: Data?.self, returning: Data.self) { group in
            group.addTask {
                for await data in listener.stream {
                    if data.count >= count { return data.prefix(count) }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result.map { Data($0) } ?? Data()
        }
    }

    /// Cancel the listener and finish the stream.
    static func stop(_ listener: RunningUDP) async {
        listener.listener.cancel()
        listener.continuation.finish()
    }

    private static func receiveLoop(_ conn: NWConnection, into continuation: AsyncStream<Data>.Continuation) {
        conn.receiveMessage { data, _, _, error in
            if error != nil { conn.cancel(); return }
            if let data = data, !data.isEmpty {
                continuation.yield(data)
            }
            Self.receiveLoop(conn, into: continuation)
        }
    }
}

struct RunningUDP {
    let port: NWEndpoint.Port
    let listener: NWListener
    let stream: AsyncStream<Data>
    let continuation: AsyncStream<Data>.Continuation
}