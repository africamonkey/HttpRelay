import Foundation
import Network

enum SOCKS5Error: Error {
    case malformed
    case unsupportedAddressType
}

struct SOCKS5Request {
    enum Command: UInt8 { case connect = 0x01, bind = 0x02, udpAssociate = 0x03 }
    enum Address {
        case ipv4(Data)
        case domain(String)
        case ipv6(Data)
    }
    let cmd: Command
    let addr: Address
    let port: UInt16
}

enum SOCKS5Parser {
    /// State machine: returns the request once enough bytes are buffered,
    /// or nil if more needed. Throws on malformed.
    static func parse(buffer: inout Data) throws -> SOCKS5Request? {
        guard buffer.count >= 4 else { return nil }
        guard buffer[0] == 0x05 else { throw SOCKS5Error.malformed }
        let cmdByte = buffer[1]
        guard let cmd = SOCKS5Request.Command(rawValue: cmdByte) else { throw SOCKS5Error.malformed }
        guard buffer[2] == 0x00 else { throw SOCKS5Error.malformed }
        let atyp = buffer[3]
        switch atyp {
        case 0x01:
            guard buffer.count >= 10 else { return nil }
            let addr = Data(buffer[4..<8])
            let port = UInt16(buffer[8]) << 8 | UInt16(buffer[9])
            buffer.removeFirst(10)
            return SOCKS5Request(cmd: cmd, addr: .ipv4(addr), port: port)
        case 0x03:
            guard buffer.count >= 5 else { return nil }
            let len = Int(buffer[4])
            guard buffer.count >= 5 + len + 2 else { return nil }
            let domain = String(data: buffer.subdata(in: 5..<(5 + len)), encoding: .utf8) ?? ""
            let port = UInt16(buffer[5 + len]) << 8 | UInt16(buffer[5 + len + 1])
            buffer.removeFirst(5 + len + 2)
            return SOCKS5Request(cmd: cmd, addr: .domain(domain), port: port)
        case 0x04:
            guard buffer.count >= 22 else { return nil }
            let addr = Data(buffer[4..<20])
            let port = UInt16(buffer[20]) << 8 | UInt16(buffer[21])
            buffer.removeFirst(22)
            return SOCKS5Request(cmd: cmd, addr: .ipv6(addr), port: port)
        default:
            throw SOCKS5Error.unsupportedAddressType
        }
    }

    /// Reply bytes: 0x05 STATUS RSV ATYP BND.ADDR BND.PORT
    static func makeReply(status: UInt8, bind _: NWEndpoint? = nil) -> Data {
        var bytes = Data([0x05, status, 0x00])
        bytes.append(contentsOf: [0x01, 0, 0, 0, 0, 0, 0])
        return bytes
    }
}

final class SOCKS5Server {
    private let logStore: LogStore
    private let queue = DispatchQueue(label: "com.httprelay.socks5")
    private var udpRelay: SOCKS5UDPRelay?

    init(logStore: LogStore) {
        self.logStore = logStore
    }

    /// Called by ProxyServer (or by TestSOCKS5) when a new connection arrives.
    /// `firstByteConsumed` is `true` when ProxyServer's polyglot dispatcher
    /// has already consumed the 0x05 version byte; in that case the next
    /// byte in the buffer is NMETHODS. When `false`, the first receive
    /// will start at the SOCKS5 version byte (legacy / test-only path).
    func handle(connection: NWConnection, firstByteConsumed: Bool = false) {
        connection.start(queue: queue)
        if firstByteConsumed {
            receiveMethodsAfterDispatch(connection)
        } else {
            receiveGreeting(connection)
        }
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

    /// Like `receiveGreeting` but the 0x05 version byte has already been
    /// consumed by ProxyServer's polyglot dispatcher. The remaining bytes
    /// start with NMETHODS, so we skip the version check.
    private func receiveMethodsAfterDispatch(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 257) { [weak self] data, _, _, error in
            guard let self = self else { return }
            if error != nil || data == nil || data!.count < 2 {
                connection.cancel(); return
            }
            let bytes = data!
            // No version byte: bytes[0] is NMETHODS.
            let nMethods = Int(bytes[0])
            guard bytes.count >= 1 + nMethods else {
                connection.cancel(); return
            }
            let offered = bytes.subdata(in: 1..<(1 + nMethods))
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

    private final class Buffer {
        var data = Data()
    }

    private func receiveRequest(_ connection: NWConnection) {
        let buf = Buffer()
        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self = self else { return }
                if let data = data { buf.data.append(data) }

                do {
                    while true {
                        let savedCount = buf.data.count
                        if let req = try SOCKS5Parser.parse(buffer: &buf.data) {
                            self.dispatch(connection: connection, request: req)
                            return
                        }
                        if buf.data.count == savedCount { break }  // not enough; wait
                    }
                } catch is SOCKS5Error {
                    connection.send(content: SOCKS5Parser.makeReply(status: 0x01),
                                   completion: .contentProcessed { _ in connection.cancel() })
                    return
                } catch {
                    connection.cancel()
                    return
                }

                if error != nil || isComplete { connection.cancel(); return }
                pump()  // re-arm with the SAME buffer
            }
        }
        pump()
    }

