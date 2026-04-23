# HttpRelay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement an iOS HTTP CONNECT proxy that receives requests from Windows via system proxy, tunnels them through the device's VPN (飞连), and displays real-time logs.

**Architecture:** User-space HTTP CONNECT proxy using NWListener and URLSession. All traffic automatically routes through the system VPN since URLSession uses the default network configuration.

**Tech Stack:** SwiftUI, Network.framework (NWListener, NWConnection), Foundation (URLSession)

---

## File Structure

```
HttpRelay/
├── HttpRelayApp.swift        (modify - remove SwiftData setup)
├── ContentView.swift         (modify - main UI)
├── Item.swift                (delete - template file)
├── LogEntry.swift            (create - log data model)
├── LogStore.swift            (create - observable log storage)
├── ProxyServer.swift         (create - NWListener + HTTP CONNECT)
└── TunnelManager.swift       (create - connection bridging)
```

---

## Task 1: Create LogEntry and LogStore Models

**Files:**
- Create: `HttpRelay/LogEntry.swift`
- Create: `HttpRelay/LogStore.swift`

- [ ] **Step 1: Create LogEntry.swift**

```swift
import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let host: String
    let port: Int
    let status: LogStatus

    enum LogStatus: String {
        case connect = "CONNECT"
        case connected = "200 OK"
        case closed = "CLOSED"
        case error = "ERROR"
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    var displayString: String {
        "\(formattedTime)  \(host):\(port)  \(status.rawValue)"
    }
}
```

- [ ] **Step 2: Create LogStore.swift**

```swift
import Foundation
import Observation

@Observable
final class LogStore {
    var entries: [LogEntry] = []
    var activeConnections: Int = 0

    func log(host: String, port: Int, status: LogEntry.LogStatus) {
        let entry = LogEntry(timestamp: Date(), host: host, port: port, status: status)
        entries.insert(entry, at: 0)
        if entries.count > 500 {
            entries.removeLast()
        }
    }

    func incrementConnections() {
        activeConnections += 1
    }

    func decrementConnections() {
        if activeConnections > 0 {
            activeConnections -= 1
        }
    }

    func clear() {
        entries.removeAll()
        activeConnections = 0
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add HttpRelay/LogEntry.swift HttpRelay/LogStore.swift
git commit -m "feat: add LogEntry and LogStore models"
```

---

## Task 2: Implement ProxyServer

**Files:**
- Create: `HttpRelay/ProxyServer.swift`

- [ ] **Step 1: Create ProxyServer.swift**

```swift
import Foundation
import Network

final class ProxyServer {
    typealias ConnectionHandler = (NWConnection) -> Void

    private let port: UInt16
    private var listener: NWListener?
    private let logStore: LogStore

    init(port: UInt16 = 10808, logStore: LogStore) {
        self.port = port
        self.logStore = logStore
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("ProxyServer listening on port \(self?.port ?? 0)")
            case .failed(let error):
                print("ProxyServer failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
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
                print("Receive error: \(error)")
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

        establishTunnel(host: host, port: port, clientConnection: connection)
    }

    private func establishTunnel(host: String, port: Int, clientConnection: NWConnection) {
        let tunnelManager = TunnelManager(
            host: host,
            port: port,
            logStore: logStore
        )

        tunnelManager.onConnected = { [weak self] in
            self?.sendSuccessResponse(clientConnection)
        }

        tunnelManager.onClose = { [weak self] in
            self?.logStore.log(host: host, port: port, status: .closed)
            self?.logStore.decrementConnections()
        }

        tunnelManager.onError = { [weak self] in
            self?.logStore.log(host: host, port: port, status: .error)
            self?.logStore.decrementConnections()
            clientConnection.cancel()
        }

        tunnelManager.start(clientConnection: clientConnection)
    }

    private func sendSuccessResponse(_ connection: NWConnection) {
        let response = "HTTP/1.1 200 Connection Established\r\n\r\n"
        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    print("Send response error: \(error)")
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
```

- [ ] **Step 2: Commit**

```bash
git add HttpRelay/ProxyServer.swift
git commit -m "feat: add ProxyServer with NWListener and HTTP CONNECT handling"
```

---

## Task 3: Implement TunnelManager

**Files:**
- Create: `HttpRelay/TunnelManager.swift`

- [ ] **Step 1: Create TunnelManager.swift**

```swift
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
```

- [ ] **Step 2: Commit**

```bash
git add HttpRelay/TunnelManager.swift
git commit -m "feat: add TunnelManager for connection bridging"
```

---

## Task 4: Update ContentView UI

**Files:**
- Modify: `HttpRelay/ContentView.swift`

- [ ] **Step 1: Rewrite ContentView.swift**

```swift
import SwiftUI

struct ContentView: View {
    @State private var isRunning = false
    @State private var logStore = LogStore()
    @State private var proxyServer: ProxyServer?
    @State private var connectionCount: Int = 0

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Toggle("代理开关", isOn: $isRunning)
                        .toggleStyle(SwitchToggleStyle(tint: .green))
                        .onChange(of: isRunning) { _, newValue in
                            toggleProxy(newValue)
                        }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("状态:")
                            .foregroundColor(.secondary)
                        Text(isRunning ? "运行中" : "已停止")
                            .fontWeight(.medium)
                    }

                    HStack {
                        Text("端口:")
                            .foregroundColor(.secondary)
                        Text("10808")
                    }

                    HStack {
                        Text("连接数:")
                            .foregroundColor(.secondary)
                        Text("\(connectionCount)")
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

                Text("日志")
                    .font(.headline)
                    .padding(.top)

                List {
                    ForEach(logStore.entries) { entry in
                        Text(entry.displayString)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .listStyle(.plain)
                .background(Color(.systemGray6))
                .cornerRadius(12)
            }
            .padding()
            .navigationTitle("HttpRelay")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: clearLogs) {
                        Label("清除日志", systemImage: "trash")
                    }
                    .disabled(isRunning)
                }
            }
        }
        .onChange(of: logStore.activeConnections) { _, newValue in
            connectionCount = newValue
        }
    }

    private func toggleProxy(_ enabled: Bool) {
        if enabled {
            startProxy()
        } else {
            stopProxy()
        }
    }

    private func startProxy() {
        proxyServer = ProxyServer(port: 10808, logStore: logStore)
        do {
            try proxyServer?.start()
        } catch {
            print("Failed to start proxy: \(error)")
            isRunning = false
        }
    }

    private func stopProxy() {
        proxyServer?.stop()
        proxyServer = nil
    }

    private func clearLogs() {
        logStore.clear()
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 2: Commit**

```bash
git add HttpRelay/ContentView.swift
git commit -m "feat: add ContentView UI with proxy toggle and logs"
```

---

## Task 5: Remove Template Code and Wire Up App

**Files:**
- Delete: `HttpRelay/Item.swift`
- Modify: `HttpRelay/HttpRelayApp.swift`

- [ ] **Step 1: Delete Item.swift**

```bash
rm HttpRelay/Item.swift
```

- [ ] **Step 2: Simplify HttpRelayApp.swift**

```swift
import SwiftUI

@main
struct HttpRelayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: remove template code and simplify app entry"
```

---

## Implementation Complete

Once all tasks are complete, the app will:
1. Start an HTTP CONNECT proxy server on port 10808 when toggled on
2. Accept CONNECT requests from Windows system proxy
3. Tunnel traffic through URLSession (routing via 飞连 VPN)
4. Display real-time logs for each connection event
5. Show active connection count

**Windows Configuration:**
- System Settings → Proxy → Manual proxy setup
- Address: iOS device IP
- Port: 10808
