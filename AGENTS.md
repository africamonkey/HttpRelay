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
  - `lifecycleLock: NSLock` - guards `listener`, `wantsToRun` and `runID`, because `start(runID:)` runs on a background queue and can race with `stop()`
  - `wantsToRun: Bool` - false once `stop()` was called, so a listener that is still being created gets cancelled instead of left running
  - `runID: UInt64` - bumped by every `stop()`; a start attempt carries the id it was given, so a start that arrives after the server was stopped is ignored
  - `localIP: String` - iOS device's WiFi IP address
  - `failureMessage: String?` - set when the listener could not be brought up (e.g. the port is taken)
  - `onLocalIPReady: ((String) -> Void)?` - callback when IP is determined
- **Key Methods**:
  - `beginRun()` - registers the intent to run and returns the id of this run. Call it on the thread that owns the server, **before** dispatching `start(runID:)` to a background queue
  - `start(runID:)` - creates and starts the NWListener on the **calling thread** (must not be the main thread - see below); the state handler runs on the main queue
  - `start()` - `beginRun()` + `start(runID:)` in one go, for callers that are already off the main thread (the tests)
  - `stop()` - cancels the listener and invalidates every pending start. Main-actor isolated, because it publishes `isRunning`
  - `publishLocalIP(for:)` - looks the LAN address up off the main thread and publishes it on the main actor
  - `reportFailure(_:for:)` - reports that the listener could not be brought up
  - `handleNewConnection(_:)` - handles incoming proxy connections
  - `receiveHTTPRequest(_:)` - receives data, checks for tunnel or parses HTTP
  - `processRequest(_:connection:)` - parses HTTP CONNECT request
  - `handleHTTPProxyRequest(method:methodStr:requestTarget:request:connection:leftover:)` - handles a plain HTTP proxy request (absolute form)
  - `establishTunnel(host:port:clientConnection:)` - creates TunnelManager for CONNECT
  - `sendSuccessResponse(_:)` - sends "HTTP/1.1 200 Connection Established"
  - `sendErrorResponse(_:code:)` - sends HTTP error response
  - `findTunnelKey(for:)` - finds tunnel by client connection reference
  - `forwardToTunnel(connection:data:)` - forwards binary data to existing tunnel
  - `getLocalIPAddress()` - queries WiFi interface IP via getifaddrs()
- **The two request forms**:
  - A CONNECT request carries the authority `host:port` as its request-target, a plain
    HTTP request carries the absolute form `scheme://host[:port]/path?query`. Only the
    latter has a path, and only the latter may leave the port out - it is then the
    default port of the scheme (RFC 9110 §4.2.3)
  - A plain HTTP request is forwarded with the path percent-encoded, with the Host
    header of the target (RFC 9112 §3.2.2) and without the hop-by-hop headers
    (RFC 9110 §7.6.1); `HTTPTarget` does the parsing
  - Only the `http` scheme is served. The proxy forwards plain HTTP; a client that wants
    TLS opens a tunnel with CONNECT
  - A tunnel that failed before it was up is answered with "502 Bad Gateway". A tunnel
    that was already up is not answered: the client speaks another protocol on it then,
    and a status line would only corrupt the stream
  - The body of a request is not part of the header block, so the request buffer keeps
    the bytes that came with it and hands them on separately - a body that arrives in
    the same segment as the headers used to be dropped

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
- **The state of the tunnel** (`stateLock`): the tunnel's queue and the main queue both
  touch it, so it is behind a lock
  - `hasConnected` - the connection to the target was established
  - `hasReceivedResponse` - the target answered; set before the bytes are handed to the
    client, so a failure that is reported afterwards cannot put a status line in front
    of the response
  - `hasFailed` - the tunnel was given up on. A connection can go to `.waiting` and come
    up anyway, and a late `.ready` must not write a second status line into the client's
    stream
  - `answerWhenTunnelBreaks` / `answerWhenTargetBreaks` - turn that state into the answer
    the client gets: a status line, or the end of the connection only

#### 3. HTTPTarget.swift
- **Purpose**: The target of a plain HTTP proxy request
- **Key Properties**: `host: String`, `port: Int`, `path: String` (percent-encoded), `query: String?` (percent-encoded)
- **Key Methods**:
  - `init?(requestTarget:)` - parses a request target in the absolute form. Returns `nil`
    for a target that is not a URL with a host and the `http` scheme, or whose port is
    not a port a connection can be made to
  - `hostHeaderValue: String` - the authority of the target, with the port only when it
    is not the default port of the scheme (RFC 9110 §7.2)
- The path and the query stay percent-encoded: `URL.path` decodes them, and a request
  that goes on the wire with a decoded path is not the request the client asked for

