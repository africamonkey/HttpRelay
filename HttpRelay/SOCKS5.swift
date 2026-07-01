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
    private var localIP: String = "0.0.0.0"

    init(logStore: LogStore) {
        self.logStore = logStore
    }

    /// Set the device's LAN IP. This is used as `BND.ADDR` in the
    /// UDP_ASSOCIATE reply (RFC 1928 §6) — the address where the
    /// SOCKS5 client must send UDP datagrams. Using `0.0.0.0` here
    /// causes strict clients (Firefox, Chrome) to immediately abort
    /// ICE because they have nowhere valid to send UDP.
    func setLocalIP(_ ip: String) {
        self.localIP = ip
    }

    /// Called by ProxyServer (or by TestSOCKS5) when a new connection arrives.
    /// `firstByteConsumed` is `true` when ProxyServer's polyglot dispatcher
    /// has already consumed the 0x05 version byte; in that case the next
    /// byte in the buffer is NMETHODS. When `false`, the first receive
    /// will start at the SOCKS5 version byte (legacy / test-only path).
    ///
    /// **Caller responsibility**: the connection must already be started
    /// (`connection.start(queue:)` called once before this method).
    /// Calling `start` here would trigger
    /// `nw_connection_set_queue called after nw_connection_start` and
    /// would set the wrong dispatch queue for the connection.
    func handle(connection: NWConnection, firstByteConsumed: Bool = false) {
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
            self.handleUDPAssociate(connection)
        }
    }

    private func handleUDPAssociate(_ connection: NWConnection) {
        do {
            let relay = udpRelay ?? SOCKS5UDPRelay()
            if udpRelay == nil { udpRelay = relay }
            let port = try relay.start()
            var reply = Data([0x05, 0x00, 0x00, 0x01])
            let parts = localIP.split(separator: ".").compactMap { UInt8($0) }
            if parts.count == 4 {
                reply.append(contentsOf: parts)
            } else {
                reply.append(contentsOf: [0, 0, 0, 0])
            }
            reply.append(contentsOf: [UInt8(port.rawValue >> 8), UInt8(port.rawValue & 0xff)])
            print("[SOCKS5] UDP_ASSOCIATE → \(localIP):\(port.rawValue)")
            connection.send(content: reply, completion: .contentProcessed { error in
                if error != nil { connection.cancel(); return }
            })
        } catch {
            connection.send(content: SOCKS5Parser.makeReply(status: 0x01, bind: nil),
                           completion: .contentProcessed { _ in connection.cancel() })
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

/// SOCKS5 UDP_ASSOCIATE relay. Holds a single UDP listener shared across
/// all associations. Parses each incoming datagram as a SOCKS5 UDP header
/// (RFC 1928 §6) and forwards the payload to the destination over a
/// reusable outbound UDP `NWConnection`.
final class SOCKS5UDPRelay {
    private let queue = DispatchQueue(label: "com.httprelay.socks5.udp")
    private(set) var listener: NWListener?
    private var outbound: [NWEndpoint: NWConnection] = [:]
    private let outboundLock = NSLock()
    private var clientToConn: [NWEndpoint: NWConnection] = [:]
    private let clientLock = NSLock()
    private var dstToClientUDP: [NWEndpoint: NWEndpoint] = [:]
    private let reverseLock = NSLock()

    /// Idempotent: first call creates the UDP listener on .any port; subsequent
    /// calls return the existing port. Throws if the listener can't be created
    /// (e.g., permission denied) or fails to reach .ready within 5 seconds.
    func start() throws -> NWEndpoint.Port {
        if let port = listener?.port { return port }
        let l = try NWListener(using: .udp, on: .any)

        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            if state == .ready { ready.signal() }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            conn.start(queue: self.queue)
            if let remote = conn.currentPath?.remoteEndpoint {
                self.clientLock.lock()
                self.clientToConn[remote] = conn
                self.clientLock.unlock()
            }
            self.receiveClientDatagram(conn)
        }
        l.start(queue: queue)
        listener = l

        guard ready.wait(timeout: .now() + 5.0) == .success else {
            l.cancel()
            listener = nil
            throw NSError(domain: "SOCKS5UDPRelay", code: -2, userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"])
        }
        guard let port = l.port else {
            throw NSError(domain: "SOCKS5UDPRelay", code: -1, userInfo: [NSLocalizedDescriptionKey: "no port after ready"])
        }
        print("[SOCKS5UDPRelay] listening on UDP port \(port.rawValue)")
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        outboundLock.lock()
        let conns = Array(outbound.values)
        outbound.removeAll()
        outboundLock.unlock()
        clientLock.lock()
        let clients = Array(clientToConn.values)
        clientToConn.removeAll()
        clientLock.unlock()
        reverseLock.lock()
        dstToClientUDP.removeAll()
        reverseLock.unlock()
        for c in conns { c.cancel() }
        for c in clients { c.cancel() }
    }

    private func receiveClientDatagram(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if error != nil { return }
            guard let data = data, !data.isEmpty else {
                self.receiveClientDatagram(conn)
                return
            }
            self.handleDatagram(from: conn, data: data)
            self.receiveClientDatagram(conn)
        }
    }

    private func handleDatagram(from conn: NWConnection, data: Data) {
        guard data.count >= 4 else { return }
        guard data[2] == 0x00 else {
            print("[SOCKS5UDPRelay] drop datagram with FRAG != 0 (\(data[2]))")
            return
        }
        let atyp = data[3]
        let parsed: (endpoint: NWEndpoint, payload: Data)?
        switch atyp {
        case 0x01:
            guard data.count >= 10 else { return }
            let base = data.startIndex
            let addrBase = base + 4
            let portBase = addrBase + 4
            let a0 = data[addrBase], a1 = data[addrBase + 1], a2 = data[addrBase + 2], a3 = data[addrBase + 3]
            let ip = "\(a0).\(a1).\(a2).\(a3)"
            let port = UInt16(data[portBase]) << 8 | UInt16(data[portBase + 1])
            let payload = data.subdata(in: (portBase + 2)..<data.endIndex)
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!)
            print("[SOCKS5UDPRelay] forward \(payload.count) bytes → \(ip):\(port)")
            parsed = (endpoint, payload)
        case 0x03:
            guard data.count >= 5 else { return }
            let base = data.startIndex
            let len = Int(data[base + 4])
            let headerEnd = base + 4 + 1 + len + 2
            guard data.count >= headerEnd else { return }
            let domain = String(data: data.subdata(in: (base + 5)..<(base + 5 + len)), encoding: .utf8) ?? ""
            let port = UInt16(data[base + 5 + len]) << 8 | UInt16(data[base + 5 + len + 1])
            let payload = data.subdata(in: headerEnd..<data.endIndex)
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(domain), port: NWEndpoint.Port(rawValue: port)!)
            print("[SOCKS5UDPRelay] forward \(payload.count) bytes → \(domain):\(port)")
            parsed = (endpoint, payload)
        case 0x04:
            print("[SOCKS5UDPRelay] drop datagram with ATYP=IPv6 (not implemented)")
            parsed = nil
        default:
            print("[SOCKS5UDPRelay] drop datagram with unknown ATYP=\(atyp)")
            parsed = nil
        }
        guard let (endpoint, payload) = parsed else { return }
        if let clientUdp = conn.currentPath?.remoteEndpoint {
            self.reverseLock.lock()
            self.dstToClientUDP[endpoint] = clientUdp
            self.reverseLock.unlock()
        }
        self.forward(endpoint: endpoint, payload: payload)
    }

    private func forward(endpoint: NWEndpoint, payload: Data) {
        outboundLock.lock()
        if let existing = outbound[endpoint] {
            outboundLock.unlock()
            existing.send(content: payload, completion: .contentProcessed { error in
                if let error = error {
                    print("[SOCKS5UDPRelay] send error → \(error)")
                }
            })
            return
        }
        let conn = NWConnection(to: endpoint, using: .udp)
        outbound[endpoint] = conn
        outboundLock.unlock()
        print("[SOCKS5UDPRelay] creating outbound connection to \(endpoint)")

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            print("[SOCKS5UDPRelay] outbound \(endpoint) state=\(state)")
            if case .ready = state {
                self.startReceiveOnOutbound(conn, endpoint: endpoint)
                conn.send(content: payload, completion: .contentProcessed { error in
                    if let error = error {
                        print("[SOCKS5UDPRelay] send error → \(error)")
                    } else {
                        print("[SOCKS5UDPRelay] sent \(payload.count) bytes → \(endpoint)")
                    }
                })
            }
            if case .failed = state {
                self.outboundLock.lock()
                self.outbound.removeValue(forKey: endpoint)
                self.outboundLock.unlock()
                self.reverseLock.lock()
                self.dstToClientUDP.removeValue(forKey: endpoint)
                self.reverseLock.unlock()
                conn.cancel()
            }
        }
        conn.start(queue: queue)
    }

    private func startReceiveOnOutbound(_ conn: NWConnection, endpoint: NWEndpoint) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let error = error {
                print("[SOCKS5UDPRelay] outbound receive error from \(endpoint): \(error)")
                return
            }
            if let data = data, !data.isEmpty {
                print("[SOCKS5UDPRelay] outbound got \(data.count) bytes from \(endpoint)")
                self.handleReplyFromRealDst(endpoint: endpoint, data: data)
            }
            self.startReceiveOnOutbound(conn, endpoint: endpoint)
        }
    }

    private func handleReplyFromRealDst(endpoint: NWEndpoint, data: Data) {
        reverseLock.lock()
        let clientUDP = dstToClientUDP[endpoint]
        reverseLock.unlock()
        guard let clientUDP = clientUDP else {
            print("[SOCKS5UDPRelay] reply \(data.count) bytes from \(endpoint) but no client mapping")
            return
        }
        clientLock.lock()
        let clientConn = clientToConn[clientUDP]
        clientLock.unlock()

        let port: UInt16 = {
            if case .hostPort(_, let p) = endpoint { return p.rawValue }
            return 0
        }()

        var reply = Data([0x00, 0x00, 0x00, 0x01])
        reply.append(contentsOf: [0, 0, 0, 0])
        reply.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xff)])
        reply.append(data)
        print("[SOCKS5UDPRelay] reply \(data.count) bytes from port \(port) → client \(clientUDP)")

        if let clientConn = clientConn {
            clientConn.send(content: reply, completion: .contentProcessed { error in
                if let error = error {
                    print("[SOCKS5UDPRelay] send-to-client error: \(error)")
                }
            })
        } else {
            let fallback = NWConnection(to: clientUDP, using: .udp)
            fallback.stateUpdateHandler = { state in
                if case .ready = state {
                    fallback.send(content: reply, completion: .contentProcessed { _ in
                        fallback.cancel()
                    })
                }
                if case .failed = state {
                    fallback.cancel()
                }
            }
            fallback.start(queue: queue)
        }
    }
}
