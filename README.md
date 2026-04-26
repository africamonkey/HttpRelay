# HttpRelay

HttpRelay is an iOS app that acts as an HTTP CONNECT proxy server. It allows a Windows/Mac machine to route HTTP/HTTPS traffic through the iOS device, which is useful when the iOS device has access to a network (such as an enterprise VPN) that the computer cannot directly access.

## Features

- **HTTP CONNECT Proxy Server** - Runs on a configurable port (default: 10808)
- **Real-time Statistics** - TX/RX byte counting and connection tracking
- **Local IP Display** - Shows the iOS device's WiFi IP address
- **Keep Awake** - Device stays awake while proxy is running
- **Setup Guides** - Built-in tutorial for Mac and Windows proxy configuration
- **Settings** - Configurable tutorial auto-show on startup

## Requirements

- iOS 17.0+
- Xcode 15.0+

## Building

```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Usage

### Starting the Proxy

1. Open HttpRelay on your iOS device
2. Toggle "Enable Proxy Server" to start
3. Grant network permissions if prompted
4. The server IP and port will be displayed

### Configuring Your Computer

#### Mac

1. Open System Settings → Network
2. Select your network interface (Ethernet or Wi-Fi)
3. Click "Details" button
4. Select "Proxies" in the sidebar
5. Scroll down to "HTTP Proxy" and "HTTPS Proxy"
6. Enter the iOS device IP address and port (default: 10808)
7. Click "OK" to apply

#### Windows

1. Press Win + I to open Settings
2. Go to Network & Internet → Proxy
3. Under "Manual proxy setup", toggle "ON"
4. Enter the server IP address and port (default: 10808)
5. Settings are applied automatically

### Viewing Statistics

- **TX** - Total bytes sent to server
- **RX** - Total bytes received from server
- **Uptime** - Time since proxy started
- **Logs** - Real-time connection status

## Architecture

### Core Components

| File | Description |
|------|-------------|
| `ProxyServer.swift` | HTTP CONNECT proxy server using NWListener |
| `TunnelManager.swift` | Manages bidirectional data forwarding |
| `LogStore.swift` | Central state management (@Observable) |
| `LogEntry.swift` | Log entry data model |
| `ContentView.swift` | Main SwiftUI interface |
| `TutorialView.swift` | Setup guide with screenshots |
| `SettingsView.swift` | App settings |
| `AboutView.swift` | App information |

### Data Flow

```
Computer → ProxyServer → TunnelManager → Target Server
Computer ← ProxyServer ← TunnelManager ← Target Server
```

## Project Structure

```
HttpRelay/
├── HttpRelayApp.swift      # @main entry point
├── ContentView.swift       # Main UI
├── ProxyServer.swift       # HTTP CONNECT proxy
├── TunnelManager.swift     # Connection bridging
├── LogStore.swift          # State management
├── LogEntry.swift          # Data model
├── TutorialView.swift      # Setup guide
├── SettingsView.swift      # Settings
├── AboutView.swift         # About
└── Assets.xcassets/        # Images and icons
```

## License

MIT License
