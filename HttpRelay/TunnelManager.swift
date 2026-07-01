import Foundation
import Network

final class TunnelManager {
    let host: String
    let port: Int
    private let logStore: LogStore
    let logEntry: LogEntry

    private var serverConnection: NWConnection?
    private var clientConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.httprelay.tunnel")

    var onConnected: (() -> Void)?
    var onClose: (() -> Void)?
    var onError: (() -> Void)?

    private var pendingOnConnected = false
    private var connectionStartTime: Date?
    private var hasReceivedFirstResponse = false
    private var responseHeaders: [String: String] = [:]
    private var responseStatusCode: Int?

    private var connectionTimeoutItem: DispatchWorkItem?
    private let connectionTimeoutSeconds: TimeInterval = 30.0

    private final class DNSResult {
        var ip: String?
    }

    init(host: String, port: Int, logStore: LogStore, logEntry: LogEntry) {
        self.host = host
        self.port = port
        self.logStore = logStore
        self.logEntry = logEntry
    }

    func start(clientConnection: NWConnection) {
        self.clientConnection = clientConnection
        self.connectionStartTime = Date()

        print("[TunnelManager] starting tunnel to \(host):\(port)")
        let resolvedHost = Self.resolveHostWithTimeout(host: host) ?? host
        print("[TunnelManager] resolved \(host) -> \(resolvedHost)")
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(resolvedHost), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        print("[TunnelManager] endpoint created: \(endpoint)")
        let parameters = Self.makeTCPParameters()
        serverConnection = NWConnection(to: endpoint, using: parameters)
        print("[TunnelManager] serverConnection created, state: \(serverConnection?.state)")

        scheduleConnectionTimeout()

        serverConnection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            print("[TunnelManager] server connection state changed to: \(state)")

            switch state {
            case .ready:
                self.cancelConnectionTimeout()
                print("[TunnelManager] server connection READY to \(self.host):\(self.port)")
                self.pendingOnConnected = true
                DispatchQueue.main.async {
                    print("[TunnelManager] dispatching onConnected callback")
                    self.onConnected?()
                }
                print("[TunnelManager] calling startForwarding")
                self.startForwarding()
            case .failed(let error):
                self.cancelConnectionTimeout()
                print("[TunnelManager] server connection FAILED: \(error)")
                // Do NOT cancel the client connection here — ProxyServer's
                // onError handler is responsible for sending an HTTP error
                // reply before tearing the client down.
                DispatchQueue.main.async {
                    self.logStore.failEntry(self.logEntry)
                    self.onError?()
                }
            case .waiting(let error):
                // Connection refused (or other transient) often manifests
                // as .waiting rather than .failed. Treat any non-success
                // waiting state as a failure.
                print("[TunnelManager] server connection WAITING with error \(error), treating as failure")
                self.cancelConnectionTimeout()
                DispatchQueue.main.async {
                    self.logStore.failEntry(self.logEntry)
                    self.onError?()
                }
            case .cancelled:
                self.cancelConnectionTimeout()
                print("[TunnelManager] server connection CANCELLED")
                self.clientConnection?.cancel()
                DispatchQueue.main.async {
                    self.logStore.completeEntry(self.logEntry)
                    self.onClose?()
                }
            case .preparing:
                print("[TunnelManager] server connection preparing...")
            case .waiting(let error):
                print("[TunnelManager] server connection waiting: \(error)")
            default:
                print("[TunnelManager] server connection state: \(state)")
                break
            }
        }

        serverConnection?.viabilityUpdateHandler = { [weak self] isViable in
            print("[TunnelManager] server connection viabilityUpdate: \(isViable)")
            if !isViable {
                print("[TunnelManager] server connection NON-VIABLE — killing tunnel")
                self?.serverConnection?.cancel()
            }
        }

        serverConnection?.start(queue: queue)
        print("[TunnelManager] serverConnection.start() called")

        clientConnection.viabilityUpdateHandler = { isViable in
            print("[TunnelManager] client connection viabilityUpdate: \(isViable)")
            // Do not auto-close on client non-viable; let state/cancel handle it
            _ = isViable
        }

        clientConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            print("[TunnelManager] client connection state changed: \(state)")

