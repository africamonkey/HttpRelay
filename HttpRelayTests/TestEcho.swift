import Foundation
import Network

struct TestError: Error { let msg: String; init(_ m: String) { msg = m } }

enum TestEcho {
    static func startTCP() async throws -> RunningEcho {
        let l = try NWListener(using: .tcp, on: .any)
        let pair = AsyncStream<Data>.makeStream()
        let ready = AsyncStream<Void>.makeStream()
        l.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield() }
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: .global())
            Self.echoLoopTCP(conn, recorded: pair.continuation)
        }
        l.start(queue: .global())
        _ = await ready.stream.first(where: { _ in true })
        guard let port = l.port else { throw TestError("listener has no port") }
        return RunningEcho(listener: l, port: port, recorded: pair.stream, recorderContinuation: pair.continuation)
    }

    static func startUDP() async throws -> RunningEcho {
        let l = try NWListener(using: .udp, on: .any)
        let pair = AsyncStream<Data>.makeStream()
        let ready = AsyncStream<Void>.makeStream()
        l.stateUpdateHandler = { state in
            if case .ready = state { ready.continuation.yield() }
        }
        l.newConnectionHandler = { conn in
            conn.start(queue: .global())
            Self.echoLoopUDP(conn, recorded: pair.continuation)
        }
        l.start(queue: .global())
        _ = await ready.stream.first(where: { _ in true })
        guard let port = l.port else { throw TestError("listener has no port") }
        return RunningEcho(listener: l, port: port, recorded: pair.stream, recorderContinuation: pair.continuation)
    }

    private static func echoLoopTCP(_ conn: NWConnection, recorded: AsyncStream<Data>.Continuation) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if error != nil || isComplete { conn.cancel(); return }
            guard let data = data, !data.isEmpty else { echoLoopTCP(conn, recorded: recorded); return }
            recorded.yield(data)
            conn.send(content: data, isComplete: isComplete, completion: .contentProcessed { _ in
                if isComplete { return }
                echoLoopTCP(conn, recorded: recorded)
            })
        }
    }

    private static func echoLoopUDP(_ conn: NWConnection, recorded: AsyncStream<Data>.Continuation) {
        conn.receiveMessage { data, _, _, error in
            if error != nil { conn.cancel(); return }
            guard let data = data else { echoLoopUDP(conn, recorded: recorded); return }
            recorded.yield(data)
            conn.send(content: data, completion: .contentProcessed { _ in
                echoLoopUDP(conn, recorded: recorded)
            })
        }
    }
}

struct RunningEcho {
    let listener: NWListener
    let port: NWEndpoint.Port
    let recorded: AsyncStream<Data>
    let recorderContinuation: AsyncStream<Data>.Continuation
    func stop() async {
        recorderContinuation.finish()
        listener.cancel()
    }
}
