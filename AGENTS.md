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
- **Annotations**: `ObservableObject` with `@Published` properties, `@MainActor` (thread-safe). NOTE: deployment target is iOS 16.0 — do NOT use `@Observable`/Observation framework or the two-parameter `onChange(of:initial:_:)` (both iOS 17+)
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
  - `topBlockHeight`, `bottomBlockHeight: BlockHeight` - measured heights of the blocks above/below
    the log console, tagged with the layout they were measured in
- **Adaptive layout** (see `ContentLayout.swift`):
  - `GeometryReader` reports the size of the content area (the window minus the bars around it);
    `ContentLayout.isWide(windowWidth:)` picks the layout
  - Narrow (< 728pt): one column - toggle card, status card, filter bar, log console, requests footer
  - Wide (>= 728pt): sidebar (toggle, stacked status, requests) + log console column
  - The log console height is `ContentLayout.logHeight(windowHeight:reservedHeight:)`: it takes
    whatever the other blocks leave over, never less than `minLogHeight` (200pt)
  - The whole page is a `ScrollView`, so a window that is too short scrolls instead of clipping.
    The log console keeps its own scroll view, so the rows stay reachable in any window
  - The height of the blocks around the console is measured with a `PreferenceKey`. The
    measurement carries the layout it was taken in, so it cannot leak from one layout into the other
- **Features**:
  - Toggle to start/stop proxy
  - Port field (disabled while running)
  - Idle timer disabled while proxy running (`UIApplication.shared.isIdleTimerDisabled`)
  - Logs display with ScrollView + LazyVStack (avoid ForEach crash)
  - Clear logs button (disabled while running)

#### 6. ContentLayout.swift
- **Purpose**: The rules that decide how the main screen is arranged
- **Key Properties**: `wideLayoutMinWidth`, `sidebarWidth`, `minLogColumnWidth`, `minLogHeight`,
  `blockSpacing`, `layoutPadding`
- **Key Methods**: `isWide(windowWidth:)`, `logHeight(windowHeight:reservedHeight:)`
- Only ever looks at the space that is available - never at the device, its idiom or its
  orientation, because the iPhone Duo can be folded, unfolded and rotated while the app runs

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

6. **iPhone Duo / resizable windows**: The main screen used to assume a fixed phone layout
   (a 350pt log list, no scrolling). On the unfolded Duo, an iPad or a landscape phone that
   left the log console squeezed or clipped off screen - fixed by `ContentLayout.swift`, which
   derives the layout from the available window size only

## Build & Run

```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Testing

Automated:

```bash
xcodebuild test -project HttpRelay.xcodeproj -scheme HttpRelay \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

- `HttpRelayTests/` - the proxy protocol: HTTP CONNECT, SOCKS5, UDP associate
- `HttpRelayTests/DuoLayoutTests.swift` - the main screen at the sizes the iPhone Duo and an
  iPhone can take. It renders the screen in a window backed by a window scene, because without a
  scene the layout never settles and the measurement the test checks never happens

Manual:

1. Configure Windows proxy: IP of iOS device, port 10808
2. Set up HTTP CONNECT tunnel in browser or system proxy
3. Check logs for connection status
4. Monitor TX/RX bytes incrementing

## File Structure

```
HttpRelay/
├── HttpRelayApp.swift       # @main entry point
├── ContentView.swift       # Main UI (SwiftUI)
├── ContentLayout.swift      # Rules for the adaptive main screen layout
├── ProxyServer.swift        # HTTP CONNECT proxy server (Network framework)
├── TunnelManager.swift      # Connection bridging
├── LogStore.swift           # State management (ObservableObject + @Published)
├── LogEntry.swift           # Data model
├── Info.plist
└── ...test files
```