            switch state {
            case .cancelled:
                print("[TunnelManager] client connection cancelled")
                self.serverConnection?.cancel()
            case .failed(let error):
                print("[TunnelManager] client connection failed: \(error)")
                self.serverConnection?.cancel()
            default:
                break
            }
        }
    }

    func startAsProxy(clientConnection: NWConnection) {
        self.clientConnection = clientConnection
        self.connectionStartTime = Date()

        print("[TunnelManager] startAsProxy: connecting to \(host):\(port)")
        let resolvedHost = Self.resolveHostWithTimeout(host: host) ?? host
        print("[TunnelManager] startAsProxy resolved \(host) -> \(resolvedHost)")
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(resolvedHost), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let parameters = Self.makeTCPParameters()
        serverConnection = NWConnection(to: endpoint, using: parameters)

        scheduleConnectionTimeout()

        serverConnection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            print("[TunnelManager] startAsProxy server state: \(state)")

            switch state {
            case .ready:
                self.cancelConnectionTimeout()
                print("[TunnelManager] startAsProxy server READY")
                DispatchQueue.main.async {
                    self.onConnected?()
                }
                self.startProxyForwarding()
            case .failed(let error):
                self.cancelConnectionTimeout()
                print("[TunnelManager] startAsProxy server FAILED: \(error)")
                // Do NOT cancel the client connection here — ProxyServer's
                // onError handler is responsible for sending an HTTP error
                // reply before tearing the client down.
                DispatchQueue.main.async {
                    self.logStore.failEntry(self.logEntry)
                    self.onError?()
                }
            case .waiting(let error):
                print("[TunnelManager] startAsProxy server WAITING with error \(error), treating as failure")
                self.cancelConnectionTimeout()
                DispatchQueue.main.async {
                    self.logStore.failEntry(self.logEntry)
                    self.onError?()
                }
            case .cancelled:
                self.cancelConnectionTimeout()
                print("[TunnelManager] startAsProxy server CANCELLED")
                self.clientConnection?.cancel()
                DispatchQueue.main.async {
                    self.logStore.completeEntry(self.logEntry)
                    self.onClose?()
                }
            case .preparing:
                print("[TunnelManager] startAsProxy server preparing...")
            case .waiting(let error):
                print("[TunnelManager] startAsProxy server waiting: \(error)")
            default:
                break
            }
        }

        serverConnection?.viabilityUpdateHandler = { [weak self] isViable in
            print("[TunnelManager] startAsProxy server viabilityUpdate: \(isViable)")
            if !isViable {
                print("[TunnelManager] startAsProxy server NON-VIABLE — killing tunnel")
                self?.serverConnection?.cancel()
            }
        }

        serverConnection?.start(queue: queue)
    }

    private func startProxyForwarding() {
        print("[TunnelManager] startProxyForwarding called")
        guard let server = serverConnection else { return }

        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil {
                print("[TunnelManager] startProxyForwarding: server error")
                if let client = self.clientConnection {
                    client.cancel()
                }
                server.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                if !self.hasReceivedFirstResponse {
                    self.hasReceivedFirstResponse = true
                    self.parseAndLogResponse(data: data)
                }
                if isComplete {
                    print("[TunnelManager] startProxyForwarding: server->client \(data.count) bytes (FIN follows), then close")
                } else {
                    print("[TunnelManager] startProxyForwarding: server->client \(data.count) bytes")
                }
                Task { @MainActor in
                    self.logStore.addRxBytes(data.count, to: self.logEntry)
                }
                if let client = self.clientConnection {
                    client.send(content: data, isComplete: isComplete, completion: .contentProcessed { error in
                        if error != nil {
                            client.cancel()
                            server.cancel()
                            return
                        }
                        if isComplete {
                            print("[TunnelManager] startProxyForwarding: data + FIN delivered, closing server")
                            server.cancel()
                        } else {
                            self.continueProxyForwarding()
                        }
                    })
                }
            } else if isComplete {
                print("[TunnelManager] startProxyForwarding: isComplete with no data, cancelling both")
                if let client = self.clientConnection {
                    client.cancel()
                }
                server.cancel()
            } else {
                self.continueProxyForwarding()
            }
        }
    }

    private func continueProxyForwarding() {
        guard let server = serverConnection else { return }
        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil {
                print("[TunnelManager] continueProxyForwarding: server error")
                if let client = self.clientConnection {
                    client.cancel()
                }
                server.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                if !self.hasReceivedFirstResponse {
                    self.hasReceivedFirstResponse = true
                    self.parseAndLogResponse(data: data)
                }
                Task { @MainActor in
                    self.logStore.addRxBytes(data.count, to: self.logEntry)
                }
                if let client = self.clientConnection {
                    client.send(content: data, isComplete: isComplete, completion: .contentProcessed { error in
                        if error != nil {
                            client.cancel()
                            server.cancel()
                            return
                        }
                        if isComplete {
                            print("[TunnelManager] continueProxyForwarding: data + FIN delivered, closing server")
                            server.cancel()
                        } else {
                            self.continueProxyForwarding()
                        }
                    })
                }
            } else if isComplete {
                print("[TunnelManager] continueProxyForwarding: isComplete with no data, cancelling both")
                if let client = self.clientConnection {
                    client.cancel()
                }
                server.cancel()
            } else {
                self.continueProxyForwarding()
            }
        }
    }

    func sendToServer(data: Data) {
        print("[TunnelManager] sendToServer: sending \(data.count) bytes")
        Task { @MainActor in
            self.logStore.addTxBytes(data.count, to: self.logEntry)
        }
        serverConnection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("[TunnelManager] sendToServer error: \(error)")
                return
            }
            print("[TunnelManager] sendToServer: sent successfully")
        })
    }

    private func startForwarding() {
        print("[TunnelManager] startForwarding called")
        guard let client = clientConnection, let server = serverConnection else {
            print("[TunnelManager] startForwarding: missing connections")
            return
        }
        print("[TunnelManager]   client state: \(client.state)")
        print("[TunnelManager]   server state: \(server.state)")

        print("[TunnelManager] server-side forwarding only; client-side receive is handled by ProxyServer")

        print("[TunnelManager] setting up server receive handler")
        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            print("[TunnelManager] server->client callback: data.count=\(data?.count ?? -1), isComplete=\(isComplete), error=\(error?.localizedDescription ?? "nil")")

            if error != nil {
                print("[TunnelManager] server->client error, cancelling")
                client.cancel()
                server.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                if !self.hasReceivedFirstResponse {
                    self.hasReceivedFirstResponse = true
                    self.parseAndLogResponse(data: data)
                }
                if isComplete {
                    print("[TunnelManager] server->client forwarding \(data.count) bytes (FIN follows), then close")
                } else {
                    print("[TunnelManager] server->client forwarding \(data.count) bytes")
                }
                Task { @MainActor in
                    self.logStore.addRxBytes(data.count, to: self.logEntry)
                }
                client.send(content: data, isComplete: isComplete, completion: .contentProcessed { error in
                    if error != nil {
                        print("[TunnelManager] client send error")
                        client.cancel()
                        server.cancel()
                        return
                    }
                    if isComplete {
                        print("[TunnelManager] server->client: last bytes + FIN delivered, closing server")
                        server.cancel()
                    } else {
                        self.forwardToClient(client: client, server: server)
                    }
                })
            } else if isComplete {
                print("[TunnelManager] server->client: isComplete with no data, cancelling both")
                client.cancel()
                server.cancel()
            } else {
                print("[TunnelManager] server->client: no data (count=-1 or empty), keeping connection open...")
                self.forwardToClient(client: client, server: server)
            }
        }
    }

    private func parseAndLogResponse(data: Data) {
        guard let responseString = String(data: data, encoding: .utf8) else { return }

        let lines = responseString.split(separator: "\r\n")
        guard let firstLine = lines.first else { return }

        let statusLineComponents = firstLine.split(separator: " ")
        guard statusLineComponents.count >= 2 else { return }

        if let statusCode = Int(statusLineComponents[1]) {
            self.responseStatusCode = statusCode
            var headers: [String: String] = [:]
            for i in 1..<lines.count {
                let line = lines[i]
                if line.isEmpty { break }
                if let colonIndex = line.firstIndex(of: ":") {
                    let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
            }
            self.responseHeaders = headers

            let duration = connectionStartTime.map { Date().timeIntervalSince($0) }

            Task { @MainActor in
                self.logStore.updateEntry(
                    self.logEntry,
                    responseStatusCode: statusCode,
                    responseHeaders: headers,
                    duration: duration ?? 0
                )
            }
        }
    }

    private func forwardToClient(client: NWConnection, server: NWConnection) {
        print("[TunnelManager] forwardToClient: calling receive")
        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            print("[TunnelManager] forwardToClient callback: data.count=\(data?.count ?? -1), isComplete=\(isComplete)")

            if error != nil {
                print("[TunnelManager] forwardToClient: error, cancelling")
                client.cancel()
                server.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                if !self.hasReceivedFirstResponse {
                    self.hasReceivedFirstResponse = true
                    self.parseAndLogResponse(data: data)
                }
                if isComplete {
                    print("[TunnelManager] forwardToClient: forwarding \(data.count) bytes (FIN follows), then close")
                } else {
                    print("[TunnelManager] forwardToClient: forwarding \(data.count) bytes")
                }
                Task { @MainActor in
                    self.logStore.addRxBytes(data.count, to: self.logEntry)
                }
                client.send(content: data, isComplete: isComplete, completion: .contentProcessed { error in
                    if error != nil {
                        print("[TunnelManager] forwardToClient: send error")
                        client.cancel()
                        server.cancel()
                        return
                    }
                    if isComplete {
                        print("[TunnelManager] forwardToClient: last bytes + FIN delivered, closing server")
                        server.cancel()
                    } else {
                        self.forwardToClient(client: client, server: server)
                    }
                })
            } else if isComplete {
                print("[TunnelManager] forwardToClient: isComplete with no data, cancelling both")
                client.cancel()
                server.cancel()
            } else {
                print("[TunnelManager] forwardToClient: no data, recursing")
                self.forwardToClient(client: client, server: server)
            }
        }
    }

    func close() {
        clientConnection?.cancel()
        serverConnection?.cancel()
    }

    func receiveClientData(_ data: Data) {
        print("[TunnelManager] receiveClientData: received \(data.count) bytes from ProxyServer")
        Task { @MainActor in
            self.logStore.addTxBytes(data.count, to: self.logEntry)
        }
        guard let server = serverConnection else {
            print("[TunnelManager] receiveClientData: no server connection")
            return
        }
        guard server.state == .ready else {
            print("[TunnelManager] receiveClientData: server not ready (state=\(server.state)), dropping \(data.count) bytes (browser will retry)")
            return
        }
        server.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[TunnelManager] receiveClientData: send error: \(error) — NOT closing tunnel; teardown handled by state handlers")
                return
            }
            print("[TunnelManager] receiveClientData: forwarded \(data.count) bytes to server")
        })
    }

    var clientConnectionRef: NWConnection? {
        return clientConnection
    }

    private func scheduleConnectionTimeout() {
        connectionTimeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard let conn = self.serverConnection else { return }
            switch conn.state {
            case .ready:
                return
            case .cancelled, .failed:
                return
            default:
                print("[TunnelManager] connection still not ready after \(self.connectionTimeoutSeconds)s (state=\(conn.state)), cancelling")
                conn.cancel()
                DispatchQueue.main.async {
                    self.logStore.failEntry(self.logEntry)
                    self.onError?()
                }
            }
        }
        connectionTimeoutItem = item
        queue.asyncAfter(deadline: .now() + connectionTimeoutSeconds, execute: item)
    }

    private func cancelConnectionTimeout() {
        connectionTimeoutItem?.cancel()
        connectionTimeoutItem = nil
    }

    private static func makeTCPParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        if let tcpOptions = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcpOptions.connectionTimeout = 30
            tcpOptions.keepaliveIdle = 30
            tcpOptions.keepaliveInterval = 10
            tcpOptions.keepaliveCount = 3
            tcpOptions.enableFastOpen = true
            tcpOptions.noDelay = true
        }
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private static func resolveHostWithTimeout(host: String, timeout: TimeInterval = 3.0) -> String? {
        if isIPv4Address(host) { return host }

        let result = DNSResult()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            defer { semaphore.signal() }

            host.withCString { hostCStr in
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                hints.ai_protocol = IPPROTO_TCP

                var addrInfo: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(hostCStr, nil, &hints, &addrInfo)
                defer { if let r = addrInfo { freeaddrinfo(r) } }

                guard status == 0, let first = addrInfo else { return }

                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen,
                              &buf, socklen_t(buf.count),
                              nil, 0, NI_NUMERICHOST) == 0 {
                    result.ip = String(cString: buf)
                }
            }
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            print("[TunnelManager] DNS resolution timeout for \(host) after \(timeout)s")
            return nil
        }
        return result.ip
    }

    private static func isIPv4Address(_ s: String) -> Bool {
        return s.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
    }
}
