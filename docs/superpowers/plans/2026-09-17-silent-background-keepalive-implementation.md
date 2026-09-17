# Silent Background Keepalive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep HttpRelay's NWListener alive for 30 seconds after the user backgrounds the app (e.g. briefly switching to WeChat), using Apple's official `UIApplication.beginBackgroundTask` API. After 30 seconds, the system kills the app and the proxy stops cleanly so the UI reflects "Stopped".

**Architecture:** A `@MainActor` singleton `BackgroundKeepaliveCoordinator` listens for SwiftUI's `scenePhase` transitions via `@Environment(\.scenePhase)` in `HttpRelayApp`. When the scene goes to background, it calls `UIApplication.shared.beginBackgroundTask` to claim 30 seconds of background time. When the scene returns to foreground, it releases the task. If iOS fires the expiration handler before the user returns, the coordinator calls `ProxyServer.shared?.stop()`, which (via SwiftUI observation) causes ContentView to flip back to "Stopped".

**Tech Stack:** SwiftUI (`@Environment(\.scenePhase)`, `@Observable`), UIKit (`UIApplication.beginBackgroundTask`), existing Network framework / ProxyServer.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `HttpRelay/BackgroundKeepaliveCoordinator.swift` | **NEW** | `@MainActor` singleton wrapping `beginBackgroundTask` / `endBackgroundTask`; reacts to scene phase; calls `ProxyServer.shared?.stop()` on expiration |
| `HttpRelay/ProxyServer.swift` | Modify | Add `@Observable` annotation; add `private(set) var isRunning: Bool = false` (set in `start()` / `stop()`); add `static var shared: ProxyServer?` |
| `HttpRelay/HttpRelayApp.swift` | Modify | Add `@Environment(\.scenePhase)` and `.onChange` that delegates to the coordinator |
| `HttpRelay/ContentView.swift` | Modify | Set `ProxyServer.shared = proxyServer` when toggling on, `nil` when toggling off; add `.onChange(of: proxyServer?.isRunning)` so `isRunning` state syncs from observed ProxyServer back to the local `@State` |

**Not touched:** `SettingsView.swift`, `LogStore.swift`, `LogEntry.swift`, `TunnelManager.swift`, `SOCKS5.swift`, `TutorialView.swift`, `AboutView.swift`, `Info.plist`.

---

## Task 1: Add BackgroundKeepaliveCoordinator singleton

**Files:**
- Create: `HttpRelay/BackgroundKeepaliveCoordinator.swift`

- [ ] **Step 1: Create the file with the exact content**

Create `HttpRelay/BackgroundKeepaliveCoordinator.swift` with this exact content:

```swift
import Foundation
import UIKit

@MainActor
final class BackgroundKeepaliveCoordinator {
    static let shared = BackgroundKeepaliveCoordinator()

    private var taskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func start() {
        guard ProxyServer.shared?.isRunning == true else { return }
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "HttpRelay.Keepalive") { [weak self] in
            self?.expire()
        }
    }

    func stop() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }

    private func expire() {
        stop()
        ProxyServer.shared?.stop()
    }
}
```

- [ ] **Step 2: Build to verify the file compiles**

Run from the project root:
```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `BUILD SUCCEEDED`. The new file is auto-discovered by Xcode's `PBXFileSystemSynchronizedRootGroup` — no `project.pbxproj` edit needed. (Confirmed in earlier work: this project uses `PBXFileSystemSynchronizedRootGroup` for auto-discovery.)

If you see "Cannot find type 'ProxyServer' in scope", the file was not auto-discovered — verify with `ls HttpRelay/` and check Xcode's File System Synchronized Groups section. Do not edit `project.pbxproj` manually.

- [ ] **Step 3: Commit**

```bash
git add HttpRelay/BackgroundKeepaliveCoordinator.swift
git commit -m "feat: add BackgroundKeepaliveCoordinator singleton"
```

---

## Task 2: Make ProxyServer observable and expose isRunning + shared singleton

**Files:**
- Modify: `HttpRelay/ProxyServer.swift` (lines 1-21 for class header; lines 62-96 for start/stop)

- [ ] **Step 1: Add `@Observable` annotation and `import Observation`**

At the top of `HttpRelay/ProxyServer.swift`, replace:

```swift
import Foundation
import Network

final class ProxyServer {
```

with:

```swift
import Foundation
import Network
import Observation

@Observable
final class ProxyServer {
```

Note: `Observation` is the framework that provides `@Observable`. Adding the import is required for the macro to compile.

- [ ] **Step 2: Add `isRunning` property and `shared` singleton slot**

Inside the `ProxyServer` class declaration (after `var onLocalIPReady: ((String) -> Void)?` on line 15), add these two new declarations:

```swift
    private(set) var isRunning: Bool = false