    private func dispatch(connection: NWConnection, request: SOCKS5Request) {
        let cmdDesc: String
        switch request.cmd {
        case .connect: cmdDesc = "CONNECT"
        case .bind: cmdDesc = "BIND"
        case .udpAssociate: cmdDesc = "UDP_ASSOCIATE"
        }
        let addrDesc: String
        switch request.addr {
        case .ipv4(let b): addrDesc = "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
        case .domain(let s): addrDesc = s
        case .ipv6: addrDesc = "[ipv6]"
        }
        print("[SOCKS5] request: \(cmdDesc) \(addrDesc):\(request.port)")

        switch request.cmd {
        case .bind:
            connection.send(content: SOCKS5Parser.makeReply(status: 0x07),
                           completion: .contentProcessed { _ in connection.cancel() })
        case .connect:
            let host = self.hostForAddr(request.addr)
            self.handleConnect(connection: connection, host: host, port: request.port)
        case .udpAssociate:
            print("[SOCKS5] UDP_ASSOCIATE handler not yet implemented (Task 5) — closing")
            connection.cancel()
        }
    }

    private func hostForAddr(_ addr: SOCKS5Request.Address) -> String {
        switch addr {
        case .ipv4(let b): return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
        case .ipv6: return ""
        case .domain(let s): return s
        }
    }

    private func handleConnect(connection: NWConnection, host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let dst = NWConnection(to: endpoint, using: .tcp)
        let pair = ConnPair(client: connection, server: dst)

        dst.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[SOCKS5] CONNECT \(host):\(port) ready")
                connection.send(content: SOCKS5Parser.makeReply(status: 0x00, bind: nil),
                               completion: .contentProcessed { error in
                    if error != nil { pair.closeBoth(); return }
                    self.clientToServer(pair: pair)
                    self.serverToClient(pair: pair)
                })
            case .failed, .cancelled:
                print("[SOCKS5] CONNECT \(host):\(port) failed/cancelled")
                if !pair.clientClosed {
                    connection.send(content: SOCKS5Parser.makeReply(status: 0x01, bind: nil),
                                   completion: .contentProcessed { _ in pair.closeBoth() })
                } else {
                    pair.closeServer()
                }
            default: break
            }
        }
        dst.start(queue: queue)
    }

    private func clientToServer(pair: ConnPair) {
        pair.client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil || isComplete {
                pair.server.cancel(); return
            }
            guard let data = data, !data.isEmpty else {
                self.clientToServer(pair: pair); return
            }
            pair.server.send(content: data, isComplete: isComplete, completion: .contentProcessed { error in
                if error != nil { pair.closeBoth(); return }
                if isComplete { return }
                self.clientToServer(pair: pair)
            })
        }
    }

    private func serverToClient(pair: ConnPair) {
        pair.server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil || isComplete {
                pair.client.cancel(); return
            }
            guard let data = data, !data.isEmpty else {
                self.serverToClient(pair: pair); return
            }
            pair.client.send(content: data, isComplete: isComplete, completion: .contentProcessed { error in
                if error != nil { pair.closeBoth(); return }
                if isComplete { return }
                self.serverToClient(pair: pair)
            })
        }
    }
}

/// Lifecycle helper for an SOCKS5 CONNECT tunnel. Tracks which side has
/// already closed so we don't double-cancel and avoid races between
/// `stateUpdateHandler` and the receive callbacks.
private final class ConnPair {
    let client: NWConnection
    let server: NWConnection
    private let lock = NSLock()
    private var clientDone = false
    private var serverDone = false

    var clientClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return clientDone
    }

    init(client: NWConnection, server: NWConnection) {
        self.client = client
        self.server = server
    }

    func closeClient() {
        lock.lock(); defer { lock.unlock() }
        guard !clientDone else { return }
        clientDone = true
        client.cancel()
    }

    func closeServer() {
        lock.lock(); defer { lock.unlock() }
        guard !serverDone else { return }
        serverDone = true
        server.cancel()
    }

    func closeBoth() { closeClient(); closeServer() }
}

/// Will be filled in by Tasks 5/6/7. Stub here so the file compiles.
final class SOCKS5UDPRelay {
    func stop() {
    }
}
