# HttpRelay - Silent Background Keepalive (Design)

Date: 2026-09-17

## Background and Goal

HttpRelay is an iOS HTTP CONNECT proxy server. When the user briefly switches to another app (e.g. WeChat to scan a QR code), iOS suspends the app and the NWListener stops responding. The user wants the proxy to stay alive during these short absences (< 30s).

The previous designs (`background-heartbeat`, `status-sound-keepalive`) tried to keep the app alive indefinitely via `UIBackgroundModes: audio`. That approach is **high-risk for App Review** because audio background mode requires real audible content, and silent buffers + UI beeps don't satisfy Apple's reviewer scrutiny.

This design takes a different approach: **accept the 30-second background limit and use Apple's official `beginBackgroundTask` API to extend it silently**. No audio hack, no background mode declaration, no App Review risk.

## Goal

When the user switches to another app for ≤ 30 seconds, the proxy remains alive and accepts new connections. After 30 seconds without returning to foreground, the system kills the app and the proxy stops. The user simply re-enables the proxy when they return.

## Non-Goals

- No persistent background execution (Apple does not allow this for general TCP servers).
- No user notification when the 30s window expires (per user direction: silent).
- No UI indicator showing the keepalive state (per user direction: silent).
- No retry / auto-restart after expiry.

## Approach: silent 30-second extension

Use Apple's `UIApplication.beginBackgroundTask(withName:expirationHandler:)` API, triggered by SwiftUI's `@Environment(\.scenePhase)`. When `scenePhase == .background`, request 30 seconds of background execution time. When the user returns to foreground within that window, release the background task. When 30 seconds elapse without returning, the expiration handler stops the proxy cleanly so the UI reflects "Stopped".

This is the canonical Apple-recommended pattern for short-term background tasks. It is documented at https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:). No Info.plist declaration is required, and App Review will not flag it.

## Components

### `BackgroundKeepaliveCoordinator` (file: `HttpRelay/BackgroundKeepaliveCoordinator.swift`)

A `@MainActor` singleton that owns one `UIBackgroundTaskIdentifier`. Three public methods:

- `start()` — request a 30-second background task if not already active.
- `stop()` — release the background task.
- Private `expire()` — called by the system expiration handler; releases the task and calls `ProxyServer.shared?.stop()` so the UI flips to "Stopped".

```swift
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

### `HttpRelayApp` changes (file: `HttpRelay/HttpRelayApp.swift`)

Add `@Environment(\.scenePhase)` and react to phase changes:

```swift
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

### `ProxyServer` changes (file: `HttpRelay/ProxyServer.swift`)

Two changes:

1. Make the class `@Observable` (mirrors the `LogStore` pattern) so `isRunning` updates propagate to SwiftUI views automatically.

2. Expose:
   - `private(set) var isRunning: Bool = false` — set to `true` in `start()` after listener is ready, set to `false` in `stop()`.
   - `static var shared: ProxyServer?` — a mutable singleton slot.

**`ProxyServer` is now observed by ContentView**, so when the expiration handler calls `ProxyServer.shared?.stop()`, the `isRunning` flag flips to `false` and ContentView re-renders automatically — no manual sync needed.

**ContentView wiring** (must add these two lines):

```swift
// In the Toggle's setter, when proxy starts:
ProxyServer.shared = proxyServer

// In the Toggle's setter, when proxy stops:
ProxyServer.shared = nil
```

## Data flow

**Foreground → background:**
```
HttpRelayApp.scenePhase == .background
    → BackgroundKeepaliveCoordinator.shared.start()
        → guard ProxyServer.shared?.isRunning == true (skip if proxy not running)
        → guard taskID == .invalid (skip if already running)
        → UIApplication.shared.beginBackgroundTask(withName: "HttpRelay.Keepalive", expirationHandler: ...)
        → taskID = (new id)
```

**Background → foreground (within 30s):**
```
HttpRelayApp.scenePhase == .active
    → BackgroundKeepaliveCoordinator.shared.stop()
        → guard taskID != .invalid
        → UIApplication.shared.endBackgroundTask(taskID)
        → taskID = .invalid
```

