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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.logStore.log(host: String(describing: connection.endpoint), port: 0, status: .error)
                connection.cancel()
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            if let data = data, let request = String(data: data, encoding: .utf8) {
                self.processRequest(request, connection: connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func processRequest(_ request: String, connection: NWConnection) {
        let lines = request.split(separator: "\r\n")
        guard let firstLine = lines.first else {
            connection.cancel()
            return
        }

        let components = firstLine.split(separator: " ")
        guard components.count >= 2 else {
            connection.cancel()
            return
        }

        let method = String(components[0])
        let target = String(components[1])

        guard method == "CONNECT" else {
            sendErrorResponse(connection, code: "405 Method Not Allowed")
            return
        }

        let hostPort = target.split(separator: ":")
        guard hostPort.count == 2,
              let port = Int(hostPort[1]) else {
            sendErrorResponse(connection, code: "400 Bad Request")
            return
        }

        let host = String(hostPort[0])
        logStore.log(host: host, port: port, status: .connect)
        logStore.incrementConnections()

        do {
            try establishTunnel(host: host, port: port, clientConnection: connection)
        } catch {
            logStore.log(host: host, port: port, status: .error)
            logStore.decrementConnections()
            sendErrorResponse(connection, code: "502 Bad Gateway")
        }
    }

    private func establishTunnel(host: String, port: Int, clientConnection: NWConnection) throws {
        let tunnelManager = TunnelManager(
            host: host,
            port: port,
            logStore: logStore
        )

        var hasCompleted = false
        let completionLock = NSLock()

        tunnelManager.onConnected = { [weak self] in
            completionLock.lock()
            guard !hasCompleted else {
                completionLock.unlock()
                return
            }
            hasCompleted = true
            completionLock.unlock()
            self?.sendSuccessResponse(clientConnection)
        }

        tunnelManager.onClose = { [weak self] in
            completionLock.lock()
            guard !hasCompleted else {
                completionLock.unlock()
                return
            }
            hasCompleted = true
            completionLock.unlock()
            self?.logStore.log(host: host, port: port, status: .closed)
            self?.logStore.decrementConnections()
        }

        tunnelManager.onError = { [weak self] in
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
        }

        tunnelManager.start(clientConnection: clientConnection)
    }

    private func sendSuccessResponse(_ connection: NWConnection) {
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error = error {
                    self?.logStore.log(host: String(describing: connection.endpoint), port: 0, status: .error)
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