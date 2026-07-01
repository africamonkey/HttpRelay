import Foundation
import Network

struct TestError: Error { let msg: String; init(_ m: String) { msg = m } }

enum TestEcho {
    static func startTCP() async throws -> RunningEcho {
        let l = try NWListener(using: .tcp, on: .any)
        let ready = AsyncStream<Void>.makeStream()
        l.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield() }
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: .global())
            Self.echoLoopTCP(conn)
        }
        l.start(queue: .global())
        _ = await ready.stream.first(where: { _ in true })
        guard let port = l.port else { throw TestError("listener has no port") }
        return RunningEcho(listener: l, port: port)
    }

    static func startUDP() async throws -> RunningEcho {
        let l = try NWListener(using: .udp, on: .any)
        let ready = AsyncStream<Void>.makeStream()
        l.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield() }
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: .global())
            Self.echoLoopUDP(conn)
        }
        l.start(queue: .global())
        _ = await ready.stream.first(where: { _ in true })
        guard let port = l.port else { throw TestError("listener has no port") }
        return RunningEcho(listener: l, port: port)
    }

    private static func echoLoopTCP(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if error != nil || isComplete { conn.cancel(); return }
            guard let data = data, !data.isEmpty else { echoLoopTCP(conn); return }
            conn.send(content: data, isComplete: isComplete, completion: .contentProcessed { _ in
                if isComplete { return }
                echoLoopTCP(conn)
            })
        }
    }

    private static func echoLoopUDP(_ conn: NWConnection) {
        conn.receiveMessage { data, _, _, error in
            if error != nil { conn.cancel(); return }
            guard let data = data else { echoLoopUDP(conn); return }
            conn.send(content: data, completion: .contentProcessed { _ in
                echoLoopUDP(conn)
            })
        }
    }
}

struct RunningEcho {
    let listener: NWListener
    let port: NWEndpoint.Port
    func stop() async { listener.cancel() }
}
