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
        forwardData(from: clientConnection, to: serverConnection, direction: "client->server")
        forwardData(from: serverConnection, to: clientConnection, direction: "server->client")
    }

    private func forwardData(from source: NWConnection?, to destination: NWConnection?, direction: String) {
        guard let source = source else { return }

        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[TunnelManager] forward \(direction) receive error: \(error)")
                source.cancel()
                destination?.cancel()
                return
            }

            if isComplete {
                print("[TunnelManager] forward \(direction) complete, cancelling")
                source.cancel()
                destination?.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                print("[TunnelManager] forward \(direction) sending \(data.count) bytes")
                destination?.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        print("[TunnelManager] forward \(direction) send error: \(error)")
                        source.cancel()
                        destination?.cancel()
                        return
                    }
                    self?.forwardData(from: source, to: destination, direction: direction)
                })
            } else {
                self.forwardData(from: source, to: destination, direction: direction)
            }
        }
    }

    func close() {
        clientConnection?.cancel()
        serverConnection?.cancel()
    }
}