import Foundation
import Network
import Combine

final class ProxyServer: ObservableObject {
    typealias ConnectionHandler = (NWConnection) -> Void

    private let port: UInt16
    private var listener: NWListener?
    private let logStore: LogStore
    private let socks5Server: SOCKS5Server
    private var activeTunnels: [String: TunnelManager] = [:]
    private let tunnelsLock = NSLock()
    /// Guards `listener`, `wantsToRun` and `runID`. `start(runID:)` runs on
    /// a background queue, so it can race with `stop()` on the main thread.
    private let lifecycleLock = NSLock()
    /// False once `stop()` was called, so a listener that is still being
    /// created gets cancelled instead of left running.
    private var wantsToRun = false
    /// Bumped by every `stop()`. A start attempt carries the value it was
    /// given when the run was requested; if the value has changed by the
    /// time the listener exists, the server was stopped in the meantime
    /// and the start must not take effect.
    private var runID: UInt64 = 0
    @Published private(set) var localIP: String = "—"

    /// Set when the listener could not be brought up (e.g. the port is
    /// already taken). `nil` while the server is healthy.
    @Published private(set) var failureMessage: String?

    var onLocalIPReady: ((String) -> Void)?

    @Published private(set) var isRunning: Bool = false

    static var shared: ProxyServer?

    init(port: UInt16 = 10808, logStore: LogStore) {
        self.port = port
        self.logStore = logStore
        self.socks5Server = SOCKS5Server(logStore: logStore)
    }

    /// Synchronously perform `body` while holding `tunnelsLock`. Use a helper
    /// so callers in async contexts (e.g. `Task { @MainActor in … }`) do not
    /// invoke `NSLock.lock()/unlock()` directly, which Swift 6 strict
    /// concurrency disallows.
    @discardableResult
    private func withTunnelsLock<T>(_ body: () -> T) -> T {
        tunnelsLock.lock()
        defer { tunnelsLock.unlock() }
        return body()
    }

