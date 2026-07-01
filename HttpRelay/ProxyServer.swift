import Foundation
import Network

final class ProxyServer {
    typealias ConnectionHandler = (NWConnection) -> Void

    private let port: UInt16
    private var listener: NWListener?
    private let logStore: LogStore
    private let socks5Server: SOCKS5Server
    private var activeTunnels: [String: TunnelManager] = [:]
    private let tunnelsLock = NSLock()
    private(set) var localIP: String = "—"

    var onLocalIPReady: ((String) -> Void)?

    init(port: UInt16 = 10808, logStore: LogStore) {
        self.port = port
        self.logStore = logStore
        self.socks5Server = SOCKS5Server(logStore: logStore)
    }

    var boundPort: NWEndpoint.Port? {
        return listener?.port
    }

    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }
        return address
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[ProxyServer] listening on port \(self.port)")
                self.localIP = self.getLocalIPAddress() ?? "—"
                print("[ProxyServer] local IP: \(self.localIP)")
                self.onLocalIPReady?(self.localIP)
            case .failed(let error):
                print("[ProxyServer] failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            print("[ProxyServer] new connection from \(connection.endpoint)")
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        socks5Server.stop()
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: .global())

        // Polyglot dispatcher: peek 1 byte to decide SOCKS5 vs HTTP.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] byte, _, _, error in
            guard let self = self, let byte = byte?.first else {
                connection.cancel()
                return
            }
            switch byte {
            case 0x05:
                // SOCKS5 greeting always starts with 0x05. The version
                // byte has already been consumed by the peek, so tell
                // the SOCKS5 server.
                self.socks5Server.handle(connection: connection, firstByteConsumed: true)
            case 0x41...0x5A, 0x61...0x7A:
                // HTTP method: uppercase letter (CONNECT/GET/POST/...) or lowercase defensive
                self.handleHTTPConnection(connection, pushback: byte)
            default:
                connection.cancel()
            }
        }
    }

    /// Handles a connection whose first byte is ASCII (an HTTP method). The
    /// byte was already consumed by the polyglot dispatcher, so we re-feed
    /// it into a fresh receive that buffers bytes until the request line
    /// and headers are complete, then hands off to the existing
    /// `processRequest` pipeline.
    private func handleHTTPConnection(_ connection: NWConnection, pushback: UInt8) {
        let buf = HTTPRequestBuffer(pushback: pushback)

        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                guard let data = data, !data.isEmpty else {
                    pump()
                    return
                }
                buf.append(data)
                switch buf.tryParse() {
                case .needMore:
                    pump()
                case .ready(let request):
                    self.processRequest(request, connection: connection)
                    // processRequest kicks off its own receive chain. We're done here.
                }
            }
        }
        pump()
    }

    /// Small per-connection buffer that consumes the request line + headers
    /// and yields the parsed `request: String` once the header block is
    /// complete (terminated by `\r\n\r\n`).
    private final class HTTPRequestBuffer {
        private var data: Data
        init(pushback: UInt8) { data = Data([pushback]) }
        func append(_ more: Data) { data.append(more) }

        enum ParseResult {
            case needMore
            case ready(request: String)
        }

        func tryParse() -> ParseResult {
            // Need \r\n\r\n to indicate end of headers.
            guard let endRange = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
                return .needMore
            }
            // Request line + headers; if there's a body in the same buffer we
            // include it. processRequest parses just the request line — extra
            // bytes are handled by the existing receive loop in receiveHTTPRequest.
            let headerEnd = endRange.upperBound
            let requestBytes = data.subdata(in: 0..<headerEnd)
            // Strip the trailing \r\n\r\n — processRequest expects the
            // header block without the terminator.
            let request = String(data: requestBytes.dropLast(4), encoding: .utf8) ?? ""
            return .ready(request: request)
        }
    }

    private func receiveHTTPRequest(_ connection: NWConnection) {
        print("[ProxyServer] receiveHTTPRequest: starting receive on \(connection.endpoint)")
        connection.receive(minimumIncompleteLength: 0, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            print("[ProxyServer] receiveHTTPRequest callback: data.count=\(data?.count ?? -1), isComplete=\(isComplete), error=\(error?.localizedDescription ?? "nil")")

            if let error = error {
                print("[ProxyServer] receiveHTTPRequest: error, cancelling")
                connection.cancel()
                return
            }

            if isComplete {
                print("[ProxyServer] receiveHTTPRequest: connection completed")
                connection.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                print("[ProxyServer] receiveHTTPRequest: received \(data.count) bytes, checking if tunnel exists...")

                if let tunnelKey = self.findTunnelKey(for: connection) {
                    print("[ProxyServer] receiveHTTPRequest: forwarding \(data.count) bytes to existing tunnel")
                    self.forwardToTunnel(connection: connection, data: data)
                } else if let request = String(data: data, encoding: .utf8) {
                    print("[ProxyServer] receiveHTTPRequest: processing as HTTP request")
                    self.processRequest(request, connection: connection)
                } else {
                    print("[ProxyServer] receiveHTTPRequest: binary data but no tunnel, ignoring")
                }
            }

            self.receiveHTTPRequest(connection)
        }
    }

    private func findTunnelKey(for connection: NWConnection) -> String? {
        tunnelsLock.lock()
        defer { tunnelsLock.unlock() }
        let searchKey = activeTunnels.keys.first { key in
            if let tunnel = activeTunnels[key] {
                return tunnel.clientConnectionRef === connection
            }
            return false
        }
        return searchKey
    }

    private func forwardToTunnel(connection: NWConnection, data: Data) {
        tunnelsLock.lock()
        let tunnel = activeTunnels.first { $0.value.clientConnectionRef === connection }?.value
        tunnelsLock.unlock()

        if let tunnel = tunnel {
            tunnel.receiveClientData(data)
        }
    }

    private func processRequest(_ request: String, connection: NWConnection) {
        print("[ProxyServer] processRequest: parsing request")
        let lines = request.split(separator: "\r\n")
        guard let firstLine = lines.first else {
            print("[ProxyServer] processRequest: no first line, cancelling")
            connection.cancel()
            return
        }

        let components = firstLine.split(separator: " ")
        guard components.count >= 2 else {
            print("[ProxyServer] processRequest: not enough components, cancelling")
            connection.cancel()
            return
        }

        let methodStr = String(components[0])
        let target = String(components[1])
        print("[ProxyServer] processRequest: method=\(methodStr), target=\(target)")

        let method = LogEntry.HTTPMethod(rawValue: methodStr) ?? .unknown

        if method == .connect {
            let hostPort = target.split(separator: ":")
            guard hostPort.count == 2,
                  let port = Int(hostPort[1]) else {
                print("[ProxyServer] processRequest: invalid target, sending 400")
                sendErrorResponse(connection, code: "400 Bad Request")
                return
            }

            let host = String(hostPort[0])
            let (path, query) = parsePathAndQuery(from: request)
            let requestHeaders = parseHeaders(from: request)

            print("[ProxyServer] processRequest: CONNECT to \(host):\(port), path=\(path)")
            let logEntry = logStore.log(host: host, port: port, path: path, query: query, method: method, requestHeaders: requestHeaders)
            logStore.incrementConnections()

            do {
                try establishTunnel(host: host, port: port, clientConnection: connection, logEntry: logEntry)
            } catch {
                print("[ProxyServer] processRequest: establishTunnel failed: \(error)")
                logStore.failEntry(logEntry)
                logStore.decrementConnections()
                sendErrorResponse(connection, code: "502 Bad Gateway")
            }
        } else {
            print("[ProxyServer] processRequest: handling as HTTP proxy request")
            handleHTTPPxoyRequest(method: method, methodStr: methodStr, target: target, request: request, connection: connection)
        }
        // NOTE: do not call receiveHTTPRequest here. The receive loop is
        // started either after a successful CONNECT handshake (in
        // establishTunnel's onConnected) or after an HTTP proxy request is
        // set up. Starting it here would cause the receive loop to consume
        // the proxy's own HTTP error reply bytes as if they were a new
        // request.
    }

    private func handleHTTPPxoyRequest(method: LogEntry.HTTPMethod, methodStr: String, target: String, request: String, connection: NWConnection) {
        guard let url = URL(string: target) else {
            print("[ProxyServer] handleHTTPPxoyRequest: invalid URL: \(target)")
            sendErrorResponse(connection, code: "400 Bad Request")
            return
        }

        guard let host = url.host, let port = url.port else {
            print("[ProxyServer] handleHTTPPxoyRequest: missing host/port in URL: \(target)")
            sendErrorResponse(connection, code: "400 Bad Request")
            return
        }

        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query
        let requestHeaders = parseHeaders(from: request)

        print("[ProxyServer] handleHTTPPxoyRequest: \(methodStr) \(host):\(port)\(path)")
        let logEntry = logStore.log(host: host, port: port, path: path, query: query, method: method, requestHeaders: requestHeaders)
        logStore.incrementConnections()

        let tunnelManager = TunnelManager(
            host: host,
            port: port,
            logStore: logStore,
            logEntry: logEntry
        )

        let key = "\(host):\(port):\(ObjectIdentifier(connection as AnyObject))"
        tunnelsLock.lock()
        activeTunnels[key] = tunnelManager
        tunnelsLock.unlock()

        tunnelManager.onConnected = { [weak self] in
            print("[ProxyServer] handleHTTPPxoyRequest: connected to \(host):\(port), sending request")
            self?.sendHTTPProxyRequest(tunnelManager: tunnelManager, methodStr: methodStr, path: path, query: query, request: request, connection: connection)
            // Tunnel established; start forwarding client→server bytes
            // (POST body, follow-up requests on the same connection).
            self?.receiveHTTPRequest(connection)
        }

        tunnelManager.onClose = { [weak self] in
            print("[ProxyServer] handleHTTPPxoyRequest: connection closed")
            if let self = self {
                self.logStore.completeEntry(logEntry)
                self.logStore.decrementConnections()
                self.tunnelsLock.lock()
                self.activeTunnels.removeValue(forKey: key)
                self.tunnelsLock.unlock()
            }
        }

        tunnelManager.onError = { [weak self] in
            print("[ProxyServer] handleHTTPPxoyRequest: connection error")
            if let self = self {
                self.logStore.failEntry(logEntry)
                self.logStore.decrementConnections()
                self.tunnelsLock.lock()
                self.activeTunnels.removeValue(forKey: key)
                self.tunnelsLock.unlock()
            }
        }

        tunnelManager.startAsProxy(clientConnection: connection)
    }

    private func sendHTTPProxyRequest(tunnelManager: TunnelManager, methodStr: String, path: String, query: String?, request: String, connection: NWConnection) {
        let fullPath: String
        if let query = query, !query.isEmpty {
            fullPath = "\(path)?\(query)"
        } else {
            fullPath = path
        }

        let lines = request.split(separator: "\r\n")
        var headers = parseHeaders(from: request)
        headers["Host"] = headers["Host"] ?? tunnelManager.host

        let firstLine = "\(methodStr) \(fullPath) HTTP/1.1"
        var httpRequest = firstLine + "\r\n"
        for (key, value) in headers {
            httpRequest += "\(key): \(value)\r\n"
        }

        if let bodyRange = request.range(of: "\r\n\r\n") {
            let body = request[bodyRange.upperBound...]
            httpRequest += "\r\n"
            httpRequest += String(body)
        } else {
            httpRequest += "\r\n"
        }

        if let data = httpRequest.data(using: .utf8) {
            tunnelManager.sendToServer(data: data)
        }

        logStore.updateEntry(tunnelManager.logEntry, responseStatusCode: 0, responseHeaders: nil, duration: 0)
    }

    private func parsePathAndQuery(from request: String) -> (path: String, query: String?) {
        let lines = request.split(separator: "\r\n")
        guard let firstLine = lines.first else {
            return ("/", nil)
        }

        let components = firstLine.split(separator: " ")
        guard components.count >= 2 else {
            return ("/", nil)
        }

        let target = String(components[1])

        if target.contains("?") {
            let parts = target.split(separator: "?", maxSplits: 1)
            let pathPart = String(parts[0])
            let queryPart = parts.count > 1 ? String(parts[1]) : nil
            return (pathPart, queryPart)
        }

        return (target, nil)
    }

    private func parseHeaders(from request: String) -> [String: String] {
        var headers: [String: String] = [:]
        let lines = request.split(separator: "\r\n")

        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        return headers
    }

    private func establishTunnel(host: String, port: Int, clientConnection: NWConnection, logEntry: LogEntry) throws {
        let tunnelManager = TunnelManager(
            host: host,
            port: port,
            logStore: logStore,
            logEntry: logEntry
        )

        let key = "\(host):\(port):\(ObjectIdentifier(clientConnection as AnyObject))"
        tunnelsLock.lock()
        activeTunnels[key] = tunnelManager
        tunnelsLock.unlock()

        tunnelManager.onConnected = { [weak self] in
            print("[ProxyServer] onConnected callback fired for \(host):\(port)")
            self?.sendSuccessResponse(clientConnection)
            // Tunnel established: now start forwarding client→server bytes
            // through the receive loop.
            self?.receiveHTTPRequest(clientConnection)
            print("[ProxyServer] done with onConnected for \(host):\(port)")
        }

        tunnelManager.onClose = { [weak self] in
            print("[ProxyServer] onClose callback fired for \(host):\(port)")
            if let self = self {
                self.logStore.completeEntry(logEntry)
                self.logStore.decrementConnections()
                self.tunnelsLock.lock()
                self.activeTunnels.removeValue(forKey: key)
                self.tunnelsLock.unlock()
            }
        }

        tunnelManager.onError = { [weak self] in
            print("[ProxyServer] onError callback fired for \(host):\(port)")
            if let self = self {
                self.logStore.failEntry(logEntry)
                self.logStore.decrementConnections()
                // Reply to the client with 502 so HTTP clients see a proper
                // status line instead of a silent close.
                self.sendErrorResponse(clientConnection, code: "502 Bad Gateway")
                self.tunnelsLock.lock()
                self.activeTunnels.removeValue(forKey: key)
                self.tunnelsLock.unlock()
            }
        }

        tunnelManager.start(clientConnection: clientConnection)
        print("[ProxyServer] tunnelManager.start() called, waiting for connected callback...")
    }

    private func sendSuccessResponse(_ connection: NWConnection) {
        print("[ProxyServer] sending 200 Connection Established")
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    print("[ProxyServer] send response error: \(error)")
                } else {
                    print("[ProxyServer] 200 response sent successfully")
                }
            })
        }
    }

    private func sendErrorResponse(_ connection: NWConnection, code: String) {
        let response = "HTTP/1.1 \(code)\r\n\r\n"
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