#### 4. LogStore.swift
- **Purpose**: Central state management for logs and statistics
- **Annotations**: `ObservableObject` with `@Published` properties, `@MainActor` (thread-safe). NOTE: deployment target is iOS 16.0 — do NOT use `@Observable`/Observation framework or the two-parameter `onChange(of:initial:_:)` (both iOS 17+)
- **Key Properties**:
  - `entries: [LogEntry]` - limited to 500 entries
  - `activeConnections: Int` - current connection count
  - `totalTxBytes: Int64` - total bytes sent to server
  - `totalRxBytes: Int64` - total bytes received from server
  - `filteredEntries: [LogEntry]` - cached, recomputed when a filter input changes
- **Key Methods**:
  - `log(host:port:path:query:method:requestHeaders:)` - adds new log entry
  - `addTxBytes(_:)`, `addRxBytes(_:)` - updates byte counters (flushed once per frame)
  - `incrementConnections()`, `decrementConnections()` - connection lifecycle
  - `clear()` - resets all state

#### 5. LogEntry.swift
- **Purpose**: Single log entry data model
- **Properties**: `id`, `timestamp`, `host`, `port`, `path`, `query`, `method`, `status: EntryStatus`
- **EntryStatus enum**: `inProgress`, `completed`, `failed`
- **Display**: the row shows `HH:mm:ss.SSS`, the method, the host and the path
- **A CONNECT entry has no path**: the request-target of a CONNECT request is the
  authority `host:port` (RFC 9110 §7.2), so the path stays empty. `fullURL` is then
  the authority alone, and the row shows the port (`:443`) below the host. Storing
  the request-target as the path would print the authority twice.

#### 6. ContentView.swift
- **Purpose**: Main SwiftUI UI
- **State Variables**:
  - `isRunning: Bool` - proxy running state
  - `logStore: LogStore` - shared log store
  - `proxyServerHolder: ProxyServerHolder` - holds the current proxy instance and republishes its changes, so the `onChange` handlers fire when the server reports something
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
- **Starting the proxy (see "The toggle must not block the main thread" below)**:
  - The toggle flips the UI immediately and starts the server on a background queue
  - The setup guide is presented from the `onChange` of `proxyServerHolder.server?.isRunning`,
    i.e. once the server is actually up - never from inside the tap handler
  - A failure to bring the listener up is shown as an alert: through
    `proxyServerHolder.server?.failureMessage` when the listener failed, and through the
    `catch` in `toggleProxy` when it could not be created at all
  - Every way out of "running" goes through `resetRunningState()`, so a failed start
    does not leave the uptime timer running or the device awake
  - `ProxyServerHolder` republishes the server's changes. Reading
    `holder.server?.isRunning` in a body only subscribes the view to the holder, so
    without the forwarding the `onChange` handlers would not fire reliably

#### 7. ContentLayout.swift
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
   - `ProxyServer` uses `NSLock` for the tunnel dictionary and another for the listener lifecycle
   - `SOCKS5Server` uses `NSLock` for `localIP` and `udpRelay`, which are written on the
     main thread and read on the connection's queue
   - `TunnelManager` uses `Task { @MainActor in }` for LogStore updates

4. **SwiftUI Crash Prevention** (ForEach crash):
   - Use `ScrollView + LazyVStack` instead of `List`
   - LogStore uses private setters
   - Limited to 500 log entries

5. **IP Address Detection**: Uses `getifaddrs()` to query the bridge interface (hotspot)
   first, then `en0` (WiFi), then `en1`

6. **Keep Awake**: `UIApplication.shared.isIdleTimerDisabled = true` when running

7. **The toggle must not block the main thread**: The first tap of "Enable Debugger Server"
   used to freeze the UI for ~490 ms. The measurements and the fix are documented in
   `docs/superpowers/specs/2026-10-24-first-tap-freeze-fix.md`. In short:
   - `NWListener` creation on the main thread: 17-49 ms (the first listener of a process
     initialises the Network framework)
   - `getifaddrs()`/`getnameinfo()` on the listener's main queue: 2-7 ms
   - `isIdleTimerDisabled = true`: 26 ms the first time, 0.3 ms afterwards
   - SwiftUI's first layout of the "running" state: 22-82 ms
   - The setup guide sheet's first render: 160-380 ms
   The fixes:
   - `ProxyServer.start(runID:)` runs on a background queue; the UI reacts at once
   - `publishLocalIP(for:)` does the interface lookup off the main thread
   - `HttpRelayApp.init()` warms up the Network framework and the idle timer at launch
   - The setup guide is presented from the `onChange` of `server?.isRunning`, so it is
     built after the server is up instead of during the tap
   - The setup guide no longer uses a paged `TabView`, which roughly halved its first render
   Result: the tap itself went from ~55 ms to ~6 ms, and the first-tap freeze from
   ~490 ms to ~40 ms (the guide still takes ~150 ms to appear, after the server is up)

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