    static var shared: ProxyServer?
```

So the class now reads (lines 4-22 area):

```swift
@Observable
final class ProxyServer {
    typealias ConnectionHandler = (NWConnection) -> Void

    private let port: UInt16
    private var listener: NWListener?
    private let logStore: LogStore
    private let socks5Server: SOCKS5Server
    private var activeTunnels: [String: TunnelManager] = [:]
    private let tunnelsLock = NSLock()
    private(set) var localIP: String = "—"

    var onLocalIPReady: ((String) -> Void)?

    private(set) var isRunning: Bool = false

    static var shared: ProxyServer?
```

- [ ] **Step 3: Set `isRunning = true` at the end of `start()`**

In `start()` (line 62), the body currently ends with `listener?.start(queue: .main)`. Replace that final line so the method ends with:

```swift
        listener?.start(queue: .main)
        isRunning = true
    }
```

The full `start()` method should now be:

```swift
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[ProxyServer] listening on port \(self.port)")
                self.localIP = self.getLocalIPAddress() ?? "—"
                print("[ProxyServer] local IP: \(self.localIP)")
                self.socks5Server.setLocalIP(self.localIP)
                self.onLocalIPReady?(self.localIP)
            case .failed(let error):
                print("[ProxyServer] failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            print("[ProxyServer] new connection from \(connection.endpoint)")
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: .main)
        isRunning = true
    }
```

- [ ] **Step 4: Set `isRunning = false` at the end of `stop()`**

In `stop()` (line 92), the body is currently:

```swift
    func stop() {
        listener?.cancel()
        listener = nil
        socks5Server.stop()
    }
```

Replace with:

```swift
    func stop() {
        listener?.cancel()
        listener = nil
        socks5Server.stop()
        isRunning = false
    }
```

- [ ] **Step 5: Build to verify**

```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `BUILD SUCCEEDED`. If "ambiguous use of 'isRunning'" or similar errors appear, double-check `isRunning` is declared exactly once.

- [ ] **Step 6: Commit**

```bash
git add HttpRelay/ProxyServer.swift
git commit -m "feat: make ProxyServer observable; expose isRunning and shared singleton"
```

---

## Task 3: Wire scenePhase into HttpRelayApp

**Files:**
- Modify: `HttpRelay/HttpRelayApp.swift` (replace entire file)

- [ ] **Step 1: Replace HttpRelayApp.swift with the new content**

Replace the entire file with this exact content:

```swift
import SwiftUI

@main
struct HttpRelayApp: App {
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                BackgroundKeepaliveCoordinator.shared.start()
            case .active:
                BackgroundKeepaliveCoordinator.shared.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add HttpRelay/HttpRelayApp.swift
git commit -m "feat: react to scenePhase via BackgroundKeepaliveCoordinator"
```

---

## Task 4: Wire ContentView to ProxyServer.shared and observe isRunning

**Files:**
- Modify: `HttpRelay/ContentView.swift` (Toggle's `set:` block, lines 28-66)

- [ ] **Step 1: Set `ProxyServer.shared = proxyServer` when starting**

In the `Toggle("Enable Debugger Server", isOn: Binding(...))` setter block, find this section (around line 31):

```swift
                                let port = UInt16(portString) ?? 10808
                                proxyServer = ProxyServer(port: port, logStore: logStore)
                                proxyServer?.onLocalIPReady = { [self] ip in
```

Replace with:

```swift
                                let port = UInt16(portString) ?? 10808
                                proxyServer = ProxyServer(port: port, logStore: logStore)
                                ProxyServer.shared = proxyServer
                                proxyServer?.onLocalIPReady = { [self] ip in
```

The single added line is `ProxyServer.shared = proxyServer`. This makes the running proxy reachable from `BackgroundKeepaliveCoordinator.expire()`.

- [ ] **Step 2: Set `ProxyServer.shared = nil` when stopping**

In the same setter block, find the `else` branch (around line 57-65):

```swift
                            } else {
                                proxyServer?.stop()
                                proxyServer = nil
                                isRunning = false
                                startTime = nil
                                timer?.invalidate()
                                timer = nil
                                UIApplication.shared.isIdleTimerDisabled = false
                            }
```

Replace with:

```swift
                            } else {
                                proxyServer?.stop()
                                ProxyServer.shared = nil
                                proxyServer = nil
                                isRunning = false
                                startTime = nil
                                timer?.invalidate()
                                timer = nil
                                UIApplication.shared.isIdleTimerDisabled = false
                            }
```

The single added line is `ProxyServer.shared = nil`.

- [ ] **Step 3: Add `.onChange(of: proxyServer?.isRunning)` to observe expiration**

After the closing `}` of the `VStack(alignment: .leading, spacing: 16)` block (which is the outermost content view) but before `.padding()`, add a new `.onChange` modifier. Find this line near line 142:

```swift
            .padding()
            .navigationBarTitleDisplayMode(.inline)
```

Replace with:

```swift
            .padding()
            .onChange(of: proxyServer?.isRunning ?? false) { _, newValue in
                if !newValue && isRunning {
                    isRunning = false
                    startTime = nil
                    timer?.invalidate()
                    timer = nil
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
            .navigationBarTitleDisplayMode(.inline)
```

This handles the case where `ProxyServer.stop()` was called from outside (e.g. the coordinator's `expire()`) — we mirror the local UI state to match.

- [ ] **Step 4: Build to verify**

```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add HttpRelay/ContentView.swift
git commit -m "feat: wire ContentView to ProxyServer.shared; observe isRunning for expiration"
```

---

## Task 5: End-to-end build verification

**Files:** none — verification only

- [ ] **Step 1: Clean build**

```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' clean build
```
Expected: `BUILD SUCCEEDED`. Fix any compile errors before moving on.

- [ ] **Step 2: Confirm Info.plist is unchanged**

The spec requires NO Info.plist changes. Verify:

```bash
git diff main HEAD -- HttpRelay/Info.plist HttpRelay.xcodeproj/project.pbxproj
```

Expected: no output (no changes to Info.plist or pbxproj from the audio work).

- [ ] **Step 3: Manual smoke test on simulator**

```bash
open -a Simulator
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/HttpRelay-*/Build/Products/Debug-iphonesimulator/HttpRelay.app
xcrun simctl launch booted com.africamonkey.HttpRelay
```

Then in the running app:
1. Toggle "Enable Debugger Server" on.
2. Press Cmd+Shift+H to go home (simulating background).
3. Wait 5 seconds.
4. Return to app (Cmd+Shift+H is single press; tap the app icon).
5. Verify the app did not crash and the listener is still in the "Running" state.

Note: simulator does not enforce the same background-suspension as a real device. Real-device verification is needed for the spec's manual tests (Task 6).

- [ ] **Step 4: Commit any incidental fixes**

If steps 1-3 surfaced minor issues you fixed (typos, missing parens, etc.):
```bash
git add -A
git commit -m "fix: post-integration cleanup"
```

---

## Task 6: Manual verification checklist (real device, requires human)

**Files:** none — verification only

The spec defines 5 manual tests. Run them in order on a real iOS device. Each test must pass before the feature is "done."

- [ ] **Test 1 — Stay alive within 30s (core scenario)**
  1. Launch app, enable proxy.
  2. From a Windows client, send a request to confirm proxy works.
  3. Switch to WeChat (or any other app), scan a QR code, return to HttpRelay (should take < 30s).
  4. From Windows, send another request.
  5. **Expected:** Request succeeds; UI still shows "Running".

- [ ] **Test 2 — Expire after 30s**
  1. Enable proxy.
  2. Switch to WeChat, stay > 30 seconds.
  3. Return to HttpRelay.
  4. **Expected:** UI shows "Stopped"; user re-enables proxy.

- [ ] **Test 3 — Lock screen behavior**
  1. Enable proxy, lock the device.
  2. Wait 60 seconds, unlock.
  3. **Expected:** UI shows "Stopped".

- [ ] **Test 4 — No-op when proxy not running**
  1. Launch app, do NOT enable proxy.
  2. Switch to other apps, return.
  3. **Expected:** No crashes; no `beginBackgroundTask` calls (the guard short-circuits because `ProxyServer.shared == nil`).

- [ ] **Test 5 — Build clean on simulator**
  1. The simulator does not enforce real background-suspension. Smoke-test that the build still works on iPhone 17 Pro simulator and the app does not crash on launch.

---

## Self-Review Checklist

When all tasks above are done:

- [ ] All 4 file changes are committed (1 new file + 3 modified).
- [ ] `xcodebuild ... build` succeeds from a clean state.
- [ ] `Info.plist` is unchanged.
- [ ] At least tests 1, 2, 4 pass on a real device. (Tests 3 and 5 are bonus coverage; if any fail, investigate and fix before considering the feature complete.)
