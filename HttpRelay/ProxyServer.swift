import Foundation
import Network

protocol ProxyServerDelegate: AnyObject {
    func proxyServer(_ server: ProxyServer, didFailWithError error: NWError)
}

final class ProxyServer {
    typealias ConnectionHandler = (NWConnection) -> Void

    private let port: UInt16
    private var listener: NWListener?
    private let logStore: LogStore
    private var activeTunnels: [String: TunnelManager] = [:]
    private let tunnelsLock = NSLock()

    weak var delegate: ProxyServerDelegate?

    init(port: UInt16 = 10808, logStore: LogStore) {
        self.port = port
        self.logStore = logStore
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
            case .failed(let error):
                print("[ProxyServer] failed: \(error)")
                self.delegate?.proxyServer(self, didFailWithError: error)
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
    }

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: .global())

        receiveHTTPRequest(connection)
    }

    private func receiveHTTPRequest(_ connection: NWConnection) {
        print("[ProxyServer] receiveHTTPRequest: starting receive on \(connection.endpoint)")
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            print("[ProxyServer] receiveHTTPRequest callback: data.count=\(data?.count ?? -1), isComplete=\(isComplete), error=\(error?.localizedDescription ?? "nil")")

            if let error = error {
                self.logStore.log(host: String(describing: connection.endpoint), port: 0, status: .error)
                connection.cancel()
                return
            }

            if isComplete {
                print("[ProxyServer] receiveHTTPRequest: connection completed")
                connection.cancel()
                return
            }

            if let data = data, let request = String(data: data, encoding: .utf8) {
                print("[ProxyServer] receiveHTTPRequest: processing request")
                self.processRequest(request, connection: connection)
            } else {
                print("[ProxyServer] receiveHTTPRequest: no data, waiting more...")
                self.receiveHTTPRequest(connection)
            }
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

        let method = String(components[0])
        let target = String(components[1])
        print("[ProxyServer] processRequest: method=\(method), target=\(target)")

        guard method == "CONNECT" else {
            print("[ProxyServer] processRequest: not CONNECT, sending 405")
            sendErrorResponse(connection, code: "405 Method Not Allowed")
            return
        }

        let hostPort = target.split(separator: ":")
        guard hostPort.count == 2,
              let port = Int(hostPort[1]) else {
            print("[ProxyServer] processRequest: invalid target, sending 400")
            sendErrorResponse(connection, code: "400 Bad Request")
            return
        }

        let host = String(hostPort[0])
        print("[ProxyServer] processRequest: connecting to \(host):\(port)")
        logStore.log(host: host, port: port, status: .connect)
        logStore.incrementConnections()

        do {
            try establishTunnel(host: host, port: port, clientConnection: connection)
        } catch {
            print("[ProxyServer] processRequest: establishTunnel failed: \(error)")
            logStore.log(host: host, port: port, status: .error)
            logStore.decrementConnections()
            sendErrorResponse(connection, code: "502 Bad Gateway")
        }

        print("[ProxyServer] processRequest: continuing to wait for more data on connection")
        self.receiveHTTPRequest(connection)
    }

    private func establishTunnel(host: String, port: Int, clientConnection: NWConnection) throws {
        let tunnelManager = TunnelManager(
            host: host,
            port: port,
            logStore: logStore
        )

        let key = host + ":\(port)"
        tunnelsLock.lock()
        activeTunnels[key] = tunnelManager
        tunnelsLock.unlock()

        var hasCompleted = false
        let completionLock = NSLock()

        tunnelManager.onConnected = { [weak self] in
            print("[ProxyServer] onConnected callback fired for \(host):\(port)")
            completionLock.lock()
            guard !hasCompleted else {
                completionLock.unlock()
                print("[ProxyServer] onConnected but hasCompleted=true, ignoring")
                return
            }
            hasCompleted = true
            completionLock.unlock()
            print("[ProxyServer] calling sendSuccessResponse for \(host):\(port)")
            self?.sendSuccessResponse(clientConnection)
            if let self = self {
                self.tunnelsLock.lock()
                self.activeTunnels.removeValue(forKey: host + ":\(port)")
                self.tunnelsLock.unlock()
            }
            print("[ProxyServer] done with onConnected for \(host):\(port)")
        }

        tunnelManager.onClose = { [weak self] in
            print("[ProxyServer] onClose callback fired for \(host):\(port)")
            completionLock.lock()
            guard !hasCompleted else {
                completionLock.unlock()
                return
            }
            hasCompleted = true
            completionLock.unlock()
            self?.logStore.log(host: host, port: port, status: .closed)
            self?.logStore.decrementConnections()
            if let self = self {
                self.tunnelsLock.lock()
                self.activeTunnels.removeValue(forKey: host + ":\(port)")
                self.tunnelsLock.unlock()
            }
        }

        tunnelManager.onError = { [weak self] in
            print("[ProxyServer] onError callback fired for \(host):\(port)")
            completionLock.lock()
            guard !hasCompleted else {
                completionLock.unlock()
                return
            }
            hasCompleted = true
            completionLock.unlock()
            self?.logStore.log(host: host, port: port, status: .error)
            self?.logStore.decrementConnections()
            clientConnection.cancel()
            if let self = self {
                self.tunnelsLock.lock()
                self.activeTunnels.removeValue(forKey: host + ":\(port)")
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
                    self?.logStore.log(host: String(describing: connection.endpoint), port: 0, status: .error)
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