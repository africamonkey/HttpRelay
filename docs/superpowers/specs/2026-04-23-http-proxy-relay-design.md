# HttpRelay - iOS HTTP Proxy Relay App

## 1. Concept & Vision

HttpRelay turns an iOS device into a lightweight HTTP CONNECT proxy relay. Windows PCs connect via system-level HTTP proxy to the iOS app, which tunnels traffic through the device's existing VPN connection (飞连). The app is minimal, functional, and displays real-time activity logs.

**Target user:** Individual needing to route Windows traffic through a VPN-enabled iOS device for temporary/occasional use.

## 2. Design Language

- **Framework:** SwiftUI + Network.framework (NWListener/NWConnection)
- **Dependencies:** None (pure Apple frameworks)
- **UI Style:** Native SwiftUI, dark-mode friendly

## 3. Architecture

```
┌─────────────────────────────────────────────────────┐
│                    iOS Device                        │
│  ┌─────────────┐      ┌─────────────────────────┐  │
│  │ ProxyServer │◄────►│    TunnelManager         │  │
│  │ (NWListener) │      │  - establish tunnels    │  │
│  │  port 10808 │      │  - manage connections    │  │
│  └──────┬──────┘      └───────────┬──────────────┘  │
│         │                         │                 │
│         │         ┌───────────────┘                 │
│         │         │                                 │
│         ▼         ▼                                 │
│  ┌─────────────────────────────────────────────┐    │
│  │           URLSession (system network)        │    │
│  │         (automatically routes via VPN)       │    │
│  └─────────────────────┬───────────────────────┘    │
│                        │                             │
└────────────────────────┼─────────────────────────────┘
                         │ VPN (飞连)
                         ▼
                    [Internet]
```

## 4. Components

### 4.1 ProxyServer
- Uses `NWListener` on port `10808`
- Accepts HTTP CONNECT method only
- Parses `CONNECT <host>:<port> HTTP/1.1`
- Responds `HTTP/1.1 200 Connection Established`
- Handles multiple simultaneous connections

### 4.2 TunnelManager
- Creates `NWConnection` to target host:port from CONNECT request
- Bridges data between client connection and target connection
- Tracks active tunnel count
- Emits log events for each state change

### 4.3 LogEntry
- Timestamp (HH:mm:ss)
- Host and port
- Status (CONNECT / 200 OK / CLOSED / ERROR)

### 4.4 Data Flow
1. Windows sends `CONNECT target.com:443 HTTP/1.1`
2. ProxyServer parses and extracts target
3. TunnelManager creates URLSession connection to target
4. ProxyServer returns `200 Connection Established`
5. Bidirectional data forwarding until disconnect
6. LogEntry created for connect/success/close events

## 5. UI Layout

```
┌─────────────────────────────┐
│  HttpRelay           [开关] │
├─────────────────────────────┤
│  状态: 运行中 / 已停止       │
│  端口: 10808                │
│  连接数: 3                  │
├─────────────────────────────┤
│  日志                       │
│  ─────────────────────────  │
│  10:23:45  a.com:443  CONNECT
│  10:23:46  a.com:443  200 OK │
│  10:23:47  b.com:80   CONNECT
│  ...                        │
└─────────────────────────────┘
```

## 6. Technical Notes

- **Background handling:** App should maintain connection when backgrounded (limited by iOS)
- **Port:** 10808 (high port, non-privileged)
- **No authentication:** Anonymous access
- **Protocol:** HTTP CONNECT only (HTTPS tunneling)

## 7. File Structure

```
HttpRelay/
├── HttpRelayApp.swift
├── ContentView.swift
├── ProxyServer.swift       # NWListener + HTTP CONNECT handling
├── TunnelManager.swift     # Connection bridging
├── LogEntry.swift          # Log data model
└── LogStore.swift          # Observable log storage
```
