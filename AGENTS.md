# HttpRelay - iOS HTTP CONNECT Proxy

## Project Overview

HttpRelay is an iOS app that acts as an HTTP CONNECT proxy server. It allows a Windows machine to route HTTP/HTTPS traffic through the iOS device, which is useful for scenarios where the iOS device has access to a network (like enterprise VPN via 飞连) that the Windows machine cannot directly access.

### Key Features
- HTTP CONNECT proxy server on configurable port (default 10808)
- Real-time TX/RX byte counting
- Connection count tracking
- Local IP address display
- Keep device awake while proxy is running
- Log display with connection status

## Architecture

### Core Components

#### 1. ProxyServer.swift
- **Purpose**: HTTP CONNECT proxy server using NWListener
- **Key Properties**:
  - `port: UInt16` - listening port (default 10808)
  - `listener: NWListener?` - the TCP listener
  - `activeTunnels: [String: TunnelManager]` - dictionary of active tunnels, keyed by `"\(host):\(port):\(ObjectIdentifier(clientConnection))"`
  - `tunnelsLock: NSLock` - thread-safe access to tunnels dictionary
  - `localIP: String` - iOS device's WiFi IP address
  - `onLocalIPReady: ((String) -> Void)?` - callback when IP is determined
- **Key Methods**:
  - `start()` - starts NWListener on specified port
  - `stop()` - cancels listener
  - `handleNewConnection(_:)` - handles incoming proxy connections
  - `receiveHTTPRequest(_:)` - receives data, checks for tunnel or parses HTTP
  - `processRequest(_:connection:)` - parses HTTP CONNECT request
  - `establishTunnel(host:port:clientConnection:)` - creates TunnelManager for CONNECT
  - `sendSuccessResponse(_:)` - sends "HTTP/1.1 200 Connection Established"
  - `sendErrorResponse(_:code:)` - sends HTTP error response
  - `findTunnelKey(for:)` - finds tunnel by client connection reference
  - `forwardToTunnel(connection:data:)` - forwards binary data to existing tunnel
  - `getLocalIPAddress()` - queries WiFi interface IP via getifaddrs()

#### 2. TunnelManager.swift
- **Purpose**: Manages bidirectional data forwarding between client and target server
- **Key Properties**:
  - `host: String` - target server host
  - `port: Int` - target server port
  - `logStore: LogStore` - for logging and byte counting
  - `serverConnection: NWConnection?` - connection to target server
  - `clientConnection: NWConnection?` - connection to proxy client
  - `queue: DispatchQueue` - serial queue for connection operations
  - `onConnected`, `onClose`, `onError` - callbacks
  - `clientConnectionRef: NWConnection?` - exposes client connection for tunnel lookup
- **Key Methods**:
  - `start(clientConnection:)` - initiates connection to target server
  - `startForwarding()` - sets up bidirectional receive handlers
  - `forwardToServer(client:server:)` - recursive client→server forwarder
  - `forwardToClient(client:server:)` - recursive server→client forwarder
  - `receiveClientData(_:)` - handles data forwarded from ProxyServer (binary HTTPS data)
  - `close()` - cancels both connections
- **Byte Counting**: Every data forward calls `logStore.addTxBytes()` or `logStore.addRxBytes()` via `Task { @MainActor in }`

#### 3. LogStore.swift
- **Purpose**: Central state management for logs and statistics
- **Annotations**: `@Observable`, `@MainActor` (thread-safe)
- **Key Properties**:
  - `entries: [LogEntry]` - limited to 100 entries
  - `activeConnections: Int` - current connection count
  - `totalTxBytes: Int64` - total bytes sent to server
  - `totalRxBytes: Int64` - total bytes received from server
- **Key Methods**:
  - `log(host:port:status:)` - adds new log entry
  - `addTxBytes(_:)`, `addRxBytes(_:)` - updates byte counters
  - `incrementConnections()`, `decrementConnections()` - connection lifecycle
  - `clear()` - resets all state

#### 4. LogEntry.swift
- **Purpose**: Single log entry data model
- **Properties**: `id`, `timestamp`, `host`, `port`, `status: LogStatus`
- **LogStatus enum**: `connect`, `connected`, `closed`, `error`
- **Display**: `HH:mm:ss  host:port  status` format