    var boundPort: NWEndpoint.Port? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return listener?.port
    }

    private func getLocalIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var addresses: [String: String] = [:]

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            // `ifa_addr` is NULL for interfaces without an address.
            guard let address = interface.ifa_addr else { continue }
            let addrFamily = address.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(address, socklen_t(address.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, socklen_t(0), NI_NUMERICHOST)
                addresses[name] = String(cString: hostname)
            }
        }

        // Priority: bridge interfaces (Hotspot), en0 (WiFi), en1...
        if let bridgeKey = addresses.keys.first(where: { $0.hasPrefix("bridge") }), let ip = addresses[bridgeKey] {
            return ip
        } else if let ip = addresses["en0"] {
            return ip
        } else if let ip = addresses["en1"] {
            return ip
        } else if let enKey = addresses.keys.first(where: { $0.hasPrefix("en") }), let ip = addresses[enKey] {
            return ip
        }

        return nil
    }

    /// Registers the intent to run the server and returns the id of this run.
    ///
    /// Call this on the thread that owns the server, *before* dispatching
    /// `start(runID:)` to a background queue. That way a `stop()` the user
    /// triggers in the meantime wins over the pending start: `stop()` bumps
    /// the run id, so the pending start notices that it was cancelled and
    /// never brings the listener up.
    func beginRun() -> UInt64 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        wantsToRun = true
        return runID
    }

    /// Creates the listener and starts it.
    ///
    /// Creating the first `NWListener` of a process initialises the Network
    /// framework and takes tens of milliseconds, so this must not run on the
    /// main thread. The listener is created and started on the calling
    /// thread; the state handler runs on the main queue. The `id` comes
    /// from `beginRun()`.
    func start(runID id: UInt64) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            reportFailure(error, for: nil)
            throw error
        }

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[ProxyServer] listening on port \(self.port)")
                self.publishLocalIP(for: newListener)
            case .failed(let error):
                print("[ProxyServer] failed: \(error)")
                self.reportFailure(error, for: newListener)
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            print("[ProxyServer] new connection from \(connection.endpoint)")
            guard let self = self else {
                connection.cancel()
                return
            }
            self.handleNewConnection(connection)
        }

        // The user may have switched the server off while the listener was
        // being created. In that case nobody is going to cancel it.
        lifecycleLock.lock()
        guard wantsToRun, runID == id else {
            lifecycleLock.unlock()
            newListener.cancel()
            return
        }
        let previous = listener
        listener = newListener
        lifecycleLock.unlock()

        previous?.cancel()
        newListener.start(queue: .main)
    }

    /// Starts the server on the calling thread.
    ///
    /// Convenience for callers that are already off the main thread (the
    /// tests). `beginRun()` has to run before the work is dispatched to
    /// another queue - use `beginRun()` and `start(runID:)` for that.
    func start() throws {
        try start(runID: beginRun())
    }

    /// Works out the device's LAN address and publishes it.
    ///
    /// `getifaddrs()`/`getnameinfo()` are syscalls, so they run off the main
    /// thread; only the publishing hops back onto the main actor.
    private func publishLocalIP(for listener: NWListener) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let ip = self.getLocalIPAddress() ?? "—"
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lifecycleLock.lock()
                let stillWanted = self.wantsToRun && self.listener === listener
                self.lifecycleLock.unlock()
                guard stillWanted else { return }
                print("[ProxyServer] local IP: \(ip)")
                self.localIP = ip
                self.socks5Server.setLocalIP(ip)
                self.onLocalIPReady?(ip)
                self.isRunning = true
            }
        }
    }

    /// Reports that the server could not be brought up.
    ///
    /// `failedListener` is the listener that failed, or `nil` when the
    /// listener could not even be created. A failure is only reported for
    /// the listener that is currently in charge, so a listener that fails
    /// after the user already stopped the server stays quiet.
    private func reportFailure(_ error: Error, for failedListener: NWListener?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lifecycleLock.lock()
            let isCurrent = failedListener == nil || self.listener === failedListener
            if isCurrent {
                self.wantsToRun = false
                if failedListener != nil {
                    self.listener = nil
                }
            }
            self.lifecycleLock.unlock()
            guard isCurrent else { return }
            self.isRunning = false
            self.failureMessage = "Failed to start debugger: \(error.localizedDescription)"
        }
    }

    /// Stops the server.
    ///
    /// Main-actor isolated because it publishes `isRunning`; every call site
    /// is on the main thread.
    @MainActor
    func stop() {
        lifecycleLock.lock()
        runID &+= 1
        wantsToRun = false
        let current = listener
        listener = nil
        lifecycleLock.unlock()

        current?.cancel()
        socks5Server.stop()
        isRunning = false
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
                case .ready(let request, let leftover):
                    self.processRequest(request, connection: connection, leftover: leftover)
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
            /// The header block and the bytes that came with it. The bytes
            /// after the header block are the body of the request (or the
            /// first bytes of the protocol the client speaks after a
            /// CONNECT), and they have to be forwarded as well.
            case ready(request: String, leftover: Data)
        }

        func tryParse() -> ParseResult {
            // Need \r\n\r\n to indicate end of headers.
            guard let endRange = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
                return .needMore
            }
            // Request line + headers; everything after them is the body of
            // the request and is handed on separately - it would be lost if
            // the buffer stopped here.
            let headerEnd = endRange.upperBound
            let requestBytes = data.subdata(in: 0..<headerEnd)
            let leftover = data.subdata(in: headerEnd..<data.count)
            // Strip the trailing \r\n\r\n — processRequest expects the
            // header block without the terminator.
            let request = String(data: requestBytes.dropLast(4), encoding: .utf8) ?? ""
            return .ready(request: request, leftover: leftover)
        }
    }

    private func receiveHTTPRequest(_ connection: NWConnection) {
        print("[ProxyServer] receiveHTTPRequest: starting receive on \(connection.endpoint)")
        connection.receive(minimumIncompleteLength: 0, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            print("[ProxyServer] receiveHTTPRequest callback: data.count=\(data?.count ?? -1), isComplete=\(isComplete), error=\(error?.localizedDescription ?? "nil")")

            if error != nil {
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

                if self.findTunnelKey(for: connection) != nil {
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

    /// Parses a request and sets up the tunnel it asks for.
    ///
    /// `leftover` are the bytes that came with the request but are not
    /// part of it: the body of the request, or the first bytes of the
    /// protocol the client speaks after a CONNECT.
    private func processRequest(_ request: String, connection: NWConnection, leftover: Data = Data()) {
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
            // The port has to be one a connection can be made to; a port
            // outside the range would trap when it is turned into an
            // NWEndpoint.Port.
            guard hostPort.count == 2,
                  let port = Int(hostPort[1]),
                  (1...65535).contains(port) else {
                print("[ProxyServer] processRequest: invalid target, sending 400")
                sendErrorResponse(connection, code: "400 Bad Request")
                return
            }

            let host = String(hostPort[0])
            // The request-target of a CONNECT request is the authority
            // `host:port` (RFC 9110 §7.2), not a path. Storing it as the
            // path would print the authority twice in the request details.
            let path = ""
            let query: String? = nil
            let requestHeaders = parseHeaders(from: request)

            print("[ProxyServer] processRequest: CONNECT to \(host):\(port), path=\(path)")
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let logEntry = logStore.log(host: host, port: port, path: path, query: query, method: method, requestHeaders: requestHeaders)
                logStore.incrementConnections()
                do {
                    try establishTunnel(host: host, port: port, clientConnection: connection, logEntry: logEntry, leftover: leftover)
                } catch {
                    print("[ProxyServer] processRequest: establishTunnel failed: \(error)")
                    logStore.failEntry(logEntry)
                    logStore.decrementConnections()
                    sendErrorResponse(connection, code: "502 Bad Gateway")
                }
            }
        } else {
            print("[ProxyServer] processRequest: handling as HTTP proxy request")
            handleHTTPProxyRequest(method: method, methodStr: methodStr, requestTarget: target, request: request, connection: connection, leftover: leftover)
        }
        // NOTE: do not call receiveHTTPRequest here. The receive loop is
        // started either after a successful CONNECT handshake (in
        // establishTunnel's onConnected) or after an HTTP proxy request is
        // set up. Starting it here would cause the receive loop to consume
        // the proxy's own HTTP error reply bytes as if they were a new
        // request.
    }

    private func handleHTTPProxyRequest(method: LogEntry.HTTPMethod, methodStr: String, requestTarget: String, request: String, connection: NWConnection, leftover: Data) {
        guard let target = HTTPTarget(requestTarget: requestTarget) else {
            print("[ProxyServer] handleHTTPProxyRequest: invalid target: \(requestTarget)")
            sendErrorResponse(connection, code: "400 Bad Request")
            return
        }

        let host = target.host
        let port = target.port
        let path = target.path
        let query = target.query
        let requestHeaders = parseHeaders(from: request)

        print("[ProxyServer] handleHTTPProxyRequest: \(methodStr) \(host):\(port)\(path)")
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let logEntry = logStore.log(host: host, port: port, path: path, query: query, method: method, requestHeaders: requestHeaders)
            logStore.incrementConnections()

            let tunnelManager = TunnelManager(
                host: host,
                port: port,
                logStore: logStore,
                logEntry: logEntry
            )

            let key = "\(host):\(port):\(ObjectIdentifier(connection as AnyObject))"
            self.withTunnelsLock { self.activeTunnels[key] = tunnelManager }

            tunnelManager.onConnected = { [weak self] in
                guard let self = self else { return }
                print("[ProxyServer] handleHTTPProxyRequest: connected to \(host):\(port), sending request")
                self.sendHTTPProxyRequest(tunnelManager: tunnelManager, methodStr: methodStr, target: target, clientHeaders: requestHeaders, request: request, connection: connection, leftover: leftover)
                // Tunnel established; start forwarding client→server bytes
                // (POST body, follow-up requests on the same connection).
                self.receiveHTTPRequest(connection)
            }

            tunnelManager.onClose = { [weak self] in
                print("[ProxyServer] handleHTTPProxyRequest: connection closed")
                if let self = self {
                    self.logStore.completeEntry(logEntry)
                    self.logStore.decrementConnections()
                    self.withTunnelsLock { self.activeTunnels.removeValue(forKey: key) }
                }
            }

            tunnelManager.onError = { [weak self] in
                print("[ProxyServer] handleHTTPProxyRequest: connection error")
                if let self = self {
                    self.logStore.failEntry(logEntry)
                    self.logStore.decrementConnections()
                    // Reply to the client with 502 so it sees a proper
                    // status line instead of waiting for a timeout. A
                    // target that already answered is left alone: the
                    // status line would only land in the middle of its
                    // response.
                    switch tunnelManager.answerWhenTargetBreaks {
                    case .statusLine:
                        self.sendErrorResponse(connection, code: "502 Bad Gateway")
                    case .endOfConnection:
                        break
                    }
                    self.withTunnelsLock { self.activeTunnels.removeValue(forKey: key) }
                }
            }

            tunnelManager.startAsProxy(clientConnection: connection)
        }
    }

    private func sendHTTPProxyRequest(tunnelManager: TunnelManager, methodStr: String, target: HTTPTarget, clientHeaders: [String: String], request: String, connection: NWConnection, leftover: Data) {
        let fullPath: String
        if let query = target.query, !query.isEmpty {
            fullPath = "\(target.path)?\(query)"
        } else {
            fullPath = target.path
        }

        var headers = clientHeaders
        // A proxy replaces the Host header with the authority of the
        // request target (RFC 9112 §3.2.2).
        for key in headers.keys.filter({ $0.lowercased() == "host" }) {
            headers.removeValue(forKey: key)
        }
        headers["Host"] = target.hostHeaderValue

        // Hop-by-hop headers belong to the connection between the client
        // and the proxy, not to the request the proxy forwards
        // (RFC 9110 §7.6.1). The Connection header names the other headers
        // that are hop-by-hop as well.
        //
        // Transfer-Encoding stays: the body is passed on unchanged, so its
        // framing has to stay with it.
        var hopByHop = Set(["connection", "keep-alive", "proxy-authenticate",
                            "proxy-authorization", "proxy-connection", "te",
                            "trailer", "upgrade"])
        if let connectionHeader = headers.first(where: { $0.key.lowercased() == "connection" })?.value {
            for name in connectionHeader.split(separator: ",") {
                hopByHop.insert(name.trimmingCharacters(in: .whitespaces).lowercased())
            }
        }
        for key in headers.keys.filter({ hopByHop.contains($0.lowercased()) }) {
            headers.removeValue(forKey: key)
        }

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

        // The body that came with the header block is not part of the
        // request string, so it goes to the server on its own - right
        // behind the request it belongs to.
        if !leftover.isEmpty {
            tunnelManager.sendToServer(data: leftover)
        }

        logStore.updateEntry(tunnelManager.logEntry, responseStatusCode: 0, responseHeaders: nil, duration: 0)
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

    private func establishTunnel(host: String, port: Int, clientConnection: NWConnection, logEntry: LogEntry, leftover: Data) throws {
        let tunnelManager = TunnelManager(
            host: host,
            port: port,
            logStore: logStore,
            logEntry: logEntry
        )

        let key = "\(host):\(port):\(ObjectIdentifier(clientConnection as AnyObject))"
        withTunnelsLock { activeTunnels[key] = tunnelManager }

        tunnelManager.onConnected = { [weak self] in
            print("[ProxyServer] onConnected callback fired for \(host):\(port)")
            self?.sendSuccessResponse(clientConnection)
            // Bytes the client sent before the tunnel was up - the first
            // bytes of the protocol it speaks after the CONNECT - go to
            // the server behind the 200.
            if !leftover.isEmpty {
                tunnelManager.receiveClientData(leftover)
            }
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
                self.withTunnelsLock { self.activeTunnels.removeValue(forKey: key) }
            }
        }

        tunnelManager.onError = { [weak self] in
            print("[ProxyServer] onError callback fired for \(host):\(port)")
            if let self = self {
                self.logStore.failEntry(logEntry)
                self.logStore.decrementConnections()
                // Reply to the client with 502 so HTTP clients see a proper
                // status line instead of a silent close. A tunnel that was
                // already up is not answered: the client is speaking
                // another protocol on it then, and a status line would only
                // corrupt the stream.
                switch tunnelManager.answerWhenTunnelBreaks {
                case .statusLine:
                    self.sendErrorResponse(clientConnection, code: "502 Bad Gateway")
                case .endOfConnection:
                    break
                }
                self.withTunnelsLock { self.activeTunnels.removeValue(forKey: key) }
            }
        }

        tunnelManager.start(clientConnection: clientConnection)
        print("[ProxyServer] tunnelManager.start() called, waiting for connected callback...")
    }

    private func sendSuccessResponse(_ connection: NWConnection) {
        print("[ProxyServer] sending 200 Connection Established")
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { error in
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