**30s elapses without returning:**
```
iOS calls expiration handler (on main thread)
    → BackgroundKeepaliveCoordinator.expire()
        → stop() (releases task)
        → ProxyServer.shared?.stop()
            → NWListener.cancel
            → socks5Server.stop()
            → UIApplication.isIdleTimerDisabled = false
            → proxyServer.isRunning = false
                → ContentView observes via @Observable, re-renders
                → Status text flips to "Stopped", toggle flips off
```

## Lifecycle and Error Handling

| Scenario | Behavior |
|---|---|
| User enables proxy | ProxyServer.start() runs normally; no background task yet |
| User switches to WeChat within 30s | scenePhase.background → start() begins 30s task |
| User returns to HttpRelay within 30s | scenePhase.active → stop() releases the task; proxy keeps running |
| User away > 30s | expiration handler fires → expire() stops proxy; user sees "Stopped" |
| User enables proxy while in background (impossible by UI flow) | N/A — toggle requires foreground interaction |
| User starts proxy after already in background (also impossible) | N/A |
| `beginBackgroundTask` returns `.invalid` (rare — system denied) | taskID stays invalid; no extension; system suspends app per normal rules. Silent. |
| System pressure causes early expiration | Handled by same expire() path; proxy stops; UI flips to "Stopped" |
| User toggles proxy off while in foreground | Existing ProxyServer.stop() path; scenePhase.onChange does nothing extra |
| App killed by user (app switcher swipe) | background task released by iOS automatically; nothing to clean up |

## File changes

| File | Status | Description |
|---|---|---|
| `HttpRelay/BackgroundKeepaliveCoordinator.swift` | **NEW** | `@MainActor` singleton coordinating `beginBackgroundTask` calls |
| `HttpRelay/HttpRelayApp.swift` | Modify | Add `@Environment(\.scenePhase)` and `onChange` switch |
| `HttpRelay/ProxyServer.swift` | Modify | Add `@Observable` + `private(set) var isRunning: Bool = false` + `static var shared: ProxyServer?` |
| `HttpRelay/ContentView.swift` | Modify | Set `ProxyServer.shared = proxyServer` when enabling, `= nil` when disabling; observe `proxyServer.isRunning` reactively |

**Not touched:** `SettingsView.swift`, `LogStore.swift`, `LogEntry.swift`, `TunnelManager.swift`, `SOCKS5.swift`, `TutorialView.swift`, `AboutView.swift`, `Info.plist`.

## Testing / Verification

### Build
```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `BUILD SUCCEEDED`.

### Manual verification (real device)

1. **Stay alive within 30s (core scenario)**
   - Launch app, enable proxy.
   - From a Windows client, send a request to confirm proxy works.
   - Switch to WeChat, scan a QR code, return to HttpRelay (should take < 30s).
   - From Windows, send another request.
   - Expected: request succeeds; UI still shows "Running".

2. **Expire after 30s**
   - Enable proxy.
   - Switch to WeChat, stay > 30 seconds.
   - Return to HttpRelay.
   - Expected: UI shows "Stopped"; user re-enables proxy.

3. **Lock screen behavior**
   - Enable proxy, lock the device.
   - Wait 60 seconds, unlock.
   - Expected: UI shows "Stopped".

4. **No-op when proxy not running**
   - Launch app, do NOT enable proxy.
   - Switch to other apps, return.
   - Expected: no crashes; no background tasks requested (guard in start()).

5. **Build clean on simulator**
   - The simulator does not enforce real background-suspension. Smoke-test that the build still works on iPhone 17 Pro simulator.

### Unit tests

Not introduced. Consistent with project convention.

## Risks

- **iOS may reduce background time below 30s under resource pressure.** Acceptable — the expiration handler stops the proxy cleanly.
- **ScenePhase transitions can fire in unexpected sequences.** The `guard` checks in the coordinator handle the common cases. If iOS fires `.background` twice without an intervening `.active`, the second call is a no-op (taskID already set). Acceptable.
- **`ProxyServer.shared` is set by ContentView, not by the coordinator.** This is a small coupling, but matches the existing pattern (ContentView owns the proxy lifecycle). If the singleton is `nil` when `start()` is called, the coordinator's first `guard` short-circuits — no harm done.

## Reference

- Apple docs: https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:)
- Previous designs (superseded): `docs/superpowers/specs/2026-09-17-background-heartbeat-design.md`, `docs/superpowers/specs/2026-09-17-status-sound-keepalive-design.md`
