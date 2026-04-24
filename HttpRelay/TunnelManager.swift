import Foundation
import Network

final class TunnelManager {
    private let host: String
    private let port: Int
    private let logStore: LogStore

    private var serverConnection: NWConnection?
    private var clientConnection: NWConnection?
    private let queue = DispatchQueue(label: "com.httprelay.tunnel")

    var onConnected: (() -> Void)?
    var onClose: (() -> Void)?
    var onError: (() -> Void)?

    init(host: String, port: Int, logStore: LogStore) {
        self.host = host
        self.port = port
        self.logStore = logStore
    }

    func start(clientConnection: NWConnection) {
        self.clientConnection = clientConnection

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
                DispatchQueue.main.async {
                    self.onConnected?()
                    self.logStore.log(host: self.host, port: self.port, status: .connected)
                }
                self.startForwarding()
            case .failed(let error):
                print("[TunnelManager] server connection FAILED: \(error)")
                self.clientConnection?.cancel()
                DispatchQueue.main.async {
                    self.onError?()
                }
            case .cancelled:
                print("[TunnelManager] server connection CANCELLED")
                self.clientConnection?.cancel()
                DispatchQueue.main.async {
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

    private func startForwarding() {
        print("[TunnelManager] startForwarding called")
        guard let client = clientConnection, let server = serverConnection else {
            print("[TunnelManager] startForwarding: missing connections")
            return
        }
        print("[TunnelManager]   client state: \(client.state)")
        print("[TunnelManager]   server state: \(server.state)")

        print("[TunnelManager] starting bidirectional forwarding")
        print("[TunnelManager]   about to call client.receive (waiting for Windows data)")

        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
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
                print("[TunnelManager] client->server: no data yet, waiting...")
                self.forwardToServer(client: client, server: server)
            }
        }

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
                print("[TunnelManager] server->client forwarding \(data.count) bytes")
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
                print("[TunnelManager] server->client: no data yet, waiting...")
                self.forwardToClient(client: client, server: server)
            }
        }
    }

    private func forwardToServer(client: NWConnection, server: NWConnection) {
        print("[TunnelManager] forwardToServer: calling receive")
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            print("[TunnelManager] forwardToServer callback: data.count=\(data?.count ?? -1), isComplete=\(isComplete)")

            if error != nil || isComplete {
                client.cancel()
                server.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                print("[TunnelManager] forwardToServer: forwarding \(data.count) bytes")
                server.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        client.cancel()
                        server.cancel()
                        return
                    }
                    self.forwardToServer(client: client, server: server)
                })
            } else {
                print("[TunnelManager] forwardToServer: no data, continuing...")
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
                client.cancel()
                server.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                print("[TunnelManager] forwardToClient: forwarding \(data.count) bytes")
                client.send(content: data, completion: .contentProcessed { error in
                    if error != nil {
                        client.cancel()
                        server.cancel()
                        return
                    }
                    self.forwardToClient(client: client, server: server)
                })
            } else {
                print("[TunnelManager] forwardToClient: no data, continuing...")
                self.forwardToClient(client: client, server: server)
            }
        }
    }

    func close() {
        clientConnection?.cancel()
        serverConnection?.cancel()
    }
}