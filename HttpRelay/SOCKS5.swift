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
            reply.append(contentsOf: [0, 0, 0, 0])
            reply.append(contentsOf: [UInt8(port.rawValue >> 8), UInt8(port.rawValue & 0xff)])
            print("[SOCKS5] UDP_ASSOCIATE → relay port \(port.rawValue)")
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
            conn.start(queue: self?.queue ?? .global())
            self?.receiveLoop(conn)
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
        for c in conns { c.cancel() }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if error != nil {
                return
            }
            guard let data = data, !data.isEmpty else {
                self.receiveLoop(conn)
                return
            }
            // Discriminator: was this peer previously seen as a SOCKS5 dst?
            // If yes → reply path (we already know which client it belongs to).
            // If no → forward path (a SOCKS5 client sent us a datagram).
            //
            // **Note on port matching for TURN/STUN**: TURN-over-UDP and
            // STUN binding responses routinely come from a different source
            // port than the request was sent to (NAT rebinding on the dst's
            // side, or a separate STUN/TURN response port). The dstToClientUDP
            // map keys by the full `NWEndpoint` (addr+port). To handle
            // port-mismatch, we relax the lookup to match on (addr, any-port):
            // if a key exists with the same address but a different port, treat
            // it as a reply for that client. This is necessary for WebRTC's
            // TURN-over-UDP and STUN binding flows to work end-to-end.
            let remote = conn.currentPath?.remoteEndpoint
            if let remote = remote, let client = self.reverseLookupLoose(remote) {
                self.handleReply(from: remote, data: data, clientUDP: client)
            } else {
                self.handleDatagram(from: conn, data: data)
            }
            self.receiveLoop(conn)
        }
    }

    /// Wrap an inbound reply from a real dst back into a SOCKS5 UDP packet
    /// and send it to the original SOCKS5 client.
    private func handleReply(from dst: NWEndpoint, data: Data, clientUDP: NWEndpoint) {
        // SOCKS5 UDP reply header: RSV(2) FRAG(1) ATYP(1) DST.ADDR(4) DST.PORT(2) DATA
        // We don't easily recover IPv4 bytes from `NWEndpoint.hostPort`; use 0.0.0.0.
        // For DST.PORT, the real dst's source port is what the browser sent to —
        // this is what a normal SOCKS5 server would put here.
        let port: UInt16
        if case .hostPort(_, let p) = dst { port = p.rawValue } else { port = 0 }

        var reply = Data([0x00, 0x00, 0x00, 0x01])
        reply.append(contentsOf: [0, 0, 0, 0])
        reply.append(contentsOf: [UInt8(port >> 8), UInt8(port & 0xff)])
        reply.append(data)
        print("[SOCKS5UDPRelay] reply \(data.count) bytes from port \(port) → client \(clientUDP)")

        let clientConn = NWConnection(to: clientUDP, using: .udp)
        clientConn.stateUpdateHandler = { state in
            if case .ready = state {
                clientConn.send(content: reply, completion: .contentProcessed { _ in
                    clientConn.cancel()
                })
            }
            if case .failed = state {
                clientConn.cancel()
            }
        }
        clientConn.start(queue: queue)
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
        self.forward(endpoint: endpoint, payload: payload)
        if let clientUdp = conn.currentPath?.remoteEndpoint {
            self.reverseLock.lock()
            self.dstToClientUDP[endpoint] = clientUdp
            self.reverseLock.unlock()
        }
    }

    private func forward(endpoint: NWEndpoint, payload: Data) {
        outboundLock.lock()
        if let existing = outbound[endpoint],
           existing.state == .ready || existing.state == .preparing || existing.state == .setup {
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

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            if case .ready = state {
                conn.send(content: payload, completion: .contentProcessed { error in
                    if let error = error {
                        print("[SOCKS5UDPRelay] send error → \(error)")
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

    /// Reverse-lookup the client UDP endpoint for a given real-dst endpoint.
    /// Returns nil if no mapping exists (e.g., a real dst sent an unsolicited
    /// packet that was never matched by a SOCKS5 client datagram).
    func reverseLookup(_ realDst: NWEndpoint) -> NWEndpoint? {
        reverseLock.lock(); defer { reverseLock.unlock() }
        return dstToClientUDP[realDst]
    }

    /// Looser reverse-lookup: tries exact match first, then falls back to
    /// matching on the IP only (any port). Necessary because TURN-over-UDP
    /// and STUN binding responses routinely come from a different source
    /// port than the request was sent to (NAT rebinding, separate
    /// response ports). Without this, WebRTC's ICE/TURN flow drops replies.
    ///
    /// Picks the most recent mapping matching the IP (iterates the map
    /// in unspecified order, but for a small set of mappings that's fine).
    func reverseLookupLoose(_ realDst: NWEndpoint) -> NWEndpoint? {
        reverseLock.lock()
        defer { reverseLock.unlock() }
        if let exact = dstToClientUDP[realDst] { return exact }
        // Match on the host portion (NWEndpoint.hostPort(_, _) only).
        guard case .hostPort(let targetHost, _) = realDst else { return nil }
        for (key, client) in dstToClientUDP {
            if case .hostPort(let h, _) = key, h == targetHost {
                return client
            }
        }
        return nil
    }
}
