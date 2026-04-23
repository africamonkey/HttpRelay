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

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
        let parameters = NWParameters.tcp
        serverConnection = NWConnection(to: endpoint, using: parameters)

        serverConnection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.onConnected?()
                    self.logStore.log(host: self.host, port: self.port, status: .connected)
                }
                self.startForwarding()
            case .failed(let error):
                print("Server connection failed: \(error)")
                DispatchQueue.main.async {
                    self.onError?()
                }
            case .cancelled:
                DispatchQueue.main.async {
                    self.onClose?()
                }
            default:
                break
            }
        }

        serverConnection?.start(queue: queue)

        clientConnection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .cancelled:
                self.serverConnection?.cancel()
            case .failed:
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
                print("Forward \(direction) error: \(error)")
                source.cancel()
                return
            }

            if isComplete {
                source.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                destination?.send(content: data, completion: .contentProcessed { [weak self] error in
                    if let error = error {
                        print("Send \(direction) error: \(error)")
                        source.cancel()
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