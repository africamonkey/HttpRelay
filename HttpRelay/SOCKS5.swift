import Foundation
import Network

final class SOCKS5Server {
    private let logStore: LogStore
    private let queue = DispatchQueue(label: "com.httprelay.socks5")
    private var udpRelay: SOCKS5UDPRelay?

    @MainActor
    init(logStore: LogStore) {
        self.logStore = logStore
    }

    /// Called by ProxyServer after the first byte (0x05) has already been
    /// consumed by the polyglot dispatcher (Task 4).
    func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveGreeting(connection)
    }

    /// Stop accepting new work.
    func stop() {
        udpRelay?.stop()
        udpRelay = nil
    }

    private func receiveGreeting(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 257) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if error != nil || data == nil || data!.count < 2 {
                connection.cancel(); return
            }
            let bytes = data!
            guard bytes[0] == 0x05 else {
                connection.cancel(); return
            }
            let nMethods = Int(bytes[1])
            guard bytes.count >= 2 + nMethods else {
                connection.cancel(); return
            }
            let offered = bytes.subdata(in: 2..<(2 + nMethods))
            if !offered.contains(0x00) {
                connection.send(content: Data([0x05, 0xFF]), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            connection.send(content: Data([0x05, 0x00]), completion: .contentProcessed { error in
                if error != nil { connection.cancel(); return }
                self.receiveRequest(connection)
            })
        }
    }

    private func receiveRequest(_ connection: NWConnection) {
        connection.cancel()
    }
}

/// Will be filled in by Tasks 5/6/7. Stub here so the file compiles.
final class SOCKS5UDPRelay {
    func stop() {
    }
}