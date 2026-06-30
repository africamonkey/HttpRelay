import Foundation
import Network

enum TestTCP {

    static func sendAndRecv(_ conn: NWConnection, _ data: Data, count: Int, timeout: Duration) async throws -> Data {
        conn.stateUpdateHandler = { _ in }
        conn.start(queue: .global())
        try await waitReady(conn, timeout: timeout)
        try await send(conn, data, timeout: timeout)
        return try await receive(conn, minIncomplete: count, maxLength: count, timeout: timeout)
    }

    static func awaitState(_ conn: NWConnection, _ expected: NWConnection.State, timeout: Duration) async throws -> Bool {
        if conn.stateUpdateHandler == nil {
            conn.stateUpdateHandler = { _ in }
        }
        let interval = seconds(timeout)
        let pollNs: UInt64 = 50_000_000
        let end = Date().addingTimeInterval(interval)
        while Date() < end {
            if conn.state == expected { return true }
            try await Task.sleep(nanoseconds: pollNs)
        }
        return false
    }

    static func waitReady(_ conn: NWConnection, timeout: Duration) async throws {
        let interval = seconds(timeout)
        let pollNs: UInt64 = 20_000_000
        let end = Date().addingTimeInterval(interval)
        while Date() < end {
            if conn.state == .ready { return }
            try await Task.sleep(nanoseconds: pollNs)
        }
        throw NSError(domain: "TestTCP", code: 1, userInfo: [NSLocalizedDescriptionKey: "did not reach .ready in \(interval)s"])
    }

    static func send(_ conn: NWConnection, _ data: Data, timeout: Duration) async throws {
        let interval = seconds(timeout)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let deadline = DispatchWorkItem {
                cont.resume(throwing: NSError(domain: "TestTCP", code: 2, userInfo: [NSLocalizedDescriptionKey: "send timeout"]))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: deadline)
            conn.send(content: data, completion: .contentProcessed { error in
                deadline.cancel()
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    static func receive(_ conn: NWConnection, minIncomplete: Int, maxLength: Int, timeout: Duration) async throws -> Data {
        let interval = seconds(timeout)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let deadline = DispatchWorkItem {
                cont.resume(throwing: NSError(domain: "TestTCP", code: 3, userInfo: [NSLocalizedDescriptionKey: "receive timeout"]))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: deadline)
            conn.receive(minimumIncompleteLength: minIncomplete, maximumLength: maxLength) { data, _, _, error in
                deadline.cancel()
                if let error = error {
                    cont.resume(throwing: error)
                } else if let data = data, !data.isEmpty {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: NSError(domain: "TestTCP", code: 4, userInfo: [NSLocalizedDescriptionKey: "no data received"]))
                }
            }
        }
    }

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
