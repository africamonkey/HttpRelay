import Foundation
import Network

enum SOCKS5Error: Error {
    case malformed
    case unsupportedCommand
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
    static func makeReply(status: UInt8, bind: NWEndpoint?) -> Data {
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
        var buffer = Data()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data { buffer.append(data) }

            do {
                while true {
                    let savedCount = buffer.count
                    if let req = try SOCKS5Parser.parse(buffer: &buffer) {
                        self.dispatch(connection: connection, request: req)
                        return
                    }
                    if buffer.count == savedCount { break }
                }
            } catch is SOCKS5Error {
                connection.send(content: SOCKS5Parser.makeReply(status: 0x01, bind: nil),
                               completion: .contentProcessed { _ in connection.cancel() })
                return
            } catch {
                connection.cancel()
                return
            }

            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receiveRequest(connection)
        }
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
            connection.send(content: SOCKS5Parser.makeReply(status: 0x07, bind: nil),
                           completion: .contentProcessed { _ in connection.cancel() })
        case .connect:
            print("[SOCKS5] CONNECT handler not yet implemented (Task 3) — closing")
            connection.cancel()
        case .udpAssociate:
            print("[SOCKS5] UDP_ASSOCIATE handler not yet implemented (Task 5) — closing")
            connection.cancel()
        }
    }
}

/// Will be filled in by Tasks 5/6/7. Stub here so the file compiles.
final class SOCKS5UDPRelay {
    func stop() {
    }
}