#### 5. ContentView.swift
- **Purpose**: Main SwiftUI UI
- **State Variables**:
  - `isRunning: Bool` - proxy running state
  - `logStore: LogStore` - shared log store
  - `proxyServer: ProxyServer?` - current proxy instance
  - `connectionCount: Int` - derived from logStore.activeConnections
  - `txBytes: Int64`, `rxBytes: Int64` - derived from logStore totals
  - `localIP: String` - updated via onLocalIPReady callback
  - `portString: String` - editable port setting
- **UI Layout** (two columns):
  - Left: Status (colored green/red), IP, Port (editable)
  - Right: TX, RX (byte formatted), Conn count
- **Features**:
  - Toggle to start/stop proxy
  - Port field (disabled while running)
  - Idle timer disabled while proxy running (`UIApplication.shared.isIdleTimerDisabled`)
  - Logs display with ScrollView + LazyVStack (avoid ForEach crash)
  - Clear logs button (disabled while running)

### Data Flow

1. **HTTP CONNECT Phase**:
   ```
   Windows → ProxyServer → TunnelManager → Target Server
   Windows ← ProxyServer ← TunnelManager ← Target Server
   ```

2. **Binary HTTPS Data Phase** (after CONNECT established):
   ```
   Windows → ProxyServer.receiveHTTPRequest() → findTunnelKey() → forwardToTunnel()
   Windows → TunnelManager.receiveClientData() → server.send()
   Windows ← ProxyServer ← TunnelManager ← server.receive() ← Target Server
   ```

3. **Tunnel Key Format**: `"\(host):\(port):\(ObjectIdentifier(clientConnection as AnyObject))"`
   - Unique per connection because ObjectIdentifier is unique per object instance

### Critical Implementation Details

1. **NWListener**: Uses `NWParameters.tcp` with `allowLocalEndpointReuse = true`

2. **Receive Strategy**:
   - Client receive: `minimumIncompleteLength: 0, maximumLength: 65536`
   - Server receive: `minimumIncompleteLength: 1, maximumLength: 65536`
   - Changed from default to handle partial data immediately

3. **Thread Safety**:
   - `LogStore` is `@MainActor` for SwiftUI thread safety
   - `ProxyServer` uses `NSLock` for tunnel dictionary access
   - `TunnelManager` uses `Task { @MainActor in }` for LogStore updates

4. **SwiftUI Crash Prevention** (ForEach crash):
   - Use `ScrollView + LazyVStack` instead of `List`
   - LogStore uses private setters
   - Limited to 100 log entries

5. **IP Address Detection**: Uses `getifaddrs()` to query `en0` or `en1` interface for IPv4 address

6. **Keep Awake**: `UIApplication.shared.isIdleTimerDisabled = true` when running

## Common Issues Fixed

1. **ForEach Crash**: SwiftUI ForEach crash with Identifiable - fixed by using ScrollView+LazyVStack and proper Equatable

2. **Binary HTTPS Data Not Forwarded**: Original code only processed UTF-8 strings, binary data was ignored - fixed by adding tunnel lookup for existing tunnels and `receiveClientData()` method

3. **Connection Stalling**: `minimumIncompleteLength: 1` blocked partial receives - changed to `0`

4. **Thread Safety**: Dictionary access from multiple callbacks - added NSLock

5. **Tunnel Identification**: Multiple tunnels to same host:port needed unique keys - added ObjectIdentifier

## Build & Run

```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Testing

1. Configure Windows proxy: IP of iOS device, port 10808
2. Set up HTTP CONNECT tunnel in browser or system proxy
3. Check logs for connection status
4. Monitor TX/RX bytes incrementing

## File Structure

```
HttpRelay/
├── HttpRelayApp.swift       # @main entry point
├── ContentView.swift       # Main UI (SwiftUI)
├── ProxyServer.swift        # HTTP CONNECT proxy server (Network framework)
├── TunnelManager.swift      # Connection bridging
├── LogStore.swift           # State management (@Observable)
├── LogEntry.swift           # Data model
├── Info.plist
└── ...test files
```