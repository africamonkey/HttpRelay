# HTTP Debugger Log Enhancement Design

## Overview

Enhance the HTTP Debugger log functionality to provide a complete HTTP traffic inspection experience, similar to Charles/Proxyman, to convince Apple reviewers this is a legitimate developer debugging tool.

## Data Model

### LogEntry Enhancement

```swift
struct LogEntry: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let host: String
    let port: Int
    let path: String
    let query: String?
    let method: HTTPMethod
    let requestHeaders: [String: String]
    var responseStatusCode: Int?
    var responseHeaders: [String: String]?
    var txBytes: Int64
    var rxBytes: Int64
    var duration: TimeInterval?
    let status: LogStatus

    enum LogStatus: String, Equatable {
        case request = "REQUEST"
        case response = "RESPONSE"
        case completed = "COMPLETED"
        case failed = "FAILED"
    }
}

enum HTTPMethod: String, Equatable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
    case head = "HEAD"
    case options = "OPTIONS"
    case connect = "CONNECT"
    case unknown = "UNKNOWN"
}
```

### LogStore Enhancement

```swift
@Observable
@MainActor
final class LogStore {
    private(set) var entries: [LogEntry] = []
    private(set) var activeConnections: Int = 0
    private(set) var totalTxBytes: Int64 = 0
    private(set) var totalRxBytes: Int64 = 0

    // Filter support
    var searchText: String = ""
    var selectedMethods: Set<HTTPMethod> = []
    var selectedStatusFilters: Set<String> = [] // "2xx", "3xx", "4xx", "5xx"

    var filteredEntries: [LogEntry] { /* filtered by searchText, selectedMethods, selectedStatusFilters */ }
}
```

## UI Design

### 1. Main Log List View

**Layout:**
- Filter bar at top with search field and filter chips
- Scrollable list of log entries
- Each entry shows: timestamp, method badge, status code, host:port/path, bytes, duration

**Entry Row Design:**
```
[HH:mm:ss.SSS] [GET] [200] api.example.com:443/users?id=1  1.2KB  45ms
```

**Method Badge Colors:**
- GET: Blue (#007AFF)
- POST: Green (#34C759)
- PUT: Orange (#FF9500)
- DELETE: Red (#FF3B30)
- CONNECT: Purple (#AF52DE)
- Others: Gray (#8E8E93)

**Status Code Colors:**
- 2xx: Green
- 3xx: Blue
- 4xx: Orange
- 5xx: Red

### 2. Detail View (Sheet)

```
┌─────────────────────────────────────┐
│ GET                                  │
│ https://api.example.com/users?id=1   │
│ 200 OK        45ms        1.2KB     │
├─────────────────────────────────────┤
│ REQUEST                              │
│ ─────────────────────────────────────│
│ Host: api.example.com                │
│ Content-Type: application/json       │
│ Accept: */*                         │
│ Authorization: Bearer xxx            │
├─────────────────────────────────────┤
│ RESPONSE                             │
│ ─────────────────────────────────────│
│ HTTP/1.1 200 OK                     │
│ Content-Type: application/json      │
│ Content-Length: 1024                │
│ Cache-Control: no-cache              │
└─────────────────────────────────────┘
```

### 3. Filter Bar

```
[🔍 Search host/path...] [GET] [POST] [PUT] [2xx] [3xx] [4xx] [5xx] [✕ Clear]
```

## Technical Implementation

### ProxyServer Changes

1. `processRequest()` - Parse full URL including path and query string
2. Extract HTTP method from request line
3. Pass request headers to `establishTunnel()`
4. Log REQUEST status when CONNECT headers received

### TunnelManager Changes

1. Store requestHeaders received from client
2. Parse HTTP response line to extract status code and response headers
3. Calculate duration from tunnel start to first response data
4. Update LogEntry with responseStatusCode, responseHeaders, duration
5. Log RESPONSE/COMPLETED status appropriately

### LogStore Changes

1. Add filteredEntries computed property
2. Add filter methods
3. Support clearing filters

### ContentView Changes

1. Replace simple log list with enhanced log list
2. Add filter bar
3. Add detail sheet on entry tap
4. Show connection count from filtered view

## File Changes

1. `LogEntry.swift` - Enhanced data model
2. `LogStore.swift` - Add filtering support
3. `ProxyServer.swift` - Parse URL, headers, log REQUEST
4. `TunnelManager.swift` - Track response, duration, update log
5. `ContentView.swift` - New UI with filter bar and detail view

## Implementation Priority

1. LogEntry + LogStore enhancement (data layer)
2. ProxyServer parsing enhancement
3. TunnelManager response tracking
4. ContentView UI update