7. **First-tap freeze**: The "Enable Debugger Server" toggle blocked the main thread for
   ~490 ms on its first tap - the listener was created on the main thread, the interface
   lookup ran on the listener's main queue, and the setup guide sheet was built during the
   tap. Fixed by moving the listener creation and the IP lookup off the main thread,
   warming the Network framework at launch, and presenting the guide once the server is up

8. **The two request forms**: A CONNECT request has no path - its request-target is the
   authority - and a plain HTTP request may leave the port out. The proxy used to store
   the request-target of a CONNECT request as the path (so the request details printed
   the authority twice) and to refuse a plain HTTP request without a port with
   "400 Bad Request". Fixed by `HTTPTarget` and by an empty path for CONNECT entries;
   documented in `docs/superpowers/specs/2026-10-25-the-two-request-forms.md`

9. **A request that the proxy mangled or dropped**: The forwarded request used the
   decoded path (`/a%20b` became `/a b`), the `Host` header was copied from the client
   instead of being replaced with the authority of the target, the hop-by-hop headers
   were forwarded to the origin server, and a body that arrived in the same segment as
   the header block was dropped while its `Content-Length` was forwarded

10. **A broken tunnel answered the client twice**: A tunnel that broke after it was up
    still got a "502 Bad Gateway" written into the client's stream, which corrupts the
    TLS stream of a CONNECT. A tunnel that was never up gets the status line, a tunnel
    that was up only gets the end of the connection

11. **A port that crashed the app**: `CONNECT example.com:70000` turned the port into an
    `NWEndpoint.Port` with `UInt16(port)!` and crashed the proxy. Both request forms
    check the port now

12. **A failed tunnel in the log**: `LogStore.completeEntry` overwrote a `failed` entry
    with `completed`, so a tunnel that had broken was logged as a success

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

- `HttpRelayTests/` - the proxy protocol: HTTP CONNECT, plain HTTP proxying, SOCKS5, UDP
  associate, plus the lifecycle of the server (a start that was cancelled must not come up,
  a stale start must not take over a newer run, a taken port must be reported)
- `HttpRelayTests/HTTPRegressionTests.swift` - the two request forms end to end: a CONNECT
  without a path in the log, a plain HTTP request without a port in the target, the
  forwarded request with its path and its `Host` header, the body of a request, the
  hop-by-hop headers, a tunnel that breaks, a failed tunnel in the log, and a port that no
  connection can be made to
- `HttpRelayTests/HTTPTargetTests.swift` - the parsing of a request target in the
  absolute form
- `HttpRelayTests/TunnelFailureTests.swift` - the answer a client gets when its tunnel
  breaks
- `HttpRelayTests/DuoLayoutTests.swift` - the main screen at the sizes the iPhone Duo and an
  iPhone can take. It renders the screen in a window backed by a window scene, because without a
  scene the layout never settles and the measurement the test checks never happens
- `HttpRelayUITests/HttpRelayUITests.swift` - `testToggleStartsAProxyThatAnswers` taps the
  toggle, waits for the screen to publish the device's IP address (which only happens once
  the listener is up) and then sends a real HTTP CONNECT request to the port from the port
  field. It checks for `502 Bad Gateway`, the answer only this app gives for a CONNECT to a
  closed port, so another proxy listening on the same port cannot make it pass.

Manual:

1. Configure Windows proxy: IP of iOS device, port 10808
2. Set up HTTP CONNECT tunnel in browser or system proxy
3. Check logs for connection status
4. Monitor TX/RX bytes incrementing

## File Structure

```
HttpRelay/
├── HttpRelayApp.swift       # @main entry point, warms up the Network framework
├── ContentView.swift        # Main UI (SwiftUI)
├── ContentLayout.swift      # Rules for the adaptive main screen layout
├── ProxyServer.swift        # HTTP CONNECT proxy server (Network framework)
├── HTTPTarget.swift         # The target of a plain HTTP proxy request
├── TunnelManager.swift      # Connection bridging
├── SOCKS5.swift             # SOCKS5 server and UDP relay
├── LogStore.swift           # State management (ObservableObject + @Published)
├── LogEntry.swift           # Data model
├── TutorialView.swift       # The setup guide that is shown when the server starts
├── SettingsView.swift       # Settings sheet
├── AboutView.swift          # About sheet
├── BackgroundKeepaliveCoordinator.swift  # Keeps the proxy alive in the background
└── Assets.xcassets          # Icons and the screenshots of the setup guide

HttpRelayTests/              # Unit tests (swift-testing)
HttpRelayUITests/            # UI tests (XCTest)
docs/superpowers/specs/      # Design documents, one per change
```
