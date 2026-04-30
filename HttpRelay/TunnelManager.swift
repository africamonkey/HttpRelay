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
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        print("[TunnelManager] endpoint created: \(endpoint)")
        let parameters = NWParameters.tcp
        serverConnection = NWConnection(to: endpoint, using: parameters)
        print("[TunnelManager] serverConnection created, state: \(serverConnection?.state)")

        serverConnection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            print("[TunnelManager] server connection state changed to: \(state)")

            switch state {
            case .ready:
                print("[TunnelManager] server connection READY to \(self.host):\(self.port)")
                self.pendingOnConnected = true
                DispatchQueue.main.async {
                    print("[TunnelManager] dispatching onConnected callback")
                    self.onConnected?()
                }
                print("[TunnelManager] calling startForwarding")
                self.startForwarding()
            case .failed(let error):
                print("[TunnelManager] server connection FAILED: \(error)")
                self.clientConnection?.cancel()
                DispatchQueue.main.async {
                    self.logStore.failEntry(self.logEntry)
                    self.onError?()
                }
            case .cancelled:
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

        serverConnection?.start(queue: queue)
        print("[TunnelManager] serverConnection.start() called")

        self.clientConnection?.stateUpdateHandler = { [weak self] state in
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
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let parameters = NWParameters.tcp
        serverConnection = NWConnection(to: endpoint, using: parameters)

        serverConnection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            print("[TunnelManager] startAsProxy server state: \(state)")

            switch state {
            case .ready:
                print("[TunnelManager] startAsProxy server READY")
                DispatchQueue.main.async {
                    self.onConnected?()
                }
                self.startProxyForwarding()
            case .failed(let error):
                print("[TunnelManager] startAsProxy server FAILED: \(error)")
                self.clientConnection?.cancel()
                DispatchQueue.main.async {
                    self.logStore.failEntry(self.logEntry)
                    self.onError?()
                }
            case .cancelled:
                print("[TunnelManager] startAsProxy server CANCELLED")
                self.clientConnection?.cancel()
                DispatchQueue.main.async {
                    self.logStore.completeEntry(self.logEntry)
                    self.onClose?()
                }
            default:
                break
            }
        }

        serverConnection?.start(queue: queue)
    }

    private func startProxyForwarding() {
        print("[TunnelManager] startProxyForwarding called")
        guard let server = serverConnection else { return }

        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil || isComplete {
                print("[TunnelManager] startProxyForwarding: server error/complete")
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
                print("[TunnelManager] startProxyForwarding: server->client \(data.count) bytes")
                Task { @MainActor in
                    self.logStore.addRxBytes(data.count, to: self.logEntry)
                }
                if let client = self.clientConnection {
                    client.send(content: data, completion: .contentProcessed { error in
                        if error != nil {
                            client.cancel()
                            server.cancel()
                            return
                        }
                        self.continueProxyForwarding()
                    })
                }
            } else {
                self.continueProxyForwarding()
            }
        }
    }

    private func continueProxyForwarding() {
        guard let server = serverConnection else { return }
        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil || isComplete {
                print("[TunnelManager] continueProxyForwarding: server error/complete")
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
                    client.send(content: data, completion: .contentProcessed { error in
                        if error != nil {
                            client.cancel()
                            server.cancel()
                            return
                        }
                        self.continueProxyForwarding()
                    })
                }
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

        print("[TunnelManager] starting bidirectional forwarding")

        print("[TunnelManager] setting up client receive handler")
        client.receive(minimumIncompleteLength: 0, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            print("[TunnelManager] client->server callback: data.count=\(data?.count ?? -1), isComplete=\(isComplete), error=\(error?.localizedDescription ?? "nil")")

            if error != nil || isComplete {
                print("[TunnelManager] client->server error/complete, cancelling")
                client.cancel()
                server.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                print("[TunnelManager] client->server forwarding \(data.count) bytes")
                Task { @MainActor in
                    self.logStore.addTxBytes(data.count, to: self.logEntry)
                }
                server.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        print("[TunnelManager] server send error")
                        client.cancel()
                        server.cancel()
                        return
                    }
                    self.forwardToServer(client: client, server: server)
                })
            } else {
                print("[TunnelManager] client->server: no data (count=-1 or empty), keeping connection open...")
                self.forwardToServer(client: client, server: server)
            }
        }

        print("[TunnelManager] setting up server receive handler")
        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            print("[TunnelManager] server->client callback: data.count=\(data?.count ?? -1), isComplete=\(isComplete), error=\(error?.localizedDescription ?? "nil")")

            if error != nil || isComplete {
                print("[TunnelManager] server->client error/complete, cancelling")
                client.cancel()
                server.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                if !self.hasReceivedFirstResponse {
                    self.hasReceivedFirstResponse = true
                    self.parseAndLogResponse(data: data)
                }
                print("[TunnelManager] server->client forwarding \(data.count) bytes")
                Task { @MainActor in
                    self.logStore.addRxBytes(data.count, to: self.logEntry)
                }
                client.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        print("[TunnelManager] client send error")
                        client.cancel()
                        server.cancel()
                        return
                    }
                    self.forwardToClient(client: client, server: server)
                })
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

    private func forwardToServer(client: NWConnection, server: NWConnection) {
        print("[TunnelManager] forwardToServer: calling receive")
        client.receive(minimumIncompleteLength: 0, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            print("[TunnelManager] forwardToServer callback: data.count=\(data?.count ?? -1), isComplete=\(isComplete)")

            if error != nil || isComplete {
                print("[TunnelManager] forwardToServer: error/complete, cancelling")
                client.cancel()
                server.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                print("[TunnelManager] forwardToServer: forwarding \(data.count) bytes")
                Task { @MainActor in
                    self.logStore.addTxBytes(data.count, to: self.logEntry)
                }
                server.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        print("[TunnelManager] forwardToServer: send error")
                        client.cancel()
                        server.cancel()
                        return
                    }
                    self.forwardToServer(client: client, server: server)
                })
            } else {
                print("[TunnelManager] forwardToServer: no data, recursing")
                self.forwardToServer(client: client, server: server)
            }
        }
    }

    private func forwardToClient(client: NWConnection, server: NWConnection) {
        print("[TunnelManager] forwardToClient: calling receive")
        server.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            print("[TunnelManager] forwardToClient callback: data.count=\(data?.count ?? -1), isComplete=\(isComplete)")

            if error != nil || isComplete {
                print("[TunnelManager] forwardToClient: error/complete, cancelling")
                client.cancel()
                server.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                if !self.hasReceivedFirstResponse {
                    self.hasReceivedFirstResponse = true
                    self.parseAndLogResponse(data: data)
                }
                print("[TunnelManager] forwardToClient: forwarding \(data.count) bytes")
                Task { @MainActor in
                    self.logStore.addRxBytes(data.count, to: self.logEntry)
                }
                client.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        print("[TunnelManager] forwardToClient: send error")
                        client.cancel()
                        server.cancel()
                        return
                    }
                    self.forwardToClient(client: client, server: server)
                })
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
        server.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("[TunnelManager] receiveClientData: send error: \(error)")
                return
            }
            print("[TunnelManager] receiveClientData: forwarded \(data.count) bytes to server")
        })
    }

    var clientConnectionRef: NWConnection? {
        return clientConnection
    }
}
